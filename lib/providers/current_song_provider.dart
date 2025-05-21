import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class CurrentSongProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Song? _currentSong;
  bool _isPlaying = false;
  bool _isLooping = false;
  bool _isShuffling = false;
  List<Song> _queue = [];
  int _currentIndex = -1;
  final Map<String, String> _urlCache = {}; // Cache for song URLs
  bool _isDownloadingSong = false; // Renamed from isLoading
  bool _isLoadingAudio = false; // New property for audio loading
  final Map<String, double> _downloadProgress = {}; // Track download progress
  Duration? _totalDuration; // To store the total duration of the current song

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
    _loadCurrentSongFromStorage(); // Load the last playing song on initialization
    _audioPlayer.onDurationChanged.listen((duration) {
      _totalDuration = duration;
      notifyListeners();
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      // Handle song completion: play next, loop, or stop
      if (_isPlaying) { // Ensure action is taken only if it was playing
        if (_isLooping && _currentSong != null) {
          // Replay the current song
          playSong(_currentSong!); 
        } else if (_currentIndex != -1 && _currentIndex < _queue.length - 1 && !_isLooping) {
          // Play next song if not looping and not at the end of the queue
          playNext();
        } else {
          // If no loop, no shuffle, and at the end of queue, or no queue
          _isPlaying = false;
          _isLoadingAudio = false;
          // Optionally, call stopSong() or just update UI
          // For now, just update state and notify. If stopSong() is desired, ensure it doesn't clear essential state for UI.
          notifyListeners(); 
        }
      }
    });
  }

  Future<void> _saveCurrentSongToStorage() async {
    if (_currentSong != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_song', jsonEncode(_currentSong!.toJson()));
    }
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song');
    if (songJson != null) {
      try {
        _currentSong = Song.fromJson(jsonDecode(songJson));
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song: $e');
      }
    }
  }

  void playSong(Song song) async {
    _isLoadingAudio = true;
    _totalDuration = null; // Reset duration for the new song
    notifyListeners();

    try {
      _currentSong = song;
      String sourceUrl = _urlCache[song.id] ?? song.effectiveAudioUrl;

      if (sourceUrl.isEmpty) {
        // Fetch and cache the URL if not already cached
        sourceUrl = await fetchSongUrl(song);
        _urlCache[song.id] = sourceUrl;
      }

      // Validate the URL
      final parsedUri = Uri.tryParse(sourceUrl);
      if (parsedUri == null || !parsedUri.hasAbsolutePath) {
        throw Exception('Invalid audio URL: $sourceUrl');
      }

      if (song.isDownloaded) {
        await _audioPlayer.play(DeviceFileSource(sourceUrl));
      } else {
        await _audioPlayer.play(UrlSource(sourceUrl));
      }

      _isPlaying = true;
      _isLoadingAudio = false;
      // Duration will be updated by onDurationChanged listener
      notifyListeners();

      // Pre-fetch the next 3 songs in the queue
      _prefetchNextSongs();
      _saveCurrentSongToStorage(); // Save the current song when it starts playing
    } catch (e) {
      debugPrint('Error playing song: $e');
      _isLoadingAudio = false;
      _totalDuration = null;
      stopSong(); // stopSong will also notifyListeners
      // Notify the user about the error
      // notifyListeners(); // Already notified by stopSong or explicitly if stopSong doesn't
    }
  }

  Future<String> fetchSongUrl(Song song) async {
    // Simulate fetching the song URL (replace with actual API call if needed)
    return song.audioUrl;
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
        notifyListeners();
      }
    }
  }

  void stopSong() async {
    await _audioPlayer.stop();
    _currentSong = null;
    _isPlaying = false;
    _isLoadingAudio = false;
    _totalDuration = null; // Clear duration when song stops
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_song'); // Clear the saved song when playback stops
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

  void setQueue(List<Song> songs) {
    _queue = songs;
    _currentIndex = songs.isNotEmpty ? 0 : -1;
    notifyListeners();
  }

  void playPrevious() {
    if (_queue.isNotEmpty && _currentIndex > 0) {
      _currentIndex--;
      playSong(_queue[_currentIndex]);
    }
  }

  void playNext() {
    if (_queue.isNotEmpty) {
      if (_isShuffling) {
        // Implement shuffle logic if desired, e.g., pick a random index
        // For now, let's stick to sequential for simplicity or assume shuffle modifies queue order
        if (_currentIndex < _queue.length - 1) {
           _currentIndex++;
        } else {
          _currentIndex = 0; // Loop back or stop, depending on desired shuffle behavior
        }
      } else {
        if (_currentIndex < _queue.length - 1) {
          _currentIndex++;
        } else {
          // Reached end of queue, optionally stop or loop to beginning
          // For now, do nothing if at the end and not looping/shuffling
          // The onPlayerComplete listener will handle this better.
          return; 
        }
      }
      playSong(_queue[_currentIndex]);
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
    _queue.add(song);
    notifyListeners();
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
      final filePath = '${directory.path}/${song.title}.mp3';
      final url = audioUrl;

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          if (totalBytes != null) {
            _downloadProgress[song.title] = bytes.length / totalBytes;
            notifyListeners(); // Notify listeners to update UI
          }
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          song.localFilePath = filePath;
          song.isDownloaded = true;
          _downloadProgress.remove(song.title);
          _isDownloadingSong = false;
          notifyListeners();
          debugPrint('Download complete!');
        },
        onError: (e) {
          debugPrint('Download failed: $e');
          _downloadProgress.remove(song.title);
          _isDownloadingSong = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('Error downloading song: $e');
      _downloadProgress.remove(song.title);
      _isDownloadingSong = false;
      notifyListeners();
    }
  }

  void playStream(String streamUrl, {required String stationName, String? stationFavicon}) {
    _isLoadingAudio = true;
    _totalDuration = null; // Radio streams might not have a fixed duration or it might be irrelevant
    notifyListeners();

    _currentSong = Song(
      id: DateTime.now().toString(),
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

