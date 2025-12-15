import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import '../services/playlist_manager_service.dart';
import 'package:path/path.dart' as p;
import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart';
import 'dart:async';
import '../models/lyrics_data.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:http/http.dart' as http;
import '../services/download_notification_service.dart';
import '../services/lyrics_service.dart';
import '../services/version_service.dart';

/// Validation result containing information about corrupted and unmarked songs
class ValidationResult {
  final List<Song> corruptedSongs;
  final List<Song> unmarkedSongs;

  ValidationResult({required this.corruptedSongs, required this.unmarkedSongs});

  int get totalIssues => corruptedSongs.length + unmarkedSongs.length;
}

class CurrentSongProvider with ChangeNotifier {
  final AudioHandler _audioHandler;
  Song? _currentSongFromAppLogic;
  bool _isPlaying = false;
  bool _isShuffling = false;
  List<Song> _queue = [];
  List<Song> _unshuffledQueue = [];
  int _currentIndexInAppQueue = -1;

  // Download management
  DownloadManager? _downloadManager;
  bool _isDownloadManagerInitialized = false;
  final Map<String, Song> _activeDownloads = {};
  final List<Song> _downloadQueue = [];
  int _currentActiveDownloadCount = 0;
  final Map<String, DateTime> _downloadStartTimes =
      {}; // Track when downloads started
  final Map<String, int> _downloadRetryCount = {};
  final Map<String, DateTime> _downloadLastRetry = {};

  // Queue reordering flag to prevent unwanted current song changes
  bool _isReorderingQueue = false;

  // Prevent sync loops when provider initiates queue changes
  DateTime? _lastProviderInitiatedQueueChange;

  // Prevent syncing during queue updates
  bool _isUpdatingAudioHandlerQueue = false;
  final Map<String, Timer> _retryTimers = {};
  static const int _maxDownloadRetries = 3;
  static const Duration _baseRetryDelay = Duration(seconds: 2);

  // Playback state
  int _playRequestCounter = 0;
  bool _isLoadingAudio = false;
  final Map<String, double> _downloadProgress = {};
  Duration _currentPosition = Duration.zero;
  Duration? _totalDuration;

  // Radio specific
  String? _stationName;
  String? _stationFavicon;

  // Playback settings
  double _playbackSpeed = 1.0;
  bool _switchContextWithoutInterruption = true;

  // Stream subscriptions
  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _mediaItemSubscription;
  StreamSubscription? _queueSubscription;
  StreamSubscription? _positionSubscription;

  // Services
  final DownloadNotificationService _downloadNotificationService =
      DownloadNotificationService();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  // Getters
  Song? get currentSong => _currentSongFromAppLogic;
  bool get isPlaying => _isPlaying;
  AudioHandler get audioHandler => _audioHandler;
  double get playbackSpeed => _playbackSpeed;
  bool get switchContextWithoutInterruption =>
      _switchContextWithoutInterruption;
  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  bool get isDownloadingSong => _downloadProgress.isNotEmpty;
  Map<String, Song> get activeDownloadTasks =>
      Map.unmodifiable(_activeDownloads);
  List<Song> get songsQueuedForDownload => List.unmodifiable(_downloadQueue);
  bool get isLoadingAudio => _isLoadingAudio;
  Duration? get totalDuration => _totalDuration;
  Duration get currentPosition => _currentPosition;
  Stream<Duration> get positionStream => AudioService.position;
  String? get stationName => _stationName;
  String? get stationFavicon => _stationFavicon;

  bool get isCurrentlyPlayingRadio {
    final mediaItem = _audioHandler.mediaItem.value;
    return mediaItem?.extras?['isRadio'] as bool? ?? false;
  }

  /// Returns the current repeat mode directly from the AudioHandler.
  /// Uses AudioServiceRepeatMode from audio_service package.
  AudioServiceRepeatMode get repeatMode =>
      _audioHandler.playbackState.value.repeatMode;

  bool get isShuffling => _isShuffling;

  static bool isAppInBackground = false;

  CurrentSongProvider(this._audioHandler) {
    _initializeProvider();
  }

  Future<void> _initializeProvider() async {
    await _initializeDownloadManager();
    await _primeDownloadProgressFromStorage();
    await _loadCurrentSongFromStorage(); // Make this awaited to ensure state is loaded before validation
    _listenToAudioHandler();
    await _loadPlaybackSpeedFromStorage();
    await _loadSwitchContextSettingFromStorage();

    _downloadNotificationService
        .setNotificationActionCallback(handleDownloadNotificationAction);
    _downloadNotificationService.setAudioHandler(_audioHandler);

    // Validate queue on initialization - now that state is fully loaded
    await validateAndFixQueue();

    // Ensure audio handler is properly synchronized after state loading
    await _synchronizeAudioHandlerState();
  }

  /// Synchronize the audio handler state with the provider's state after loading
  Future<void> _synchronizeAudioHandlerState() async {
    try {
      // If we have a current song and queue, ensure the audio handler is properly set up
      if (_currentSongFromAppLogic != null && _queue.isNotEmpty) {
        // Update the audio handler's queue if needed
        final mediaItems = await _prepareMediaItemsBatched(_queue);
        await _audioHandler.updateQueue(mediaItems);

        // Set the correct queue index
        if (_currentIndexInAppQueue >= 0 &&
            _currentIndexInAppQueue < _queue.length) {
          await _audioHandler.customAction(
              'setQueueIndex', {'index': _currentIndexInAppQueue});
        }

        // Prepare the current song for playback (but don't start playing automatically)
        await _audioHandler
            .customAction('prepareToPlay', {'index': _currentIndexInAppQueue});

        debugPrint(
            "CurrentSongProvider: Audio handler state synchronized successfully");
      } else {
        // No current song, ensure audio handler is in a clean state
        await _audioHandler.updateQueue([]);
        debugPrint(
            "CurrentSongProvider: Audio handler cleared - no saved state");
      }
    } catch (e) {
      debugPrint(
          "CurrentSongProvider: Error synchronizing audio handler state: $e");
      _errorHandler.logError(e, context: 'synchronizeAudioHandlerState');
    }
  }

  // Playback speed control methods
  Future<void> setPlaybackSpeed(double speed) async {
    if (Platform.isIOS) return;
    if (speed < 0.25 || speed > 3.0) return;

    try {
      await (_audioHandler as AudioPlayerHandler).setPlaybackSpeed(speed);
      _playbackSpeed = speed;
      notifyListeners();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_speed', speed);
    } catch (e) {
      _errorHandler.logError(e, context: 'setPlaybackSpeed');
    }
  }

  Future<void> resetPlaybackSpeed() async {
    if (Platform.isIOS) return;

    try {
      await (_audioHandler as AudioPlayerHandler).resetPlaybackSpeed();
      _playbackSpeed = 1.0;
      notifyListeners();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_speed', 1.0);
    } catch (e) {
      _errorHandler.logError(e, context: 'resetPlaybackSpeed');
    }
  }

  Future<void> setSwitchContextWithoutInterruption(bool value) async {
    _switchContextWithoutInterruption = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('switch_context_without_interruption', value);
    notifyListeners();
  }

  // Queue management
  Future<void> validateAndFixQueue() async {
    try {
      // Check if current index is valid
      if (_currentIndexInAppQueue < 0 ||
          _currentIndexInAppQueue >= _queue.length) {
        // Only show the error message if we have a queue but invalid index
        // This prevents showing the error when there's legitimately no saved state
        if (_queue.isNotEmpty) {
          debugPrint(
              "CurrentSongProvider: Invalid current index $_currentIndexInAppQueue for queue of length ${_queue.length}, fixing...");
        }

        if (_queue.isNotEmpty) {
          _currentIndexInAppQueue = 0;
          _currentSongFromAppLogic = _queue[0];
        } else {
          _currentIndexInAppQueue = -1;
          _currentSongFromAppLogic = null;
        }
        notifyListeners();
        _saveCurrentSongToStorage();
      }

      // Check if current song matches the queue
      if (_currentSongFromAppLogic != null &&
          _currentIndexInAppQueue >= 0 &&
          _currentIndexInAppQueue < _queue.length) {
        final expectedSong = _queue[_currentIndexInAppQueue];
        if (_currentSongFromAppLogic!.id != expectedSong.id) {
          debugPrint("CurrentSongProvider: Current song mismatch, fixing...");
          _currentSongFromAppLogic = expectedSong;
          notifyListeners();
          _saveCurrentSongToStorage();
        }
      }

      // Check for duplicate songs in queue
      final Set<String> seenIds = {};
      final List<Song> uniqueSongs = [];
      for (final song in _queue) {
        if (!seenIds.contains(song.id)) {
          seenIds.add(song.id);
          uniqueSongs.add(song);
        } else {
          debugPrint(
              "CurrentSongProvider: Found duplicate song in queue: ${song.id}");
        }
      }

      if (uniqueSongs.length != _queue.length) {
        debugPrint("CurrentSongProvider: Removing duplicate songs from queue");
        _queue = uniqueSongs;

        // Update current index if needed
        if (_currentSongFromAppLogic != null) {
          final newIndex =
              _queue.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
          if (newIndex != -1) {
            _currentIndexInAppQueue = newIndex;
          } else {
            _currentIndexInAppQueue = 0;
            _currentSongFromAppLogic = _queue.isNotEmpty ? _queue[0] : null;
          }
        }

        notifyListeners();
        _saveCurrentSongToStorage();
      }
    } catch (e, stackTrace) {
      debugPrint("CurrentSongProvider: Error validating queue: $e");
      debugPrintStack(stackTrace: stackTrace);
      _errorHandler.logError(e,
          context: 'queue validation', stackTrace: stackTrace);
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length) {
      return;
    }

    // Set flag to prevent unwanted current song changes during reordering
    _isReorderingQueue = true;

    try {
      // Store the currently playing song before reordering
      final currentlyPlayingSong = _currentSongFromAppLogic;
      final currentlyPlayingSongId = currentlyPlayingSong?.id;

      final song = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, song);

      // Always preserve the currently playing song reference
      if (currentlyPlayingSongId != null) {
        _currentIndexInAppQueue =
            _queue.indexWhere((s) => s.id == currentlyPlayingSongId);
        // Ensure the current song reference remains the same
        _currentSongFromAppLogic = currentlyPlayingSong;
      }

      notifyListeners();

      final mediaItems = await _prepareMediaItemsBatched(_queue);
      await _audioHandler.updateQueue(mediaItems);
      if (_currentIndexInAppQueue != -1) {
        await _audioHandler
            .customAction('setQueueIndex', {'index': _currentIndexInAppQueue});
      }
      _saveCurrentSongToStorage();
    } finally {
      // Reset flag after reordering is complete
      _isReorderingQueue = false;
    }
  }

  Future<void> setQueue(List<Song> songs, {int initialIndex = 0}) async {
    List<Song> canonicalSongs = [];
    for (final s in songs) {
      final downloaded =
          await _findExistingDownloadedSongByTitleArtist(s.title, s.artist);
      if (downloaded != null) {
        canonicalSongs.add(s.copyWith(
          id: downloaded.id,
          isDownloaded: downloaded.isDownloaded,
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

    _unshuffledQueue = List.from(canonicalSongs);

    if (_isShuffling && canonicalSongs.isNotEmpty) {
      // Create shuffled queue with initial song at the beginning if specified
      Song? initialSong;
      if (initialIndex >= 0 && initialIndex < canonicalSongs.length) {
        initialSong = canonicalSongs[initialIndex];
      }

      if (initialSong != null) {
        // Remove initial song from list to shuffle
        List<Song> songsToShuffle = List.from(canonicalSongs);
        songsToShuffle.removeWhere((s) => s.id == initialSong!.id);
        songsToShuffle.shuffle();
        // Put initial song at the beginning of shuffled queue
        _queue = [initialSong, ...songsToShuffle];
      } else {
        _queue = List.from(canonicalSongs)..shuffle();
      }
    } else {
      _queue = List.from(canonicalSongs);
    }

    debugPrint(
        "CurrentSongProvider: Queue initialized - shuffling: $_isShuffling, queue size: ${_queue.length}, unshuffled size: ${_unshuffledQueue.length}");

    if (_queue.isNotEmpty) {
      Song? initialSong;
      if (initialIndex >= 0 && initialIndex < _unshuffledQueue.length) {
        initialSong = _unshuffledQueue[initialIndex];
      }

      if (initialSong != null) {
        _currentIndexInAppQueue =
            _queue.indexWhere((s) => s.id == initialSong!.id);
        if (_currentIndexInAppQueue == -1) {
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

    try {
      final mediaItems = await _prepareMediaItemsBatched(_queue);
      await _audioHandler.updateQueue(mediaItems);

      if (_currentSongFromAppLogic != null && _currentIndexInAppQueue != -1) {
        await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
      } else if (_queue.isEmpty) {
        await _audioHandler.stop();
      }
    } catch (e) {
      debugPrint('Error setting queue: $e');
      // If there's an error, try to set a minimal queue with just the current song
      if (_currentSongFromAppLogic != null) {
        try {
          final mediaItem = await _prepareMediaItem(_currentSongFromAppLogic!);
          await _audioHandler.updateQueue([mediaItem]);
          await _skipToQueueItemWithFlag(0);
        } catch (fallbackError) {
          debugPrint('Fallback queue setting also failed: $fallbackError');
        }
      }
    }

    notifyListeners();
    _saveCurrentSongToStorage();
  }

  void addToQueue(Song song) async {
    if (_queue.any((s) => s.id == song.id)) return;

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
    Song? currentSong = _currentSongFromAppLogic;
    int currentIndex = _currentIndexInAppQueue;

    if (currentSong != null &&
        currentIndex >= 0 &&
        currentIndex < _queue.length) {
      _queue.clear();
      _queue.add(currentSong);
      _currentIndexInAppQueue = 0;

      final mediaItem = await _prepareMediaItem(currentSong);
      await _audioHandler.updateQueue([mediaItem]);
    } else {
      _queue.clear();
      _currentIndexInAppQueue = -1;
      await _audioHandler.updateQueue([]);
    }

    notifyListeners();
    _saveCurrentSongToStorage();
  }

  // Playback control methods
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
    final oldShuffleState = _isShuffling;
    _isShuffling = newShuffleState;

    if (_queue.isEmpty) {
      notifyListeners();
      await _saveCurrentSongToStorage();
      return;
    }

    final currentSongBeforeAction = _currentSongFromAppLogic;
    debugPrint(
        "CurrentSongProvider: Toggling shuffle from $oldShuffleState to $newShuffleState, current song: ${currentSongBeforeAction?.title}");

    if (newShuffleState) {
      // Enable shuffle: save unshuffled queue and create shuffled version
      if (_unshuffledQueue.isEmpty) {
        _unshuffledQueue = List.from(_queue);
      }

      // Create shuffled queue from current position
      _createShuffledQueueFromCurrentPosition();
    } else {
      // Disable shuffle: restore the unshuffled queue
      if (_unshuffledQueue.isNotEmpty) {
        _queue = List.from(_unshuffledQueue);

        // Find current song position in unshuffled queue
        if (currentSongBeforeAction != null) {
          final newIndex =
              _queue.indexWhere((s) => s.id == currentSongBeforeAction.id);
          if (newIndex != -1) {
            _currentIndexInAppQueue = newIndex;
            _currentSongFromAppLogic = currentSongBeforeAction;
          } else {
            _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
            _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
          }
        } else {
          _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
          _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
        }
      }
    }

    debugPrint(
        "CurrentSongProvider: After shuffle toggle, queue length: ${_queue.length}, current index: $_currentIndexInAppQueue, current song: ${_currentSongFromAppLogic?.title}");

    try {
      // Update the audio handler's queue without changing playback state
      await _updateAudioHandlerQueue();

      // Set the audio handler shuffle mode to none since we handle shuffle in the provider
      await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);

      debugPrint(
          "CurrentSongProvider: Audio handler queue updated successfully");
    } catch (e) {
      debugPrint(
          "CurrentSongProvider: Error updating audio handler queue during shuffle: $e");
    }

    notifyListeners();
    await _saveCurrentSongToStorage();
  }

  void playPrevious() {
    debugPrint(
        "CurrentSongProvider: playPrevious called, shuffling: $_isShuffling, queue size: ${_queue.length}");

    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();

      if (_isShuffling) {
        // Handle shuffle logic in provider
        _handleShufflePrevious();
      } else {
        // Non-shuffle mode: let audio handler handle the navigation
        _updateAudioHandlerQueue().then((_) {
          _audioHandler.skipToPrevious().then((_) {
            _isLoadingAudio = false;
            notifyListeners();
          }).catchError((e) {
            debugPrint("CurrentSongProvider: Error in skipToPrevious: $e");
            _isLoadingAudio = false;
            notifyListeners();
          });
        }).catchError((e) {
          debugPrint(
              "CurrentSongProvider: Error updating audio handler queue: $e");
          _isLoadingAudio = false;
          notifyListeners();
        });
      }
    } else {
      // Empty queue - let audio handler handle it
      _audioHandler.skipToPrevious().then((_) {
        notifyListeners();
      }).catchError((e) {
        debugPrint(
            "CurrentSongProvider: Error in skipToPrevious with empty queue: $e");
        notifyListeners();
      });
    }
  }

  void playNext() {
    debugPrint(
        "CurrentSongProvider: playNext called, shuffling: $_isShuffling, queue size: ${_queue.length}");

    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();

      if (_isShuffling) {
        // Handle shuffle logic in provider
        _handleShuffleNext();
      } else {
        // Non-shuffle mode: let audio handler handle the navigation
        _updateAudioHandlerQueue().then((_) {
          _audioHandler.skipToNext().then((_) {
            _isLoadingAudio = false;
            notifyListeners();
          }).catchError((e) {
            debugPrint("CurrentSongProvider: Error in skipToNext: $e");
            _isLoadingAudio = false;
            notifyListeners();
          });
        }).catchError((e) {
          debugPrint(
              "CurrentSongProvider: Error updating audio handler queue: $e");
          _isLoadingAudio = false;
          notifyListeners();
        });
      }
    } else {
      // Empty queue - let audio handler handle it
      _audioHandler.skipToNext().then((_) {
        notifyListeners();
      }).catchError((e) {
        debugPrint(
            "CurrentSongProvider: Error in skipToNext with empty queue: $e");
        notifyListeners();
      });
    }
  }

  Future<void> _handleShuffleNext() async {
    if (_queue.isEmpty) return;

    debugPrint(
        "CurrentSongProvider: _handleShuffleNext from index $_currentIndexInAppQueue");

    // Find next available song starting from next index
    final nextAvailableIndex =
        await _findNextAvailableSongIndex(_currentIndexInAppQueue + 1, _queue);

    if (nextAvailableIndex == null) {
      // No available songs found - check repeat mode
      final repeatMode = _audioHandler.playbackState.value.repeatMode;
      debugPrint(
          "CurrentSongProvider: No available songs found, repeat mode: $repeatMode");

      if (repeatMode == AudioServiceRepeatMode.all) {
        // Try from beginning
        final firstAvailableIndex =
            await _findNextAvailableSongIndex(0, _queue);
        if (firstAvailableIndex != null) {
          final previousIndex = _currentIndexInAppQueue;
          _currentIndexInAppQueue = firstAvailableIndex;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          try {
            await _updateAudioHandlerQueue();
            await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
          } catch (e) {
            debugPrint("CurrentSongProvider: Error in _handleShuffleNext: $e");
            _currentIndexInAppQueue = previousIndex;
            _currentSongFromAppLogic = _queue[previousIndex];
          }
          _isLoadingAudio = false;
          notifyListeners();
          await _saveCurrentSongToStorage();
          return;
        }
      }

      // No repeat or no available songs - end playback
      debugPrint("CurrentSongProvider: No available songs, stopping playback");
      await _audioHandler.pause();
      _isLoadingAudio = false;
      notifyListeners();
      return;
    }

    // Update current index and song BEFORE calling audio handler
    final previousIndex = _currentIndexInAppQueue;
    _currentIndexInAppQueue = nextAvailableIndex;
    _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];

    debugPrint(
        "CurrentSongProvider: Moving to shuffled song: ${_currentSongFromAppLogic?.title} at index $_currentIndexInAppQueue (from $previousIndex)");

    try {
      // Update audio handler queue and skip to the new song
      await _updateAudioHandlerQueue();
      await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
      debugPrint(
          "CurrentSongProvider: Successfully moved to next shuffled song");
    } catch (e) {
      debugPrint("CurrentSongProvider: Error in _handleShuffleNext: $e");
      // Try to find next available song on error
      final nextAvailableOnError = await _findNextAvailableSongIndex(
          _currentIndexInAppQueue + 1, _queue);
      if (nextAvailableOnError != null &&
          nextAvailableOnError != _currentIndexInAppQueue) {
        _currentIndexInAppQueue = nextAvailableOnError;
        _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
        try {
          await _updateAudioHandlerQueue();
          await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
        } catch (e2) {
          debugPrint("CurrentSongProvider: Error retrying shuffle next: $e2");
          _currentIndexInAppQueue = previousIndex;
          _currentSongFromAppLogic = _queue[previousIndex];
        }
      } else {
        // Revert on error to maintain consistency
        _currentIndexInAppQueue = previousIndex;
        _currentSongFromAppLogic = _queue[previousIndex];
      }
    }

    _isLoadingAudio = false;
    notifyListeners();
    await _saveCurrentSongToStorage();
  }

  Future<void> _handleShufflePrevious() async {
    if (_queue.isEmpty) return;

    debugPrint(
        "CurrentSongProvider: _handleShufflePrevious from index $_currentIndexInAppQueue");

    // Find previous available song starting from previous index
    // We need to search backwards through the queue
    int? prevAvailableIndex;
    for (int i = 1; i <= _queue.length; i++) {
      final checkIndex =
          (_currentIndexInAppQueue - i + _queue.length) % _queue.length;
      final song = _queue[checkIndex];
      if (await _isSongAvailable(song)) {
        prevAvailableIndex = checkIndex;
        break;
      }
    }

    if (prevAvailableIndex == null) {
      // No available songs found - check repeat mode
      final repeatMode = _audioHandler.playbackState.value.repeatMode;
      debugPrint(
          "CurrentSongProvider: No available songs found going backwards, repeat mode: $repeatMode");

      if (repeatMode == AudioServiceRepeatMode.all) {
        // Try from end
        for (int i = _queue.length - 1; i >= 0; i--) {
          if (await _isSongAvailable(_queue[i])) {
            prevAvailableIndex = i;
            break;
          }
        }
        if (prevAvailableIndex != null) {
          final previousIndex = _currentIndexInAppQueue;
          _currentIndexInAppQueue = prevAvailableIndex;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          try {
            await _updateAudioHandlerQueue();
            await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
          } catch (e) {
            debugPrint(
                "CurrentSongProvider: Error in _handleShufflePrevious: $e");
            _currentIndexInAppQueue = previousIndex;
            _currentSongFromAppLogic = _queue[previousIndex];
          }
          _isLoadingAudio = false;
          notifyListeners();
          await _saveCurrentSongToStorage();
          return;
        }
      }

      // No repeat or no available songs - stay at current
      debugPrint(
          "CurrentSongProvider: No available songs going backwards, staying at current");
      _isLoadingAudio = false;
      notifyListeners();
      return;
    }

    // Update current index and song BEFORE calling audio handler
    final previousIndex = _currentIndexInAppQueue;
    _currentIndexInAppQueue = prevAvailableIndex;
    _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];

    debugPrint(
        "CurrentSongProvider: Moving to previous shuffled song: ${_currentSongFromAppLogic?.title} at index $_currentIndexInAppQueue (from $previousIndex)");

    try {
      // Update audio handler queue and skip to the new song
      await _updateAudioHandlerQueue();
      await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
      debugPrint(
          "CurrentSongProvider: Successfully moved to previous shuffled song");
    } catch (e) {
      debugPrint("CurrentSongProvider: Error in _handleShufflePrevious: $e");
      // Try to find previous available song on error
      int? prevAvailableOnError;
      for (int i = 1; i <= _queue.length; i++) {
        final checkIndex =
            (_currentIndexInAppQueue - i + _queue.length) % _queue.length;
        if (await _isSongAvailable(_queue[checkIndex])) {
          prevAvailableOnError = checkIndex;
          break;
        }
      }
      if (prevAvailableOnError != null &&
          prevAvailableOnError != _currentIndexInAppQueue) {
        _currentIndexInAppQueue = prevAvailableOnError;
        _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
        try {
          await _updateAudioHandlerQueue();
          await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
        } catch (e2) {
          debugPrint(
              "CurrentSongProvider: Error retrying shuffle previous: $e2");
          _currentIndexInAppQueue = previousIndex;
          _currentSongFromAppLogic = _queue[previousIndex];
        }
      } else {
        // Revert on error to maintain consistency
        _currentIndexInAppQueue = previousIndex;
        _currentSongFromAppLogic = _queue[previousIndex];
      }
    }

    _isLoadingAudio = false;
    notifyListeners();
    await _saveCurrentSongToStorage();
  }

  Future<void> seek(Duration position) async {
    // Use the standard audio handler seek - it handles both streaming and local files
    await _audioHandler.seek(position);

    // Force immediate position update
    _currentPosition = position;
    notifyListeners();
  }

  /// Force sync the current position from the audio player
  Future<void> forcePositionSync() async {
    await _audioHandler.customAction('forcePositionSync', {});
    // Also update our internal position
    _currentPosition = (_audioHandler as AudioPlayerHandler).currentPosition;
    notifyListeners();
  }

  // Main play methods
  Future<void> playSong(Song songToPlay,
      {bool isResumingOrLooping = false}) async {
    _playRequestCounter++;
    final int currentPlayRequest = _playRequestCounter;

    // Check if song is available before attempting to play
    if (!isResumingOrLooping) {
      final isAvailable = await _isSongAvailable(songToPlay);
      if (!isAvailable) {
        debugPrint(
            'Song "${songToPlay.title}" is not available (no network or not downloaded). Skipping...');

        // If we have a queue, try to find the next available song
        if (_queue.isNotEmpty) {
          final currentIndex = _queue.indexWhere((s) => s.id == songToPlay.id);
          if (currentIndex != -1) {
            final nextAvailableIndex =
                await _findNextAvailableSongIndex(currentIndex + 1, _queue);
            if (nextAvailableIndex != null) {
              debugPrint(
                  'Found next available song at index $nextAvailableIndex, playing that instead.');
              await playSong(_queue[nextAvailableIndex],
                  isResumingOrLooping: false);
              return;
            }
          }
        }

        // No available songs found
        _isLoadingAudio = false;
        _errorHandler.logError(
            Exception(
                'Song "${songToPlay.title}" is not available offline and requires network connection.'),
            context: 'playSong');
        notifyListeners();
        return;
      }
    }

    _isLoadingAudio = true;
    if (!isResumingOrLooping || _currentSongFromAppLogic?.id != songToPlay.id) {
      _currentSongFromAppLogic = songToPlay;
    }
    _stationName = null;
    _stationFavicon = null;
    notifyListeners();

    try {
      if (currentPlayRequest != _playRequestCounter) return;

      if (!isResumingOrLooping) {
        int indexInExistingQueue =
            _queue.indexWhere((s) => s.id == songToPlay.id);

        if (indexInExistingQueue != -1) {
          _currentIndexInAppQueue = indexInExistingQueue;
          if (_queue[_currentIndexInAppQueue].id == songToPlay.id) {
            _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          }

          List<MediaItem> fullQueueMediaItems = await _prepareMediaItemsBatched(
              _queue,
              playRequest: currentPlayRequest);
          if (currentPlayRequest != _playRequestCounter) return;
          await _audioHandler.updateQueue(fullQueueMediaItems);
        } else {
          MediaItem mediaItem = await _prepareMediaItem(
              _currentSongFromAppLogic!,
              playRequest: currentPlayRequest);
          if (currentPlayRequest != _playRequestCounter) return;
          _queue = [_currentSongFromAppLogic!];
          _currentIndexInAppQueue = 0;
          await _audioHandler.updateQueue([mediaItem]);
        }
        if (currentPlayRequest != _playRequestCounter) return;
        await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
      }

      if (currentPlayRequest != _playRequestCounter) return;
      await _audioHandler.play();
      _prefetchNextSongs();
      _saveCurrentSongToStorage();

      // Refetch missing metadata if needed
      final Song? currentSong = _currentSongFromAppLogic;
      if (currentSong != null) {
        await _refetchMissingMetadataIfNeeded(currentSong);
      }
    } catch (e) {
      if (currentPlayRequest == _playRequestCounter) {
        debugPrint('Error playing song "${songToPlay.title}": $e');

        // Try to skip to next available song on error
        if (_queue.isNotEmpty) {
          final currentIndex = _queue.indexWhere((s) => s.id == songToPlay.id);
          if (currentIndex != -1) {
            final nextAvailableIndex =
                await _findNextAvailableSongIndex(currentIndex + 1, _queue);
            if (nextAvailableIndex != null &&
                nextAvailableIndex != currentIndex) {
              debugPrint(
                  'Error playing song, skipping to next available at index $nextAvailableIndex');
              _isLoadingAudio = false;
              notifyListeners();
              await playSong(_queue[nextAvailableIndex],
                  isResumingOrLooping: false);
              return;
            }
          }
        }

        _errorHandler.logError(e, context: 'playSong');
        _isLoadingAudio = false;
        notifyListeners();
      } else {
        debugPrint(
            'Error in stale play request for ${songToPlay.title}, ignoring.');
      }
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
    _stationName = stationName;
    _stationFavicon = stationFavicon ?? '';

    final radioSongId = 'radio_${stationName.hashCode}_${streamUrl.hashCode}';

    _currentSongFromAppLogic = Song(
        id: radioSongId,
        title: stationName,
        artist: 'Radio Station',
        artistId: '',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl,
        isDownloaded: false,
        extras: {'isRadio': true});
    notifyListeners();

    if (currentPlayRequest != _playRequestCounter) return;

    final mediaItem = MediaItem(
      id: streamUrl,
      title: stationName,
      artist: 'Radio Station',
      artUri: stationFavicon != null && stationFavicon.isNotEmpty
          ? Uri.tryParse(stationFavicon)
          : null,
      extras: {'isRadio': true, 'songId': radioSongId},
    );

    await _audioHandler.updateQueue([mediaItem]);
    await _skipToQueueItemWithFlag(0);

    if (currentPlayRequest != _playRequestCounter) return;

    _saveCurrentSongToStorage();
  }

  // Context switching methods
  Future<void> playWithContext(List<Song> context, Song song,
      {bool playImmediately = true}) async {
    int index = context.indexWhere((s) => s.id == song.id);
    if (index == -1) return;

    // Filter out unavailable songs from the context
    final availableSongs = <Song>[];
    for (final s in context) {
      if (await _isSongAvailable(s)) {
        availableSongs.add(s);
      } else {
        debugPrint(
            'Filtering out unavailable song "${s.title}" from playlist context');
      }
    }

    if (availableSongs.isEmpty) {
      debugPrint('No available songs in context, cannot play');
      _errorHandler.logError(
          Exception(
              'No available songs in playlist. All songs require network connection or are not downloaded.'),
          context: 'playWithContext');
      notifyListeners();
      return;
    }

    // Find the selected song in the filtered list
    int filteredIndex = availableSongs.indexWhere((s) => s.id == song.id);
    if (filteredIndex == -1) {
      // Selected song is not available, find the first available song
      debugPrint(
          'Selected song "${song.title}" is not available, using first available song');
      filteredIndex = 0;
      song = availableSongs[0];
    }

    _queue = List<Song>.from(availableSongs);
    _unshuffledQueue = List<Song>.from(availableSongs);
    _currentIndexInAppQueue = filteredIndex;
    _currentSongFromAppLogic = _queue[filteredIndex];

    // If shuffle is on, create a shuffled queue from the current position
    if (_isShuffling) {
      _createShuffledQueueFromCurrentPosition();
    }

    if (_audioHandler is AudioPlayerHandler) {
      (_audioHandler as AudioPlayerHandler).shouldBePaused = !playImmediately;
    }

    // Play the current song immediately without waiting for the entire queue
    try {
      // First, play the current song right away
      if (playImmediately) {
        await playSong(_currentSongFromAppLogic!, isResumingOrLooping: false);
      } else {
        // Still prepare the queue but don't play
        await _updateAudioHandlerQueue();
        await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
      }
    } catch (e) {
      debugPrint('Error playing song in context: $e');
      // Try to find next available song
      final nextAvailableIndex = await _findNextAvailableSongIndex(
          _currentIndexInAppQueue + 1, _queue);
      if (nextAvailableIndex != null) {
        _currentIndexInAppQueue = nextAvailableIndex;
        _currentSongFromAppLogic = _queue[nextAvailableIndex];
        if (playImmediately) {
          await playSong(_currentSongFromAppLogic!, isResumingOrLooping: false);
        } else {
          await _updateAudioHandlerQueue();
          await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
        }
      }
    }

    notifyListeners();
    _saveCurrentSongToStorage();

    // Save unshuffled queue to storage
    final prefs = await SharedPreferences.getInstance();
    List<String> unshuffledQueueJson =
        _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(
        'current_unshuffled_queue_v2', unshuffledQueueJson);
  }

  Future<void> switchContext(List<Song> newContext, [Song? targetSong]) async {
    if (_currentSongFromAppLogic == null) return;

    int newIndex = newContext
        .indexWhere((s) => _areSongsEquivalent(s, _currentSongFromAppLogic!));
    if (newIndex == -1) {
      // If we can't find the current song in the new context, fall back to playing
      // the target song (if provided) or the first equivalent song in the new context
      final songToPlay = targetSong ??
          newContext.firstWhere(
            (s) => _areSongsEquivalent(s, _currentSongFromAppLogic!),
            orElse: () => newContext.first,
          );
      await playWithContext(newContext, songToPlay,
          playImmediately: _isPlaying);
      return;
    }

    if (!_switchContextWithoutInterruption) {
      await playWithContext(newContext, _currentSongFromAppLogic!,
          playImmediately: _isPlaying);
      return;
    }

    final currentPosition = _currentPosition;
    final wasPlaying = _isPlaying;
    final wasShuffling = _isShuffling;

    _queue = List<Song>.from(newContext);
    _unshuffledQueue = List<Song>.from(newContext);
    _currentIndexInAppQueue = newIndex;
    _currentSongFromAppLogic = _queue[newIndex];

    // If shuffle was on, reshuffle the queue from the current position
    if (wasShuffling) {
      _createShuffledQueueFromCurrentPosition();
    }

    await _updateAudioHandlerQueue();
    await _skipToQueueItemWithFlag(_currentIndexInAppQueue);

    if (wasPlaying && currentPosition > Duration.zero) {
      await _audioHandler.seek(currentPosition);
    }

    notifyListeners();
    _saveCurrentSongToStorage();

    // Save unshuffled queue to storage
    final prefs = await SharedPreferences.getInstance();
    List<String> unshuffledQueueJson =
        _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(
        'current_unshuffled_queue_v2', unshuffledQueueJson);
  }

  Future<void> smartPlayWithContext(List<Song> context, Song song,
      {bool playImmediately = true}) async {
    if (_currentSongFromAppLogic != null &&
        _areSongsEquivalent(_currentSongFromAppLogic!, song)) {
      await switchContext(context, song);
    } else {
      await playWithContext(context, song, playImmediately: playImmediately);
    }
  }

  /// Play all songs from a context, with shuffle behavior:
  /// - If shuffle is on: skip to a random song and shuffle the queue from there
  /// - If shuffle is off: start from the first song
  Future<void> playAllWithContext(List<Song> context,
      {bool playImmediately = true}) async {
    if (context.isEmpty) return;

    Song songToPlay;
    if (_isShuffling) {
      // When shuffle is on, pick a random song
      final random = Random();
      songToPlay = context[random.nextInt(context.length)];
    } else {
      // When shuffle is off, start from the first song
      songToPlay = context.first;
    }

    await playWithContext(context, songToPlay,
        playImmediately: playImmediately);
  }

  // Helper methods
  Future<void> _skipToQueueItemWithFlag(int index) async {
    _lastProviderInitiatedQueueChange = DateTime.now();
    await _audioHandler.skipToQueueItem(index);
  }

  bool _areSongsEquivalent(Song song1, Song song2) {
    // First check if they're the same song by ID
    if (song1.id == song2.id) return true;

    // Then check if they have the same title and artist (for compatibility with existing logic)
    return song1.baseTitle.toLowerCase().trim() ==
            song2.baseTitle.toLowerCase().trim() &&
        song1.artist.toLowerCase().trim() == song2.artist.toLowerCase().trim();
  }

  /// Creates a shuffled queue from the current position, keeping the current song at the beginning
  void _createShuffledQueueFromCurrentPosition() {
    if (_unshuffledQueue.isEmpty || _currentSongFromAppLogic == null) return;

    // Get all songs except the current one
    List<Song> songsToShuffle = _unshuffledQueue
        .where((s) => s.id != _currentSongFromAppLogic!.id)
        .toList();

    // Shuffle the remaining songs
    songsToShuffle.shuffle();

    // Create new queue with current song at the beginning, followed by shuffled songs
    _queue = [_currentSongFromAppLogic!, ...songsToShuffle];
    _currentIndexInAppQueue = 0;

    debugPrint(
        "CurrentSongProvider: Created shuffled queue from current position, current song: ${_currentSongFromAppLogic?.title}, queue length: ${_queue.length}");
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndexInAppQueue == -1) return;
    // Prefetching logic can be implemented here if needed
  }

  Future<void> _updateAudioHandlerQueue() async {
    if (_queue.isEmpty) return;

    _isUpdatingAudioHandlerQueue = true;
    try {
      // Prepare media items and track which songs were successfully prepared
      final mediaItems = await _prepareMediaItemsBatched(_queue);

      // If some songs were skipped, we need to adjust the current index
      // Find the current song in the prepared media items
      if (_currentIndexInAppQueue >= 0 &&
          _currentIndexInAppQueue < _queue.length) {
        final currentSong = _queue[_currentIndexInAppQueue];
        // Find the index of the current song in the prepared media items
        int mediaItemIndex = -1;
        for (int i = 0; i < mediaItems.length; i++) {
          final songId = mediaItems[i].extras?['songId'] as String?;
          if (songId == currentSong.id) {
            mediaItemIndex = i;
            break;
          }
        }

        // If current song is not in prepared items, find next available
        if (mediaItemIndex == -1) {
          final nextAvailableIndex = await _findNextAvailableSongIndex(
              _currentIndexInAppQueue + 1, _queue);
          if (nextAvailableIndex != null) {
            _currentIndexInAppQueue = nextAvailableIndex;
            _currentSongFromAppLogic = _queue[nextAvailableIndex];
            // Find the new index in media items
            for (int i = 0; i < mediaItems.length; i++) {
              final songId = mediaItems[i].extras?['songId'] as String?;
              if (songId == _queue[nextAvailableIndex].id) {
                mediaItemIndex = i;
                break;
              }
            }
          }
        }

        await _audioHandler.updateQueue(mediaItems);

        if (mediaItemIndex != -1) {
          await _audioHandler
              .customAction('setQueueIndex', {'index': mediaItemIndex});
          // Update our internal index to match the media items index
          // But keep track of the original queue index for reference
        }
      } else {
        await _audioHandler.updateQueue(mediaItems);
      }
    } finally {
      _isUpdatingAudioHandlerQueue = false;
    }
  }

  Future<void> _refetchMissingMetadataIfNeeded(Song currentSong) async {
    bool needsMetadataUpdate = false;

    if (currentSong.albumArtUrl.isEmpty ||
        currentSong.albumArtUrl.startsWith('http')) {
      needsMetadataUpdate = true;
    }

    if (currentSong.albumArtUrl.isNotEmpty &&
        !currentSong.albumArtUrl.startsWith('http')) {
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        final artPath = p.join(appDocDir.path, currentSong.albumArtUrl);
        if (!await File(artPath).exists()) {
          needsMetadataUpdate = true;
        }
      } catch (e) {
        debugPrint('[playSong] Error checking local album art file: $e');
      }
    }

    if (currentSong.isDownloaded &&
        (currentSong.localFilePath == null ||
            currentSong.localFilePath!.isEmpty)) {
      needsMetadataUpdate = true;
    }

    if (needsMetadataUpdate) {
      debugPrint(
          '[playSong] Refetching missing info for song: "${currentSong.title}" (ID: ${currentSong.id})');
      await updateMissingMetadata(currentSong);

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

  // Essential missing methods

  /// Prepare media items in batches to avoid overwhelming the system with long queues
  /// Skips unavailable songs gracefully instead of failing
  Future<List<MediaItem>> _prepareMediaItemsBatched(List<Song> songs,
      {int batchSize = 10, int? playRequest}) async {
    if (songs.isEmpty) return [];

    final List<MediaItem> mediaItems = [];
    final int totalBatches = (songs.length / batchSize).ceil();

    debugPrint(
        "CurrentSongProvider: Preparing ${songs.length} media items in $totalBatches batches of $batchSize");

    for (int batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
      final int startIndex = batchIndex * batchSize;
      final int endIndex = (startIndex + batchSize).clamp(0, songs.length);
      final List<Song> batch = songs.sublist(startIndex, endIndex);

      // Prepare items individually and skip unavailable ones
      for (final song in batch) {
        try {
          // Check availability before preparing
          if (!await _isSongAvailable(song)) {
            debugPrint(
                "CurrentSongProvider: Skipping unavailable song '${song.title}' in batch ${batchIndex + 1}");
            continue;
          }

          final mediaItem =
              await _prepareMediaItem(song, playRequest: playRequest);
          mediaItems.add(mediaItem);
        } catch (e) {
          debugPrint(
              "CurrentSongProvider: Error preparing song '${song.title}' in batch ${batchIndex + 1}: $e");
          // Skip this song and continue with others
          continue;
        }
      }

      debugPrint(
          "CurrentSongProvider: Completed batch ${batchIndex + 1}/$totalBatches (${mediaItems.length} items prepared, ${batch.length - mediaItems.length} skipped)");
    }

    return mediaItems;
  }

  Future<MediaItem> _prepareMediaItem(Song song, {int? playRequest}) async {
    Song effectiveSong = song;

    if (!(song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false))) {
      final existingDownloadedSong =
          await _findExistingDownloadedSongByTitleArtist(
              song.title, song.artist);
      if (playRequest != null && playRequest != _playRequestCounter) {
        return Future.error('Cancelled');
      }
      if (existingDownloadedSong != null) {
        effectiveSong = song.copyWith(
          id: existingDownloadedSong.id,
          isDownloaded: true,
          localFilePath: existingDownloadedSong.localFilePath,
          duration: existingDownloadedSong.duration ?? song.duration,
          albumArtUrl: existingDownloadedSong.albumArtUrl.isNotEmpty &&
                  !existingDownloadedSong.albumArtUrl.startsWith('http')
              ? existingDownloadedSong.albumArtUrl
              : song.albumArtUrl,
        );
        await _persistSongMetadata(effectiveSong);
        await PlaylistManagerService().updateSongInPlaylists(effectiveSong);
      }
    }

    String playableUrl =
        await fetchSongUrl(effectiveSong, playRequest: playRequest);
    if (playRequest != null && playRequest != _playRequestCounter) {
      return Future.error('Cancelled');
    }

    if (playableUrl.isEmpty) {
      final apiService = ApiService();
      final fetchedApiUrl = await apiService.fetchAudioUrl(
          effectiveSong.artist, effectiveSong.title);
      if (playRequest != null && playRequest != _playRequestCounter) {
        return Future.error('Cancelled');
      }
      if (fetchedApiUrl != null && fetchedApiUrl.isNotEmpty) {
        playableUrl = fetchedApiUrl;
        effectiveSong = effectiveSong.copyWith(
            isDownloaded: false, localFilePath: null, audioUrl: playableUrl);
      } else {
        throw Exception(
            'Could not resolve playable URL for ${effectiveSong.title}');
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
        if (playRequest != null && playRequest != _playRequestCounter) {
          return Future.error('Cancelled');
        }
        songDuration = fetchedDuration;
        if (songDuration != null &&
            songDuration != Duration.zero &&
            effectiveSong.duration != songDuration) {
          effectiveSong = effectiveSong.copyWith(duration: songDuration);
        }
      } catch (e) {
        debugPrint("Error getting duration for ${effectiveSong.title}: $e");
        songDuration = effectiveSong.duration ?? Duration.zero;
      } finally {
        await audioPlayer.dispose();
      }
    }

    final extras = Map<String, dynamic>.from(effectiveSong.extras ?? {});
    extras['isRadio'] = effectiveSong.artist == 'Radio Station';
    extras['songId'] = effectiveSong.id;
    extras['isLocal'] = effectiveSong.isDownloaded;
    if (effectiveSong.isDownloaded &&
        effectiveSong.localFilePath != null &&
        effectiveSong.albumArtUrl.isNotEmpty &&
        !effectiveSong.albumArtUrl.startsWith('http')) {
      extras['localArtFileName'] = effectiveSong.albumArtUrl;
    }

    return songToMediaItem(effectiveSong, playableUrl, songDuration)
        .copyWith(extras: extras);
  }

  /// Check if a song is available for playback (downloaded or has network URL)
  Future<bool> _isSongAvailable(Song song) async {
    // Check if song is downloaded and file exists
    if (song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false)) {
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        final downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';
        final filePath =
            p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
        if (await File(filePath).exists()) {
          return true;
        }
      } catch (e) {
        debugPrint('Error checking local file for ${song.title}: $e');
      }
    }

    // Check if song has a valid network URL
    if (song.audioUrl.isNotEmpty &&
        (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false) &&
        !song.audioUrl.startsWith('file:/')) {
      // For streaming songs, be optimistic and assume network is available
      // The audio player will handle connection failures gracefully
      // Only do a network check as a last resort for very unreliable connections
      return true;
    }

    // For imported songs, check if they have a local file
    if (song.isImported) {
      return false; // Imported songs without local files are not available
    }

    // Song might be available if we can fetch URL (but we don't want to block on this)
    // Return true optimistically - we'll handle errors during actual playback
    return true;
  }

  /// Check network availability by attempting a simple HTTP request
  Future<bool> _checkNetworkAvailability() async {
    try {
      final client = http.Client();
      final response = await client
          .get(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 3));
      client.close();
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Network check failed: $e');
      return false;
    }
  }

  /// Find the next available song in the queue starting from the given index
  Future<int?> _findNextAvailableSongIndex(
      int startIndex, List<Song> songs) async {
    for (int i = 0; i < songs.length; i++) {
      final index = (startIndex + i) % songs.length;
      final song = songs[index];
      if (await _isSongAvailable(song)) {
        return index;
      }
    }
    return null;
  }

  Future<String> fetchSongUrl(Song song, {int? playRequest}) async {
    if (song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false)) {
      final appDocDir = await getApplicationDocumentsDirectory();
      if (playRequest != null && playRequest != _playRequestCounter) {
        return Future.error('Cancelled');
      }
      final downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath =
          p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
      if (await File(filePath).exists()) {
        final needsRedownload = await validateAndRedownloadIfNeeded(song);
        if (needsRedownload) {
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
      final updatedSong =
          song.copyWith(isDownloaded: false, localFilePath: null);
      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong);
      await PlaylistManagerService().updateSongInPlaylists(updatedSong);
      if (!song.isImported) {
        await redownloadSong(updatedSong);
      }
      if (song.isImported) {
        return '';
      }
    }

    if (song.isImported) {
      return '';
    }

    if (song.audioUrl.isNotEmpty &&
        (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false) &&
        !song.audioUrl.startsWith('file:/')) {
      return song.audioUrl;
    }

    final apiService = ApiService();
    final fetchedUrl = await apiService.fetchAudioUrl(song.artist, song.title);
    if (playRequest != null && playRequest != _playRequestCounter) {
      return Future.error('Cancelled');
    }
    return fetchedUrl ?? '';
  }

  // Initialization and storage methods
  Future<void> _initializeDownloadManager() async {
    if (_isDownloadManagerInitialized && _downloadManager != null) return;

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

  /// Check for stuck downloads and clean them up
  void _checkForStuckDownloads() {
    final now = DateTime.now();
    final stuckThreshold =
        const Duration(minutes: 5); // Consider stuck after 5 minutes

    final stuckDownloads = <String>[];

    for (final entry in _downloadStartTimes.entries) {
      final songId = entry.key;
      final startTime = entry.value;
      final progress = _downloadProgress[songId] ?? 0.0;

      // If download has been running for more than 5 minutes with no progress
      if (now.difference(startTime) > stuckThreshold && progress == 0.0) {
        stuckDownloads.add(songId);
      }
    }

    // Clean up stuck downloads
    for (final songId in stuckDownloads) {
      debugPrint(
          'Detected stuck download for song ID: $songId, cleaning up...');
      _handleDownloadError(
          songId, Exception('Download stuck - no progress for 5 minutes'));
    }
  }

  /// Public method to manually check for stuck downloads
  void checkForStuckDownloads() {
    _checkForStuckDownloads();
  }

  /// Public method to reinitialize the download manager if it's stuck
  Future<void> reinitializeDownloadManagerIfNeeded() async {
    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint('DownloadManager not initialized, reinitializing...');
      await reinitializeDownloadManager();
    }
  }

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
                'Error decoding song from SharedPreferences for key $key: $e');
          }
        }
      }
    }
    notifyListeners();
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song_v2');
    final savedPositionMilliseconds = prefs.getInt('current_position_v2');

    final savedLoopModeIndex = prefs.getInt('loop_mode_v2');
    if (savedLoopModeIndex != null &&
        savedLoopModeIndex < AudioServiceRepeatMode.values.length) {
      await _audioHandler
          .setRepeatMode(AudioServiceRepeatMode.values[savedLoopModeIndex]);
    }

    final savedShuffleMode = prefs.getBool('shuffle_mode_v2') ?? false;
    _isShuffling = savedShuffleMode;
    await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);

    if (songJson != null) {
      try {
        Map<String, dynamic> songMap = jsonDecode(songJson);
        Song loadedSong = Song.fromJson(songMap);
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
            _unshuffledQueue = List.from(_queue);
          }
        }

        if (!isRadioStream &&
            _queue.isNotEmpty &&
            _currentIndexInAppQueue != -1 &&
            _currentIndexInAppQueue < _queue.length) {
          final mediaItems = await Future.wait(
              _queue.map((s) async => await _prepareMediaItem(s)).toList());
          await _audioHandler.updateQueue(mediaItems);
          await _audioHandler.customAction(
              'prepareToPlay', {'index': _currentIndexInAppQueue});

          if (savedPositionMilliseconds != null) {
            await _audioHandler
                .seek(Duration(milliseconds: savedPositionMilliseconds));
          }
        } else if (_currentSongFromAppLogic != null) {
          final playableUrl = await fetchSongUrl(_currentSongFromAppLogic!);
          final mediaItem =
              songToMediaItem(_currentSongFromAppLogic!, playableUrl, null);

          if (isRadioStream) {
            _stationName = _currentSongFromAppLogic!.title;
            _stationFavicon = _currentSongFromAppLogic!.albumArtUrl;
            final radioExtras =
                Map<String, dynamic>.from(mediaItem.extras ?? {});
            radioExtras['isRadio'] = true;
            radioExtras['songId'] = _currentSongFromAppLogic!.id;
            final radioMediaItem = mediaItem.copyWith(
                extras: radioExtras,
                id: _currentSongFromAppLogic!.audioUrl,
                title: _stationName ?? 'Unknown Station',
                artist: "Radio Station");
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
              // Force immediate position sync after seeking
              _currentPosition =
                  Duration(milliseconds: savedPositionMilliseconds);
            }
          }
        }

        // Ensure position is synchronized with audio handler after loading
        final currentPlayerPosition =
            (_audioHandler as AudioPlayerHandler).currentPosition;
        if (currentPlayerPosition > Duration.zero) {
          _currentPosition = currentPlayerPosition;
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

  void _listenToAudioHandler() {
    _playbackStateSubscription =
        _audioHandler.playbackState.listen((playbackState) {
      final oldIsPlaying = _isPlaying;
      final oldIsLoading = _isLoadingAudio;
      final oldQueueIndex = _currentIndexInAppQueue;

      _isPlaying = playbackState.playing;
      _isLoadingAudio =
          playbackState.processingState == AudioProcessingState.loading ||
              playbackState.processingState == AudioProcessingState.buffering;

      // Sync queue index from audio handler, but NOT when shuffle is enabled
      // When shuffle is on, the provider handles navigation and should be the source of truth
      // Also don't sync if provider recently initiated a queue change to prevent loops
      final audioHandlerQueueIndex = playbackState.queueIndex;
      final recentlyChangedByProvider =
          _lastProviderInitiatedQueueChange != null &&
              DateTime.now().difference(_lastProviderInitiatedQueueChange!) <
                  const Duration(milliseconds: 500);

      if (!_isShuffling && // CRITICAL FIX: Don't sync when shuffling
          !recentlyChangedByProvider && // Don't sync if provider just changed it
          !_isUpdatingAudioHandlerQueue && // Don't sync while updating queue
          audioHandlerQueueIndex != null &&
          audioHandlerQueueIndex != _currentIndexInAppQueue &&
          audioHandlerQueueIndex >= 0 &&
          audioHandlerQueueIndex < _queue.length) {
        _currentIndexInAppQueue = audioHandlerQueueIndex;
        debugPrint(
            "CurrentSongProvider: Queue index synced from audio handler: $oldQueueIndex -> $_currentIndexInAppQueue");

        // Update current song if the index changed, but not during queue reordering
        if (!_isReorderingQueue &&
            _queue.isNotEmpty &&
            _currentIndexInAppQueue < _queue.length) {
          final newCurrentSong = _queue[_currentIndexInAppQueue];
          if (_currentSongFromAppLogic?.id != newCurrentSong.id) {
            _currentSongFromAppLogic = newCurrentSong;
          }
        }
      } else if (_isShuffling &&
          audioHandlerQueueIndex != null &&
          audioHandlerQueueIndex != _currentIndexInAppQueue) {
        debugPrint(
            "CurrentSongProvider: Ignoring audio handler queue index sync ($oldQueueIndex -> $audioHandlerQueueIndex) because shuffle is enabled");
      }

      if (oldIsPlaying != _isPlaying) {
        debugPrint(
            "CurrentSongProvider: Playing state changed from $oldIsPlaying to $_isPlaying");
      }
      if (oldIsLoading != _isLoadingAudio) {
        debugPrint(
            "CurrentSongProvider: Loading state changed from $oldIsLoading to $_isLoadingAudio");
      }

      if (oldIsPlaying && !_isPlaying) {
        debugPrint("CurrentSongProvider: Saving state due to pause");
        _saveCurrentSongToStorage();
      }

      if (_isLoadingAudio) {
        _checkForStuckLoadingState();
      }

      if (oldIsPlaying != _isPlaying ||
          oldIsLoading != _isLoadingAudio ||
          oldQueueIndex != _currentIndexInAppQueue) {
        notifyListeners();
      }
    });

    _mediaItemSubscription = _audioHandler.mediaItem.listen((mediaItem) async {
      bool needsNotification = false;

      if (_totalDuration != mediaItem?.duration) {
        _totalDuration = mediaItem?.duration;
        needsNotification = true;
      }

      if (mediaItem == null) {
        if (_currentSongFromAppLogic != null) {
          _currentSongFromAppLogic = null;
          needsNotification = true;
        }
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
          if (_isLoadingAudio &&
              _currentSongFromAppLogic != null &&
              newCurrentSongLogicCandidate.id != _currentSongFromAppLogic!.id) {
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

    _positionSubscription = AudioService.position.listen((position) {
      // Enhanced position stream handling for better foreground sync
      final oldPosition = _currentPosition;
      _currentPosition = position;

      // Debug log for significant position changes (helpful for foreground sync debugging)
      if ((position - oldPosition).abs() > const Duration(seconds: 2)) {
        debugPrint(
            "CurrentSongProvider: Significant position update from ${oldPosition.inSeconds}s to ${position.inSeconds}s");
      }

      notifyListeners();
    });

    _queueSubscription = _audioHandler.queue.listen((audioHandlerQueue) async {
      try {
        // Validate audio handler queue
        if (audioHandlerQueue.isEmpty) {
          if (_queue.isNotEmpty) {
            debugPrint(
                "CurrentSongProvider: Audio handler queue is empty, clearing provider queue");
            _queue.clear();
            _currentIndexInAppQueue = -1;
            _currentSongFromAppLogic = null;
            notifyListeners();
            _saveCurrentSongToStorage();
          }
          return;
        }

        // Sync the provider's queue with the audio handler's queue
        // But don't sync if we're currently updating the audio handler queue
        if (_isUpdatingAudioHandlerQueue) {
          debugPrint(
              "CurrentSongProvider: Skipping queue sync - currently updating audio handler queue");
          return;
        }

        bool queueChanged = false;

        // Check if the queue length changed
        if (_queue.length != audioHandlerQueue.length) {
          queueChanged = true;
          debugPrint(
              "CurrentSongProvider: Queue length changed from ${_queue.length} to ${audioHandlerQueue.length}");
        }

        // Check if any songs in the queue have changed
        if (!queueChanged &&
            _queue.isNotEmpty &&
            audioHandlerQueue.isNotEmpty) {
          for (int i = 0;
              i < _queue.length && i < audioHandlerQueue.length;
              i++) {
            final providerSong = _queue[i];
            final handlerMediaItem = audioHandlerQueue[i];
            final handlerSongId =
                handlerMediaItem.extras?['songId'] as String? ??
                    handlerMediaItem.id;

            if (providerSong.id != handlerSongId) {
              queueChanged = true;
              debugPrint(
                  "CurrentSongProvider: Queue item at index $i changed from ${providerSong.id} to $handlerSongId");
              break;
            }
          }
        }

        if (queueChanged) {
          // Rebuild the provider's queue from the audio handler's queue
          List<Song> newQueue = [];
          for (final mediaItem in audioHandlerQueue) {
            final songId = mediaItem.extras?['songId'] as String?;
            if (songId != null) {
              // Try to find the song in the current queue first
              final existingSong = _queue.firstWhere(
                (s) => s.id == songId,
                orElse: () => Song(
                  id: songId,
                  title: mediaItem.title,
                  artist: mediaItem.artist ?? 'Unknown Artist',
                  artistId: mediaItem.extras?['artistId'] as String? ?? '',
                  album: mediaItem.album,
                  albumArtUrl: mediaItem.artUri?.toString() ?? '',
                  audioUrl: mediaItem.id,
                  isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                  localFilePath:
                      (mediaItem.extras?['isLocal'] as bool? ?? false)
                          ? p.basename(mediaItem.id)
                          : null,
                ),
              );
              newQueue.add(existingSong);
            }
          }

          // Validate the new queue
          if (newQueue.isEmpty) {
            debugPrint(
                "CurrentSongProvider: Warning - new queue is empty after sync");
            return;
          }

          _queue = newQueue;

          // Update current index if needed
          if (_currentSongFromAppLogic != null) {
            final newIndex =
                _queue.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
            if (newIndex != -1 && _currentIndexInAppQueue != newIndex) {
              _currentIndexInAppQueue = newIndex;
              debugPrint(
                  "CurrentSongProvider: Current index updated to $newIndex");
            } else if (newIndex == -1) {
              // Current song is no longer in the queue, find the closest match
              debugPrint(
                  "CurrentSongProvider: Current song ${_currentSongFromAppLogic!.id} not found in new queue, updating to first song");
              _currentIndexInAppQueue = 0;
              _currentSongFromAppLogic = _queue[0];
            }
          } else if (_queue.isNotEmpty) {
            // No current song but queue has items, set to first
            _currentIndexInAppQueue = 0;
            _currentSongFromAppLogic = _queue[0];
          }

          // Validate current index
          if (_currentIndexInAppQueue >= _queue.length) {
            debugPrint(
                "CurrentSongProvider: Warning - current index $_currentIndexInAppQueue is out of bounds, resetting to 0");
            _currentIndexInAppQueue = 0;
            _currentSongFromAppLogic = _queue.isNotEmpty ? _queue[0] : null;
          }

          notifyListeners();
          _saveCurrentSongToStorage();
        }
      } catch (e, stackTrace) {
        debugPrint("CurrentSongProvider: Error in queue subscription: $e");
        debugPrintStack(stackTrace: stackTrace);
        _errorHandler.logError(e,
            context: 'queue subscription', stackTrace: stackTrace);
      }
    });
  }

  Future<void> _loadPlaybackSpeedFromStorage() async {
    if (Platform.isIOS) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble('playback_speed');
      if (savedSpeed != null && savedSpeed >= 0.25 && savedSpeed <= 3.0) {
        _playbackSpeed = savedSpeed;
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
    await prefs.setInt(
        'loop_mode_v2', _audioHandler.playbackState.value.repeatMode.index);
    await prefs.setBool('shuffle_mode_v2', _isShuffling);
  }

  /// Public method to save state to storage (called during app lifecycle changes)
  Future<void> saveStateToStorage() async {
    try {
      await _saveCurrentSongToStorage();
      debugPrint("CurrentSongProvider: State saved to storage successfully");
    } catch (e) {
      debugPrint("CurrentSongProvider: Error saving state to storage: $e");
      _errorHandler.logError(e, context: 'saveStateToStorage');
    }
  }

  Future<Song?> _findExistingDownloadedSongByTitleArtist(
      String title, String artist) async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final appDocDir = await getApplicationDocumentsDirectory();
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

            // Check for exact title match (including versions - different versions are different songs)
            if (songCandidate.isDownloaded &&
                songCandidate.localFilePath != null &&
                songCandidate.localFilePath!.isNotEmpty &&
                songCandidate.title.toLowerCase() == title.toLowerCase() &&
                songCandidate.artist.toLowerCase() == artist.toLowerCase()) {
              final fullPath = p.join(appDocDir.path, downloadsSubDir,
                  songCandidate.localFilePath!);
              if (await File(fullPath).exists()) {
                return songCandidate;
              } else {
                debugPrint(
                    "Song ${songCandidate.title} matched title/artist and isDownloaded=true, but local file $fullPath missing.");
              }
            }

            // Also check for imported songs that might be the same track
            if (songCandidate.isImported &&
                songCandidate.localFilePath != null &&
                songCandidate.localFilePath!.isNotEmpty &&
                songCandidate.title.toLowerCase() == title.toLowerCase() &&
                songCandidate.artist.toLowerCase() == artist.toLowerCase()) {
              final fullPath = p.join(appDocDir.path, downloadsSubDir,
                  songCandidate.localFilePath!);
              if (await File(fullPath).exists()) {
                return songCandidate;
              }
            }
          } catch (e) {
            debugPrint(
                'Error decoding song from SharedPreferences for key $key: $e');
          }
        }
      }
    }
    return null;
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
        return item.extras!['localArtFileName'] as String;
      }
    }
    return item.artUri?.toString() ?? '';
  }

  void _checkForStuckLoadingState() {
    Timer(const Duration(seconds: 45), () {
      if (_isLoadingAudio) {
        debugPrint(
            "CurrentSongProvider: Detected stuck loading state, resetting state");
        // Simply reset the loading state - the audio handler will handle recovery
        _isLoadingAudio = false;
        notifyListeners();
      }
    });
  }

  Future<void> handleAppForeground() async {
    debugPrint(
        "CurrentSongProvider: App foregrounded, syncing position and checking states");

    // Enhanced position synchronization for foreground transition
    try {
      // Wait for audio handler to complete its foreground processing
      await Future.delayed(const Duration(milliseconds: 200));

      // CRITICAL FIX: Detect and fix the audio session bug first
      // This prevents the bug where audio stops but UI shows as playing
      final bugDetectionResult =
          await _audioHandler.customAction('detectAndFixAudioSessionBug', {});
      if (bugDetectionResult is Map &&
          bugDetectionResult['bugDetected'] == true) {
        debugPrint(
            "CurrentSongProvider: Audio session bug was detected and fixed during foreground");
        // Update our state to reflect the fix
        _isPlaying = false;
        notifyListeners();
      }

      // Force position sync when app comes to foreground
      await _audioHandler.customAction('forcePositionSync', {});

      // Get the current position from audio handler after sync
      final currentPlayerPosition =
          (_audioHandler as AudioPlayerHandler).currentPosition;
      final wasPlayingBefore = _isPlaying;

      debugPrint(
          "CurrentSongProvider: Syncing position from ${_currentPosition.inSeconds}s to ${currentPlayerPosition.inSeconds}s");

      // Be smart about position updates - don't immediately trust 0 if we were at a different position
      Duration positionToUse = currentPlayerPosition;
      if (currentPlayerPosition == Duration.zero &&
          _currentPosition > Duration.zero &&
          _isPlaying) {
        debugPrint(
            "CurrentSongProvider: Audio handler returned 0 position but we were at ${_currentPosition.inSeconds}s and playing - keeping current position for now");
        positionToUse = _currentPosition;
      } else {
        // Update our position
        _currentPosition = currentPlayerPosition;
      }

      // Update playing state from audio handler
      final audioHandlerState = _audioHandler.playbackState.value;
      _isPlaying = audioHandlerState.playing;

      // Log the sync for debugging
      if (wasPlayingBefore != _isPlaying) {
        debugPrint(
            "CurrentSongProvider: Playing state also synced from $wasPlayingBefore to $_isPlaying");
      }

      notifyListeners();

      // Additional position verification after audio handler stabilizes
      Future.delayed(const Duration(milliseconds: 1200), () {
        final verifyPosition =
            (_audioHandler as AudioPlayerHandler).currentPosition;
        // More aggressive correction for position sync issues
        if (verifyPosition > Duration.zero &&
            (verifyPosition - _currentPosition).abs() >
                const Duration(seconds: 1)) {
          debugPrint(
              "CurrentSongProvider: Position drift detected, re-syncing from ${_currentPosition.inSeconds}s to ${verifyPosition.inSeconds}s");
          _currentPosition = verifyPosition;
          notifyListeners();
        } else if (_currentPosition == Duration.zero &&
            verifyPosition > Duration.zero &&
            _isPlaying) {
          debugPrint(
              "CurrentSongProvider: Correcting stuck 0 position to ${verifyPosition.inSeconds}s");
          _currentPosition = verifyPosition;
          notifyListeners();
        }
      });

      // Handle stuck loading states
      if (_isLoadingAudio) {
        await Future.delayed(const Duration(seconds: 3));

        if (_isLoadingAudio) {
          debugPrint(
              "CurrentSongProvider: Still loading after 3 seconds, resetting state");
          _isLoadingAudio = false;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("CurrentSongProvider: Error during foreground sync: $e");
      // Fall back to basic position sync if something goes wrong
      final fallbackPosition =
          (_audioHandler as AudioPlayerHandler).currentPosition;
      _currentPosition = fallbackPosition;
      notifyListeners();
    }
  }

  // Download notification and metadata methods
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

  Future<void> _persistSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  void updateSongDetails(Song updatedSong) {
    bool providerStateChanged = false;

    final indexInProviderQueue =
        _queue.indexWhere((s) => s.id == updatedSong.id);
    if (indexInProviderQueue != -1) {
      _queue[indexInProviderQueue] = updatedSong;
      providerStateChanged = true;
    }

    if (_currentSongFromAppLogic?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      providerStateChanged = true;
    }

    if (providerStateChanged) {
      _prepareMediaItem(updatedSong).then((newMediaItem) async {
        final handlerQueue = List<MediaItem>.from(_audioHandler.queue.value);
        int itemIndexInHandlerQueue = handlerQueue
            .indexWhere((mi) => mi.extras?['songId'] == updatedSong.id);

        if (itemIndexInHandlerQueue != -1) {
          handlerQueue[itemIndexInHandlerQueue] = newMediaItem;
          await _audioHandler.updateQueue(handlerQueue);
        }

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

  /// Updates song details but does NOT automatically switch the currently playing song
  /// This is used when a song download completes to prevent interrupting the current playback
  void updateSongDetailsWithoutSwitchingCurrent(Song updatedSong) {
    bool providerStateChanged = false;

    // Update the song in the queue
    final indexInProviderQueue =
        _queue.indexWhere((s) => s.id == updatedSong.id);
    if (indexInProviderQueue != -1) {
      _queue[indexInProviderQueue] = updatedSong;
      providerStateChanged = true;
    }

    // Also update in unshuffled queue if it exists
    if (_unshuffledQueue.isNotEmpty) {
      final indexInUnshuffledQueue =
          _unshuffledQueue.indexWhere((s) => s.id == updatedSong.id);
      if (indexInUnshuffledQueue != -1) {
        _unshuffledQueue[indexInUnshuffledQueue] = updatedSong;
      }
    }

    // IMPORTANT: Do NOT update _currentSongFromAppLogic here
    // The current song should keep playing from its original source (online URL)
    // until the user explicitly selects the song again

    debugPrint(
        "CurrentSongProvider: Updated song ${updatedSong.title} details without switching current playback (isDownloaded: ${updatedSong.isDownloaded})");

    // Update the audio handler queue with new metadata, but don't change current playback
    if (providerStateChanged) {
      // Only update queue items that aren't currently playing
      final currentMediaItem = _audioHandler.mediaItem.value;
      final isCurrentlyPlaying =
          currentMediaItem?.extras?['songId'] == updatedSong.id;

      if (!isCurrentlyPlaying) {
        // Safe to update non-current songs in the queue
        _prepareMediaItem(updatedSong).then((newMediaItem) async {
          final handlerQueue = List<MediaItem>.from(_audioHandler.queue.value);
          int itemIndexInHandlerQueue = handlerQueue
              .indexWhere((mi) => mi.extras?['songId'] == updatedSong.id);

          if (itemIndexInHandlerQueue != -1) {
            handlerQueue[itemIndexInHandlerQueue] = newMediaItem;
            await _audioHandler.updateQueue(handlerQueue);
          }
        }).catchError((e) {
          debugPrint('Error updating MediaItem in queue: $e');
        });
      } else {
        debugPrint(
            "CurrentSongProvider: Skipping audio handler update for currently playing song to avoid switching sources");
      }

      notifyListeners();
    }
  }

  Future<void> updateMissingMetadata(Song song) async {
    if (!song.isDownloaded) return;

    Song updatedSong = song;
    bool needsUpdate = false;

    if (updatedSong.albumArtUrl.startsWith('http')) {
      final localArtFileName =
          await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
      if (localArtFileName != null) {
        updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        needsUpdate = true;
      }
    }

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
        if (await file.exists()) {
          return fileName;
        } else {
          debugPrint(
              '[downloadAlbumArt] Local art file missing, attempting to fetch from network for ${song.title} by ${song.artist}');
          final apiService = ApiService();
          final searchResults =
              await apiService.fetchSongsVersionAware(song.artist, song.title);
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
        debugPrint(
            'File missing for downloaded song ${song.title}, but validateAndRedownloadIfNeeded only handles corruption');
        return false;
      }

      final fileSize = await file.length();
      if (fileSize == 0 || fileSize < 1024) {
        debugPrint(
            'File corrupted for downloaded song ${song.title} (size: $fileSize bytes), triggering redownload');
        await redownloadSong(song);
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('Error validating file for ${song.title}: $e');
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
                  await PlaylistManagerService()
                      .updateSongInPlaylists(updatedSong);
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

  Future<void> redownloadSong(Song song) async {
    debugPrint('CurrentSongProvider: Redownloading song: ${song.title}');

    try {
      _downloadRetryCount.remove(song.id);
      _downloadLastRetry.remove(song.id);
      _retryTimers[song.id]?.cancel();
      _retryTimers.remove(song.id);
      _activeDownloads.remove(song.id);
      _downloadProgress.remove(song.id);
      _downloadQueue.removeWhere((s) => s.id == song.id);

      final resetSong = song.copyWith(
        isDownloaded: false,
        localFilePath: null,
        isDownloading: false,
        downloadProgress: 0.0,
      );

      await _persistSongMetadata(resetSong);
      updateSongDetails(resetSong);
      await PlaylistManagerService().updateSongInPlaylists(resetSong);

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

      await queueSongForDownload(resetSong);
      debugPrint(
          'CurrentSongProvider: Song queued for redownload: ${song.title}');
    } catch (e) {
      debugPrint(
          'CurrentSongProvider: Error redownloading song ${song.title}: $e');
      _errorHandler.logError(e, context: 'redownloadSong');
    }
  }

  // Download management methods (simplified)
  // Check download status without triggering downloads
  Future<void> checkDownloadStatus(Song song) async {
    if (song.isImported) {
      debugPrint(
          'Song "${song.title}" is imported. Skipping download status check.');
      if (_downloadProgress[song.id] != 1.0) {
        _downloadProgress[song.id] = 1.0;
        if (_activeDownloads.containsKey(song.id)) {
          _activeDownloads.remove(song.id);
        }
        notifyListeners();
      }
      return;
    }

    final existingDownloadedSong =
        await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);
    if (existingDownloadedSong != null) {
      debugPrint(
          "Song \"${song.title}\" by ${song.artist} is already downloaded. Updating metadata.");
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

      final songToProcess = song.copyWith(
        id: existingDownloadedSong.id,
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        audioUrl: existingDownloadedSong.localFilePath,
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: albumArtToUse,
      );

      await _persistSongMetadata(songToProcess);
      updateSongDetails(songToProcess);
      await PlaylistManagerService().updateSongInPlaylists(songToProcess);

      _downloadProgress[songToProcess.id] = 1.0;
      if (_activeDownloads.containsKey(songToProcess.id)) {
        _activeDownloads.remove(songToProcess.id);
      }
      notifyListeners();
    }
  }

  Future<void> queueSongForDownload(Song song) async {
    await _initializeDownloadManager();
    if (_downloadManager == null) {
      debugPrint(
          "DownloadManager unavailable after initialization. Cannot queue \"${song.title}\".");
      return;
    }

    if (song.isImported) {
      debugPrint('Song "${song.title}" is imported. Skipping download queue.');
      if (_downloadProgress[song.id] != 1.0) {
        _downloadProgress[song.id] = 1.0;
        if (_activeDownloads.containsKey(song.id)) {
          _activeDownloads.remove(song.id);
        }
        notifyListeners();
      }
      return;
    }

    final existingDownloadedSong =
        await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);
    if (existingDownloadedSong != null) {
      debugPrint(
          "Song \"${song.title}\" by ${song.artist} is already downloaded. Updating metadata and skipping download queue.");
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

      final songToProcess = song.copyWith(
        id: existingDownloadedSong.id,
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        audioUrl: existingDownloadedSong.localFilePath,
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: albumArtToUse,
      );

      await _persistSongMetadata(songToProcess);
      updateSongDetails(songToProcess);
      await PlaylistManagerService().updateSongInPlaylists(songToProcess);

      _downloadProgress[songToProcess.id] = 1.0;
      if (_activeDownloads.containsKey(songToProcess.id)) {
        _activeDownloads.remove(songToProcess.id);
      }
      notifyListeners();
      return;
    }

    if (_activeDownloads.containsKey(song.id) ||
        _downloadQueue.any((s) => s.id == song.id)) {
      return;
    }

    _downloadQueue.add(song);
    notifyListeners();
    _triggerNextDownloadInProviderQueue();
  }

  void _triggerNextDownloadInProviderQueue() async {
    // Check for stuck downloads before processing new ones
    _checkForStuckDownloads();

    final prefs = await SharedPreferences.getInstance();
    final maxConcurrentDownloads = prefs.getInt('maxConcurrentDownloads') ?? 1;

    while (_currentActiveDownloadCount < maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final Song songToDownload = _downloadQueue.removeAt(0);
      _activeDownloads[songToDownload.id] = songToDownload;
      _downloadProgress[songToDownload.id] =
          _downloadProgress[songToDownload.id] ?? 0.0;
      _downloadStartTimes[songToDownload.id] =
          DateTime.now(); // Track start time
      _currentActiveDownloadCount++;
      notifyListeners();
      _processAndSubmitDownload(songToDownload);
    }
  }

  Future<void> _processAndSubmitDownload(Song song) async {
    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint(
          'DownloadManager not initialized, attempting to reinitialize...');
      await reinitializeDownloadManager();
      if (!_isDownloadManagerInitialized || _downloadManager == null) {
        _handleDownloadError(song.id,
            Exception("DownloadManager failed to initialize after retry"));
        return;
      }
    }

    String? audioUrl;
    try {
      // Add timeout for URL fetching to prevent getting stuck
      audioUrl = await fetchSongUrl(song).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout while fetching song URL');
        },
      );
      if (audioUrl.isEmpty ||
          audioUrl.startsWith('file://') ||
          !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        final apiService = ApiService();
        audioUrl =
            await apiService.fetchAudioUrl(song.artist, song.title).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw Exception('Timeout while fetching audio URL from API');
          },
        );
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
        }
      },
    );

    try {
      // Add timeout for the actual download to prevent getting stuck
      final downloadedFile = await _downloadManager!.getFile(queueItem).timeout(
        const Duration(minutes: 10), // 10 minute timeout for downloads
        onTimeout: () {
          throw Exception(
              'Download timeout - download took longer than 10 minutes');
        },
      );
      if (downloadedFile != null && await downloadedFile.exists()) {
        final fileSize = await downloadedFile.length();
        if (fileSize > 0) {
          _handleDownloadSuccess(song.id, p.basename(downloadedFile.path));
        } else {
          await _cleanupCorruptedFile(downloadedFile);
          _handleDownloadFailure(
              song.id, Exception('Downloaded file is empty or corrupted'));
        }
      } else {
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

  void _handleDownloadSuccess(String songId, String actualLocalFileName) async {
    Song? song = _activeDownloads[songId];
    if (song == null) return;

    try {
      Song updatedSong = song.copyWith(
        isDownloaded: true,
        localFilePath: actualLocalFileName,
        isDownloading: false,
        downloadProgress: 1.0,
      );

      if (updatedSong.albumArtUrl.startsWith('http')) {
        final localArtFileName =
            await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
        if (localArtFileName != null) {
          updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        }
      }

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
      updateSongDetailsWithoutSwitchingCurrent(updatedSong);
      await PlaylistManagerService().updateSongInPlaylists(updatedSong);
      debugPrint(
          'Download complete: ${updatedSong.title}. Lyrics fetched: ${lyricsData != null && (lyricsData.plainLyrics != null || lyricsData.syncedLyrics != null)}');
    } catch (e) {
      debugPrint(
          "Error during post-download success processing for ${song.title}: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
        _downloadStartTimes.remove(songId); // Clean up start time tracking
      }
      _currentActiveDownloadCount--;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    }
  }

  void _handleDownloadFailure(String songId, dynamic error) {
    final song = _activeDownloads[songId];
    final retryCount = _downloadRetryCount[songId] ?? 0;

    if (song != null && retryCount < _maxDownloadRetries) {
      _downloadRetryCount[songId] = retryCount + 1;
      _downloadLastRetry[songId] = DateTime.now();

      final retryDelay =
          Duration(seconds: _baseRetryDelay.inSeconds * (1 << retryCount));
      _retryTimers[songId]?.cancel();
      _retryTimers[songId] = Timer(retryDelay, () {
        _downloadQueue.insert(0, song);
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
        _currentActiveDownloadCount--;
        notifyListeners();
        _triggerNextDownloadInProviderQueue();
      });

      _activeDownloads.remove(songId);
      _downloadProgress.remove(songId);
      _downloadStartTimes.remove(songId); // Clean up start time tracking
      _currentActiveDownloadCount--;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    } else {
      _handleDownloadError(songId, error);
    }
  }

  void _handleDownloadError(String songId, dynamic error) {
    final song = _activeDownloads[songId];
    try {
      if (song != null) {
        _errorHandler.logError(error, context: 'downloadSong');
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'handleDownloadError');
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
        _downloadStartTimes.remove(songId); // Clean up start time tracking
      }
      _currentActiveDownloadCount--;
      notifyListeners();
      _triggerNextDownloadInProviderQueue();
    }
  }

  Future<void> cancelDownload(String songId) async {
    int queueIndex = _downloadQueue.indexWhere((s) => s.id == songId);
    if (queueIndex != -1) {
      _downloadQueue.removeAt(queueIndex);
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
      }
      notifyListeners();
      return;
    }

    final song = _activeDownloads[songId];
    if (song == null) {
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
        notifyListeners();
      }
      return;
    }

    if (!_isDownloadManagerInitialized || _downloadManager == null) {
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
        await _downloadManager!.cancelDownload(originalAudioUrl);
      } catch (e) {
        debugPrint('URL-based cancel failed for ${song.title}: $e');
      }
    }

    try {
      await _downloadManager!.cancelDownload(uniqueFileNameBaseForCancellation);
    } catch (e) {
      debugPrint('Filename-based cancel also failed for ${song.title}: $e');
    }

    _retryTimers[songId]?.cancel();
    _retryTimers.remove(songId);
    _downloadRetryCount.remove(songId);
    _downloadLastRetry.remove(songId);

    if (_activeDownloads.containsKey(songId)) {
      _activeDownloads.remove(songId);
    }
    if (_downloadProgress.containsKey(songId)) {
      _downloadProgress.remove(songId);
    }
    notifyListeners();
  }

  Future<void> cancelAllDownloads() async {
    debugPrint("Attempting to cancel all downloads.");

    final List<String> songIdsToCancel = [];
    songIdsToCancel.addAll(_activeDownloads.keys);
    songIdsToCancel.addAll(_downloadQueue.map((s) => s.id).toList());
    final uniqueSongIdsToCancel = songIdsToCancel.toSet().toList();

    if (uniqueSongIdsToCancel.isEmpty) {
      debugPrint("No downloads to cancel.");
      return;
    }

    for (final songId in uniqueSongIdsToCancel) {
      await cancelDownload(songId);
    }

    _downloadQueue.clear();
    _downloadRetryCount.clear();
    _downloadLastRetry.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();

    debugPrint(
        "All download cancellation requests initiated. Provider queue cleared.");
    notifyListeners();
  }

  // Utility methods
  void updateDownloadedSong(Song updatedSong) {
    if (currentSong?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      notifyListeners();
    }
  }

  void setCurrentSong(Song song) async {
    _currentSongFromAppLogic = song;
    notifyListeners();
  }

  void playUrl(String url) {
    debugPrint(
        'Playing URL directly: $url - This method might need adaptation for audio_service');
    final tempSong = Song(
        id: url,
        title: "Direct URL",
        artist: "",
        artistId: "",
        albumArtUrl: "",
        audioUrl: url);
    playSong(tempSong);
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

      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong);
      debugPrint(
          "Lyrics updated for song: ${updatedSong.title} (ID: ${updatedSong.id})");
    } else {
      debugPrint("Song with ID $songId not found for updating lyrics.");
    }
  }

  Future<void> processSongLibraryRemoval(String songId) async {
    bool providerStateChanged = false;

    if (_currentSongFromAppLogic?.id == songId) {
      _currentSongFromAppLogic = null;
      providerStateChanged = true;
    }

    final int initialQueueLength = _queue.length;
    _queue.removeWhere((s) => s.id == songId);
    if (_queue.length != initialQueueLength) {
      providerStateChanged = true;
    }

    if (providerStateChanged) {
      if (_queue.isNotEmpty) {
        final mediaItems = await Future.wait(
            _queue.map((s) async => _prepareMediaItem(s)).toList());
        await _audioHandler.updateQueue(mediaItems);

        if (_currentSongFromAppLogic == null && _queue.isNotEmpty) {
          _currentIndexInAppQueue = 0;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          await _skipToQueueItemWithFlag(_currentIndexInAppQueue);
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

  @override
  void dispose() {
    _downloadManager?.dispose();
    _activeDownloads.clear();
    _downloadProgress.clear();

    _playbackStateSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _queueSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}
