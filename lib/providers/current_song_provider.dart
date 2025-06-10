import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart'; // Import AudioPlayer from audioplayers package
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:path/path.dart' as p; // Import path package
import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart'; // Assumed path to your audio_handler.dart
import 'dart:async';
import 'package:resumable_downloader/resumable_downloader.dart';

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

  DownloadManager? _downloadManager;
  bool _isDownloadManagerInitialized = false;

  // _activeDownloads will now track the single song actively being processed by the provider's logic
  final Map<String, Song> _activeDownloads = {}; 
  
  // New: Provider-level download queue and processing flag
  final List<Song> _downloadQueue = [];
  // ignore: unused_field
  bool _isProcessingProviderDownload = false;

  bool _isLoadingAudio = false; // For UI feedback when initiating play
  final Map<String, double> _downloadProgress = {}; // songId -> progress (0.0 to 1.0)
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

  // Add public getter for audioHandler
  AudioHandler get audioHandler => _audioHandler;

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

  void updateDownloadedSong(Song updatedSong) {
    // Update the current song if it matches the updated song
    if (currentSong?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      notifyListeners();
    }
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
    _initializeDownloadManager(); // Initialize DownloadManager
    _loadCurrentSongFromStorage(); // Load last playing song and queue
    _listenToAudioHandler();
  }

  Future<void> _initializeDownloadManager() async {
    if (_isDownloadManagerInitialized && _downloadManager != null) {
      // Already initialized
      return;
    }
    try {
      final baseDir = await getApplicationDocumentsDirectory();
      _downloadManager = DownloadManager(
        subDir: 'ltunes_downloads',
        baseDirectory: baseDir,
        fileExistsStrategy: FileExistsStrategy.resume,
        maxConcurrentDownloads: 100000000, 
        maxRetries: 2,
        delayBetweenRetries: const Duration(seconds: 2),
        logger: (log) => debugPrint('[DownloadManager:${log.level.name}] ${log.message}'),
      );
      // start the internal downloader loop so it will pick up any newly enqueued items
      // No explicit start method required for DownloadManager in this version.
      _isDownloadManagerInitialized = true;
    } catch (e) {
      debugPrint("Failed to initialize DownloadManager: $e");
      _isDownloadManagerInitialized = false;
      _downloadManager = null;
    }
  }

  void _listenToAudioHandler() {
    _playbackStateSubscription = _audioHandler.playbackState.listen((playbackState) {
      final oldIsPlaying = _isPlaying;
      final oldIsLoading = _isLoadingAudio;

      _isPlaying = playbackState.playing;
      _isLoadingAudio = playbackState.processingState == AudioProcessingState.loading ||
          playbackState.processingState == AudioProcessingState.buffering;

      // _totalDuration is managed by _mediaItemSubscription and _positionSubscription (for radio)
      if (oldIsPlaying != _isPlaying || oldIsLoading != _isLoadingAudio) {
        notifyListeners();
      }
    });

    _mediaItemSubscription = _audioHandler.mediaItem.listen((mediaItem) async {
      bool needsNotification = false;

      // Update _totalDuration
      // For non-radio, _totalDuration comes from mediaItem.duration.
      // For radio, _totalDuration is handled by _positionSubscription to be "live".
      if (!(mediaItem?.extras?['isRadio'] as bool? ?? false)) {
        if (_totalDuration != mediaItem?.duration) {
          _totalDuration = mediaItem?.duration;
          needsNotification = true;
        }
      }

      // Update _currentSongFromAppLogic, _stationName, _stationFavicon
      if (mediaItem == null) {
        if (_currentSongFromAppLogic != null) { _currentSongFromAppLogic = null; needsNotification = true; }
        // _totalDuration already handled above or by radio logic in _positionSubscription
        if (_stationName != null) { _stationName = null; needsNotification = true; }
        if (_stationFavicon != null) { _stationFavicon = null; needsNotification = true; }
      } else {
        Song? newCurrentSongLogicCandidate;
        String? newStationNameCandidate;
        String? newStationFaviconCandidate;

        if (mediaItem.extras?['isRadio'] as bool? ?? false) {
          final radioSongId = mediaItem.extras!['songId'] as String? ?? mediaItem.id;
          newCurrentSongLogicCandidate = Song(
              id: radioSongId,
              title: mediaItem.title,
              artist: mediaItem.artist ?? 'Radio',
              albumArtUrl: mediaItem.artUri?.toString() ?? '',
              audioUrl: mediaItem.id,
              isDownloaded: false,
              extras: {'isRadio': true}
          );
          newStationNameCandidate = newCurrentSongLogicCandidate.title;
          newStationFaviconCandidate = newCurrentSongLogicCandidate.albumArtUrl;
          // For radio, _totalDuration is handled in _positionSubscription
        } else{
          final songId = mediaItem.extras?['songId'] as String?;
          if (songId != null) {
            newCurrentSongLogicCandidate = _queue.firstWhere((s) => s.id == songId,
                orElse: () {
                  return Song(
                      id: songId,
                      title: mediaItem.title,
                      artist: mediaItem.artist ?? 'Unknown Artist',
                      album: mediaItem.album,
                      albumArtUrl: mediaItem.artUri?.toString() ?? '',
                      audioUrl: mediaItem.id,
                      isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                      localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false) ? p.basename(mediaItem.id) : null
                  );
                });
          } else {
            newCurrentSongLogicCandidate = Song(
                id: mediaItem.id,
                title: mediaItem.title,
                artist: mediaItem.artist ?? 'Unknown Artist',
                album: mediaItem.album,
                albumArtUrl: await _resolveArtUriPath(mediaItem),
                audioUrl: mediaItem.id,
                isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false) ? p.basename(mediaItem.id) : null
            );
          }
          newStationNameCandidate = null;
          newStationFaviconCandidate = null;
        }

        if (_currentSongFromAppLogic?.id != newCurrentSongLogicCandidate.id ||
            _currentSongFromAppLogic?.title != newCurrentSongLogicCandidate.title ||
            _currentSongFromAppLogic?.artist != newCurrentSongLogicCandidate.artist ||
            _currentSongFromAppLogic?.albumArtUrl != newCurrentSongLogicCandidate.albumArtUrl) {
          _currentSongFromAppLogic = newCurrentSongLogicCandidate;
          needsNotification = true;
        }
        if (_stationName != newStationNameCandidate) { _stationName = newStationNameCandidate; needsNotification = true; }
        if (_stationFavicon != newStationFaviconCandidate) { _stationFavicon = newStationFaviconCandidate; needsNotification = true; }
      }

      if (needsNotification) {
        notifyListeners();
      }
    });

    _positionSubscription = AudioService.position.listen((position) {
      bool needsNotifyForTotalDuration = false;
      if (_currentPosition != position) {
        _currentPosition = position;
        // UI listening to AudioService.position will update the current seek time.
        // No need to call notifyListeners() just for _currentPosition change if UI handles it.
      }

      // Handle "live" duration for radio streams
      if (isCurrentlyPlayingRadio) {
        if (_totalDuration != position) {
          _totalDuration = position;
          needsNotifyForTotalDuration = true; // _totalDuration changed, FullScreenPlayer needs this
        }
      }

      if (needsNotifyForTotalDuration) {
        notifyListeners();
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
    _downloadManager?.dispose(); // Dispose the download manager
    _activeDownloads.clear();
    _downloadProgress.clear();

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
    String playableUrl = await fetchSongUrl(song);
    if (playableUrl.isEmpty) {
      throw Exception('Could not resolve playable URL for ${song.title}');
    }

    Duration? songDuration = song.duration;
    if (songDuration == null || songDuration == Duration.zero) {
      final audioPlayer = AudioPlayer();
      try {
        await audioPlayer.setSourceUrl(playableUrl);
        songDuration = await audioPlayer.getDuration();
      } catch (e) {
        debugPrint("Error getting duration for ${song.title}: $e");
        songDuration = Duration.zero;
      } finally {
        await audioPlayer.dispose();
      }
    }

    Song songForMediaItem = song;
    if (playableUrl != song.audioUrl && !song.isDownloaded) {
      songForMediaItem = song.copyWith(audioUrl: playableUrl);
      await _persistSongMetadata(songForMediaItem);
      final qIndex = _queue.indexWhere((s) => s.id == songForMediaItem.id);
      if (qIndex != -1) {
        _queue[qIndex] = songForMediaItem;
      }
      if (_currentSongFromAppLogic?.id == songForMediaItem.id) {
        _currentSongFromAppLogic = songForMediaItem;
      }
    }

    final extras = Map<String, dynamic>.from(songForMediaItem.extras ?? {});
    extras['isRadio'] = false;
    extras['songId'] = songForMediaItem.id;
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
    notifyListeners(); // Notify for initial UI update (e.g. show new song title, clear radio info, show loading)

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
      const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager
      // Correct path for local files, including the subdirectory
      final filePath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
      if (await File(filePath).exists()) {
        return filePath; // Return full path for local files
      } else {
        debugPrint('Local file for ${song.title} marked as downloaded but file missing. Resetting metadata.');
        // File missing, reset metadata and attempt to stream
        song = song.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(song);
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
      // _isLoadingAudio will be set to false by _listenToAudioHandler
    }
  }

  void stopSong() async {
    await _audioHandler.stop();
    _currentSongFromAppLogic = null;
    _totalDuration = null;
    _currentIndexInAppQueue = -1;
    _isLoadingAudio = false; // Ensure loading is false on stop
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
    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();
    }
    _audioHandler.skipToPrevious();
  }

  void playNext() {
    // The handler now manages shuffle/repeat logic for skipToNext
    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();
    }
    _audioHandler.skipToNext();
  }

  Future<void> queueSongForDownload(Song song) async {
    // Ensure DownloadManager is ready before queueing
    await _initializeDownloadManager();
    if (_downloadManager == null) {
      debugPrint("DownloadManager unavailable after initialization. Cannot queue \"${song.title}\".");
      return;
    }

    Song songToProcess = song;

    // Check 1: Already downloaded and file exists?
    if (songToProcess.isDownloaded && songToProcess.localFilePath != null && songToProcess.localFilePath!.isNotEmpty) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final filePath = p.join(appDocDir.path, _downloadManager!.subDir, songToProcess.localFilePath!);
      if (await File(filePath).exists()) {
        debugPrint('Song "${songToProcess.title}" is already downloaded and file exists. Skipping queueing.');
        if (_downloadProgress[songToProcess.id] != 1.0) {
          _downloadProgress[songToProcess.id] = 1.0;
          if (_activeDownloads.containsKey(songToProcess.id)) {
            _activeDownloads.remove(songToProcess.id);
          }
          notifyListeners();
        }
        return;
      } else {
        debugPrint('Song "${songToProcess.title}" marked downloaded but file missing. Resetting metadata.');
        songToProcess = songToProcess.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(songToProcess);
        updateSongDetails(songToProcess);
      }
    }

    // Check 2: Already actively being downloaded by this provider?
    if (_activeDownloads.containsKey(songToProcess.id)) {
      debugPrint('Song "${songToProcess.title}" is already in active downloads by provider. Skipping queueing.');
      return;
    }

    // Check 3: Already in the provider's download queue?
    if (_downloadQueue.any((s) => s.id == songToProcess.id)) {
      debugPrint('Song "${songToProcess.title}" is already in the provider download queue. Skipping queueing.');
      return;
    }

    // Add to provider's queue
    _downloadQueue.add(songToProcess);
    debugPrint('Song "${songToProcess.title}" added to provider download queue. Queue size: ${_downloadQueue.length}');
    notifyListeners(); // Notify that queue has changed, UI might show "queued"
    _triggerNextDownloadInProviderQueue();
  }

  void _triggerNextDownloadInProviderQueue() {
    // only start a new download if none is processing and queue isn't empty
    if (_isProcessingProviderDownload || _downloadQueue.isEmpty) {
      return;
    }

    _isProcessingProviderDownload = true;
    final Song songToDownload = _downloadQueue.removeAt(0);
    _activeDownloads[songToDownload.id] = songToDownload;
    _downloadProgress[songToDownload.id] = _downloadProgress[songToDownload.id] ?? 0.0;
    notifyListeners();
    _processAndSubmitDownload(songToDownload);
  }

  Future<void> _processAndSubmitDownload(Song song) async {
    // Note: _activeDownloads and _downloadProgress are now set by _triggerNextDownloadInProviderQueue
    // This method assumes it's been called for a song that is now the "current" provider-managed download.

    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint("DownloadManager not initialized. Cannot process download for ${song.title}.");
      // _handleDownloadError needs song.id, which is available.
      // The error handling will also trigger the next download from queue.
      _handleDownloadError(song.id, Exception("DownloadManager not initialized"));
      return;
    }

    // _activeDownloads[song.id] = song; // Moved to _triggerNextDownloadInProviderQueue
    // _downloadProgress[song.id] = _downloadProgress[song.id] ?? 0.0; // Moved
    // notifyListeners(); // Moved

    String? audioUrl;
    try {
      audioUrl = await fetchSongUrl(song); // Use the passed song object
      if (audioUrl.isEmpty || audioUrl.startsWith('file://') || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        final apiService = ApiService();
        audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      }
      if (audioUrl == null || audioUrl.isEmpty || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        throw Exception('Failed to fetch a valid audio URL for download.');
      }
    } catch (e) {
      debugPrint('Error fetching audio URL for download of "${song.title}": $e');
      _handleDownloadError(song.id, e);
      return;
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac'];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle = sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
        break;
      }
    }
    
    final String uniqueFileNameBase = '${song.id}_$sanitizedTitle';

    final queueItem = QueueItem(
      url: audioUrl,
      fileName: uniqueFileNameBase,
      progressCallback: (progressDetails) {
        if (_activeDownloads.containsKey(song.id)) {
          _downloadProgress[song.id] = progressDetails.progress;
          notifyListeners();
        }
      },
    );

    try {
      debugPrint('Submitting download for ${song.title} (base filename: $uniqueFileNameBase) to DownloadManager.');
      final downloadedFile = await _downloadManager!.getFile(queueItem);

      if (downloadedFile != null && await downloadedFile.exists()) {
        _handleDownloadSuccess(song.id, p.basename(downloadedFile.path));
      } else {
        // Attempt to clean up potential partial file if DownloadManager didn't.
        // This part is speculative as DownloadManager should handle its files.
        final appDocDir = await getApplicationDocumentsDirectory();
        final String potentialPartialPath = p.join(appDocDir.path, _downloadManager!.subDir, queueItem.fileName!);
        final File partialFile = File(potentialPartialPath);
        if (await partialFile.exists()) {
          try {
            await partialFile.delete();
            debugPrint('Deleted potential partial file: $potentialPartialPath');
          } catch (deleteError) {
            debugPrint('Error deleting potential partial file $potentialPartialPath: $deleteError');
          }
        }
        _handleDownloadError(song.id, Exception('DownloadManager.getFile completed but file is null or does not exist.'));
      }
    } catch (e) {
      debugPrint('Error from DownloadManager for ${song.title}: $e');
      _handleDownloadError(song.id, e);
    }
  }


  void _handleDownloadSuccess(String songId, String actualLocalFileName) async {
    final song = _activeDownloads[songId];
    if (song == null) {
      _isProcessingProviderDownload = false;
      _triggerNextDownloadInProviderQueue();
      return;
    }
    try {
      Song updatedSong = song.copyWith(localFilePath: actualLocalFileName, isDownloaded: true);
      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong); 
      PlaylistManagerService().updateSongInPlaylists(updatedSong);
      debugPrint('Download complete: ${updatedSong.title}');
    } catch (e) {
      debugPrint("Error during post-download success processing for ${song.title}: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _isProcessingProviderDownload = false;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    }
  }

  void _handleDownloadError(String songId, dynamic error) {
    final song = _activeDownloads[songId]; // Get the song being processed

    try {
      if (song != null) {
        debugPrint('Download failed for ${song.title}: $error');
      } else {
        debugPrint('Handling download error for songId $songId (not in _activeDownloads by provider). Error: $error');
        // If song is null, it means it wasn't the one _isProcessingProviderDownload was true for,
        // or state is inconsistent.
      }
    } catch (e) {
      debugPrint("Internal error in _handleDownloadError for songId $songId: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _isProcessingProviderDownload = false;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    }
  }

  Future<void> cancelDownload(String songId) async {
    // Check if the song is in the provider's manual queue
    int queueIndex = _downloadQueue.indexWhere((s) => s.id == songId);
    if (queueIndex != -1) {
      _downloadQueue.removeAt(queueIndex);
      debugPrint("Song ID $songId removed from provider's download queue.");
      // If it was only in the queue, no need to interact with DownloadManager yet.
      // Clean up progress if it was somehow set.
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
      }
      notifyListeners();
      return; // Song was only in queue, not yet given to DownloadManager by provider logic.
    }

    // If not in queue, check if it's the one actively being processed by the provider
    final song = _activeDownloads[songId];
    if (song == null) {
      debugPrint("Song ID $songId not found in active downloads by provider for cancellation.");
      if (_downloadProgress.containsKey(songId)) {
          _downloadProgress.remove(songId);
          notifyListeners();
      }
      return;
    }
    
    // If actively being processed by provider, attempt to cancel with DownloadManager
    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint("DownloadManager not initialized. Cannot cancel active download.");
      // Even if DM is not init, we should clean up provider state for this song.
      // _handleDownloadError will set _isProcessingProviderDownload = false and trigger next.
      _handleDownloadError(songId, Exception("Cancel attempted but DownloadManager not initialized"));
      return;
    }
    
    String? originalAudioUrl = song.audioUrl; 
    if (originalAudioUrl.isEmpty) { 
        try {
            originalAudioUrl = await fetchSongUrl(song);
             if (originalAudioUrl.isEmpty || originalAudioUrl.startsWith('file://') || !(Uri.tryParse(originalAudioUrl)?.isAbsolute ?? false) ) {
                final apiService = ApiService();
                originalAudioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
            }
        } catch (e) {
            debugPrint("Could not determine URL for cancelling download of ${song.title}: $e");
            // Still attempt filename cancel below if URL fetch fails
        }
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac'];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle = sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
        break;
      }
    }
    
    final String uniqueFileNameBaseForCancellation = '${song.id}_$sanitizedTitle';

    if (originalAudioUrl != null && originalAudioUrl.isNotEmpty) {
        try {
          debugPrint('Attempting to cancel download for ${song.title} via URL: $originalAudioUrl');
          await _downloadManager!.cancelDownload(originalAudioUrl);
          debugPrint('URL-based cancel request sent for ${song.title}.');
        } catch (e) {
          debugPrint('URL-based cancel failed for ${song.title}: $e. Will attempt filename cancel.');
        }
    } else {
        debugPrint("URL for cancelling download of ${song.title} is empty. Attempting filename cancel.");
    }

    try {
      debugPrint('Attempting to cancel download for ${song.title} via base filename: $uniqueFileNameBaseForCancellation');
      await _downloadManager!.cancelDownload(uniqueFileNameBaseForCancellation); 
      debugPrint('Filename-based cancel request sent for ${song.title}.');
    } catch (e) {
      debugPrint('Filename-based cancel also failed for ${song.title}: $e');
    }
    
    // Regardless of DownloadManager's cancel success, treat this as an error/completion locally.
    // The DownloadManager's getFile() Future should complete (often with an error) if cancelled.
    // _handleDownloadError will be called when that Future completes.
    // For immediate UI feedback of cancellation:
    if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId); // Proactively remove from provider's active list
    }
    if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
    }
    // _isProcessingProviderDownload will be set to false by _handleDownloadError/Success
    // when the `await _downloadManager.getFile()` call finally unblocks.
    // Then _triggerNextDownloadInProviderQueue will be called.
    notifyListeners();
  }

  Future<void> playStream(String streamUrl, {required String stationName, String? stationFavicon}) async {
    _isLoadingAudio = true;
    // _currentSongFromAppLogic = null; // Clear regular song // This will be set to the radio song object
    _stationName = stationName;
    _stationFavicon = stationFavicon ?? '';


    final radioSongId = 'radio_${stationName.hashCode}_${streamUrl.hashCode}';
    // final mediaItem = MediaItem( // This is defined later
    //   id: streamUrl, // Playable URL
    //   title: stationName,
    //   artist: 'Radio Station',
    //   artUri: stationFavicon != null && stationFavicon.isNotEmpty ? Uri.tryParse(stationFavicon) : null,
    //   extras: {'isRadio': true, 'songId': radioSongId}, // Ensure songId is set for radio
    // );

    // Update app's notion of current song to this radio stream
    _currentSongFromAppLogic = Song(
        id: radioSongId, // Use the unique radioSongId
        title: stationName,
        artist: 'Radio Station',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl, // Store the actual stream URL
        isDownloaded: false,
        extras: {'isRadio': true} // Add extras to Song model if it supports it, or handle this distinction another way
    );
    notifyListeners(); // Notify after _currentSongFromAppLogic and station details are set, and to show loading


    // Update the queue in the handler to just this radio stream
    // Or, if you want radio to be outside the main queue, handle accordingly.
    // For now, let's make it the current item.
    // Re-create mediaItem here as it was commented out above for clarity of _isLoadingAudio and notifyListeners() timing
    final mediaItem = MediaItem(
      id: streamUrl, // Playable URL
      title: stationName,
      artist: 'Radio Station',
      artUri: stationFavicon != null && stationFavicon.isNotEmpty ? Uri.tryParse(stationFavicon) : null,
      extras: {'isRadio': true, 'songId': radioSongId},
    );
    await _audioHandler.playMediaItem(mediaItem);
    _saveCurrentSongToStorage(); // Save that we are playing a radio stream
    // _isLoadingAudio will be set to false by _listenToAudioHandler
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
