import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService

class CurrentSongProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Song? _currentSong;
  bool _isPlaying = false;
  bool _isLooping = false;
  bool _isShuffling = false;
  List<Song> _queue = [];
  int _currentIndex = -1; // Index in the _queue
  final Map<String, String> _urlCache = {}; // Cache for song URLs
  bool _isDownloadingSong = false; // Renamed from isLoading
  bool _isLoadingAudio = false; // New property for audio loading
  final Map<String, double> _downloadProgress = {}; // Track download progress
  Duration? _totalDuration; // To store the total duration of the current song

  String? _stationName;
  String? get stationName => _stationName;
  String? _stationFavicon;
  String? get stationFavicon => _stationFavicon;

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  bool get isShuffling => _isShuffling;
  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  bool get isDownloadingSong => _isDownloadingSong; // Getter for renamed property
  bool get isLoadingAudio => _isLoadingAudio; // Getter for new property
  Duration? get totalDuration => _totalDuration; // Getter for total duration
  Stream<Duration> get onPositionChanged => _audioPlayer.onPositionChanged; // Stream for playback position

  CurrentSongProvider() {
    _loadCurrentSongFromStorage(); // Load the last playing song and queue on initialization
    _audioPlayer.onDurationChanged.listen((duration) {
      _totalDuration = duration;
      notifyListeners();
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      // Handle song completion: play next, loop, or stop
      if (_isPlaying) { 
        if (_isLooping && _currentSong != null) {
          playSong(_currentSong!, isResumingOrLooping: true); 
        } else if (_queue.isNotEmpty) {
          playNext();
        } else {
          _isPlaying = false;
          _isLoadingAudio = false;
          notifyListeners(); 
        }
      }
    });
  }

  Future<void> _saveCurrentSongToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (_currentSong != null) {
      await prefs.setString('current_song', jsonEncode(_currentSong!.toJson()));
      await prefs.setInt('current_index', _currentIndex);
      List<String> queueJson = _queue.map((song) => jsonEncode(song.toJson())).toList();
      await prefs.setStringList('current_queue', queueJson);
    } else {
      await prefs.remove('current_song');
      await prefs.remove('current_index');
      await prefs.remove('current_queue');
    }
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song');
    if (songJson != null) {
      try {
        _currentSong = Song.fromJson(jsonDecode(songJson));
        _currentIndex = prefs.getInt('current_index') ?? -1;
        List<String>? queueJson = prefs.getStringList('current_queue');
        if (queueJson != null) {
          _queue = queueJson.map((sJson) => Song.fromJson(jsonDecode(sJson))).toList();
        }
        // Do not auto-play, just load the state. UI can decide to show it.
        // If _currentSong is not null, we might want to prepare the player or show info.
        // For now, just loading the data.
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song/queue from storage: $e');
        // Clear potentially corrupted data
        await prefs.remove('current_song');
        await prefs.remove('current_index');
        await prefs.remove('current_queue');
      }
    }
  }

  void playSong(Song song, {bool isResumingOrLooping = false}) async {
    _isLoadingAudio = true;
    if (!isResumingOrLooping) {
      _totalDuration = null;
    }
    // Update _currentSong with the new song instance.
    // This ensures that any modifications to 'song' (like download status)
    // are reflected in _currentSong if it's the same logical song.
    _currentSong = song;
    _stationName = song.title;
    _stationFavicon = song.albumArtUrl;
    notifyListeners();

    try {
      // _currentSong is now set to the song instance passed to this method.
      
      if (!isResumingOrLooping) {
        final indexInQueue = _queue.indexWhere((s) => s.id == _currentSong!.id);
        if (indexInQueue != -1) {
          _currentIndex = indexInQueue;
        } else {
          // Song not in queue, _currentIndex might be -1 or stale.
        }
      }

      String pathOrUrlToPlay;
      Source playerSource;

      bool playFromValidLocalFile = _currentSong!.isDownloaded &&
                                  _currentSong!.localFilePath != null &&
                                  _currentSong!.localFilePath!.isNotEmpty &&
                                  !_currentSong!.localFilePath!.startsWith('http://') &&
                                  !_currentSong!.localFilePath!.startsWith('https://');

      if (playFromValidLocalFile) {
        pathOrUrlToPlay = _currentSong!.localFilePath!;
        final file = File(pathOrUrlToPlay);
        if (await file.exists()) {
          debugPrint("Local file exists: $pathOrUrlToPlay. Using DeviceFileSource for song '${_currentSong!.title}'.");
          playerSource = DeviceFileSource(pathOrUrlToPlay);
        } else {
          // File is missing, this is a critical error in data consistency.
          debugPrint("CRITICAL ERROR: Song '${_currentSong!.title}' is marked as downloaded, but file is MISSING at $pathOrUrlToPlay.");
          debugPrint("This indicates a data inconsistency. Please check download and deletion logic.");
          
          // Correct the metadata for _currentSong
          // Create a new Song instance with corrected data
          Song correctedSong = _currentSong!.copyWith(isDownloaded: false, localFilePath: null);
          // _currentSong = correctedSong; // Update _currentSong to the corrected version
          // No, we pass correctedSong to the recursive call. The original 'song' parameter for this call
          // will be updated to correctedSong at the beginning of the *next* call to playSong.

          // Persist this correction immediately
          await _persistSongMetadata(correctedSong);
          
          // Also update it in the queue if it's there
          final indexInQueueIfPresent = _queue.indexWhere((s) => s.id == correctedSong.id);
          if (indexInQueueIfPresent != -1) {
            _queue[indexInQueueIfPresent] = correctedSong;
          }
          // Update in PlaylistManagerService
          PlaylistManagerService().updateSongInPlaylists(correctedSong);

          // Notify UI about the metadata change before retrying
          // We need to update _currentSong here if it was the one being played,
          // so the UI reflects the change *before* the retry potentially shows loading again.
          if (_currentSong?.id == correctedSong.id) {
            _currentSong = correctedSong;
          }
          notifyListeners(); // Notify for metadata change

          // Retry playing the song with corrected metadata (it will now stream)
          debugPrint("Retrying playback for '${correctedSong.title}' after metadata correction.");
          // The playSong call will set _isLoadingAudio = true again.
          // It will also update _currentSong = correctedSong at its start.
          playSong(correctedSong, isResumingOrLooping: isResumingOrLooping);
          return; // Exit this execution path as a new one has started.
        }
      } else {
        // Logic for streaming if not a valid local file
        if (_currentSong!.isDownloaded && (_currentSong!.localFilePath == null || _currentSong!.localFilePath!.isEmpty || _currentSong!.localFilePath!.startsWith('http'))) {
          debugPrint("Warning: Song '${_currentSong!.title}' is marked downloaded but localFilePath is invalid ('${_currentSong!.localFilePath}'). Attempting to stream.");
          // This state is problematic. Consider correcting metadata here too.
          // For now, it proceeds to stream. If this also fails, the error below will be caught.
        }

        pathOrUrlToPlay = _urlCache[_currentSong!.id] ?? '';

        if (pathOrUrlToPlay.isEmpty || !(Uri.tryParse(pathOrUrlToPlay)?.isAbsolute ?? false)) {
          if (_currentSong!.audioUrl.isNotEmpty && (Uri.tryParse(_currentSong!.audioUrl)?.isAbsolute ?? false)) {
            pathOrUrlToPlay = _currentSong!.audioUrl;
          } else {
            pathOrUrlToPlay = await fetchSongUrl(_currentSong!);
          }
          
          if (pathOrUrlToPlay.isNotEmpty && (Uri.tryParse(pathOrUrlToPlay)?.isAbsolute ?? false)) {
            _urlCache[_currentSong!.id] = pathOrUrlToPlay;
          }
        }
        
        final parsedUri = Uri.tryParse(pathOrUrlToPlay);
        if (pathOrUrlToPlay.isEmpty || parsedUri == null || !parsedUri.isAbsolute || !parsedUri.hasScheme) {
          throw Exception('Invalid or missing audio URL for streaming for song "${_currentSong!.title}": "$pathOrUrlToPlay"');
        }
        debugPrint("Attempting to play from URL: $pathOrUrlToPlay for song '${_currentSong!.title}'");
        playerSource = UrlSource(pathOrUrlToPlay);
      }

      await _audioPlayer.play(playerSource);

      _isPlaying = true;
      _isLoadingAudio = false;
      notifyListeners();

      _prefetchNextSongs();
      _saveCurrentSongToStorage();
    } catch (e) {
      debugPrint('Error playing song (${_currentSong?.title}): $e');
      _isLoadingAudio = false;
      _isPlaying = false;
      _totalDuration = null;
      notifyListeners();
    }
  }

  Future<String> fetchSongUrl(Song song) async {
    // If song is downloaded and localFilePath is a valid, non-URL path
    if (song.isDownloaded &&
        song.localFilePath != null &&
        song.localFilePath!.isNotEmpty &&
        !song.localFilePath!.startsWith('http://') &&
        !song.localFilePath!.startsWith('https://')) {
      return song.localFilePath!;
    }

    // If not downloaded, or localFilePath is invalid (e.g., a URL, empty)
    // Try direct audioUrl if it's a valid absolute URL
    if (song.audioUrl.isNotEmpty && (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false)) {
      return song.audioUrl;
    }

    // Fallback: try to fetch from API
    final apiService = ApiService();
    final fetchedUrl = await apiService.fetchAudioUrl(song.artist, song.title);
    return fetchedUrl ?? '';
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndex == -1) return;

    for (int i = 1; i <= 3; i++) {
      final nextIndex = _currentIndex + i;
      if (nextIndex < _queue.length) {
        final nextSong = _queue[nextIndex];
        if (!_urlCache.containsKey(nextSong.id)) {
          final url = await fetchSongUrl(nextSong);
          _urlCache[nextSong.id] = url;
        }
      }
    }
  }

  void pauseSong() async {
    await _audioPlayer.pause();
    _isPlaying = false;
    _isLoadingAudio = false; // No longer loading when paused
    notifyListeners();
  }

  void resumeSong() async {
    if (currentSong != null) {
      _isLoadingAudio = true;
      notifyListeners();
      try {
        await _audioPlayer.resume();
        _isPlaying = true;
        _isLoadingAudio = false;
        notifyListeners();
      } catch (e) {
        debugPrint('Error resuming song: $e');
        _isLoadingAudio = false;
        // Potentially try to play the song from start if resume fails
        // playSong(currentSong!, isResumingOrLooping: true);
        notifyListeners();
      }
    }
  }

  void stopSong() async {
    await _audioPlayer.stop();
    _currentSong = null;
    _isPlaying = false;
    _isLoadingAudio = false;
    _totalDuration = null; 
    _currentIndex = -1; // Reset current index
    // _queue = []; // Optionally clear queue on stop, or retain for later
    notifyListeners();

    // Clear the saved song, index, and queue when playback stops explicitly
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_song');
    await prefs.remove('current_index');
    await prefs.remove('current_queue');
  }

  void toggleLoop() {
    _isLooping = !_isLooping;
    _audioPlayer.setReleaseMode(
      _isLooping ? ReleaseMode.loop : ReleaseMode.stop,
    );
    notifyListeners();
  }

  void toggleShuffle() {
    _isShuffling = !_isShuffling;
    notifyListeners();
  }

  void setQueue(List<Song> songs, {int initialIndex = 0}) {
    _queue = List.from(songs); // Make a copy
    if (_queue.isNotEmpty && initialIndex < _queue.length && initialIndex >= 0) {
      _currentIndex = initialIndex;
      // Optionally, play the song at initialIndex if not already playing or if it's different
      // if (_currentSong == null || _currentSong!.id != _queue[_currentIndex].id) {
      //   playSong(_queue[_currentIndex]);
      // }
    } else if (_queue.isEmpty) {
      _currentIndex = -1;
      // if (_currentSong != null) stopSong(); // Stop if queue becomes empty
    } else {
       _currentIndex = _queue.isNotEmpty ? 0 : -1; // Default to first song or -1
    }
    notifyListeners();
    _saveCurrentSongToStorage(); // Save queue when it's set
  }

  void playPrevious() {
    if (_queue.isNotEmpty) {
      if (_isShuffling) {
        // Simple shuffle: pick a random song that's not the current one
        if (_queue.length > 1) {
          int newIndex;
          do {
            newIndex = (DateTime.now().millisecondsSinceEpoch % _queue.length);
          } while (newIndex == _currentIndex);
          _currentIndex = newIndex;
        } else {
          _currentIndex = 0; // Only one song, play it
        }
      } else { // Sequential
        if (_currentIndex > 0) {
          _currentIndex--;
        } else {
          _currentIndex = _queue.length - 1; // Loop to end
        }
      }
      playSong(_queue[_currentIndex]);
    }
  }

  void playNext() {
    if (_queue.isNotEmpty) {
      if (_isShuffling) {
        if (_queue.length > 1) {
          int newIndex;
          do {
            newIndex = (DateTime.now().millisecondsSinceEpoch % _queue.length);
          } while (newIndex == _currentIndex);
          _currentIndex = newIndex;
        } else {
           _currentIndex = 0; // Only one song
        }
      } else { // Sequential
        if (_currentIndex < _queue.length - 1) {
          _currentIndex++;
        } else {
          _currentIndex = 0; // Loop to start
        }
      }
      if (_currentIndex < _queue.length && _currentIndex >= 0) {
        playSong(_queue[_currentIndex]);
      } else if (_queue.isNotEmpty) { // Fallback if index somehow got out of bounds
        _currentIndex = 0;
        playSong(_queue[_currentIndex]);
      } else {
        // Queue is empty, or became empty. Stop playback.
        _isPlaying = false;
        _isLoadingAudio = false;
        _currentSong = null;
        notifyListeners();
      }
    } else {
        _isPlaying = false;
        _isLoadingAudio = false;
        _currentSong = null;
        notifyListeners();
    }
  }

  void downloadSong(Song song) {
    _isDownloadingSong = true;
    notifyListeners();
    // Implement download logic here
    debugPrint('Downloading song: ${song.title}');
    _isDownloadingSong = false;
    notifyListeners();
  }

  void addToQueue(Song song) {
    if (!_queue.any((s) => s.id == song.id)) {
      _queue.add(song);
      if (_currentIndex == -1 && _queue.length == 1) { // If queue was empty, this is now the current song
        _currentIndex = 0;
        // Optionally play it if nothing is playing
        // if (!_isPlaying && _currentSong == null) playSong(song);
      }
      notifyListeners();
      _saveCurrentSongToStorage(); // Save queue when modified
    }
  }

  Future<void> clearQueue() async {
    _queue.clear();
    _currentIndex = -1;
    // Optionally stop the current song if it's no longer in any logical queue context
    // For now, we'll let it continue playing if it was, but it won't be part of "next"
    // Or, uncomment to stop:
    // if (_currentSong != null && !_queue.any((s) => s.id == _currentSong!.id)) {
    //   await _audioPlayer.stop();
    //   _currentSong = null;
    //   _isPlaying = false;
    //   _isLoadingAudio = false;
    //   _totalDuration = null;
    // }
    notifyListeners();
    // Clear queue from storage
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_queue');
    await prefs.remove('current_index'); // Also clear index as queue is empty
    // Decide if current_song should also be cleared if queue is cleared.
    // For now, keeping current_song, but it won't have a queue context.
  }

  // Helper to persist individual song metadata
  Future<void> _persistSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  void updateSongDetails(Song updatedSong) {
    bool changedInProvider = false;
    // Update in queue
    final indexInQueue = _queue.indexWhere((s) => s.id == updatedSong.id);
    if (indexInQueue != -1) {
      _queue[indexInQueue] = updatedSong;
      changedInProvider = true;
    }
    // Update current song if it's the one
    if (_currentSong?.id == updatedSong.id) {
      _currentSong = updatedSong;
      changedInProvider = true;
    }

    if (changedInProvider) {
      notifyListeners();
      _saveCurrentSongToStorage(); // Persist changes to current song/queue state
    }
    // Also ensure the general song metadata in SharedPreferences is up-to-date
    _persistSongMetadata(updatedSong);
  }


  Future<void> downloadSongInBackground(Song song) async {
    _isDownloadingSong = true;
    notifyListeners();
    String? audioUrl;
    try {
      final apiService = ApiService();
      audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      if (audioUrl == null) {
        debugPrint('Failed to fetch audio URL.');
        _isDownloadingSong = false;
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('Error fetching audio URL: $e');
      _isDownloadingSong = false;
      notifyListeners();
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      // Sanitize the song title to create a valid filename
      final String sanitizedTitle = song.title
          .replaceAll(RegExp(r'[^\w\s.-]'), '_') // Replace invalid chars with underscore
          .replaceAll(RegExp(r'\s+'), '_'); // Replace spaces with underscore for cleaner names
      final filePath = '${directory.path}/$sanitizedTitle.mp3';
      final url = audioUrl;

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          if (totalBytes != null) {
            _downloadProgress[song.id] = bytes.length / totalBytes; // Use song.id as key
            notifyListeners(); // Notify listeners to update UI
          }
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          
          // Update the song instance directly
          song.localFilePath = filePath;
          song.isDownloaded = true;
          
          _downloadProgress.remove(song.id); 
          _isDownloadingSong = false;

          // Persist the updated song metadata
          await _persistSongMetadata(song);

          // Update the song in the provider's state (queue, currentSong)
          final indexInQueue = _queue.indexWhere((s) => s.id == song.id);
          if (indexInQueue != -1) {
            _queue[indexInQueue] = song;
          }
          if (_currentSong?.id == song.id) {
            _currentSong = song;
          }

          // Notify PlaylistManagerService
          PlaylistManagerService().updateSongInPlaylists(song);

          notifyListeners();
          debugPrint('Download complete!');
          _saveCurrentSongToStorage(); // Save if current song or queue was updated
        },
        onError: (e) {
          debugPrint('Download failed: $e');
          _downloadProgress.remove(song.id); // Use song.id as key
          _isDownloadingSong = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('Error downloading song: $e');
      _downloadProgress.remove(song.id); // Use song.id as key
      _isDownloadingSong = false;
      notifyListeners();
    }
  }

  void playStream(String streamUrl, {required String stationName, String? stationFavicon}) {
    _stationName = stationName;
    _stationFavicon = stationFavicon;
    _isLoadingAudio = true;
    _totalDuration = null; 
    notifyListeners();

    // ignore: unused_local_variable
    Song radioSong = Song(
      id: 'radio_${stationName.hashCode}_${streamUrl.hashCode}', // More unique ID for radio
      title: stationName,
      artist: 'Radio Station',
      albumArtUrl: stationFavicon ?? '',
      audioUrl: streamUrl,
      localFilePath: null,
      isDownloaded: false,
    );
    notifyListeners();

    _audioPlayer.play(UrlSource(streamUrl));
    _isPlaying = true;
    _isLoadingAudio = false;
    // For streams, onDurationChanged might not fire or might give irrelevant data.
    // _totalDuration remains null or could be set to a conventional value if needed.
    notifyListeners();

    // The global onPlayerComplete listener should handle stream completion/errors if applicable
    // The specific listener below might be redundant or could be specialized for streams
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        if (_isLooping) {
          playStream(streamUrl, stationName: stationName, stationFavicon: stationFavicon);
        } else {
          // Let global onPlayerComplete handle this, or stop explicitly
          // stopSong(); 
        }
      }
    });
  }

  void playUrl(String url) {
    // Implement the logic to play the audio from the given URL
    print('Playing URL: $url');
    // Notify listeners if needed
    notifyListeners();
  }

  void setCurrentSong(Song song) {
    _currentSong = song;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
    // Position will update via onPositionChanged stream
  }
}

