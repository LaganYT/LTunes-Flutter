import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:path/path.dart' as p; // Import path package
import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart'; // Assumed path to your audio_handler.dart
import 'dart:async';
import '../models/lyrics_data.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:http/http.dart' as http;
import '../services/download_notification_service.dart';
import '../services/lyrics_service.dart';

// Define LoopMode enum
enum LoopMode { none, queue, song }

/// Validation result containing information about corrupted and unmarked songs
class ValidationResult {
  final List<Song> corruptedSongs;
  final List<Song> unmarkedSongs;

  ValidationResult({required this.corruptedSongs, required this.unmarkedSongs});

  int get totalIssues => corruptedSongs.length + unmarkedSongs.length;
}

class CurrentSongProvider with ChangeNotifier {
  // final AudioPlayer _audioPlayer = AudioPlayer(); // Removed
  final AudioHandler _audioHandler;
  Song?
      _currentSongFromAppLogic; // Represents the song our app thinks is current
  bool _isPlaying = false;
  // bool _isLooping = false; // Replaced by LoopMode logic derived from audio_handler
  bool _isShuffling = false; // Manage shuffle state by shuffling queue once
  List<Song> _queue = [];
  // ignore: unused_field
  List<Song> _unshuffledQueue = [];
  int _currentIndexInAppQueue = -1; // Index in the _queue (app's perspective)

  DownloadManager? _downloadManager;
  bool _isDownloadManagerInitialized = false;

  // _activeDownloads tracks songs currently being processed by the provider's logic
  final Map<String, Song> _activeDownloads = {};

  // New: Provider-level download queue
  final List<Song> _downloadQueue = [];

  // Track the current number of active downloads to respect maxConcurrentDownloads setting
  int _currentActiveDownloadCount = 0;

  // Add retry tracking for downloads
  final Map<String, int> _downloadRetryCount = {};
  final Map<String, DateTime> _downloadLastRetry = {};
  final Map<String, Timer> _retryTimers = {};
  static const int _maxDownloadRetries = 3;
  static const Duration _baseRetryDelay = Duration(seconds: 2);

  int _playRequestCounter = 0;

  bool _isLoadingAudio = false; // For UI feedback when initiating play
  final Map<String, double> _downloadProgress =
      {}; // songId -> progress (0.0 to 1.0)
  Duration _currentPosition = Duration.zero;
  Duration? _totalDuration;

  // Radio specific, might be derivable from MediaItem
  String? _stationName;
  String? get stationName => _stationName;
  String? _stationFavicon;
  String? get stationFavicon => _stationFavicon;

  // Playback speed control
  double _playbackSpeed = 1.0;
  double get playbackSpeed => _playbackSpeed;

  // Switch context behavior setting
  bool _switchContextWithoutInterruption = true;
  bool get switchContextWithoutInterruption =>
      _switchContextWithoutInterruption;

  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _mediaItemSubscription;
  StreamSubscription? _queueSubscription;
  StreamSubscription? _positionSubscription;

  // Download notification service
  final DownloadNotificationService _downloadNotificationService =
      DownloadNotificationService();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  Song? get currentSong => _currentSongFromAppLogic;
  bool get isPlaying => _isPlaying;

  // Add public getter for audioHandler
  AudioHandler get audioHandler => _audioHandler;

  // Playback speed control methods
  Future<void> setPlaybackSpeed(double speed) async {
    // Disable playback speed on iOS
    if (Platform.isIOS) return;

    if (speed < 0.25 || speed > 3.0) return; // Limit speed range

    try {
      await (_audioHandler as AudioPlayerHandler).setPlaybackSpeed(speed);
      _playbackSpeed = speed;
      notifyListeners();

      // Save speed preference
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_speed', speed);
    } catch (e) {
      debugPrint("Error setting playback speed: $e");
    }
  }

  // Switch context behavior setting methods
  Future<void> setSwitchContextWithoutInterruption(bool value) async {
    _switchContextWithoutInterruption = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('switch_context_without_interruption', value);
    notifyListeners();
  }

  /// Reorders the queue and updates the audio handler and current index accordingly.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length) return;
    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    // Update the current index if needed
    if (_currentSongFromAppLogic != null) {
      _currentIndexInAppQueue =
          _queue.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
    }

    // Notify listeners immediately to update UI without flash
    notifyListeners();

    // Update the audio handler's queue (async operations after UI update)
    final mediaItems =
        await Future.wait(_queue.map((s) => _prepareMediaItem(s)).toList());
    await _audioHandler.updateQueue(mediaItems);
    if (_currentIndexInAppQueue != -1) {
      await _audioHandler
          .customAction('setQueueIndex', {'index': _currentIndexInAppQueue});
    }
    _saveCurrentSongToStorage();
  }

  Future<void> resetPlaybackSpeed() async {
    // Disable playback speed on iOS
    if (Platform.isIOS) return;

    try {
      await (_audioHandler as AudioPlayerHandler).resetPlaybackSpeed();
      _playbackSpeed = 1.0;
      notifyListeners();

      // Save speed preference
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_speed', 1.0);
    } catch (e) {
      debugPrint("Error resetting playback speed: $e");
    }
  }

  Future<void> _loadPlaybackSpeedFromStorage() async {
    // Disable playback speed on iOS
    if (Platform.isIOS) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble('playback_speed');
      if (savedSpeed != null && savedSpeed >= 0.25 && savedSpeed <= 3.0) {
        _playbackSpeed = savedSpeed;
        // Apply the saved speed to the audio handler with pitch correction
        await (_audioHandler as AudioPlayerHandler)
            .setPlaybackSpeed(savedSpeed);
      }
    } catch (e) {
      debugPrint("Error loading playback speed from storage: $e");
    }
  }

  Future<void> _loadSwitchContextSettingFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _switchContextWithoutInterruption =
          prefs.getBool('switch_context_without_interruption') ?? true;
    } catch (e) {
      debugPrint("Error loading switch context setting from storage: $e");
    }
  }

  // Getter for LoopMode based on AudioHandler's state
  LoopMode get loopMode {
    // Always derive from audio_handler's playbackState
    final currentAudioHandlerMode =
        _audioHandler.playbackState.value.repeatMode;
    switch (currentAudioHandlerMode) {
      case AudioServiceRepeatMode.none:
        return LoopMode.none;
      case AudioServiceRepeatMode.all:
        return LoopMode.queue;
      case AudioServiceRepeatMode.one:
        return LoopMode.song;
      default:
        return LoopMode.none;
    }
  }

  bool get isShuffling => _isShuffling;

  void updateDownloadedSong(Song updatedSong) {
    // Update the current song if it matches the updated song
    if (currentSong?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      notifyListeners();
    }
  }

  static bool isAppInBackground =
      false; // Set from main.dart lifecycle observer

  void _updateDownloadNotification() async {
    if (!isAppInBackground)
      return; // Only show notification if app is in background
    final notificationsEnabled =
        await _downloadNotificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      return;
    }
    _downloadNotificationService.updateDownloadProgress(
      activeDownloads: _activeDownloads,
      queuedSongs: _downloadQueue,
      downloadProgress: _downloadProgress,
    );
  }

  void _forceUpdateDownloadNotification() async {
    if (!isAppInBackground)
      return; // Only show notification if app is in background
    final notificationsEnabled =
        await _downloadNotificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      return;
    }
    _downloadNotificationService.forceUpdateNotification(
      activeDownloads: _activeDownloads,
      queuedSongs: _downloadQueue,
      downloadProgress: _downloadProgress,
    );
  }

  Future<void> handleDownloadNotificationAction(String action) async {
    debugPrint('CurrentSongProvider: Handling notification action: $action');
    try {
      switch (action) {
        case 'cancel_all':
          debugPrint('CurrentSongProvider: Executing cancel_all action');
          await cancelAllDownloads();
          debugPrint('CurrentSongProvider: cancel_all action completed');
          break;
        case 'view_queue':
          debugPrint('CurrentSongProvider: Executing view_queue action');
          // Send custom action to audio handler for navigation
          _audioHandler.customAction('openDownloadQueue', {});
          debugPrint('CurrentSongProvider: view_queue action completed');
          break;
        default:
          debugPrint(
              'CurrentSongProvider: Unknown notification action: $action');
      }
    } catch (e) {
      debugPrint(
          'CurrentSongProvider: Error handling notification action $action: $e');
      _errorHandler.logError(e, context: 'handleDownloadNotificationAction');
    }
  }

  // Method to request notification permissions
  Future<bool> requestNotificationPermissions() async {
    final notificationsEnabled =
        await _downloadNotificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      return await _downloadNotificationService.areNotificationsEnabled();
    }
    return true;
  }

  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  // bool get isDownloadingSong => _isDownloadingSong; // Changed
  bool get isDownloadingSong => _downloadProgress.isNotEmpty; // Changed
  Map<String, Song> get activeDownloadTasks =>
      Map.unmodifiable(_activeDownloads); // Added
  List<Song> get songsQueuedForDownload =>
      List.unmodifiable(_downloadQueue); // Added
  bool get isLoadingAudio => _isLoadingAudio;
  Duration? get totalDuration => _totalDuration;
  Duration get currentPosition => _currentPosition;
  // Stream<Duration> get onPositionChanged => _audioPlayer.onPositionChanged; // Replaced
  Stream<Duration> get positionStream =>
      AudioService.position; // UI should listen to this for seekbar

  bool get isCurrentlyPlayingRadio {
    final mediaItem = _audioHandler.mediaItem.value;
    return mediaItem?.extras?['isRadio'] as bool? ?? false;
  }

  CurrentSongProvider(this._audioHandler) {
    _initializeDownloadManager().then((_) async {
      await _primeDownloadProgressFromStorage();
    }); // Initialize DownloadManager and prime download progress
    _loadCurrentSongFromStorage(); // Load last playing song and queue
    _listenToAudioHandler();
    _loadPlaybackSpeedFromStorage(); // Load saved playback speed
    _loadSwitchContextSettingFromStorage(); // Load switch context setting

    // Set up download notification action callback and AudioHandler
    _downloadNotificationService
        .setNotificationActionCallback(handleDownloadNotificationAction);
    _downloadNotificationService.setAudioHandler(_audioHandler);
  }

  /// Primes the downloadProgress map from persisted storage so UI reflects true download state after app restart.
  Future<void> _primeDownloadProgressFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final appDocDir = await getApplicationDocumentsDirectory();
    final String downloadsSubDir =
        _downloadManager?.subDir ?? 'ltunes_downloads';
    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap =
                jsonDecode(songJson) as Map<String, dynamic>;
            Song song = Song.fromJson(songMap);
            if (song.isDownloaded &&
                song.localFilePath != null &&
                song.localFilePath!.isNotEmpty) {
              final fullPath =
                  p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
              if (await File(fullPath).exists()) {
                _downloadProgress[song.id] = 1.0;
              } else {
                _downloadProgress.remove(song.id);
              }
            } else {
              _downloadProgress.remove(song.id);
            }
          } catch (e) {
            debugPrint(
                'Error decoding song from SharedPreferences for key $key during _primeDownloadProgressFromStorage: $e');
          }
        }
      }
    }
    notifyListeners();
  }

  Future<String?> _downloadAlbumArt(String url, Song song) async {
    try {
      final directory = await getApplicationDocumentsDirectory();

      String albumIdentifier;
      if (song.album != null && song.album!.isNotEmpty) {
        albumIdentifier = '${song.album}_${song.artist}'
            .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      } else {
        albumIdentifier = song.id;
      }

      String extension = '';
      Uri? uri;
      if (url.startsWith('http')) {
        uri = Uri.parse(url);
        extension = p.extension(uri.path);
      } else {
        extension = p.extension(url);
      }
      if (extension.isEmpty ||
          extension.length > 5 ||
          !extension.startsWith('.')) {
        extension = '.jpg';
      }
      final fileName = 'art_$albumIdentifier$extension';
      final filePath = p.join(directory.path, fileName);
      final file = File(filePath);

      // If url is a network URL, download as before
      if (url.startsWith('http')) {
        if (await file.exists()) {
          return fileName;
        }
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
          debugPrint('Album art downloaded to: $filePath');
          return fileName;
        } else {
          debugPrint(
              'Failed to download album art. Status code: ${response.statusCode}');
        }
      } else {
        // url is a local filename, check if file exists
        if (await file.exists()) {
          return fileName;
        } else {
          // Try to fetch artwork from the network using song info
          debugPrint(
              '[downloadAlbumArt] Local art file missing, attempting to fetch from network for ${song.title} by ${song.artist}');
          final apiService = ApiService();
          // 1. Try to find the song
          final searchResults =
              await apiService.fetchSongs('$song.title $song.artist');
          Song? exactMatch;
          for (final result in searchResults) {
            if (result.title.toLowerCase() == song.title.toLowerCase() &&
                result.artist.toLowerCase() == song.artist.toLowerCase()) {
              exactMatch = result;
              break;
            }
          }
          String? networkArtUrl;
          if (exactMatch != null &&
              exactMatch.albumArtUrl.isNotEmpty &&
              exactMatch.albumArtUrl.startsWith('http')) {
            networkArtUrl = exactMatch.albumArtUrl;
          } else if (song.album != null && song.album!.isNotEmpty) {
            // 2. Try to get the album art
            final album = await apiService.getAlbum(song.album!, song.artist);
            if (album != null && album.fullAlbumArtUrl.isNotEmpty) {
              networkArtUrl = album.fullAlbumArtUrl;
            }
          }
          if (networkArtUrl != null && networkArtUrl.isNotEmpty) {
            try {
              final response = await http.get(Uri.parse(networkArtUrl));
              if (response.statusCode == 200) {
                await file.writeAsBytes(response.bodyBytes);
                debugPrint('Fetched fallback album art to: $filePath');
                return fileName;
              } else {
                debugPrint(
                    'Failed to fetch fallback album art. Status code: ${response.statusCode}');
              }
            } catch (e) {
              debugPrint('Error downloading fallback album art: $e');
            }
          } else {
            debugPrint(
                'No network artwork found for ${song.title} by ${song.artist}');
          }
        }
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'downloadAlbumArt');
    }
    return null;
  }

  Future<void> _initializeDownloadManager() async {
    if (_isDownloadManagerInitialized && _downloadManager != null) {
      // Already initialized
      return;
    }
    try {
      final baseDir = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      final maxConcurrentDownloads =
          prefs.getInt('maxConcurrentDownloads') ?? 1;

      _downloadManager = DownloadManager(
        subDir: 'ltunes_downloads',
        baseDirectory: baseDir,
        fileExistsStrategy: FileExistsStrategy.resume,
        maxRetries: 2,
        maxConcurrentDownloads: maxConcurrentDownloads,
        delayBetweenRetries: const Duration(seconds: 2),
        logger: (log) =>
            debugPrint('[DownloadManager:${log.level.name}] ${log.message}'),
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

  Future<void> reinitializeDownloadManager() async {
    // Reset the initialization flag to force reinitialization
    _isDownloadManagerInitialized = false;
    _downloadManager = null;
    await _initializeDownloadManager();
  }

  void _listenToAudioHandler() {
    // Listen to playback state for play/pause/loading
    _playbackStateSubscription =
        _audioHandler.playbackState.listen((playbackState) {
      final oldIsPlaying = _isPlaying;
      final oldIsLoading = _isLoadingAudio;

      _isPlaying = playbackState.playing;
      _isLoadingAudio =
          playbackState.processingState == AudioProcessingState.loading ||
              playbackState.processingState == AudioProcessingState.buffering;

      // Log state changes
      if (oldIsPlaying != _isPlaying) {
        debugPrint(
            "CurrentSongProvider: Playing state changed from $oldIsPlaying to $_isPlaying (processingState: ${playbackState.processingState})");
      }
      if (oldIsLoading != _isLoadingAudio) {
        debugPrint(
            "CurrentSongProvider: Loading state changed from $oldIsLoading to $_isLoadingAudio");
      }

      // Save state on pause
      if (oldIsPlaying && !_isPlaying) {
        debugPrint("CurrentSongProvider: Saving state due to pause");
        _saveCurrentSongToStorage();
      }

      // Check for stuck loading state
      if (_isLoadingAudio) {
        _checkForStuckLoadingState();
      }

      // Notify UI if play/pause/loading state changed
      if (oldIsPlaying != _isPlaying || oldIsLoading != _isLoadingAudio) {
        notifyListeners();
      }
    });

    // Listen to media item changes for song/metadata updates
    _mediaItemSubscription = _audioHandler.mediaItem.listen((mediaItem) async {
      bool needsNotification = false;

      // Update _totalDuration.
      // For radio streams, duration will be null, and we handle it as a "live" stream.
      // For regular tracks, this will update when audio_handler gets the duration.
      if (_totalDuration != mediaItem?.duration) {
        _totalDuration = mediaItem?.duration;
        needsNotification = true;
      }

      // Update _currentSongFromAppLogic, _stationName, _stationFavicon
      if (mediaItem == null) {
        if (_currentSongFromAppLogic != null) {
          _currentSongFromAppLogic = null;
          needsNotification = true;
        }
        // _totalDuration already handled above or by radio logic in _positionSubscription
        if (_stationName != null) {
          _stationName = null;
          needsNotification = true;
        }
        if (_stationFavicon != null) {
          _stationFavicon = null;
          needsNotification = true;
        }
      } else {
        Song? newCurrentSongLogicCandidate;
        String? newStationNameCandidate;
        String? newStationFaviconCandidate;

        if (mediaItem.extras?['isRadio'] as bool? ?? false) {
          final radioSongId =
              mediaItem.extras!['songId'] as String? ?? mediaItem.id;
          newCurrentSongLogicCandidate = Song(
              id: radioSongId,
              title: mediaItem.title,
              artist: mediaItem.artist ?? 'Radio',
              artistId: mediaItem.extras?['artistId'] as String? ?? '',
              albumArtUrl: mediaItem.artUri?.toString() ?? '',
              audioUrl: mediaItem.id,
              isDownloaded: false,
              extras: {'isRadio': true});
          newStationNameCandidate = newCurrentSongLogicCandidate.title;
          newStationFaviconCandidate = newCurrentSongLogicCandidate.albumArtUrl;
          // For radio, _totalDuration is handled in _positionSubscription
        } else {
          final songId = mediaItem.extras?['songId'] as String?;
          if (songId != null) {
            newCurrentSongLogicCandidate =
                _queue.firstWhere((s) => s.id == songId, orElse: () {
              return Song(
                id: songId,
                title: mediaItem.title,
                artist: mediaItem.artist ?? 'Unknown Artist',
                artistId: mediaItem.extras?['artistId'] as String? ?? '',
                album: mediaItem.album,
                albumArtUrl: mediaItem.artUri?.toString() ?? '',
                audioUrl: mediaItem.id,
                isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false)
                    ? p.basename(mediaItem.id)
                    : null,
              );
            });
          } else {
            newCurrentSongLogicCandidate = Song(
              id: mediaItem.id,
              title: mediaItem.title,
              artist: mediaItem.artist ?? 'Unknown Artist',
              artistId: mediaItem.extras?['artistId'] as String? ?? '',
              album: mediaItem.album,
              albumArtUrl: await _resolveArtUriPath(mediaItem),
              audioUrl: mediaItem.id,
              isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
              localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false)
                  ? p.basename(mediaItem.id)
                  : null,
            );
          }
          newStationNameCandidate = null;
          newStationFaviconCandidate = null;
        }

        if (_currentSongFromAppLogic?.id != newCurrentSongLogicCandidate.id ||
            _currentSongFromAppLogic?.title !=
                newCurrentSongLogicCandidate.title ||
            _currentSongFromAppLogic?.artist !=
                newCurrentSongLogicCandidate.artist ||
            _currentSongFromAppLogic?.albumArtUrl !=
                newCurrentSongLogicCandidate.albumArtUrl) {
          // GUARD: If loading, only allow update if the incoming song matches the one being loaded
          if (_isLoadingAudio &&
              _currentSongFromAppLogic != null &&
              newCurrentSongLogicCandidate.id != _currentSongFromAppLogic!.id) {
            // Skip update to prevent fallback to previous song during loading
            return;
          }
          _currentSongFromAppLogic = newCurrentSongLogicCandidate;
          needsNotification = true;
        }
        if (_currentSongFromAppLogic != null) {
          final newIndex =
              _queue.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
          if (newIndex != -1 && _currentIndexInAppQueue != newIndex) {
            _currentIndexInAppQueue = newIndex;
            needsNotification = true;
          }
        } else if (_currentSongFromAppLogic == null &&
            _currentIndexInAppQueue != -1) {
          _currentIndexInAppQueue = -1;
          needsNotification = true;
        }
        if (_stationName != newStationNameCandidate) {
          _stationName = newStationNameCandidate;
          needsNotification = true;
        }
        if (_stationFavicon != newStationFaviconCandidate) {
          _stationFavicon = newStationFaviconCandidate;
          needsNotification = true;
        }
      }

      if (needsNotification) {
        notifyListeners();
      }
    });

    // Listen to position stream for seekbar and lyrics sync
    _positionSubscription = AudioService.position.listen((position) {
      _currentPosition = position;
      notifyListeners(); // UI seekbar and lyrics sync
    });
  }

  Future<String> _resolveArtUriPath(MediaItem item) async {
    if (item.artUri != null && item.artUri.toString().startsWith('http')) {
      return item.artUri.toString();
    }
    if (item.extras?['localArtFileName'] != null) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath =
          p.join(directory.path, item.extras!['localArtFileName'] as String);
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

  // Helper method to find an existing downloaded song by title and artist
  Future<Song?> _findExistingDownloadedSongByTitleArtist(
      String title, String artist) async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final appDocDir = await getApplicationDocumentsDirectory();
    // Ensure _downloadManager is initialized to get subDir, or use default
    await _initializeDownloadManager();
    final String downloadsSubDir =
        _downloadManager?.subDir ?? 'ltunes_downloads';

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap =
                jsonDecode(songJson) as Map<String, dynamic>;
            Song songCandidate = Song.fromJson(songMap);

            if (songCandidate.isDownloaded &&
                songCandidate.localFilePath != null &&
                songCandidate.localFilePath!.isNotEmpty &&
                songCandidate.title.toLowerCase() == title.toLowerCase() &&
                songCandidate.artist.toLowerCase() == artist.toLowerCase()) {
              final fullPath = p.join(appDocDir.path, downloadsSubDir,
                  songCandidate.localFilePath!);
              if (await File(fullPath).exists()) {
                return songCandidate; // Found a downloaded match with an existing file
              } else {
                debugPrint(
                    "Song ${songCandidate.title} (ID: ${songCandidate.id}) matched title/artist and isDownloaded=true, but local file $fullPath missing.");
              }
            }
          } catch (e) {
            debugPrint(
                'Error decoding song from SharedPreferences for key $key during _findExistingDownloadedSongByTitleArtist: $e');
          }
        }
      }
    }
    return null; // No downloaded match found with an existing file
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
      await prefs.setString(
          'current_song_v2', jsonEncode(_currentSongFromAppLogic!.toJson()));
      await prefs.setInt('current_index_v2', _currentIndexInAppQueue);
      await prefs.setInt(
          'current_position_v2', _currentPosition.inMilliseconds);
      List<String> queueJson =
          _queue.map((song) => jsonEncode(song.toJson())).toList();
      await prefs.setStringList('current_queue_v2', queueJson);
      if (_isShuffling && _unshuffledQueue.isNotEmpty) {
        List<String> unshuffledQueueJson =
            _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
        await prefs.setStringList(
            'current_unshuffled_queue_v2', unshuffledQueueJson);
      } else {
        await prefs.remove('current_unshuffled_queue_v2');
      }
    } else {
      await prefs.remove('current_song_v2');
      await prefs.remove('current_index_v2');
      await prefs.remove('current_position_v2');
      await prefs.remove('current_queue_v2');
      await prefs.remove('current_unshuffled_queue_v2');
    }
    // Save loop mode
    await prefs.setInt(
        'loop_mode_v2', _audioHandler.playbackState.value.repeatMode.index);
    // Save shuffle mode
    await prefs.setBool('shuffle_mode_v2', _isShuffling);
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song_v2');
    final savedPositionMilliseconds = prefs.getInt('current_position_v2');

    // Load and set loop mode
    final savedLoopModeIndex = prefs.getInt('loop_mode_v2');
    if (savedLoopModeIndex != null &&
        savedLoopModeIndex < AudioServiceRepeatMode.values.length) {
      await _audioHandler
          .setRepeatMode(AudioServiceRepeatMode.values[savedLoopModeIndex]);
    }

    // Load and set shuffle mode
    final savedShuffleMode = prefs.getBool('shuffle_mode_v2') ?? false;
    _isShuffling = savedShuffleMode;
    await _audioHandler.setShuffleMode(
        AudioServiceShuffleMode.none); // Always none, we manage it.

    if (songJson != null) {
      try {
        Map<String, dynamic> songMap = jsonDecode(songJson);
        Song loadedSong = Song.fromJson(songMap);
        // Migration logic for file paths (if any) should be in Song.fromJson or here

        // Check if the loaded song is a radio stream
        bool isRadioStream = loadedSong.id.startsWith('radio_') ||
            (loadedSong.extras?['isRadio'] as bool? ?? false);

        _currentSongFromAppLogic = loadedSong;
        _currentIndexInAppQueue = prefs.getInt('current_index_v2') ?? -1;
        List<String>? queueJsonStrings =
            prefs.getStringList('current_queue_v2');
        if (queueJsonStrings != null) {
          _queue = queueJsonStrings
              .map((sJson) => Song.fromJson(jsonDecode(sJson)))
              .toList();
        }

        if (_isShuffling) {
          List<String>? unshuffledQueueJsonStrings =
              prefs.getStringList('current_unshuffled_queue_v2');
          if (unshuffledQueueJsonStrings != null) {
            _unshuffledQueue = unshuffledQueueJsonStrings
                .map((sJson) => Song.fromJson(jsonDecode(sJson)))
                .toList();
          } else if (_queue.isNotEmpty) {
            // Fallback: if shuffled but no unshuffled queue saved, it means something went wrong or it's an old version.
            // We can't perfectly reconstruct the original order. We can leave _unshuffledQueue empty,
            // so toggling shuffle off will just keep the current order.
            _unshuffledQueue =
                List.from(_queue); // At least have something to revert to.
          }
        }

        // Restore state to audio_handler
        if (!isRadioStream &&
            _queue.isNotEmpty &&
            _currentIndexInAppQueue != -1 &&
            _currentIndexInAppQueue < _queue.length) {
          final mediaItems = await Future.wait(
              _queue.map((s) async => await _prepareMediaItem(s)).toList());
          await _audioHandler.updateQueue(mediaItems);
          // Prepare the item at the saved index without playing it.
          await _audioHandler.customAction(
              'prepareToPlay', {'index': _currentIndexInAppQueue});

          if (savedPositionMilliseconds != null) {
            await _audioHandler
                .seek(Duration(milliseconds: savedPositionMilliseconds));
          }
        } else if (_currentSongFromAppLogic != null) {
          // Handles single song or radio stream
          // For radio, fetchSongUrl will just return its existing audioUrl (the stream URL)
          // For regular song, it will fetch if necessary.
          final playableUrl = await fetchSongUrl(_currentSongFromAppLogic!);
          final mediaItem =
              songToMediaItem(_currentSongFromAppLogic!, playableUrl, null);

          // If it's a radio stream, set its specific properties from the loaded song
          if (isRadioStream) {
            _stationName = _currentSongFromAppLogic!.title;
            _stationFavicon = _currentSongFromAppLogic!.albumArtUrl;
            // Ensure mediaItem for radio has 'isRadio' extra
            final radioExtras =
                Map<String, dynamic>.from(mediaItem.extras ?? {});
            radioExtras['isRadio'] = true;
            radioExtras['songId'] = _currentSongFromAppLogic!
                .id; // Ensure original radio songId is used
            final radioMediaItem = mediaItem.copyWith(
                extras: radioExtras,
                id: _currentSongFromAppLogic!.audioUrl,
                title: _stationName ?? 'Unknown Station',
                artist: "Radio Station");
            // Prepare the radio item without playing it.
            await _audioHandler.customAction('prepareMediaItem', {
              'mediaItem': {
                'id': radioMediaItem.id,
                'title': radioMediaItem.title,
                'artist': radioMediaItem.artist,
                'album': radioMediaItem.album,
                'artUri': radioMediaItem.artUri?.toString(),
                'duration': radioMediaItem.duration?.inMilliseconds,
                'extras': radioMediaItem.extras,
              }
            });
          } else {
            // Prepare the single song item without playing it.
            await _audioHandler.customAction('prepareMediaItem', {
              'mediaItem': {
                'id': mediaItem.id,
                'title': mediaItem.title,
                'artist': mediaItem.artist,
                'album': mediaItem.album,
                'artUri': mediaItem.artUri?.toString(),
                'duration': mediaItem.duration?.inMilliseconds,
                'extras': mediaItem.extras,
              }
            });
            if (savedPositionMilliseconds != null) {
              await _audioHandler
                  .seek(Duration(milliseconds: savedPositionMilliseconds));
            }
          }
        }
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song/queue from storage (v2): $e');
        await prefs.remove('current_song_v2');
        await prefs.remove('current_index_v2');
        await prefs.remove('current_position_v2');
        await prefs.remove('current_queue_v2');
      }
    }
  }

  Future<MediaItem> _prepareMediaItem(Song song, {int? playRequest}) async {
    Song effectiveSong = song;

    // Only scan SharedPreferences if we DON'T already have a localFilePath
    if (!(song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false))) {
      final existingDownloadedSong =
          await _findExistingDownloadedSongByTitleArtist(
              song.title, song.artist);
      if (playRequest != null && playRequest != _playRequestCounter)
        return Future.error('Cancelled');
      if (existingDownloadedSong != null) {
        debugPrint(
            "Found existing downloaded version for ${song.title} (ID: ${song.id}) by ${song.artist}. Consolidating with downloaded song ID: ${existingDownloadedSong.id}.");

        String albumArtToUse =
            song.albumArtUrl; // Default to incoming song's art
        if (existingDownloadedSong.albumArtUrl.isNotEmpty &&
            !existingDownloadedSong.albumArtUrl.startsWith('http')) {
          // If downloaded song has local art, prefer it.
          final appDocDir = await getApplicationDocumentsDirectory();
          final localArtPath =
              p.join(appDocDir.path, existingDownloadedSong.albumArtUrl);
          if (await File(localArtPath).exists()) {
            albumArtToUse = existingDownloadedSong.albumArtUrl;
          }
        }

        effectiveSong = song.copyWith(
          // Start with incoming song's display data
          id: existingDownloadedSong
              .id, // CRITICAL: Use ID of the existing downloaded song
          isDownloaded: true, // CRITICAL: Mark as downloaded
          localFilePath: existingDownloadedSong
              .localFilePath, // CRITICAL: Use downloaded song's path
          duration: existingDownloadedSong.duration ??
              song.duration, // Prefer downloaded duration, fallback to incoming
          albumArtUrl: albumArtToUse,
          // audioUrl will be determined/confirmed by fetchSongUrl based on isDownloaded status
        );

        // Persist this "merged" song information. This is important.
        // It ensures that SharedPreferences has the correct ID and download status.
        await _persistSongMetadata(effectiveSong);
        if (playRequest != null && playRequest != _playRequestCounter)
          return Future.error('Cancelled');
        // Update this song in all playlists to consolidate around the existing ID
        // This assumes PlaylistManagerService can handle ID changes or find by old ID/title/artist.
        PlaylistManagerService().updateSongInPlaylists(effectiveSong);
      }
    }

    // 'effectiveSong' is now the definitive version to work with.
    // 'fetchSongUrl' will use local path if 'effectiveSong.isDownloaded' is true and file exists.
    // If local file is missing, 'fetchSongUrl' will attempt to get a stream URL.
    String playableUrl =
        await fetchSongUrl(effectiveSong, playRequest: playRequest);
    if (playRequest != null && playRequest != _playRequestCounter)
      return Future.error('Cancelled');

    bool metadataToPersistChanged = false;

    if (playableUrl.isEmpty) {
      // Fallback: if fetchSongUrl couldn't get a local path (even if marked downloaded but file missing)
      // and original audioUrl was also empty/invalid, try API.
      final apiService = ApiService();
      final fetchedApiUrl = await apiService.fetchAudioUrl(
          effectiveSong.artist, effectiveSong.title);
      if (playRequest != null && playRequest != _playRequestCounter)
        return Future.error('Cancelled');
      if (fetchedApiUrl != null && fetchedApiUrl.isNotEmpty) {
        playableUrl = fetchedApiUrl;
        // If we got here, it means the song is NOT playable locally.
        // If it was marked as downloaded (either originally or after merging), its status is now incorrect because the file is missing.
        // We should update 'effectiveSong' to reflect it's streaming.
        effectiveSong = effectiveSong.copyWith(
            isDownloaded: false,
            localFilePath: null,
            audioUrl: playableUrl // Set audioUrl to the fetched stream URL
            );
        metadataToPersistChanged = true;
      } else {
        throw Exception(
            'Could not resolve playable URL for ${effectiveSong.title} (ID: ${effectiveSong.id}) after API fallback.');
      }
    } else {
      // Playable URL was found by fetchSongUrl.
      // If 'effectiveSong' is downloaded, 'playableUrl' is its local file path.
      // We need to ensure 'effectiveSong.audioUrl' reflects this local path if it's different
      // (e.g., if original 'song' had a streaming URL but we merged with a downloaded version).
      if (effectiveSong.isDownloaded && effectiveSong.audioUrl != playableUrl) {
        effectiveSong = effectiveSong.copyWith(audioUrl: playableUrl);
        metadataToPersistChanged = true;
      }
      // If not downloaded, and fetchSongUrl returned a (possibly new) stream URL
      else if (!effectiveSong.isDownloaded &&
          effectiveSong.audioUrl != playableUrl) {
        effectiveSong = effectiveSong.copyWith(audioUrl: playableUrl);
        metadataToPersistChanged = true;
      }
    }

    Duration? songDuration = effectiveSong.duration;
    if (songDuration == null || songDuration == Duration.zero) {
      final audioPlayer = just_audio.AudioPlayer();
      try {
        Duration? fetchedDuration;
        if (effectiveSong.isDownloaded && playableUrl.startsWith('/')) {
          fetchedDuration = await audioPlayer.setFilePath(playableUrl);
        } else {
          fetchedDuration = await audioPlayer.setUrl(playableUrl);
        }
        if (playRequest != null && playRequest != _playRequestCounter)
          return Future.error('Cancelled');
        songDuration = fetchedDuration;
        if (songDuration != null &&
            songDuration != Duration.zero &&
            effectiveSong.duration != songDuration) {
          effectiveSong = effectiveSong.copyWith(duration: songDuration);
          metadataToPersistChanged = true;
        }
      } catch (e) {
        debugPrint(
            "Error getting duration for ${effectiveSong.title} (ID: ${effectiveSong.id}) using URL $playableUrl: $e");
        songDuration =
            effectiveSong.duration ?? Duration.zero; // Keep existing or zero
      } finally {
        await audioPlayer.dispose();
      }
    }

    if (metadataToPersistChanged) {
      await _persistSongMetadata(effectiveSong);
      // Update in-memory representations if they exist
      final qIndex = _queue.indexWhere((s) => s.id == effectiveSong.id);
      if (qIndex != -1) {
        _queue[qIndex] = effectiveSong;
      }
      bool updatedCurrentSong = false;
      if (_currentSongFromAppLogic?.id == effectiveSong.id) {
        if (_currentSongFromAppLogic != effectiveSong) {
          _currentSongFromAppLogic = effectiveSong;
          updatedCurrentSong = true;
        }
      }
      // If the song's download status changed from downloaded to not-downloaded
      if (song.isDownloaded && !effectiveSong.isDownloaded) {
        PlaylistManagerService().updateSongInPlaylists(effectiveSong);
      }
      if (updatedCurrentSong) {
        notifyListeners(); // Ensure UI updates with the latest metadata
      }
    }

    final extras = Map<String, dynamic>.from(effectiveSong.extras ?? {});
    extras['isRadio'] = effectiveSong.artist == 'Radio Station';
    extras['songId'] =
        effectiveSong.id; // CRITICAL: ensure this is the ID of effectiveSong
    extras['isLocal'] = effectiveSong.isDownloaded;
    if (effectiveSong.isDownloaded &&
        effectiveSong.localFilePath != null &&
        effectiveSong.albumArtUrl.isNotEmpty &&
        !effectiveSong.albumArtUrl.startsWith('http')) {
      // Ensure localArtFileName is only set if albumArtUrl is indeed a local filename
      extras['localArtFileName'] = effectiveSong.albumArtUrl;
    }

    return songToMediaItem(effectiveSong, playableUrl, songDuration)
        .copyWith(extras: extras);
  }

  Future<String> fetchSongUrl(Song song, {int? playRequest}) async {
    if (song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false)) {
      final appDocDir = await getApplicationDocumentsDirectory();
      if (playRequest != null && playRequest != _playRequestCounter)
        return Future.error('Cancelled');
      final downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath =
          p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
      if (await File(filePath).exists()) {
        // Validate the file and redownload if corrupted
        final needsRedownload = await validateAndRedownloadIfNeeded(song);
        if (needsRedownload) {
          debugPrint(
              'File validation failed for ${song.title}, triggering redownload and falling back to streaming');
          // Return streaming URL while redownload happens in background
          if (song.audioUrl.isNotEmpty &&
              (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false) &&
              !song.audioUrl.startsWith('file:/')) {
            return song.audioUrl;
          }
          final apiService = ApiService();
          final fetchedUrl =
              await apiService.fetchAudioUrl(song.artist, song.title);
          return fetchedUrl ?? '';
        }
        return filePath;
      }
      // Song was marked downloaded but the file is gone: reset its download state and trigger redownload
      {
        final updatedSong =
            song.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(updatedSong);
        updateSongDetails(updatedSong);
        PlaylistManagerService().updateSongInPlaylists(updatedSong);

        // Trigger redownload for missing file
        if (!song.isImported) {
          await redownloadSong(updatedSong);
        }
      }
      if (song.isImported) {
        debugPrint('Imported song "${song.title}" missing, cannot stream.');
        return '';
      }
      debugPrint(
          'Local file for ${song.title} missing at $filePath, falling back to streaming.');
    }

    // If song is imported and we reached here, it means its local file is missing.
    // We should not attempt to fetch a URL from API for an imported song.
    if (song.isImported) {
      debugPrint(
          'Imported song "${song.title}" does not have a valid local file path or file is missing. Cannot stream.');
      return '';
    }

    if (song.audioUrl.isNotEmpty &&
        (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false) &&
        !song.audioUrl.startsWith('file:/')) {
      return song.audioUrl;
    }

    final apiService = ApiService();
    final fetchedUrl = await apiService.fetchAudioUrl(song.artist, song.title);
    if (playRequest != null && playRequest != _playRequestCounter)
      return Future.error('Cancelled');
    return fetchedUrl ?? '';
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndexInAppQueue == -1) return;
    // Prefetching logic can be complex with audio_service as it manages its own state.
    // For now, this is simplified. The handler might do its own prefetching if designed to.
    // This example focuses on pre-caching URLs in CurrentSongProvider if needed.
  }

  void _checkForStuckLoadingState() {
    // Start a timer to detect if we get stuck in loading state
    Timer(const Duration(seconds: 45), () {
      if (_isLoadingAudio) {
        debugPrint(
            "CurrentSongProvider: Detected stuck loading state, attempting recovery");
        _audioHandler.customAction('recoverFromStuckState', {}).then((success) {
          if (success == true) {
            debugPrint(
                "CurrentSongProvider: Recovery from stuck loading state successful");
          } else {
            debugPrint(
                "CurrentSongProvider: Recovery from stuck loading state failed");
          }
        });
      }
    });
  }

  Future<void> handleAppForeground() async {
    debugPrint(
        "CurrentSongProvider: App foregrounded, checking for stuck states");

    // Check if we're in a stuck loading state
    if (_isLoadingAudio) {
      // Wait a bit to see if it resolves naturally
      await Future.delayed(const Duration(seconds: 3));

      if (_isLoadingAudio) {
        debugPrint(
            "CurrentSongProvider: Still loading after 3 seconds, attempting recovery");
        final success =
            await _audioHandler.customAction('recoverFromStuckState', {});
        if (success == true) {
          debugPrint(
              "CurrentSongProvider: Recovery from stuck state successful");
        } else {
          debugPrint("CurrentSongProvider: Recovery from stuck state failed");
        }
      }
    }
  }

  void pauseSong() async {
    debugPrint(
        "CurrentSongProvider: Pause requested for song: ${_currentSongFromAppLogic?.title ?? 'Unknown'}");
    await _audioHandler.pause();
    debugPrint("CurrentSongProvider: Pause completed");
  }

  void resumeSong() async {
    debugPrint(
        "CurrentSongProvider: Resume requested for song: ${_currentSongFromAppLogic?.title ?? 'Unknown'} at position: ${_currentPosition.inSeconds}s");
    if (_currentSongFromAppLogic != null) {
      _isLoadingAudio = true;
      notifyListeners();
      await _audioHandler.seek(_currentPosition);
      await _audioHandler.play();
      debugPrint("CurrentSongProvider: Resume completed");
      // _isLoadingAudio will be set to false by _listenToAudioHandler
    } else {
      debugPrint("CurrentSongProvider: Resume failed - no current song");
    }
  }

  void stopSong() async {
    await _audioHandler.stop();
    _currentSongFromAppLogic = null;
    _totalDuration = null;
    _currentIndexInAppQueue = -1;
    _isLoadingAudio = false;
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  void toggleLoop() {
    final currentMode = _audioHandler.playbackState.value.repeatMode;
    AudioServiceRepeatMode nextMode;
    switch (currentMode) {
      case AudioServiceRepeatMode.none:
        nextMode = AudioServiceRepeatMode.all;
        break;
      case AudioServiceRepeatMode.all:
        nextMode = AudioServiceRepeatMode.one;
        break;
      case AudioServiceRepeatMode.one:
        nextMode = AudioServiceRepeatMode.none;
        break;
      default:
        nextMode = AudioServiceRepeatMode.none;
        break;
    }
    _audioHandler.setRepeatMode(nextMode);
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> toggleShuffle() async {
    final newShuffleState = !_isShuffling;
    _isShuffling = newShuffleState;

    if (_queue.isEmpty) {
      notifyListeners();
      _saveCurrentSongToStorage();
      return;
    }

    final currentSongBeforeAction = _currentSongFromAppLogic;

    if (newShuffleState) {
      _unshuffledQueue = List.from(_queue);
      _queue.shuffle();
    } else {
      if (_unshuffledQueue.isNotEmpty) {
        _queue = List.from(_unshuffledQueue);
      }
    }

    // Find the new index of the current song
    if (currentSongBeforeAction != null) {
      _currentIndexInAppQueue =
          _queue.indexWhere((s) => s.id == currentSongBeforeAction.id);
      if (_currentIndexInAppQueue == -1) {
        _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
        _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
      }
    } else {
      _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
      _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
    }

    // Don't update the audio handler's queue immediately to avoid position interference
    // The queue will be updated when the next song plays or when explicitly needed

    // The audio_handler's shuffle mode should always be NONE now.
    await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);

    notifyListeners();
    await _saveCurrentSongToStorage();
  }

  Future<void> setQueue(List<Song> songs, {int initialIndex = 0}) async {
    // Always use canonical downloaded version for each song
    List<Song> canonicalSongs = [];
    for (final s in songs) {
      final downloaded =
          await _findExistingDownloadedSongByTitleArtist(s.title, s.artist);
      if (downloaded != null) {
        canonicalSongs.add(s.copyWith(
          id: downloaded.id,
          isDownloaded: true,
          localFilePath: downloaded.localFilePath,
          duration: downloaded.duration ?? s.duration,
          albumArtUrl: downloaded.albumArtUrl.isNotEmpty &&
                  !downloaded.albumArtUrl.startsWith('http')
              ? downloaded.albumArtUrl
              : s.albumArtUrl,
        ));
      } else {
        canonicalSongs.add(s);
      }
    }
    _unshuffledQueue =
        List.from(canonicalSongs); // Always save the natural order
    _queue = List.from(canonicalSongs);

    if (_isShuffling) {
      _queue.shuffle();
    }

    if (_queue.isNotEmpty) {
      Song? initialSong;
      if (initialIndex >= 0 && initialIndex < _unshuffledQueue.length) {
        initialSong = _unshuffledQueue[initialIndex];
      }

      if (initialSong != null) {
        _currentIndexInAppQueue =
            _queue.indexWhere((s) => s.id == initialSong!.id);
        if (_currentIndexInAppQueue == -1) {
          // Fallback if song not found (should not happen)
          _currentIndexInAppQueue = 0;
        }
      } else {
        _currentIndexInAppQueue = 0;
      }
      _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
    } else {
      _currentIndexInAppQueue = -1;
      _currentSongFromAppLogic = null;
    }

    final mediaItems = await Future.wait(
        _queue.map((s) async => _prepareMediaItem(s)).toList());
    await _audioHandler.updateQueue(mediaItems);

    if (_currentSongFromAppLogic != null && _currentIndexInAppQueue != -1) {
      await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
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

      // Update the audio handler's queue with current provider queue order
      // This ensures shuffle order is respected when moving to previous song
      _updateAudioHandlerQueue().then((_) {
        _audioHandler.skipToPrevious();
      });
    } else {
      _audioHandler.skipToPrevious();
    }
  }

  void playNext() {
    // The handler now manages shuffle/repeat logic for skipToNext
    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();

      // Update the audio handler's queue with current provider queue order
      // This ensures shuffle order is respected when moving to next song
      _updateAudioHandlerQueue().then((_) {
        _audioHandler.skipToNext().then((_) {
          // If the current song is not downloaded, notify listeners so UI can update position/state.
          notifyListeners();
        });
      });
    } else {
      _audioHandler.skipToNext().then((_) {
        notifyListeners();
      });
    }
  }

  Future<void> _updateAudioHandlerQueue() async {
    if (_queue.isEmpty) return;

    final mediaItems =
        await Future.wait(_queue.map((s) => _prepareMediaItem(s)).toList());
    await _audioHandler.updateQueue(mediaItems);

    // Update the current playing item's index in the handler
    if (_currentIndexInAppQueue != -1) {
      await _audioHandler
          .customAction('setQueueIndex', {'index': _currentIndexInAppQueue});
    }
  }

  Future<void> queueSongForDownload(Song song) async {
    await _initializeDownloadManager();
    if (_downloadManager == null) {
      debugPrint(
          "DownloadManager unavailable after initialization. Cannot queue \"${song.title}\".");
      return;
    }

    Song songToProcess = song;

    // Skip if song is imported
    if (songToProcess.isImported) {
      debugPrint(
          'Song "[0;31m${songToProcess.title}[0m" is imported. Skipping download queue.');
      if (_downloadProgress[songToProcess.id] != 1.0) {
        _downloadProgress[songToProcess.id] = 1.0; // Mark as complete
        if (_activeDownloads.containsKey(songToProcess.id)) {
          _activeDownloads.remove(songToProcess.id);
        }
        notifyListeners();
      }
      return;
    }

    // Check for existing downloaded version by title and artist
    final existingDownloadedSong =
        await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);

    if (existingDownloadedSong != null) {
      debugPrint(
          "Song \"${song.title}\" by ${song.artist} is already downloaded (found as ID ${existingDownloadedSong.id}). Updating metadata and skipping download queue.");

      String albumArtToUse = song.albumArtUrl;
      if (existingDownloadedSong.albumArtUrl.isNotEmpty &&
          !existingDownloadedSong.albumArtUrl.startsWith('http')) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final localArtPath =
            p.join(appDocDir.path, existingDownloadedSong.albumArtUrl);
        if (await File(localArtPath).exists()) {
          albumArtToUse = existingDownloadedSong.albumArtUrl;
        }
      }

      songToProcess = song.copyWith(
        id: existingDownloadedSong.id,
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        audioUrl: existingDownloadedSong
            .localFilePath, // Or construct full path after ensuring file exists
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: albumArtToUse,
      );

      await _persistSongMetadata(songToProcess);
      updateSongDetails(songToProcess);
      PlaylistManagerService().updateSongInPlaylists(songToProcess);

      _downloadProgress[songToProcess.id] = 1.0;
      if (_activeDownloads.containsKey(songToProcess.id)) {
        _activeDownloads.remove(songToProcess.id);
      }
      notifyListeners();
      return;
    }

    // Check 1 (modified): Already downloaded (based on current songToProcess state) and file exists?
    if (songToProcess.isDownloaded &&
        songToProcess.localFilePath != null &&
        songToProcess.localFilePath!.isNotEmpty) {
      final appDocDir = await getApplicationDocumentsDirectory();
      await _initializeDownloadManager();
      final String downloadsSubDir =
          _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath =
          p.join(appDocDir.path, downloadsSubDir, songToProcess.localFilePath!);
      if (await File(filePath).exists()) {
        debugPrint(
            'Song "${songToProcess.title}" is already downloaded and file exists. Skipping queueing.');
        if (_downloadProgress[songToProcess.id] != 1.0) {
          _downloadProgress[songToProcess.id] = 1.0;
          if (_activeDownloads.containsKey(songToProcess.id)) {
            _activeDownloads.remove(songToProcess.id);
          }
          notifyListeners();
        }
        return;
      } else {
        debugPrint(
            'Song "${songToProcess.title}" marked downloaded but file missing. Resetting metadata.');
        songToProcess =
            songToProcess.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(songToProcess);
        updateSongDetails(songToProcess);
      }
    }

    // Check 2: Already actively being downloaded by this provider?
    if (_activeDownloads.containsKey(songToProcess.id)) {
      debugPrint(
          'Song "${songToProcess.title}" is already in active downloads by provider. Skipping queueing.');
      return;
    }

    // Check 3: Already in the provider's download queue?
    if (_downloadQueue.any((s) => s.id == songToProcess.id)) {
      debugPrint(
          'Song "${songToProcess.title}" is already in the provider download queue. Skipping queueing.');
      return;
    }

    // Add to provider's queue
    _downloadQueue.add(songToProcess);
    debugPrint(
        'Song "${songToProcess.title}" added to provider download queue. Queue size: ${_downloadQueue.length}');
    notifyListeners(); // Notify that queue has changed, UI might show "queued"
    _updateDownloadNotification(); // Only called if song is actually queued for download
    _triggerNextDownloadInProviderQueue();
  }

  void _triggerNextDownloadInProviderQueue() async {
    // Get the current max concurrent downloads setting
    final prefs = await SharedPreferences.getInstance();
    final maxConcurrentDownloads = prefs.getInt('maxConcurrentDownloads') ?? 1;

    // Start new downloads if we haven't reached the limit and queue isn't empty
    while (_currentActiveDownloadCount < maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final Song songToDownload = _downloadQueue.removeAt(0);
      _activeDownloads[songToDownload.id] = songToDownload;
      _downloadProgress[songToDownload.id] =
          _downloadProgress[songToDownload.id] ?? 0.0;
      _currentActiveDownloadCount++;
      notifyListeners();
      _forceUpdateDownloadNotification(); // Force update when download starts
      _processAndSubmitDownload(songToDownload);
    }
  }

  Future<void> _processAndSubmitDownload(Song song) async {
    // Note: _activeDownloads and _downloadProgress are now set by _triggerNextDownloadInProviderQueue
    // This method assumes it's been called for a song that is now the "current" provider-managed download.

    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint(
          "DownloadManager not initialized. Cannot process download for ${song.title}.");
      // _handleDownloadError needs song.id, which is available.
      // The error handling will also trigger the next download from queue.
      _handleDownloadError(
          song.id, Exception("DownloadManager not initialized"));
      return;
    }

    // Check if we should retry this download
    final retryCount = _downloadRetryCount[song.id] ?? 0;
    if (retryCount > 0) {
      final lastRetry = _downloadLastRetry[song.id];
      if (lastRetry != null) {
        final timeSinceLastRetry = DateTime.now().difference(lastRetry);
        final retryDelay = Duration(
            seconds: _baseRetryDelay.inSeconds *
                (1 << (retryCount - 1))); // Exponential backoff
        if (timeSinceLastRetry < retryDelay) {
          final remainingDelay = retryDelay - timeSinceLastRetry;
          debugPrint(
              'Retry attempt $retryCount for ${song.title} too soon. Scheduling retry in ${remainingDelay.inSeconds}s...');

          // Cancel any existing timer for this song
          _retryTimers[song.id]?.cancel();

          // Schedule retry with timer
          _retryTimers[song.id] = Timer(remainingDelay, () {
            if (_activeDownloads.containsKey(song.id)) {
              debugPrint(
                  'Retry timer expired for ${song.title}, attempting download...');
              _processAndSubmitDownload(song);
            }
          });

          // Move to next song in queue
          _activeDownloads.remove(song.id);
          _downloadProgress.remove(song.id);
          _currentActiveDownloadCount--;
          notifyListeners();
          _triggerNextDownloadInProviderQueue();
          return;
        }
      }
    }

    // _activeDownloads[song.id] = song; // Moved to _triggerNextDownloadInProviderQueue
    // _downloadProgress[song.id] = _downloadProgress[song.id] ?? 0.0; // Moved
    // notifyListeners(); // Moved

    String? audioUrl;
    try {
      audioUrl = await fetchSongUrl(song); // Use the passed song object
      if (audioUrl.isEmpty ||
          audioUrl.startsWith('file://') ||
          !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        final apiService = ApiService();
        audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      }
      if (audioUrl == null ||
          audioUrl.isEmpty ||
          !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        throw Exception('Failed to fetch a valid audio URL for download.');
      }
    } catch (e) {
      debugPrint(
          'Error fetching audio URL for download of "${song.title}": $e');
      _handleDownloadError(song.id, e);
      return;
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = [
      '.mp3',
      '.m4a',
      '.aac',
      '.wav',
      '.ogg',
      '.flac'
    ];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle =
            sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
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
          // _updateDownloadNotification(); // Removed: no notification update on progress
        }
      },
    );

    try {
      debugPrint(
          'Submitting download for ${song.title} (base filename: $uniqueFileNameBase) to DownloadManager. Retry attempt: ${retryCount + 1}');
      final downloadedFile = await _downloadManager!.getFile(queueItem);

      if (downloadedFile != null && await downloadedFile.exists()) {
        // Verify the file is not corrupted by checking its size
        final fileSize = await downloadedFile.length();
        if (fileSize > 0) {
          // Clear retry count on success
          _downloadRetryCount.remove(song.id);
          _downloadLastRetry.remove(song.id);
          _handleDownloadSuccess(song.id, p.basename(downloadedFile.path));
        } else {
          // File exists but is empty - treat as download failure
          await _cleanupCorruptedFile(downloadedFile);
          _handleDownloadFailure(
              song.id, Exception('Downloaded file is empty or corrupted'));
        }
      } else {
        // Attempt to clean up potential partial file if DownloadManager didn't.
        // This part is speculative as DownloadManager should handle its files.
        await _cleanupPartialFile(queueItem.fileName!);
        _handleDownloadFailure(
            song.id,
            Exception(
                'DownloadManager.getFile completed but file is null or does not exist.'));
      }
    } catch (e) {
      debugPrint('Error from DownloadManager for ${song.title}: $e');
      await _cleanupPartialFile(queueItem.fileName!);
      _handleDownloadFailure(song.id, e);
    }
  }

  Future<void> _cleanupCorruptedFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted corrupted file: ${file.path}');
      }
    } catch (e) {
      debugPrint('Error deleting corrupted file ${file.path}: $e');
    }
  }

  Future<void> _cleanupPartialFile(String fileName) async {
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final String potentialPartialPath =
          p.join(appDocDir.path, _downloadManager!.subDir, fileName);
      final File partialFile = File(potentialPartialPath);
      if (await partialFile.exists()) {
        await partialFile.delete();
        debugPrint('Deleted potential partial file: $potentialPartialPath');
      }
    } catch (e) {
      debugPrint('Error cleaning up partial file: $e');
    }
  }

  void _handleDownloadFailure(String songId, dynamic error) {
    final song = _activeDownloads[songId];
    final retryCount = _downloadRetryCount[songId] ?? 0;

    if (song != null && retryCount < _maxDownloadRetries) {
      // Increment retry count and schedule retry
      _downloadRetryCount[songId] = retryCount + 1;
      _downloadLastRetry[songId] = DateTime.now();

      debugPrint(
          'Download failed for ${song.title}. Retry attempt ${retryCount + 1}/$_maxDownloadRetries. Error: $error');

      // Calculate retry delay
      final retryDelay =
          Duration(seconds: _baseRetryDelay.inSeconds * (1 << retryCount));
      debugPrint(
          'Scheduling retry for ${song.title} in ${retryDelay.inSeconds}s...');

      // Cancel any existing timer for this song
      _retryTimers[songId]?.cancel();

      // Schedule retry with timer
      _retryTimers[songId] = Timer(retryDelay, () {
        debugPrint(
            'Retry timer expired for ${song.title}, re-queuing for download...');
        // Re-queue the song for retry
        _downloadQueue.insert(0, song);
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
        _currentActiveDownloadCount--;
        notifyListeners();
        _triggerNextDownloadInProviderQueue();
      });

      // Clean up current state
      _activeDownloads.remove(songId);
      _downloadProgress.remove(songId);
      _currentActiveDownloadCount--;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    } else {
      // Max retries exceeded or no song found
      debugPrint(
          'Download failed for song $songId after ${retryCount + 1} attempts. Giving up.');
      _handleDownloadError(songId, error);
    }
  }

  void _handleDownloadSuccess(String songId, String actualLocalFileName) async {
    Song? song = _activeDownloads[songId];

    if (song == null) {
      // Attempt to find it in the queue or persisted data if it's an update for an existing item
      // This part might need more robust handling if song can be null here.
      // For now, let's assume the caller (queueSongForDownload's "already downloaded" path)
      // handles providing the correct, updated song object to _persistSongMetadata, etc.
      // and this _handleDownloadSuccess is primarily for actual network downloads.
      // For immediate UI feedback of cancellation:
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads
            .remove(songId); // Proactively remove from provider's active list
      }
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
      }
      // _isProcessingProviderDownload will be set to false by _handleDownloadError/Success
      // when the `await _downloadManager.getFile()` call finally unblocks.
      // Then _triggerNextDownloadInProviderQueue will be called.
      return;
    }

    try {
      Song updatedSong = song.copyWith(
        isDownloaded: true,
        localFilePath:
            actualLocalFileName, // Use the actual filename from DownloadManager
        isDownloading: false,
        downloadProgress: 1.0,
      );

      // Download album art if it's a network URL
      if (updatedSong.albumArtUrl.startsWith('http')) {
        final localArtFileName =
            await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
        if (localArtFileName != null) {
          updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        }
      }

      // Fetch lyrics after successful download using the new lyrics service
      final lyricsService = LyricsService();
      final lyricsData =
          await lyricsService.fetchLyricsIfNeeded(updatedSong, this);
      if (lyricsData != null) {
        updatedSong = updatedSong.copyWith(
          plainLyrics: lyricsData.plainLyrics,
          syncedLyrics: lyricsData.syncedLyrics,
        );
      }

      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong);
      PlaylistManagerService().updateSongInPlaylists(updatedSong);
      debugPrint(
          'Download complete: ${updatedSong.title}. Lyrics fetched: ${lyricsData != null && (lyricsData.plainLyrics != null || lyricsData.syncedLyrics != null)}');
    } catch (e) {
      debugPrint(
          "Error during post-download success processing for ${song.title}: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _currentActiveDownloadCount--;
      notifyListeners();
      _forceUpdateDownloadNotification(); // Force update when download completes
      _triggerNextDownloadInProviderQueue();
    }
  }

  void _handleDownloadError(String songId, dynamic error) {
    final song = _activeDownloads[songId]; // Get the song being processed

    try {
      if (song != null) {
        _errorHandler.logError(error, context: 'downloadSong');
      } else {
        debugPrint(
            'Handling download error for songId $songId (not in _activeDownloads by provider). Error: $error');
        // If song is null, it means it wasn't the one _isProcessingProviderDownload was true for,
        // or state is inconsistent.
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'handleDownloadError');
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _currentActiveDownloadCount--;
      notifyListeners();
      _forceUpdateDownloadNotification(); // Force update when download completes
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
      _updateDownloadNotification(); // Update download notification
      return; // Song was only in queue, not yet given to DownloadManager by provider logic.
    }

    // If not in queue, check if it's the one actively being processed by the provider
    final song = _activeDownloads[songId];
    if (song == null) {
      debugPrint(
          "Song ID $songId not found in active downloads by provider for cancellation.");
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
        notifyListeners();
        _updateDownloadNotification(); // Update download notification
      }
      return;
    }

    // If actively being processed by provider, attempt to cancel with DownloadManager
    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint(
          "DownloadManager not initialized. Cannot cancel active download.");
      // Even if DM is not init, we should clean up provider state for this song.
      // _handleDownloadError will set _isProcessingProviderDownload = false and trigger next.
      _handleDownloadError(songId,
          Exception("Cancel attempted but DownloadManager not initialized"));
      return;
    }

    String? originalAudioUrl = song.audioUrl;
    if (originalAudioUrl.isEmpty) {
      try {
        originalAudioUrl = await fetchSongUrl(song);
        if (originalAudioUrl.isEmpty ||
            originalAudioUrl.startsWith('file://') ||
            !(Uri.tryParse(originalAudioUrl)?.isAbsolute ?? false)) {
          final apiService = ApiService();
          originalAudioUrl =
              await apiService.fetchAudioUrl(song.artist, song.title);
        }
      } catch (e) {
        debugPrint(
            "Could not determine URL for cancelling download of ${song.title}: $e");
        // Still attempt filename cancel below if URL fetch fails
      }
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = [
      '.mp3',
      '.m4a',
      '.aac',
      '.wav',
      '.ogg',
      '.flac'
    ];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle =
            sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
        break;
      }
    }

    final String uniqueFileNameBaseForCancellation =
        '${song.id}_$sanitizedTitle';

    if (originalAudioUrl != null && originalAudioUrl.isNotEmpty) {
      try {
        debugPrint(
            'Attempting to cancel download for ${song.title} via URL: $originalAudioUrl');
        await _downloadManager!.cancelDownload(originalAudioUrl);
        debugPrint('URL-based cancel request sent for ${song.title}.');
      } catch (e) {
        debugPrint(
            'URL-based cancel failed for ${song.title}: $e. Will attempt filename cancel.');
      }
    } else {
      debugPrint(
          "URL for cancelling download of ${song.title} is empty. Attempting filename cancel.");
    }

    try {
      debugPrint(
          'Attempting to cancel download for ${song.title} via base filename: $uniqueFileNameBaseForCancellation');
      await _downloadManager!.cancelDownload(uniqueFileNameBaseForCancellation);
      debugPrint('Filename-based cancel request sent for ${song.title}.');
    } catch (e) {
      debugPrint('Filename-based cancel also failed for ${song.title}: $e');
    }

    // Cancel any retry timer for this song
    _retryTimers[songId]?.cancel();
    _retryTimers.remove(songId);

    // Clear retry tracking for this song
    _downloadRetryCount.remove(songId);
    _downloadLastRetry.remove(songId);

    // Regardless of DownloadManager's cancel success, treat this as an error/completion locally.
    // The DownloadManager's getFile() Future should complete (often with an error) if cancelled.
    // _handleDownloadError will be called when that Future completes.
    // For immediate UI feedback of cancellation:
    if (_activeDownloads.containsKey(songId)) {
      _activeDownloads
          .remove(songId); // Proactively remove from provider's active list
    }
    if (_downloadProgress.containsKey(songId)) {
      _downloadProgress.remove(songId);
    }
    // _isProcessingProviderDownload will be set to false by _handleDownloadError/Success
    // when the `await _downloadManager.getFile()` call finally unblocks.
    // Then _triggerNextDownloadInProviderQueue will be called.
    notifyListeners();
    _updateDownloadNotification(); // Update download notification
  }

  Future<void> cancelAllDownloads() async {
    debugPrint("Attempting to cancel all downloads.");

    // Create a combined list of all song IDs to cancel to avoid issues with modifying collections while iterating.
    final List<String> songIdsToCancel = [];
    songIdsToCancel.addAll(_activeDownloads.keys);
    songIdsToCancel.addAll(_downloadQueue.map((s) => s.id).toList());

    // Remove duplicates, though activeDownloads and downloadQueue should ideally not have overlaps
    // if logic is correct, but good for safety.
    final uniqueSongIdsToCancel = songIdsToCancel.toSet().toList();

    if (uniqueSongIdsToCancel.isEmpty) {
      debugPrint("No downloads to cancel.");
      return;
    }

    debugPrint(
        "Found ${uniqueSongIdsToCancel.length} unique downloads to cancel.");

    // Call cancelDownload for each. cancelDownload handles DownloadManager interaction and state updates.
    for (final songId in uniqueSongIdsToCancel) {
      // We don't need to await each individual cancelDownload here if we want to fire them off
      // and let them complete asynchronously. The UI will update as each one finishes.
      // However, cancelDownload itself is async.
      // For simplicity in managing _isProcessingProviderDownload and _triggerNextDownloadInProviderQueue,
      // it might be better to let them run.
      // The current cancelDownload logic already handles removing from _activeDownloads
      // and _downloadProgress, and triggering the next download if one was active.
      // If we clear _downloadQueue here, _triggerNextDownloadInProviderQueue won't pick up new items from it.

      // If a download is active (_activeDownloads contains it), cancelDownload will handle it.
      // If it's only in _downloadQueue, cancelDownload will remove it from there.
      await cancelDownload(songId);
    }

    // Explicitly clear the provider's queue as cancelDownload only removes one at a time
    // or the active one.
    _downloadQueue.clear();

    // Clear retry tracking and cancel timers
    _downloadRetryCount.clear();
    _downloadLastRetry.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();

    // _activeDownloads and _downloadProgress should be cleared by the individual cancelDownload calls
    // as they complete or error out.
    // If there was an active download, its cancellation will set _isProcessingProviderDownload to false
    // and attempt to trigger the next download. Since _downloadQueue is now empty, nothing new will start.

    debugPrint(
        "All download cancellation requests initiated. Provider queue cleared.");
    notifyListeners(); // Notify for the queue clearing and any immediate state changes.
    _forceUpdateDownloadNotification(); // Force update when all downloads are cancelled
  }

  /// Redownload a song that has failed or is corrupted
  Future<void> redownloadSong(Song song) async {
    debugPrint('CurrentSongProvider: Redownloading song: ${song.title}');

    try {
      // Clear any existing retry count for this song
      _downloadRetryCount.remove(song.id);
      _downloadLastRetry.remove(song.id);

      // Cancel any existing retry timer for this song
      _retryTimers[song.id]?.cancel();
      _retryTimers.remove(song.id);

      // Remove from active downloads if present
      _activeDownloads.remove(song.id);
      _downloadProgress.remove(song.id);

      // Remove from queue if present
      _downloadQueue.removeWhere((s) => s.id == song.id);

      // Reset song's download state
      final resetSong = song.copyWith(
        isDownloaded: false,
        localFilePath: null,
        isDownloading: false,
        downloadProgress: 0.0,
      );

      // Update song metadata
      await _persistSongMetadata(resetSong);
      updateSongDetails(resetSong);
      PlaylistManagerService().updateSongInPlaylists(resetSong);

      // Clean up any existing corrupted files
      if (song.localFilePath != null && song.localFilePath!.isNotEmpty) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final String downloadsSubDir =
            _downloadManager?.subDir ?? 'ltunes_downloads';
        final filePath =
            p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('Deleted corrupted file for redownload: $filePath');
        }
      }

      // Queue for redownload
      await queueSongForDownload(resetSong);

      debugPrint(
          'CurrentSongProvider: Song queued for redownload: ${song.title}');
    } catch (e) {
      debugPrint(
          'CurrentSongProvider: Error redownloading song ${song.title}: $e');
      _errorHandler.logError(e, context: 'redownloadSong');
    }
  }

  /// Check if a downloaded song file is corrupted and redownload if necessary
  /// Returns true if the file needs redownload (corrupted), false if valid
  Future<bool> validateAndRedownloadIfNeeded(Song song) async {
    if (!song.isDownloaded ||
        song.localFilePath == null ||
        song.localFilePath!.isEmpty) {
      return false;
    }

    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final String downloadsSubDir =
          _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath =
          p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
      final file = File(filePath);

      if (!await file.exists()) {
        // File is missing - this should be handled by the caller
        // For this method, we only check if the file is corrupted, not missing
        debugPrint(
            'File missing for downloaded song ${song.title}, but validateAndRedownloadIfNeeded only handles corruption');
        return false;
      }

      // Check if file is corrupted (empty or too small)
      final fileSize = await file.length();
      if (fileSize == 0 || fileSize < 1024) {
        // Less than 1KB is suspicious
        debugPrint(
            'File corrupted for downloaded song ${song.title} (size: $fileSize bytes), triggering redownload');
        await redownloadSong(song);
        return true;
      }

      return false; // File is valid
    } catch (e) {
      debugPrint('Error validating file for ${song.title}: $e');
      // If we can't validate, assume it's corrupted and redownload
      await redownloadSong(song);
      return true;
    }
  }

  /// Validate all downloaded songs and redownload corrupted ones
  Future<ValidationResult> validateAllDownloadedSongs() async {
    debugPrint(
        'CurrentSongProvider: Starting validation of all downloaded songs');
    final List<Song> corruptedSongs = [];
    final List<Song> unmarkedSongs = [];

    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> keys = prefs.getKeys();

      for (String key in keys) {
        if (key.startsWith('song_')) {
          final String? songJson = prefs.getString(key);
          if (songJson != null) {
            try {
              Map<String, dynamic> songMap =
                  jsonDecode(songJson) as Map<String, dynamic>;
              Song song = Song.fromJson(songMap);

              if (song.isDownloaded &&
                  song.localFilePath != null &&
                  song.localFilePath!.isNotEmpty) {
                final appDocDir = await getApplicationDocumentsDirectory();
                final String downloadsSubDir =
                    _downloadManager?.subDir ?? 'ltunes_downloads';
                final filePath = p.join(
                    appDocDir.path, downloadsSubDir, song.localFilePath!);
                final file = File(filePath);

                if (!await file.exists()) {
                  // File is missing - unmark as downloaded
                  debugPrint(
                      'File missing for downloaded song ${song.title}, unmarking as downloaded');
                  final updatedSong = song.copyWith(
                    isDownloaded: false,
                    localFilePath: null,
                    isDownloading: false,
                    downloadProgress: 0.0,
                  );
                  await _persistSongMetadata(updatedSong);
                  updateSongDetails(updatedSong);
                  PlaylistManagerService().updateSongInPlaylists(updatedSong);
                  unmarkedSongs.add(song);
                } else {
                  // File exists, check if corrupted
                  final needsRedownload =
                      await validateAndRedownloadIfNeeded(song);
                  if (needsRedownload) {
                    corruptedSongs.add(song);
                  }
                }
              }
            } catch (e) {
              debugPrint('Error parsing song metadata for key $key: $e');
            }
          }
        }
      }

      debugPrint(
          'CurrentSongProvider: Validation complete. Found ${corruptedSongs.length} corrupted songs and unmarked ${unmarkedSongs.length} missing files');
      return ValidationResult(
          corruptedSongs: corruptedSongs, unmarkedSongs: unmarkedSongs);
    } catch (e) {
      debugPrint('CurrentSongProvider: Error during bulk validation: $e');
      _errorHandler.logError(e, context: 'validateAllDownloadedSongs');
      return ValidationResult(
          corruptedSongs: corruptedSongs, unmarkedSongs: unmarkedSongs);
    }
  }

  Future<void> playStream(String streamUrl,
      {required String stationName, String? stationFavicon}) async {
    debugPrint('playStream called with URL: $streamUrl, name: $stationName');

    if (streamUrl.isEmpty) {
      debugPrint('Error: Empty stream URL provided');
      return;
    }

    _playRequestCounter++;
    final int currentPlayRequest = _playRequestCounter;

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
        artistId: '',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl, // Store the actual stream URL
        isDownloaded: false,
        extras: {
          'isRadio': true
        } // Add extras to Song model if it supports it, or handle this distinction another way
        );
    notifyListeners(); // Notify after _currentSongFromAppLogic and station details are set, and to show loading

    if (currentPlayRequest != _playRequestCounter) return;

    // Update the queue in the handler to just this radio stream
    // Or, if you want radio to be outside the main queue, handle accordingly.
    // For now, let's make it the current item.
    // Re-create mediaItem here as it was commented out above for clarity of _isLoadingAudio and notifyListeners() timing
    final mediaItem = MediaItem(
      id: streamUrl, // Playable URL
      title: stationName,
      artist: 'Radio Station',
      artUri: stationFavicon != null && stationFavicon.isNotEmpty
          ? Uri.tryParse(stationFavicon)
          : null,
      extras: {'isRadio': true, 'songId': radioSongId},
    );

    // Clear the current queue and add the radio station
    await _audioHandler.updateQueue([mediaItem]);
    await _audioHandler.skipToQueueItem(0);

    if (currentPlayRequest != _playRequestCounter) return;

    _saveCurrentSongToStorage(); // Save that we are playing a radio stream
    // _isLoadingAudio will be set to false by _listenToAudioHandler
  }

  void addToQueue(Song song) async {
    // Prevent duplicates by ID
    if (_queue.any((s) => s.id == song.id)) {
      return;
    }
    // Always use canonical downloaded version if available
    final existingDownloadedSong =
        await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);
    Song songToAdd = song;
    if (existingDownloadedSong != null) {
      songToAdd = song.copyWith(
        id: existingDownloadedSong.id,
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: existingDownloadedSong.albumArtUrl.isNotEmpty &&
                !existingDownloadedSong.albumArtUrl.startsWith('http')
            ? existingDownloadedSong.albumArtUrl
            : song.albumArtUrl,
      );
    }
    _queue.add(songToAdd);
    final mediaItem = await _prepareMediaItem(songToAdd);
    await _audioHandler.addQueueItem(mediaItem);

    if (_currentIndexInAppQueue == -1 && _queue.length == 1) {
      _currentIndexInAppQueue = 0;
      _currentSongFromAppLogic = songToAdd;
    }
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> clearQueue() async {
    // Keep the current song if it exists
    Song? currentSong = _currentSongFromAppLogic;
    int currentIndex = _currentIndexInAppQueue;

    if (currentSong != null &&
        currentIndex >= 0 &&
        currentIndex < _queue.length) {
      // Clear the queue but keep the current song
      _queue.clear();
      _queue.add(currentSong);
      _currentIndexInAppQueue = 0; // Current song is now at index 0

      // Update the audio handler queue with just the current song
      // but don't restart playback - just update the queue structure
      final mediaItem = await _prepareMediaItem(currentSong);
      await _audioHandler.updateQueue([mediaItem]);
      // Don't call skipToQueueItem to avoid restarting the current song
    } else {
      // No current song, clear everything
      _queue.clear();
      _currentIndexInAppQueue = -1;
      await _audioHandler.updateQueue([]);
    }

    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> _persistSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  Future<void> processSongLibraryRemoval(String songId) async {
    bool providerStateChanged = false;

    // If the removed song was the current song, update _currentSongFromAppLogic
    if (_currentSongFromAppLogic?.id == songId) {
      _currentSongFromAppLogic = null;
      providerStateChanged = true;
    }

    // Remove from the provider's internal queue
    final int initialQueueLength = _queue.length;
    _queue.removeWhere((s) => s.id == songId);
    if (_queue.length != initialQueueLength) {
      providerStateChanged = true;
    }

    // If the provider's state changed (current song or queue), update audio_handler's queue
    if (providerStateChanged) {
      if (_queue.isNotEmpty) {
        final mediaItems = await Future.wait(
            _queue.map((s) async => _prepareMediaItem(s)).toList());
        await _audioHandler.updateQueue(mediaItems);

        // If _currentSongFromAppLogic is now null but queue is not empty,
        // set to first item and advance handler
        if (_currentSongFromAppLogic == null && _queue.isNotEmpty) {
          _currentIndexInAppQueue = 0;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
        } else if (_queue.isEmpty) {
          _currentIndexInAppQueue = -1;
          await _audioHandler.stop();
        }
      } else {
        _currentIndexInAppQueue = -1;
        _currentSongFromAppLogic = null;
        await _audioHandler.stop();
        await _audioHandler.updateQueue([]);
      }
    }

    if (providerStateChanged) {
      notifyListeners();
      await _saveCurrentSongToStorage();
    }
  }

  void updateSongDetails(Song updatedSong) {
    bool providerStateChanged = false;
    // ignore: unused_local_variable
    bool currentSongWasUpdated = false;

    // Update in the provider's own queue
    final indexInProviderQueue =
        _queue.indexWhere((s) => s.id == updatedSong.id);
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

    // Update handler's queue and current item if needed
    if (providerStateChanged) {
      _prepareMediaItem(updatedSong).then((newMediaItem) async {
        final handlerQueue = List<MediaItem>.from(_audioHandler.queue.value);
        int itemIndexInHandlerQueue = handlerQueue
            .indexWhere((mi) => mi.extras?['songId'] == updatedSong.id);

        if (itemIndexInHandlerQueue != -1) {
          handlerQueue[itemIndexInHandlerQueue] = newMediaItem;
          await _audioHandler.updateQueue(handlerQueue);
        }
        // Optionally update current media item metadata if playing
        final currentHandlerMediaItem = _audioHandler.mediaItem.value;
        if (currentHandlerMediaItem != null &&
            currentHandlerMediaItem.extras?['songId'] == updatedSong.id) {
          _audioHandler.customAction('updateCurrentMediaItemMetadata', {
            'mediaItem': {
              'id': newMediaItem.id,
              'title': newMediaItem.title,
              'artist': newMediaItem.artist,
              'album': newMediaItem.album,
              'artUri': newMediaItem.artUri?.toString(),
              'duration': newMediaItem.duration?.inMilliseconds,
              'extras': newMediaItem.extras,
            }
          });
        }
      }).catchError((e, stackTrace) {
        debugPrint(
            "Error preparing or updating media item in handler for song ${updatedSong.id}: $e");
        debugPrintStack(stackTrace: stackTrace);
      });
    }

    if (providerStateChanged) {
      notifyListeners();
      _saveCurrentSongToStorage();
    }
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

  Future<void> updateMissingMetadata(Song song) async {
    if (!song.isDownloaded) return;

    Song updatedSong = song;
    bool needsUpdate = false;

    // Check and download album art if it's a network URL
    if (updatedSong.albumArtUrl.startsWith('http')) {
      final localArtFileName =
          await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
      if (localArtFileName != null) {
        updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        needsUpdate = true;
      }
    }

    // Check for lyrics using the new lyrics service
    final lyricsService = LyricsService();
    final newLyrics =
        await lyricsService.fetchLyricsIfNeeded(updatedSong, this);
    if (newLyrics != null) {
      updatedSong = updatedSong.copyWith(
        plainLyrics: newLyrics.plainLyrics,
        syncedLyrics: newLyrics.syncedLyrics,
      );
      needsUpdate = true;
    }

    if (song.isDownloaded &&
        song.albumArtUrl.isNotEmpty &&
        !song.albumArtUrl.startsWith('http')) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath =
          p.join(directory.path, 'ltunes_downloads', song.albumArtUrl);
      if (!await File(fullPath).exists()) {
        final downloadedArt = await _downloadAlbumArt(song.albumArtUrl, song);
        if (downloadedArt != null) {
          final updatedSong = song.copyWith(albumArtUrl: downloadedArt);
          updateSongDetails(updatedSong);
        }
      }
    }

    if (needsUpdate) {
      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong);
    }
  }

  // playUrl is not used by current app structure, can be removed or adapted
  void playUrl(String url) {
    // This would need to create a MediaItem and call _audioHandler.playMediaItem
    debugPrint(
        'Playing URL directly: $url - This method might need adaptation for audio_service');
    final tempSong = Song(
        id: url,
        title: "Direct URL",
        artist: "",
        artistId: "",
        albumArtUrl: "",
        audioUrl: url);
    playSong(tempSong); // Or a more direct handler call
  }

  Future<void> updateSongLyrics(String songId, LyricsData lyricsData) async {
    Song? songToUpdate;
    int queueIndex = _queue.indexWhere((s) => s.id == songId);

    if (queueIndex != -1) {
      songToUpdate = _queue[queueIndex];
    } else if (_currentSongFromAppLogic?.id == songId) {
      songToUpdate = _currentSongFromAppLogic;
    }

    if (songToUpdate != null) {
      final updatedSong = songToUpdate.copyWith(
        plainLyrics: lyricsData.plainLyrics,
        syncedLyrics: lyricsData.syncedLyrics,
      );

      // Persist the metadata for the individual song
      await _persistSongMetadata(updatedSong);

      // Update the song in the provider's state and notify audio_handler and UI
      // updateSongDetails handles updating _queue, _currentSongFromAppLogic,
      // notifying listeners, and updating AudioHandler's state.
      updateSongDetails(updatedSong);

      debugPrint(
          "Lyrics updated for song: ${updatedSong.title} (ID: ${updatedSong.id})");
    } else {
      debugPrint("Song with ID $songId not found for updating lyrics.");
    }
  }

  Future<void> playSong(Song songToPlay,
      {bool isResumingOrLooping = false}) async {
    _playRequestCounter++;
    final int currentPlayRequest = _playRequestCounter;

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
      if (currentPlayRequest != _playRequestCounter) return;

      if (!isResumingOrLooping) {
        int indexInExistingQueue =
            _queue.indexWhere((s) => s.id == songToPlay.id);

        if (indexInExistingQueue != -1) {
          // Song is part of the existing _queue. Play from this queue.
          _currentIndexInAppQueue = indexInExistingQueue;
          // Only update _currentSongFromAppLogic if the song at the index matches the song to play
          if (_queue[_currentIndexInAppQueue].id == songToPlay.id) {
            _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          }

          // Prepare queue for handler, ensuring MediaItems are up to date
          List<MediaItem> fullQueueMediaItems = await Future.wait(_queue
              .map((sInQueue) =>
                  _prepareMediaItem(sInQueue, playRequest: currentPlayRequest))
              .toList());
          if (currentPlayRequest != _playRequestCounter) return;
          await _audioHandler.updateQueue(fullQueueMediaItems);
        } else {
          // Song not in current _queue, treat as a new single-item queue.
          // _currentSongFromAppLogic was set to songToPlay.
          // Call _prepareMediaItem for this song. It will update _currentSongFromAppLogic
          // if its URL changes (due to the side effect in _prepareMediaItem).
          MediaItem mediaItem = await _prepareMediaItem(
              _currentSongFromAppLogic!,
              playRequest: currentPlayRequest);
          if (currentPlayRequest != _playRequestCounter) return;
          _queue = [_currentSongFromAppLogic!];
          _currentIndexInAppQueue = 0;
          await _audioHandler.updateQueue([mediaItem]);
        }
        if (currentPlayRequest != _playRequestCounter) return;
        await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
      }

      if (currentPlayRequest != _playRequestCounter) return;
      await _audioHandler.play();
      _prefetchNextSongs();
      _saveCurrentSongToStorage(); // Save state including potentially updated queue/song

      // --- Enhancement: Refetch missing info if needed ---
      final Song? currentSong = _currentSongFromAppLogic;
      if (currentSong != null) {
        bool needsMetadataUpdate = false;
        // Check for missing or network artwork
        if (currentSong.albumArtUrl.isEmpty) {
          needsMetadataUpdate = true;
        } else if (currentSong.albumArtUrl.startsWith('http')) {
          needsMetadataUpdate = true;
        }
        // Always check for missing local album art file if not empty and not a network URL
        if (currentSong.albumArtUrl.isNotEmpty &&
            !currentSong.albumArtUrl.startsWith('http')) {
          try {
            final appDocDir = await getApplicationDocumentsDirectory();
            final artPath = p.join(appDocDir.path, currentSong.albumArtUrl);
            debugPrint('[playSong] Checking for album art at: $artPath');
            if (!await File(artPath).exists()) {
              debugPrint(
                  '[playSong] Local album art file missing at preference path: $artPath');
              needsMetadataUpdate = true;
            }
          } catch (e) {
            debugPrint('[playSong] Error checking local album art file: $e');
          }
        }
        // Check for missing audio file if marked as downloaded
        if (currentSong.isDownloaded &&
            (currentSong.localFilePath == null ||
                currentSong.localFilePath!.isEmpty)) {
          // This should already be handled by fetchSongUrl/_prepareMediaItem, but double-check
          needsMetadataUpdate = true;
        }
        if (needsMetadataUpdate) {
          debugPrint(
              '[playSong] Refetching missing info for song: "${currentSong.title}" (ID: ${currentSong.id})');
          if (currentSong.albumArtUrl.isEmpty) {
            debugPrint('[playSong] Missing artwork: albumArtUrl is empty');
          } else if (currentSong.albumArtUrl.startsWith('http')) {
            debugPrint(
                '[playSong] Artwork is a network URL, will attempt to download');
          }
          if (currentSong.albumArtUrl.isNotEmpty &&
              !currentSong.albumArtUrl.startsWith('http')) {
            try {
              final appDocDir = await getApplicationDocumentsDirectory();
              final artPath = p.join(appDocDir.path, currentSong.albumArtUrl);
              debugPrint('[playSong] Checking for album art at: $artPath');
              if (!await File(artPath).exists()) {
                debugPrint(
                    '[playSong] Missing artwork: local file $artPath does not exist');
              }
            } catch (e) {
              debugPrint(
                  '[playSong] Error checking local album art file for logging: $e');
            }
          }
          if (currentSong.isDownloaded &&
              (currentSong.localFilePath == null ||
                  currentSong.localFilePath!.isEmpty)) {
            debugPrint('[playSong] Audio file is missing for downloaded song');
          }
          await updateMissingMetadata(currentSong);
          debugPrint(
              '[playSong] updateMissingMetadata complete for song: "${currentSong.title}" (ID: ${currentSong.id})');
          // After updating, refresh the current song from storage or memory and notify listeners
          Song? refreshedSong;
          int idx = _queue.indexWhere((s) => s.id == currentSong.id);
          if (idx != -1) {
            refreshedSong = _queue[idx];
          } else if (_currentSongFromAppLogic?.id == currentSong.id) {
            refreshedSong = _currentSongFromAppLogic;
          }
          if (refreshedSong != null) {
            debugPrint(
                '[playSong] Refreshed current song after metadata update. Notifying listeners.');
            _currentSongFromAppLogic = refreshedSong;
            notifyListeners();
          }
        }
      }
      // --- End enhancement ---
    } catch (e) {
      if (currentPlayRequest == _playRequestCounter) {
        // Use _currentSongFromAppLogic for the title in error, as it's the most up-to-date version.
        _errorHandler.logError(e, context: 'playSong');
        _isLoadingAudio = false;
        notifyListeners();
      } else {
        debugPrint(
            'Error in stale play request for \u001b[33m"+songToPlay.title+", ignoring.');
      }
    }
  }

  /// Always sets the queue context before playing the song.
  Future<void> playWithContext(List<Song> context, Song song,
      {bool playImmediately = true}) async {
    int index = context.indexWhere((s) => s.id == song.id);
    if (index == -1) return;
    _queue = List<Song>.from(context);
    _unshuffledQueue = List<Song>.from(
        context); // Save the new context as the pre-shuffled queue
    _currentIndexInAppQueue = index;
    _currentSongFromAppLogic = _queue[index];
    // Set the handler's _shouldBePaused flag based on playImmediately
    if (_audioHandler is AudioPlayerHandler) {
      (_audioHandler as AudioPlayerHandler).shouldBePaused = !playImmediately;
    }
    await _updateAudioHandlerQueue();
    await _audioHandler.skipToQueueItem(index);
    notifyListeners();
    _saveCurrentSongToStorage();
    // Persist the pre-shuffled queue to storage, ensuring shuffle is off for the save
    final wasShuffling = _isShuffling;
    if (wasShuffling) {
      _isShuffling = false;
      notifyListeners();
    }
    final prefs = await SharedPreferences.getInstance();
    List<String> unshuffledQueueJson =
        _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(
        'current_unshuffled_queue_v2', unshuffledQueueJson);
    if (wasShuffling) {
      _isShuffling = true;
      notifyListeners();
    }
  }

  /// Switches the queue context while keeping the current song and position.
  /// This is useful when clicking on the same song in a different playlist/album.
  Future<void> switchContext(List<Song> newContext) async {
    // Find the current song in the new context
    if (_currentSongFromAppLogic == null) return;

    int newIndex =
        newContext.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
    if (newIndex == -1) return; // Current song not found in new context

    // If switch context without interruption is disabled, behave like playWithContext
    if (!_switchContextWithoutInterruption) {
      await playWithContext(newContext, _currentSongFromAppLogic!,
          playImmediately: _isPlaying);
      return;
    }

    // Save current position and playback state
    final currentPosition = _currentPosition;
    final wasPlaying = _isPlaying;

    // Update the queue context
    _queue = List<Song>.from(newContext);
    _unshuffledQueue = List<Song>.from(newContext);
    _currentIndexInAppQueue = newIndex;

    // Update the current song reference to the one from the new context
    _currentSongFromAppLogic = _queue[newIndex];

    // Update the audio handler queue
    await _updateAudioHandlerQueue();
    await _audioHandler.skipToQueueItem(newIndex);

    // Restore position if we were playing
    if (wasPlaying && currentPosition > Duration.zero) {
      await _audioHandler.seek(currentPosition);
    }

    notifyListeners();
    _saveCurrentSongToStorage();

    // Persist the new unshuffled queue to storage
    final wasShuffling = _isShuffling;
    if (wasShuffling) {
      _isShuffling = false;
      notifyListeners();
    }
    final prefs = await SharedPreferences.getInstance();
    List<String> unshuffledQueueJson =
        _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(
        'current_unshuffled_queue_v2', unshuffledQueueJson);
    if (wasShuffling) {
      _isShuffling = true;
      notifyListeners();
    }
  }

  /// Smart play method that automatically chooses between playWithContext and switchContext.
  /// If the clicked song is the same as the currently playing song, it switches context.
  /// Otherwise, it plays the new song with the new context.
  Future<void> smartPlayWithContext(List<Song> context, Song song,
      {bool playImmediately = true}) async {
    // Check if the clicked song is the same as the currently playing song
    if (_currentSongFromAppLogic != null &&
        _currentSongFromAppLogic!.id == song.id) {
      // Same song, switch context
      await switchContext(context);
    } else {
      // Different song, play with new context
      await playWithContext(context, song, playImmediately: playImmediately);
    }
  }
}

