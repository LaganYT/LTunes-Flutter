import 'package:flutter/material.dart';
// import 'package:audioplayers/audioplayers.dart'; // No longer directly used here
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:path/path.dart' as p; // Import path package
import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart'; // Assumed path to your audio_handler.dart
import 'dart:async';

// Define LoopMode enum
enum LoopMode { none, queue, song }

class CurrentSongProvider with ChangeNotifier {
  // final AudioPlayer _audioPlayer = AudioPlayer(); // Removed
  final AudioHandler _audioHandler;
  Song? _currentSongFromAppLogic; // Represents the song our app thinks is current
  bool _isPlaying = false;
  // bool _isLooping = false; // Replaced by LoopMode logic derived from audio_handler
  // bool _isShuffling = false; // Handled by audio_handler's shuffleMode
  List<Song> _queue = [];
  int _currentIndexInAppQueue = -1; // Index in the _queue (app's perspective)

  // bool _isDownloadingSong = false; // Removed
  final Map<String, Song> _activeDownloads = {}; // Added
  bool _isLoadingAudio = false; // For UI feedback when initiating play
  final Map<String, double> _downloadProgress = {};
  Duration _currentPosition = Duration.zero;
  Duration? _totalDuration;

  // Radio specific, might be derivable from MediaItem
  String? _stationName;
  String? get stationName => _stationName;
  String? _stationFavicon;
  String? get stationFavicon => _stationFavicon;

  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _mediaItemSubscription;
  StreamSubscription? _queueSubscription;
  StreamSubscription? _positionSubscription;


  Song? get currentSong => _currentSongFromAppLogic;
  bool get isPlaying => _isPlaying;

  // Getter for LoopMode based on AudioHandler's state
  LoopMode get loopMode {
    final currentAudioHandlerMode = _audioHandler.playbackState.value.repeatMode;
    switch (currentAudioHandlerMode) {
      case AudioServiceRepeatMode.none:
        return LoopMode.none;
      case AudioServiceRepeatMode.all:
        return LoopMode.queue;
      case AudioServiceRepeatMode.one:
        return LoopMode.song;
      default: // group or other unhandled states
        return LoopMode.none;
    }
  }

  bool get isShuffling {
    return _audioHandler.playbackState.value.shuffleMode == AudioServiceShuffleMode.all;
  }


  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  // bool get isDownloadingSong => _isDownloadingSong; // Changed
  bool get isDownloadingSong => _downloadProgress.isNotEmpty; // Changed
  Map<String, Song> get activeDownloadTasks => Map.unmodifiable(_activeDownloads); // Added
  bool get isLoadingAudio => _isLoadingAudio;
  Duration? get totalDuration => _totalDuration;
  // Stream<Duration> get onPositionChanged => _audioPlayer.onPositionChanged; // Replaced
  Stream<Duration> get onPositionChanged => AudioService.position;

  bool get isCurrentlyPlayingRadio {
    final mediaItem = _audioHandler.mediaItem.value;
    return mediaItem?.extras?['isRadio'] as bool? ?? false;
  }


  CurrentSongProvider(this._audioHandler) {
    _loadCurrentSongFromStorage(); // Load last playing song and queue
    _listenToAudioHandler();
  }

  void _listenToAudioHandler() {
    _playbackStateSubscription = _audioHandler.playbackState.listen((playbackState) {
      final oldIsPlaying = _isPlaying;
      final oldIsLoading = _isLoadingAudio;
      final oldTotalDuration = _totalDuration;

      _isPlaying = playbackState.playing;
      _isLoadingAudio = playbackState.processingState == AudioProcessingState.loading ||
                        playbackState.processingState == AudioProcessingState.buffering;
      
      // Update total duration from playbackState if available
      // MediaItem's duration is the primary source, but playbackState might update it too.
      final mediaItem = _audioHandler.mediaItem.value;
      if (mediaItem?.duration != null && mediaItem!.duration != Duration.zero) {
        _totalDuration = mediaItem.duration;
      }


      if (oldIsPlaying != _isPlaying || oldIsLoading != _isLoadingAudio || oldTotalDuration != _totalDuration) {
        notifyListeners();
      }
    });

    _mediaItemSubscription = _audioHandler.mediaItem.listen((mediaItem) async {
      if (mediaItem == null) {
        _currentSongFromAppLogic = null;
        _totalDuration = null; // Clear duration when no media item
        _stationName = null;
        _stationFavicon = null;
      } else {
        // Update total duration from MediaItem if available and different
        if (mediaItem.duration != null && mediaItem.duration != _totalDuration) {
            _totalDuration = mediaItem.duration;
        }

        if (mediaItem.extras?['isRadio'] as bool? ?? false) {
            _currentSongFromAppLogic = Song(
                id: mediaItem.extras!['songId'] as String? ?? mediaItem.id,
                title: mediaItem.title,
                artist: mediaItem.artist ?? 'Radio',
                albumArtUrl: mediaItem.artUri?.toString() ?? '',
                audioUrl: mediaItem.id, // For radio, id is the stream URL
                isDownloaded: false
            );
            _stationName = _currentSongFromAppLogic?.title;
            _stationFavicon = _currentSongFromAppLogic?.albumArtUrl;
        } else{
            final songId = mediaItem.extras?['songId'] as String?;
            if (songId != null) {
                _currentSongFromAppLogic = _queue.firstWhere((s) => s.id == songId,
                    orElse: () {
                        return Song( // Fallback if not in queue (e.g., played from notification)
                            id: songId,
                            title: mediaItem.title,
                            artist: mediaItem.artist ?? 'Unknown Artist',
                            album: mediaItem.album,
                            albumArtUrl: mediaItem.artUri?.toString() ?? '', // Use artUri directly for fallback
                            audioUrl: mediaItem.id, // id is the playable URL/path
                            isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                            localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false) ? p.basename(mediaItem.id) : null
                        );
                    });
            } else {
                 // If no songId in extras, construct a basic Song object
                _currentSongFromAppLogic = Song(
                    id: mediaItem.id, // Use mediaItem.id as a fallback song ID
                    title: mediaItem.title,
                    artist: mediaItem.artist ?? 'Unknown Artist',
                    album: mediaItem.album,
                    albumArtUrl: await _resolveArtUriPath(mediaItem),
                    audioUrl: mediaItem.id,
                    isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                    localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false) ? p.basename(mediaItem.id) : null
                );
            }
            _stationName = null;
            _stationFavicon = null;
        }
      }
      notifyListeners();
    });

    // Listen to queue changes from audio_handler (e.g. if modified by notification controls)
    // This part can be complex to keep app's queue and handler's queue in sync.
    // For now, we assume CurrentSongProvider is the main source of truth for queue modification.
    // _queueSubscription = _audioHandler.queue.listen((handlerQueue) { ... });


    // Position stream for UI slider
    _positionSubscription = AudioService.position.listen((position) {
      if (_currentPosition != position) {
        _currentPosition = position;
        // If it's a radio stream, we might update totalDuration to reflect elapsed time
        if (_currentSongFromAppLogic != null && (_currentSongFromAppLogic!.id.startsWith('radio_') || (_audioHandler.mediaItem.value?.extras?['isRadio'] as bool? ?? false))) {
            if (_totalDuration != position) {
                 _totalDuration = position; // Make duration "live" for radio
                 // notifyListeners(); // This can cause too many rebuilds, UI should listen to AudioService.position directly
            }
        }
        // notifyListeners(); // Let UI listen to AudioService.position directly for slider updates
      }
    });
  }

  Future<String> _resolveArtUriPath(MediaItem item) async {
    if (item.artUri != null && item.artUri.toString().startsWith('http')) {
      return item.artUri.toString();
    }
    if (item.extras?['localArtFileName'] != null) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, item.extras!['localArtFileName'] as String);
      if (await File(fullPath).exists()) {
        // For local files, albumArtUrl in Song model should store filename.
        // If artUri was file://, this logic might need adjustment.
        // Here, we return the filename as stored in Song model.
        return item.extras!['localArtFileName'] as String;
      }
    }
    // Fallback to artUri if it exists, otherwise empty.
    return item.artUri?.toString() ?? '';
  }


  @override
  void dispose() {
    _playbackStateSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _queueSubscription?.cancel();
    _positionSubscription?.cancel();
    // _audioHandler.stop(); // Optional: stop playback when provider is disposed
    super.dispose();
  }


  Future<void> _saveCurrentSongToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (_currentSongFromAppLogic != null) {
      await prefs.setString('current_song_v2', jsonEncode(_currentSongFromAppLogic!.toJson()));
      await prefs.setInt('current_index_v2', _currentIndexInAppQueue);
      List<String> queueJson = _queue.map((song) => jsonEncode(song.toJson())).toList();
      await prefs.setStringList('current_queue_v2', queueJson);
    } else {
      await prefs.remove('current_song_v2');
      await prefs.remove('current_index_v2');
      await prefs.remove('current_queue_v2');
    }
    // Save loop mode
    await prefs.setInt('loop_mode_v2', _audioHandler.playbackState.value.repeatMode.index);
    // Save shuffle mode
    await prefs.setBool('shuffle_mode_v2', _audioHandler.playbackState.value.shuffleMode == AudioServiceShuffleMode.all);
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song_v2');
    
    // Load and set loop mode
    final savedLoopModeIndex = prefs.getInt('loop_mode_v2');
    if (savedLoopModeIndex != null && savedLoopModeIndex < AudioServiceRepeatMode.values.length) {
      await _audioHandler.setRepeatMode(AudioServiceRepeatMode.values[savedLoopModeIndex]);
    }

    // Load and set shuffle mode
    final savedShuffleMode = prefs.getBool('shuffle_mode_v2') ?? false;
    await _audioHandler.setShuffleMode(savedShuffleMode ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);

    if (songJson != null) {
      try {
        Map<String, dynamic> songMap = jsonDecode(songJson);
        Song loadedSong = Song.fromJson(songMap);
        // Migration logic for file paths (if any) should be in Song.fromJson or here
        
        // Check if the loaded song is a radio stream
        bool isRadioStream = loadedSong.id.startsWith('radio_') || (loadedSong.extras?['isRadio'] as bool? ?? false);


        _currentSongFromAppLogic = loadedSong;
        _currentIndexInAppQueue = prefs.getInt('current_index_v2') ?? -1;
        List<String>? queueJsonStrings = prefs.getStringList('current_queue_v2');
        if (queueJsonStrings != null) {
          _queue = queueJsonStrings.map((sJson) => Song.fromJson(jsonDecode(sJson))).toList();
        }

        // Restore state to audio_handler
        if (!isRadioStream && _queue.isNotEmpty && _currentIndexInAppQueue != -1 && _currentIndexInAppQueue < _queue.length) {
          final mediaItems = await Future.wait(_queue.map((s) async => await _prepareMediaItem(s)).toList());
          await _audioHandler.updateQueue(mediaItems);
          await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
          await _audioHandler.pause(); 

        } else if (_currentSongFromAppLogic != null) { // Handles single song or radio stream
            // For radio, fetchSongUrl will just return its existing audioUrl (the stream URL)
            // For regular song, it will fetch if necessary.
            final playableUrl = await fetchSongUrl(_currentSongFromAppLogic!); 
            final mediaItem = songToMediaItem(_currentSongFromAppLogic!, playableUrl, null);
            
            // If it's a radio stream, set its specific properties from the loaded song
            if (isRadioStream) {
                _stationName = _currentSongFromAppLogic!.title;
                _stationFavicon = _currentSongFromAppLogic!.albumArtUrl;
                // Ensure mediaItem for radio has 'isRadio' extra
                final radioExtras = Map<String, dynamic>.from(mediaItem.extras ?? {});
                radioExtras['isRadio'] = true;
                radioExtras['songId'] = _currentSongFromAppLogic!.id; // Ensure original radio songId is used
                final radioMediaItem = mediaItem.copyWith(extras: radioExtras, id: _currentSongFromAppLogic!.audioUrl, title: _stationName ?? 'Unknown Station', artist: "Radio Station");
                await _audioHandler.playMediaItem(radioMediaItem); // Use playMediaItem for consistency
                await _audioHandler.pause();


            } else {
                 await _audioHandler.updateQueue([mediaItem]);
                 await _audioHandler.skipToQueueItem(0);
                 await _audioHandler.pause();
            }
        }
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song/queue from storage (v2): $e');
        await prefs.remove('current_song_v2');
        await prefs.remove('current_index_v2');
        await prefs.remove('current_queue_v2');
      }
    }
  }

  Future<MediaItem> _prepareMediaItem(Song song) async {
    // _isLoadingAudio = true; // Removed: Handled by the calling context (e.g., playSong)
    // notifyListeners(); // Removed: Handled by the calling context

    String playableUrl = await fetchSongUrl(song);
    if (playableUrl.isEmpty) {
      throw Exception('Could not resolve playable URL for ${song.title}');
    }
    
    Duration? songDuration;
    if (song.isDownloaded && song.localFilePath != null && !song.localFilePath!.startsWith('http')) {
        // For local files, audioplayers can get duration.
        // We'll let the handler's onDurationChanged update it.
    }
    // For streams, duration is often unknown until playback starts or comes from metadata.

    Song songForMediaItem = song; // Start with the passed song instance

    // Update song.audioUrl if a new one was fetched and different
    if (playableUrl != song.audioUrl && !song.isDownloaded) {
        songForMediaItem = song.copyWith(audioUrl: playableUrl);
        // Persist this updated URL
        await _persistSongMetadata(songForMediaItem);
        
        // Update this song in the main _queue if it exists there
        final qIndex = _queue.indexWhere((s) => s.id == songForMediaItem.id);
        if (qIndex != -1) {
          _queue[qIndex] = songForMediaItem;
        }
        // If _currentSongFromAppLogic is this song, update it to the new version
        if (_currentSongFromAppLogic?.id == songForMediaItem.id) {
            _currentSongFromAppLogic = songForMediaItem;
        }
    }

    // Ensure 'isRadio' extra is correctly set to false or absent for regular songs.
    final extras = Map<String, dynamic>.from(songForMediaItem.extras ?? {});
    extras['isRadio'] = false; 
    extras['songId'] = songForMediaItem.id; // Ensure songId is the actual song ID
    extras['isLocal'] = songForMediaItem.isDownloaded;
    if (songForMediaItem.isDownloaded && songForMediaItem.localFilePath != null && !songForMediaItem.albumArtUrl.startsWith('http')) {
        extras['localArtFileName'] = songForMediaItem.albumArtUrl;
    }


    return songToMediaItem(songForMediaItem, playableUrl, songDuration).copyWith(extras: extras);
  }

  Future<void> playSong(Song songToPlay, {bool isResumingOrLooping = false}) async {
    _isLoadingAudio = true;
    // Tentatively update _currentSongFromAppLogic. This might be refined if the song
    // is found in _queue (and that instance is more up-to-date), or if _prepareMediaItem updates it.
    if (!isResumingOrLooping || _currentSongFromAppLogic?.id != songToPlay.id) {
        _currentSongFromAppLogic = songToPlay;
    }
    _stationName = null; 
    _stationFavicon = null;
    notifyListeners(); // Notify for initial UI update (e.g. show new song title, clear radio info)

    try {
      if (!isResumingOrLooping) {
        int indexInExistingQueue = _queue.indexWhere((s) => s.id == songToPlay.id);

        if (indexInExistingQueue != -1) {
          // Song is part of the existing _queue. Play from this queue.
          _currentIndexInAppQueue = indexInExistingQueue;
          // Ensure _currentSongFromAppLogic points to the instance from _queue,
          // as it might have been updated by a previous _prepareMediaItem call or other logic.
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue]; 
                                                                    
          // Refresh the entire queue in AudioHandler.
          // This ensures that if radio was playing, or if any song URLs needed re-fetching,
          // the handler gets the latest set of MediaItems.
          // _prepareMediaItem will be called for each song in _queue.
          // If a song's URL is fetched, _prepareMediaItem updates that Song object within _queue
          // and potentially _currentSongFromAppLogic if it's the current song.
          List<MediaItem> fullQueueMediaItems = await Future.wait(
            _queue.map((sInQueue) => _prepareMediaItem(sInQueue)).toList()
          );
          await _audioHandler.updateQueue(fullQueueMediaItems);
          
        } else { 
          // Song not in current _queue, treat as a new single-item queue.
          // _currentSongFromAppLogic was set to songToPlay.
          // Call _prepareMediaItem for this song. It will update _currentSongFromAppLogic
          // if its URL changes (due to the side effect in _prepareMediaItem).
          MediaItem mediaItem = await _prepareMediaItem(_currentSongFromAppLogic!);
          // After _prepareMediaItem, _currentSongFromAppLogic is the definitive Song object.
          _queue = [_currentSongFromAppLogic!]; 
          _currentIndexInAppQueue = 0;
          await _audioHandler.updateQueue([mediaItem]);
        }
        // _currentSongFromAppLogic should be correct now, pointing to the actual instance being played.
        await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
      }

      await _audioHandler.play();
      _prefetchNextSongs();
      _saveCurrentSongToStorage(); // Save state including potentially updated queue/song

    } catch (e) {
      // Use _currentSongFromAppLogic for the title in error, as it's the most up-to-date version.
      debugPrint('Error playing song (${_currentSongFromAppLogic?.title ?? songToPlay.title}): $e');
      _isLoadingAudio = false;
      notifyListeners();
    }
  }

  Future<String> fetchSongUrl(Song song) async {
    if (song.isDownloaded &&
        song.localFilePath != null &&
        song.localFilePath!.isNotEmpty &&
        !song.localFilePath!.startsWith('http://') &&
        !song.localFilePath!.startsWith('https://')) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final filePath = p.join(appDocDir.path, song.localFilePath!);
      if (await File(filePath).exists()) {
        return filePath; // Return full path for local files
      } else {
        // File missing, attempt to stream
        debugPrint("Local file for ${song.title} missing. Attempting to stream.");
        // Correct metadata
        song.isDownloaded = false;
        song.localFilePath = null;
        await _persistSongMetadata(song);
        // Fall through to streaming logic
      }
    }

    if (song.audioUrl.isNotEmpty && (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false)) {
      return song.audioUrl;
    }

    final apiService = ApiService();
    final fetchedUrl = await apiService.fetchAudioUrl(song.artist, song.title);
    return fetchedUrl ?? '';
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndexInAppQueue == -1) return;
    // Prefetching logic can be complex with audio_service as it manages its own state.
    // For now, this is simplified. The handler might do its own prefetching if designed to.
    // This example focuses on pre-caching URLs in CurrentSongProvider if needed.
  }

  void pauseSong() async {
    await _audioHandler.pause();
  }

  void resumeSong() async {
    // _audioHandler.play() will resume if paused on the current item.
    if (_currentSongFromAppLogic != null) {
      _isLoadingAudio = true; // UI feedback
      notifyListeners();
      await _audioHandler.play();
    }
  }

  void stopSong() async {
    await _audioHandler.stop();
    _currentSongFromAppLogic = null;
    _totalDuration = null;
    _currentIndexInAppQueue = -1;
    // _queue.clear(); // Decide if stopping clears the queue
    // await _audioHandler.updateQueue([]);

    // Reset modes to default on explicit stop, or retain user preference
    // For now, let's retain user preference as it's saved/loaded separately.
    // If you want to reset them:
    // await _audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
    // await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);

    notifyListeners();
    _saveCurrentSongToStorage(); // Save cleared state (and current modes)
  }

  void toggleLoop() {
    final currentMode = _audioHandler.playbackState.value.repeatMode;
    AudioServiceRepeatMode nextMode;
    switch (currentMode) {
      case AudioServiceRepeatMode.none:
        nextMode = AudioServiceRepeatMode.all; // -> Loop Queue
        break;
      case AudioServiceRepeatMode.all:
        nextMode = AudioServiceRepeatMode.one; // -> Loop Song
        break;
      case AudioServiceRepeatMode.one:
        nextMode = AudioServiceRepeatMode.none; // -> Loop Off
        break;
      default: // group or other unhandled states
        nextMode = AudioServiceRepeatMode.none;
        break;
    }
    _audioHandler.setRepeatMode(nextMode);
    // No need to call notifyListeners() here if UI listens to _audioHandler.playbackState
    // However, if FullScreenPlayer relies on provider's loopMode getter, then notify.
    notifyListeners(); 
    _saveCurrentSongToStorage(); // Save the new mode
  }

  void toggleShuffle() {
    final currentMode = _audioHandler.playbackState.value.shuffleMode;
    if (currentMode == AudioServiceShuffleMode.all) {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
    } else {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
    }
    notifyListeners();
  }

  Future<void> setQueue(List<Song> songs, {int initialIndex = 0}) async {
    _queue = List.from(songs);
    if (_queue.isNotEmpty && initialIndex >= 0 && initialIndex < _queue.length) {
      _currentIndexInAppQueue = initialIndex;
      _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
    } else if (_queue.isEmpty) {
      _currentIndexInAppQueue = -1;
      _currentSongFromAppLogic = null;
    } else {
      _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
      _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
    }
    
    final mediaItems = await Future.wait(
        _queue.map((s) async => _prepareMediaItem(s)).toList()
    );
    await _audioHandler.updateQueue(mediaItems);
    
    if (_currentSongFromAppLogic != null && _currentIndexInAppQueue != -1) {
      // Don't auto-play, just set the current item in the handler
      await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
      // To prevent auto-play from skipToQueueItem, immediately pause if not intended to play
      // This depends on skipToQueueItem's implementation in your handler.
      // If it auto-plays, and you don't want that:
      // if (!_isPlaying) await _audioHandler.pause();
    } else if (_queue.isEmpty) {
        await _audioHandler.stop();
    }

    notifyListeners();
    _saveCurrentSongToStorage();
  }

  void playPrevious() {
    // The handler now manages shuffle/repeat logic for skipToPrevious
    _audioHandler.skipToPrevious();
  }

  void playNext() {
    // The handler now manages shuffle/repeat logic for skipToNext
    _audioHandler.skipToNext();
  }


  Future<void> downloadSongInBackground(Song song) async {
    // _isDownloadingSong = true; // Removed
    _activeDownloads[song.id] = song; // Added
    _downloadProgress[song.id] = 0.0;
    notifyListeners();
    String? audioUrl;
    try {
      // Use existing fetchSongUrl which handles local file check first
      audioUrl = await fetchSongUrl(song);
      if (audioUrl.isEmpty || audioUrl.startsWith('file://') || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false) ) {
         // If it's already local or URL is invalid, try API as a last resort for a fresh URL
        final apiService = ApiService();
        audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      }

      if (audioUrl == null || audioUrl.isEmpty || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        debugPrint('Failed to fetch a valid audio URL for download.');
        // _isDownloadingSong = false; // Removed
        _activeDownloads.remove(song.id); // Added
        _downloadProgress.remove(song.id);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('Error fetching audio URL for download: $e');
      // _isDownloadingSong = false; // Removed
      _activeDownloads.remove(song.id); // Added
      _downloadProgress.remove(song.id);
      notifyListeners();
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final String sanitizedTitle = song.title
          .replaceAll(RegExp(r'[^\w\s.-]'), '_')
          .replaceAll(RegExp(r'\s+'), '_');
      final String fileName = '$sanitizedTitle.mp3';
      final filePath = p.join(directory.path, fileName);

      final request = http.Request('GET', Uri.parse(audioUrl));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          if (totalBytes != null && totalBytes > 0) {
            _downloadProgress[song.id] = bytes.length / totalBytes;
            notifyListeners();
          }
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          
          Song updatedSong = song.copyWith(localFilePath: fileName, isDownloaded: true);
          
          _downloadProgress.remove(song.id); 
          // _isDownloadingSong = false; // Removed
          _activeDownloads.remove(song.id); // Added

          await _persistSongMetadata(updatedSong);
          updateSongDetails(updatedSong); // This will notifyListeners and save state

          // If this song is currently playing via stream, update handler to use local file
          if (_currentSongFromAppLogic?.id == updatedSong.id && !_currentSongFromAppLogic!.isDownloaded) {
              final currentPosition = _audioHandler.playbackState.value.position;
              MediaItem newMediaItem = await _prepareMediaItem(updatedSong);
              await _audioHandler.playMediaItem(newMediaItem); // This might restart or update source
              if (currentPosition > Duration.zero) {
                  await _audioHandler.seek(currentPosition); // Seek to original position
              }
          }
          
          PlaylistManagerService().updateSongInPlaylists(updatedSong);
          debugPrint('Download complete: ${updatedSong.title}');
        },
        onError: (e) {
          debugPrint('Download failed for ${song.title}: $e');
          _downloadProgress.remove(song.id);
          // _isDownloadingSong = false; // Removed
          _activeDownloads.remove(song.id); // Added
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('Error downloading song ${song.title}: $e');
      _downloadProgress.remove(song.id);
      // _isDownloadingSong = false; // Removed
      _activeDownloads.remove(song.id); // Added
      notifyListeners();
    }
  }

  Future<void> playStream(String streamUrl, {required String stationName, String? stationFavicon}) async {
    _isLoadingAudio = true;
    // _currentSongFromAppLogic = null; // Clear regular song // This will be set to the radio song object
    _stationName = stationName;
    _stationFavicon = stationFavicon ?? '';
    

    final radioSongId = 'radio_${stationName.hashCode}_${streamUrl.hashCode}';
    final mediaItem = MediaItem(
      id: streamUrl, // Playable URL
      title: stationName,
      artist: 'Radio Station',
      artUri: stationFavicon != null && stationFavicon.isNotEmpty ? Uri.tryParse(stationFavicon) : null,
      extras: {'isRadio': true, 'songId': radioSongId}, // Ensure songId is set for radio
    );
    
    // Update app's notion of current song to this radio stream
    _currentSongFromAppLogic = Song(
        id: radioSongId, // Use the unique radioSongId
        title: stationName,
        artist: 'Radio Station',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl, // Store the actual stream URL
        isDownloaded: false,
        extras: {'isRadio': true, 'songId': radioSongId} // Ensure extras are passed correctly
    );
    notifyListeners(); // Notify after _currentSongFromAppLogic and station details are set


    // Update the queue in the handler to just this radio stream
    // Or, if you want radio to be outside the main queue, handle accordingly.
    // For now, let's make it the current item.
    await _audioHandler.playMediaItem(mediaItem);
    _saveCurrentSongToStorage(); // Save that we are playing a radio stream
  }


  void addToQueue(Song song) async {
    if (!_queue.any((s) => s.id == song.id)) {
      _queue.add(song);
      // Update handler's queue
      final mediaItem = await _prepareMediaItem(song);
      await _audioHandler.addQueueItem(mediaItem);

      if (_currentIndexInAppQueue == -1 && _queue.length == 1) {
        _currentIndexInAppQueue = 0;
        _currentSongFromAppLogic = song;
      }
      notifyListeners();
      _saveCurrentSongToStorage();
    }
  }

  Future<void> clearQueue() async {
    _queue.clear();
    _currentIndexInAppQueue = -1;
    // If a song is playing, it might continue if it was the current item.
    // To stop it and clear handler queue:
    // await _audioHandler.stop(); // This also clears handler's current item
    await _audioHandler.updateQueue([]); // Clears handler's queue

    // If current song was part of the cleared queue, nullify it
    // _currentSongFromAppLogic = null; // Or decide based on desired behavior
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> _persistSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  void updateSongDetails(Song updatedSong) {
    bool providerStateChanged = false; // Tracks if notifyListeners is needed for provider's own state
    bool currentSongWasUpdated = false;

    // Update in the provider's own queue
    final indexInProviderQueue = _queue.indexWhere((s) => s.id == updatedSong.id);
    if (indexInProviderQueue != -1) {
      _queue[indexInProviderQueue] = updatedSong;
      providerStateChanged = true;
    }

    // Update the provider's current song if it's the one being changed
    if (_currentSongFromAppLogic?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      providerStateChanged = true;
      currentSongWasUpdated = true;
    }

    // Asynchronously prepare the MediaItem for the audio_handler
    // This needs to happen before we can update the handler.
    _prepareMediaItem(updatedSong).then((newMediaItem) async { // made async
      // 1. Update the handler's current media item if it matches the updated song.
      final currentHandlerMediaItem = _audioHandler.mediaItem.value;
      bool isCurrentlyPlayingInHandler = false;
      if (currentHandlerMediaItem != null) {
        isCurrentlyPlayingInHandler = (currentHandlerMediaItem.extras?['songId'] == updatedSong.id);
      }


      if (isCurrentlyPlayingInHandler && currentSongWasUpdated) {
          // If the currently playing song's details are updated,
          // we might need to replace the media item in the handler.
          // This can be complex if it means reloading the audio source.
          // A custom action or re-evaluating playMediaItem might be needed.
          // For now, let's assume metadata updates don't require reloading the stream itself
          // unless the playable ID (URL) changes.
          // If newMediaItem.id (playable URL) changed, more drastic action is needed.
          // For now, we focus on metadata like title, artist, art.
          
          // Option 1: Custom action to update metadata of current item (if handler supports)
          // This is safer if only non-critical metadata changes.
           _audioHandler.customAction('updateCurrentMediaItemMetadata', {
            'mediaItem': { // Send only metadata, not necessarily the full item if ID is same
              'id': newMediaItem.id, // Keep same ID if URL hasn't changed
              'title': newMediaItem.title,
              'artist': newMediaItem.artist,
              'album': newMediaItem.album,
              'artUri': newMediaItem.artUri?.toString(),
              'duration': newMediaItem.duration?.inMilliseconds,
              'extras': newMediaItem.extras,
            }
          });


      }

      // 2. Update the item in the handler's queue if it exists there.
      final handlerQueue = List<MediaItem>.from(_audioHandler.queue.value);
      int itemIndexInHandlerQueue = handlerQueue.indexWhere((mi) => mi.extras?['songId'] == updatedSong.id);

      if (itemIndexInHandlerQueue != -1) {
        handlerQueue[itemIndexInHandlerQueue] = newMediaItem;
        await _audioHandler.updateQueue(handlerQueue); // made await
      }
      // Note: No direct call to _audioHandler.updateMediaItem(newMediaItem) to avoid the original error.
      // The combination of custom action and _audioHandler.updateQueue()
      // achieves the desired update safely.

    }).catchError((e, stackTrace) {
      // It's good practice to log errors from async operations.
      debugPrint("Error preparing or updating media item in handler for song ${updatedSong.id}: $e");
      debugPrintStack(stackTrace: stackTrace);
    });

    // Notify listeners if the provider's immediate state (e.g., _queue, _currentSongFromAppLogic) changed.
    if (providerStateChanged) {
      notifyListeners();
    }

    // Always save the overall state (which includes _queue and _currentSongFromAppLogic)
    // and persist the individual song's metadata.
    _saveCurrentSongToStorage();
    _persistSongMetadata(updatedSong);
  }
  
  void setCurrentSong(Song song) async {
    // This method is likely for UI purposes to show details before playing.
    // It shouldn't trigger playback directly.
    _currentSongFromAppLogic = song;
    // If you want to update the audio_handler's current item without playing:
    // final mediaItem = await _prepareMediaItem(song);
    // _audioHandler.mediaItem.add(mediaItem);
    // final qIndex = _queue.indexWhere((s) => s.id == song.id);
    // _audioHandler.playbackState.add(_audioHandler.playbackState.value.copyWith(queueIndex: qIndex != -1 ? qIndex : null));
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _audioHandler.seek(position);
  }

  // playUrl is not used by current app structure, can be removed or adapted
  void playUrl(String url) {
    // This would need to create a MediaItem and call _audioHandler.playMediaItem
    debugPrint('Playing URL directly: $url - This method might need adaptation for audio_service');
    final tempSong = Song(id: url, title: "Direct URL", artist: "", albumArtUrl: "", audioUrl: url);
    playSong(tempSong); // Or a more direct handler call
  }
}
