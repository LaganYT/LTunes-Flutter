import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/song.dart';
import 'package:audio_session/audio_session.dart';
import '../screens/download_queue_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'audio_effects_service.dart';
import 'bug_report_service.dart';
import 'package:rxdart/rxdart.dart';

final GlobalKey<NavigatorState> globalNavigatorKey =
    GlobalKey<NavigatorState>();

MediaItem songToMediaItem(Song song, String playableUrl, Duration? duration) {
  Uri? artUri;
  if (song.albumArtUrl.isNotEmpty && song.albumArtUrl.startsWith('http')) {
    artUri = Uri.tryParse(song.albumArtUrl);
  }
  return MediaItem(
    id: playableUrl,
    title: song.title,
    artist: song.artist,
    album: song.album,
    artUri: artUri,
    duration: (duration != null && duration > Duration.zero)
        ? duration
        : song.duration,
    extras: {
      'songId': song.id,
      'isLocal': song.isDownloaded,
      'localArtFileName':
          (!song.albumArtUrl.startsWith('http') && song.albumArtUrl.isNotEmpty)
              ? song.albumArtUrl
              : null,
      'isRadio': song.isRadio,
    },
  );
}

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}

/// Improved Audio Player Handler with better initialization and queue management
class ImprovedAudioPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final BehaviorSubject<List<MediaItem>> _queueSubject = BehaviorSubject.seeded([]);
  int _currentIndex = -1;
  bool _isRadioStream = false;
  AudioSession? _audioSession;
  final bool _isIOS = Platform.isIOS;
  bool _audioSessionConfigured = false;
  bool _isBackgroundMode = false;
  String? _lastCompletedSongId;
  bool _isHandlingCompletion = false;
  Duration? _lastKnownPosition;
  bool _shouldBePaused = false;
  final AudioEffectsService _audioEffectsService = AudioEffectsService();

  // Error handling counters
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;
  Timer? _errorRecoveryTimer;

  // Session management
  DateTime? _lastSessionActivation;
  static const Duration _sessionActivationCooldown = Duration(milliseconds: 500);
  bool _isSessionActive = false;

  // Completion handling
  DateTime? _lastCompletionTime;
  static const Duration _completionCooldown = Duration(milliseconds: 500);

  // Gapless playback
  bool _gaplessModeEnabled = true;
  static const Duration _gaplessTransitionDelay = Duration(milliseconds: 10);

  ImprovedAudioPlayerHandler() {
    _initializeWithDefaults();
    _initializeAudioSession();
    _configureAudioPlayer();
    _notifyAudioHandlerAboutPlaybackEvents();
    _initializeAudioEffects();
  }

  /// Initialize handler with proper default values as shown in demo
  void _initializeWithDefaults() {
    // Initialize playback state with correct defaults
    final initialState = PlaybackState(
      updateTime: DateTime.now(),
      playing: false,
      processingState: AudioProcessingState.idle,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      repeatMode: AudioServiceRepeatMode.none,
      shuffleMode: AudioServiceShuffleMode.none,
    );
    
    playbackState.add(initialState);
    
    // Initialize queue with empty list
    queue.add(<MediaItem>[]);
    
    // Initialize queue title
    queueTitle.add('');
    
    // Initialize media item as null
    mediaItem.add(null);
  }

  /// Enhanced click handling similar to demo code
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.nvalue?.playing == true) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  /// Get current position with proper error handling
  Duration get currentPosition => _audioPlayer.position;

  /// Check if should be paused
  bool get shouldBePaused => _shouldBePaused;

  /// Set should be paused state
  set shouldBePaused(bool value) {
    _shouldBePaused = value;
    if (value && _audioPlayer.playing) {
      _audioPlayer.pause();
      playbackState.add(playbackState.nvalue!.copyWith(playing: false));
    }
  }

  /// Enable or disable gapless playback mode
  void setGaplessMode(bool enabled) {
    _gaplessModeEnabled = enabled;
    debugPrint("ImprovedAudioHandler: Gapless mode ${enabled ? 'enabled' : 'disabled'}");
  }

  /// Get current gapless mode status
  bool get gaplessModeEnabled => _gaplessModeEnabled;

  /// Configure audio player for optimal playback
  void _configureAudioPlayer() {
    // Configure automatic wait to minimize stalling
    _audioPlayer.setAutomaticallyWaitsToMinimizeStalling(true);
  }

  /// Initialize audio session with better error handling
  Future<void> _initializeAudioSession() async {
    if (_audioSessionConfigured) return;

    try {
      _audioSession = await AudioSession.instance;

      if (_isIOS) {
        await _audioSession!.configure(AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
                  AVAudioSessionCategoryOptions.allowAirPlay,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
        ));

        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream.listen((_) => _handleBecomingNoisy());

        try {
          await Future.delayed(const Duration(milliseconds: 100));
          await _audioSession!.setActive(true);
          _isSessionActive = true;
        } catch (e) {
          debugPrint("Initial audio session activation failed (non-critical): $e");
          _isSessionActive = false;
        }
      } else {
        await _audioSession!.configure(const AudioSessionConfiguration.music());
      }

      _audioSessionConfigured = true;
      debugPrint("ImprovedAudioHandler: Audio session initialized successfully");
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
    }
  }

  /// Handle audio interruptions
  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      if (event.type == AudioInterruptionType.pause ||
          event.type == AudioInterruptionType.unknown) {
        if (_audioPlayer.playing) _audioPlayer.pause();
      }
    } else {
      if (event.type == AudioInterruptionType.pause ||
          event.type == AudioInterruptionType.unknown) {
        if (_isBackgroundMode) {
          _ensureAudioSessionActive().then((_) {
            if (!_audioPlayer.playing && _currentIndex >= 0) {
              _audioPlayer.play();
            }
          });
        } else {
          if (!_audioPlayer.playing && _currentIndex >= 0) _audioPlayer.play();
        }
      }
    }
  }

  /// Handle becoming noisy (headphones disconnected)
  void _handleBecomingNoisy() {
    if (_audioPlayer.playing) _audioPlayer.pause();
  }

  /// Ensure audio session is active
  Future<void> _ensureAudioSessionActive() async {
    if (!_isIOS || _audioSession == null || !_audioSessionConfigured) return;

    if (!_audioPlayer.playing && !_isBackgroundMode) {
      return;
    }

    final now = DateTime.now();
    if (_lastSessionActivation != null &&
        now.difference(_lastSessionActivation!) < _sessionActivationCooldown) {
      return;
    }

    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      debugPrint("ImprovedAudioHandler: Too many consecutive errors, skipping activation");
      return;
    }

    if (!_isSessionActive) {
      try {
        await _audioSession!.setActive(true);
        _isSessionActive = true;
        _lastSessionActivation = now;
        _consecutiveErrors = 0;
        debugPrint("ImprovedAudioHandler: Audio session activated successfully");
      } catch (e) {
        debugPrint("ImprovedAudioHandler: Error activating audio session: $e");
        _consecutiveErrors++;
        _scheduleErrorRecovery();
      }
    }
  }

  /// Schedule error recovery
  void _scheduleErrorRecovery() {
    if (_consecutiveErrors >= _maxConsecutiveErrors && _errorRecoveryTimer == null) {
      _errorRecoveryTimer?.cancel();
      _errorRecoveryTimer = Timer(const Duration(seconds: 10), () async {
        debugPrint("ImprovedAudioHandler: Attempting audio session recovery");
        _errorRecoveryTimer = null;

        try {
          _isSessionActive = false;
          _audioSessionConfigured = false;
          _consecutiveErrors = 0;
          await _initializeAudioSession();
          await Future.delayed(const Duration(seconds: 2));

          if (_isBackgroundMode && queue.nvalue?.isNotEmpty == true && _currentIndex >= 0) {
            if (playbackState.nvalue?.playing == true) {
              debugPrint("ImprovedAudioHandler: Restoring playback after recovery");
              await _ensureBackgroundPlaybackContinuity();
            }
          }
        } catch (e) {
          debugPrint("ImprovedAudioHandler: Recovery failed: $e");
        }
      });
    }
  }

  /// Initialize audio effects
  Future<void> _initializeAudioEffects() async {
    _audioEffectsService.setAudioPlayer(_audioPlayer);
    await _audioEffectsService.loadSettings();
  }

  /// Setup playback event notifications
  void _notifyAudioHandlerAboutPlaybackEvents() {
    _audioPlayer.playerStateStream.listen((playerState) async {
      final playing = playerState.playing;
      final processingState = playerState.processingState;

      playbackState.add(playbackState.nvalue!.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 3],
        playing: playing,
        processingState: {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[processingState]!,
        updateTime: DateTime.now(),
      ));
    });

    _audioPlayer.durationStream.listen((newDuration) {
      if (newDuration != null && newDuration > Duration.zero) {
        final currentItem = mediaItem.nvalue;
        if (currentItem != null && currentItem.duration != newDuration) {
          final updatedItem = currentItem.copyWith(duration: newDuration);
          mediaItem.add(updatedItem);
        }
      }
    });

    _audioPlayer.positionStream.listen((position) async {
      if (position > Duration.zero) {
        _lastKnownPosition = position;
      }

      playbackState.add(playbackState.nvalue!.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ));

      await _handlePositionBasedCompletion(position);
    });

    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed && !_isHandlingCompletion) {
        final now = DateTime.now();
        if (_lastCompletionTime != null &&
            now.difference(_lastCompletionTime!) < _completionCooldown) {
          return;
        }

        _lastCompletionTime = now;
        _isHandlingCompletion = true;

        if (_isBackgroundMode) {
          await _ensureAudioSessionActive();
        }

        debugPrint("ImprovedAudioHandler: Processing state completed - handling completion");
        await _handleSongCompletion();
        _isHandlingCompletion = false;
      }
    });
  }

  /// Handle position-based completion detection
  Future<void> _handlePositionBasedCompletion(Duration position) async {
    final currentItem = mediaItem.nvalue;
    if (currentItem == null || !_audioPlayer.playing) return;

    if (currentItem.duration != null && position > Duration.zero) {
      final duration = currentItem.duration!;
      final timeRemaining = duration - position;
      const completionThreshold = Duration(milliseconds: 200);

      if (timeRemaining <= completionThreshold) {
        final songId = currentItem.extras?['songId'] as String?;
        final now = DateTime.now();

        if (_lastCompletionTime != null &&
            now.difference(_lastCompletionTime!) < _completionCooldown) {
          return;
        }

        if (songId != null && songId != _lastCompletedSongId && !_isHandlingCompletion) {
          _lastCompletedSongId = songId;
          _lastCompletionTime = now;
          _isHandlingCompletion = true;

          debugPrint("ImprovedAudioHandler: Position-based completion for: $songId");

          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
          }

          await _handleSongCompletion();
          _isHandlingCompletion = false;
        }
      }
    }
  }

  /// Enhanced queue management similar to demo
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    final updatedQueue = List<MediaItem>.from(queue.nvalue ?? []);
    updatedQueue.addAll(mediaItems);
    queue.add(updatedQueue);
    _queueSubject.add(updatedQueue);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final updatedQueue = List<MediaItem>.from(queue.nvalue ?? []);
    updatedQueue.add(mediaItem);
    queue.add(updatedQueue);
    _queueSubject.add(updatedQueue);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    final updatedQueue = List<MediaItem>.from(queue.nvalue ?? []);
    updatedQueue.insert(index, mediaItem);
    queue.add(updatedQueue);
    _queueSubject.add(updatedQueue);
    
    // Adjust current index if necessary
    if (_currentIndex >= index) {
      _currentIndex++;
      playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    queue.add(newQueue);
    _queueSubject.add(newQueue);
    
    if (_currentIndex >= newQueue.length) {
      _currentIndex = newQueue.isNotEmpty ? 0 : -1;
      playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    final updatedQueue = List<MediaItem>.from(queue.nvalue ?? []);
    if (index < 0 || index >= updatedQueue.length) return;
    
    updatedQueue.removeAt(index);
    queue.add(updatedQueue);
    _queueSubject.add(updatedQueue);

    if (_currentIndex == index) {
      if (updatedQueue.isEmpty) {
        _currentIndex = -1;
        await stop();
      } else if (_currentIndex >= updatedQueue.length) {
        _currentIndex = updatedQueue.length - 1;
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    
    playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
  }

  /// Update media item in queue
  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    final updatedQueue = List<MediaItem>.from(queue.nvalue ?? []);
    final index = updatedQueue.indexWhere((item) => item.id == mediaItem.id);
    
    if (index != -1) {
      updatedQueue[index] = mediaItem;
      queue.add(updatedQueue);
      _queueSubject.add(updatedQueue);
      
      // Update current media item if it's the one being updated
      if (index == _currentIndex) {
        mediaItem.add(mediaItem);
      }
    }
  }

  /// Enhanced skipping with proper queue management
  @override
  Future<void> skipToQueueItem(int index) async {
    final currentQueue = queue.nvalue ?? [];
    if (index < 0 || index >= currentQueue.length) {
      await stop();
      return;
    }

    try {
      await _ensureAudioSessionActive();

      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      _currentIndex = index;
      playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
      mediaItem.add(currentQueue[_currentIndex]);

      await _prepareToPlay(index);
      await _ensureAudioSessionActive();

      if (_shouldBePaused) {
        _shouldBePaused = false;
      }

      if (_audioPlayer.volume == 0.0) {
        await _audioPlayer.setVolume(1.0);
      }

      if (_audioPlayer.processingState == ProcessingState.ready) {
        await _audioPlayer.play();
        await _syncMetadata();
      }
    } catch (e) {
      debugPrint("Error during skipToQueueItem: $e");
      _handlePlaybackError(e);
    }
  }

  /// Enhanced skip to next with better queue handling
  @override
  Future<void> skipToNext() async {
    final currentQueue = queue.nvalue ?? [];
    if (currentQueue.isEmpty) return;

    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    int newIndex = _currentIndex + 1;
    if (newIndex >= currentQueue.length) {
      final repeatMode = playbackState.nvalue?.repeatMode ?? AudioServiceRepeatMode.none;
      if (repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        newIndex = 0; // Loop to first song
      }
    }

    debugPrint("ImprovedAudioHandler: skipToNext from $_currentIndex to $newIndex");
    await skipToQueueItem(newIndex);
  }

  /// Enhanced skip to previous with better queue handling
  @override
  Future<void> skipToPrevious() async {
    final currentQueue = queue.nvalue ?? [];
    if (currentQueue.isEmpty) return;

    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    int newIndex = _currentIndex - 1;
    if (newIndex < 0) {
      final repeatMode = playbackState.nvalue?.repeatMode ?? AudioServiceRepeatMode.none;
      if (repeatMode == AudioServiceRepeatMode.all) {
        newIndex = currentQueue.length - 1;
      } else {
        newIndex = currentQueue.length - 1; // Loop to last song
      }
    }

    debugPrint("ImprovedAudioHandler: skipToPrevious from $_currentIndex to $newIndex");
    await skipToQueueItem(newIndex);
  }

  /// Enhanced play method with better error handling
  @override
  Future<void> play() async {
    if (_audioPlayer.playing || _shouldBePaused) {
      return;
    }

    BugReportService().logAudioEvent('play_requested', data: {
      'current_index': _currentIndex,
      'queue_length': queue.nvalue?.length ?? 0,
      'should_be_paused': _shouldBePaused,
    });

    await _incrementPlayCounts();
    await _ensureAudioSessionActive();

    try {
      final currentQueue = queue.nvalue ?? [];
      if (_audioPlayer.processingState == ProcessingState.idle) {
        if (_currentIndex >= 0 && _currentIndex < currentQueue.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _syncMetadata();
        }
      } else if (_audioPlayer.processingState == ProcessingState.ready) {
        await _audioPlayer.play();
        await _syncMetadata();
      } else if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        if (_currentIndex >= 0 && _currentIndex < currentQueue.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _syncMetadata();
        }
      } else {
        await _audioPlayer.play();
      }
    } catch (e) {
      debugPrint("Error during play operation: $e");
      _handlePlaybackError(e);
    }
  }

  /// Enhanced pause method
  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
    playbackState.add(playbackState.nvalue!.copyWith(
      playing: false,
      updateTime: DateTime.now(),
    ));
  }

  /// Enhanced stop method
  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    mediaItem.add(null);
    playbackState.add(playbackState.nvalue!.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
      updatePosition: Duration.zero,
      updateTime: DateTime.now(),
    ));
  }

  /// Enhanced seek method with better error handling
  @override
  Future<void> seek(Duration position) async {
    try {
      await _audioPlayer.seek(position);
      
      playbackState.add(playbackState.nvalue!.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ));

      // Verify position after seek
      await Future.delayed(const Duration(milliseconds: 100));
      final actualPosition = _audioPlayer.position;
      
      if ((actualPosition - position).abs() > const Duration(seconds: 1)) {
        playbackState.add(playbackState.nvalue!.copyWith(
          updatePosition: actualPosition,
          updateTime: DateTime.now(),
        ));
      }
    } catch (e) {
      debugPrint("Error during seek operation: $e");
      final currentPosition = _audioPlayer.position;
      playbackState.add(playbackState.nvalue!.copyWith(
        updatePosition: currentPosition,
        updateTime: DateTime.now(),
      ));
    }
  }

  /// Set repeat mode with proper audio player configuration
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.nvalue!.copyWith(repeatMode: repeatMode));
    
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _audioPlayer.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.one:
        await _audioPlayer.setLoopMode(LoopMode.one);
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        await _audioPlayer.setLoopMode(LoopMode.off);
        break;
    }
  }

  /// Set shuffle mode
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    playbackState.add(playbackState.nvalue!.copyWith(shuffleMode: shuffleMode));
  }

  /// Prepare audio source for playback
  Future<void> _prepareToPlay(int index) async {
    final currentQueue = queue.nvalue ?? [];
    if (index < 0 || index >= currentQueue.length) {
      debugPrint("ImprovedAudioHandler: Invalid index in _prepareToPlay");
      return;
    }

    final itemToPlay = currentQueue[index];
    _currentIndex = index;
    
    _isHandlingCompletion = false;
    _lastCompletionTime = null;
    
    mediaItem.add(itemToPlay);
    playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));

    _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;
    final newSongId = itemToPlay.extras?['songId'] as String?;
    if (newSongId != null && newSongId != _lastCompletedSongId) {
      _lastCompletedSongId = null;
      _isHandlingCompletion = false;
      _lastKnownPosition = null;
    }

    AudioSource source;
    try {
      if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
        final filePath = itemToPlay.extras?['localFilePath'] as String? ?? itemToPlay.id;
        final file = File(filePath);
        if (!await file.exists()) {
          throw Exception("Local file not found: $filePath");
        }
        source = AudioSource.file(filePath);
      } else {
        source = AudioSource.uri(
          Uri.parse(itemToPlay.id),
          tag: itemToPlay,
        );
      }

      await _audioPlayer.setAudioSource(source);

      // Wait for ready state with timeout
      int attempts = 0;
      const int maxAttempts = 20;
      const Duration checkInterval = Duration(milliseconds: 50);

      while (_audioPlayer.processingState != ProcessingState.ready &&
          attempts < maxAttempts) {
        await Future.delayed(checkInterval);
        attempts++;
      }

      if (_audioPlayer.processingState != ProcessingState.ready) {
        throw Exception("Audio player failed to become ready");
      }

      playbackState.add(playbackState.nvalue!.copyWith(
        updatePosition: Duration.zero,
        updateTime: DateTime.now(),
      ));
      
      _audioEffectsService.reapplyEffects();
      _resolveArtworkAsync(itemToPlay);
    } catch (e) {
      debugPrint("Error preparing audio source: $e");
      _handlePlaybackError(e);
      rethrow;
    }
  }

  /// Handle playback errors
  void _handlePlaybackError(dynamic error) {
    final currentItem = mediaItem.nvalue;
    if (_isRadioStream && currentItem != null) {
      _showRadioErrorDialog(currentItem.title);
    }
    
    playbackState.add(playbackState.nvalue!.copyWith(
      playing: false,
      processingState: AudioProcessingState.error,
      updateTime: DateTime.now(),
    ));
  }

  /// Show radio error dialog
  void _showRadioErrorDialog(String stationName) {
    final navigator = globalNavigatorKey.currentState;
    if (navigator != null) {
      showDialog(
        context: navigator.context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Radio Stream Error'),
            content: Text('Failed to load radio station "$stationName".'):
            actions: <Widget>[
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
    }
  }

  /// Resolve artwork asynchronously
  Future<void> _resolveArtworkAsync(MediaItem item) async {
    try {
      MediaItem resolvedItem = await _resolveArtForItem(item);
      
      final currentQueue = queue.nvalue ?? [];
      if (_currentIndex >= 0 && _currentIndex < currentQueue.length) {
        final updatedQueue = List<MediaItem>.from(currentQueue);
        updatedQueue[_currentIndex] = resolvedItem;
        queue.add(updatedQueue);
        _queueSubject.add(updatedQueue);
      }

      mediaItem.add(resolvedItem);
    } catch (e) {
      debugPrint("Error resolving artwork for ${item.title}: $e");
    }
  }

  /// Resolve artwork for media item
  Future<MediaItem> _resolveArtForItem(MediaItem item) async {
    String? artFileNameToResolve;
    final isHttp = item.artUri?.toString().startsWith('http') ?? false;
    final isFileUri = item.artUri?.isScheme('file') ?? false;

    if (item.artUri != null && !isHttp && !isFileUri) {
      artFileNameToResolve = item.artUri.toString();
    } else if (item.artUri == null && item.extras?['localArtFileName'] != null) {
      artFileNameToResolve = item.extras!['localArtFileName'] as String;
    }

    if (artFileNameToResolve != null &&
        artFileNameToResolve.isNotEmpty &&
        (item.extras?['isLocal'] as bool? ?? false)) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final fullPath = p.join(directory.path, artFileNameToResolve);
        if (await File(fullPath).exists()) {
          return item.copyWith(artUri: Uri.file(fullPath));
        }
      } catch (_) {}
      return item.copyWith(artUri: null);
    }
    return item;
  }

  /// Sync metadata
  Future<void> _syncMetadata() async {
    final currentItem = mediaItem.nvalue;
    if (currentItem != null) {
      mediaItem.add(currentItem);
    }
  }

  /// Handle song completion
  Future<void> _handleSongCompletion() async {
    final repeatMode = playbackState.nvalue?.repeatMode ?? AudioServiceRepeatMode.none;
    final currentQueue = queue.nvalue ?? [];
    
    debugPrint("ImprovedAudioHandler: Song completion - Repeat: $repeatMode, Index: $_currentIndex");

    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    if (repeatMode == AudioServiceRepeatMode.one) {
      if (_currentIndex >= 0 && _currentIndex < currentQueue.length) {
        debugPrint("ImprovedAudioHandler: Repeating single song");
        await _prepareToPlay(_currentIndex);
        await _audioPlayer.seek(Duration.zero);
        playbackState.add(playbackState.nvalue!.copyWith(
          updatePosition: Duration.zero,
          playing: true,
          updateTime: DateTime.now(),
        ));
        await _audioPlayer.play();
        await _syncMetadata();
        return;
      }
    } else {
      if (_currentIndex == currentQueue.length - 1) {
        if (repeatMode == AudioServiceRepeatMode.all) {
          debugPrint("ImprovedAudioHandler: Looping queue to first song");
          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
          }
          await skipToQueueItem(0);
        } else {
          debugPrint("ImprovedAudioHandler: End of queue reached");
          if (_isBackgroundMode) {
            await _audioPlayer.pause();
            playbackState.add(playbackState.nvalue!.copyWith(
              playing: false,
              processingState: AudioProcessingState.ready,
              updateTime: DateTime.now(),
            ));
            await _ensureAudioSessionActive();
          } else {
            await stop();
          }
          return;
        }
      } else {
        await skipToNext();
      }
    }
  }

  /// Increment play counts for statistics
  Future<void> _incrementPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final statsEnabled = prefs.getBool('listeningStatsEnabled') ?? true;
    
    final currentQueue = queue.nvalue ?? [];
    if (!statsEnabled || _currentIndex < 0 || _currentIndex >= currentQueue.length) {
      return;
    }

    final item = currentQueue[_currentIndex];
    final songId = item.extras?['songId'] as String?;
    final artist = item.artist ?? '';
    final album = item.album ?? '';

    if (songId == null || songId.isEmpty) return;

    // Update song play count
    final songKey = 'song_$songId';
    final songJson = prefs.getString(songKey);
    if (songJson != null) {
      final songMap = _safeJsonDecode(songJson);
      if (songMap != null) {
        int playCount = (songMap['playCount'] as int?) ?? 0;
        songMap['playCount'] = ++playCount;
        await prefs.setString(songKey, jsonEncode(songMap));
      }
    }

    // Update album play count
    if (album.isNotEmpty) {
      final albumKeys = prefs.getKeys().where((k) => k.startsWith('album_'));
      for (final key in albumKeys) {
        final albumJson = prefs.getString(key);
        if (albumJson != null) {
          final albumMap = _safeJsonDecode(albumJson);
          if (albumMap != null && (albumMap['title'] as String?) == album) {
            int playCount = (albumMap['playCount'] as int?) ?? 0;
            albumMap['playCount'] = ++playCount;
            await prefs.setString(key, jsonEncode(albumMap));
          }
        }
      }
    }

    // Update artist play count
    if (artist.isNotEmpty) {
      final artistPlayCountsKey = 'artist_play_counts';
      final artistPlayCountsJson = prefs.getString(artistPlayCountsKey);
      Map<String, int> artistPlayCounts = {};
      if (artistPlayCountsJson != null) {
        artistPlayCounts = _safeJsonDecode(artistPlayCountsJson)?.cast<String, int>() ?? {};
      }
      artistPlayCounts[artist] = (artistPlayCounts[artist] ?? 0) + 1;
      await prefs.setString(artistPlayCountsKey, jsonEncode(artistPlayCounts));
    }

    // Update daily play count
    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final dailyPlayCountsJson = prefs.getString('daily_play_counts');
    Map<String, int> dailyPlayCounts = {};
    if (dailyPlayCountsJson != null) {
      dailyPlayCounts = _safeJsonDecode(dailyPlayCountsJson)?.cast<String, int>() ?? {};
    }
    dailyPlayCounts[todayKey] = (dailyPlayCounts[todayKey] ?? 0) + 1;
    await prefs.setString('daily_play_counts', jsonEncode(dailyPlayCounts));
  }

  /// Safe JSON decode
  Map<String, dynamic>? _safeJsonDecode(String json) {
    try {
      return Map<String, dynamic>.from(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  /// Ensure background playback continuity
  Future<void> _ensureBackgroundPlaybackContinuity() async {
    if (!_isIOS || _audioSession == null) return;

    try {
      await _ensureAudioSessionActive();
      
      final currentQueue = queue.nvalue ?? [];
      if (_isBackgroundMode && currentQueue.isNotEmpty) {
        final currentState = _audioPlayer.processingState;
        
        if (currentState == ProcessingState.completed && _currentIndex >= 0 && _currentIndex < currentQueue.length) {
          final repeatMode = playbackState.nvalue?.repeatMode ?? AudioServiceRepeatMode.none;
          
          if (repeatMode == AudioServiceRepeatMode.all || _currentIndex < currentQueue.length - 1) {
            debugPrint("ImprovedAudioHandler: Ensuring background continuity - moving to next");
            await skipToNext();
          } else if (repeatMode == AudioServiceRepeatMode.one) {
            debugPrint("ImprovedAudioHandler: Ensuring background continuity - restarting current");
            await _prepareToPlay(_currentIndex);
            await _audioPlayer.play();
            await _syncMetadata();
          }
        }
      }
    } catch (e) {
      debugPrint("Error ensuring background playback continuity: $e");
    }
  }

  /// Handle app foreground
  Future<void> handleAppForeground() async {
    _isBackgroundMode = false;
    
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
    }

    // Enhanced position sync
    final isPlaying = _audioPlayer.playing;
    final processingState = _audioPlayer.processingState;
    
    Duration? stablePosition;
    final lastKnownPos = _lastKnownPosition ?? Duration.zero;
    
    for (int attempt = 0; attempt < 3; attempt++) {
      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      final currentPos = _audioPlayer.position;
      
      if (!isPlaying) {
        stablePosition = currentPos;
        break;
      }
      
      if (currentPos > Duration.zero) {
        stablePosition = currentPos;
        break;
      }
      
      if (attempt == 2) {
        stablePosition = lastKnownPos > Duration.zero ? lastKnownPos : currentPos;
      }
    }

    final finalPosition = stablePosition ?? Duration.zero;
    _lastKnownPosition = finalPosition;

    debugPrint("ImprovedAudioHandler: App foregrounded - Position: ${finalPosition.inSeconds}s, Playing: $isPlaying");

    playbackState.add(playbackState.nvalue!.copyWith(
      updatePosition: finalPosition,
      playing: isPlaying,
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[processingState] ?? AudioProcessingState.idle,
      updateTime: DateTime.now(),
    ));
  }

  /// Handle app background
  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS) {
      await _ensureAudioSessionActive();
    }
  }

  /// Dispose handler resources
  Future<void> dispose() async {
    _errorRecoveryTimer?.cancel();
    _queueSubject.close();
    
    if (_isBackgroundMode && _isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
        debugPrint("ImprovedAudioHandler: Audio session maintained during disposal");
      } catch (e) {
        debugPrint("Error maintaining audio session during disposal: $e");
      }
    }

    await _audioPlayer.dispose();
  }

  /// Enhanced custom actions with additional functionality
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'updateCurrentMediaItemMetadata':
        return await _handleUpdateMediaItemMetadata(extras);
        
      case 'setQueueIndex':
        final index = extras?['index'] as int?;
        if (index != null && index >= 0) {
          final currentQueue = queue.nvalue ?? [];
          if (index < currentQueue.length) {
            _currentIndex = index;
            playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
          }
        }
        break;
        
      case 'handleAppForeground':
        await handleAppForeground();
        break;
        
      case 'handleAppBackground':
        await handleAppBackground();
        break;
        
      case 'ensureBackgroundPlaybackContinuity':
        await _ensureBackgroundPlaybackContinuity();
        break;
        
      case 'getCurrentPosition':
        return _audioPlayer.position.inMilliseconds;
        
      case 'getAudioDuration':
        return _audioPlayer.duration?.inMilliseconds;
        
      case 'isAudioReady':
        return _audioPlayer.processingState == ProcessingState.ready;
        
      case 'setGaplessMode':
        final enabled = extras?['enabled'] as bool? ?? true;
        setGaplessMode(enabled);
        return {'gaplessMode': enabled};
        
      case 'getGaplessMode':
        return {'gaplessMode': _gaplessModeEnabled};
        
      // Audio effects actions
      case 'setAudioEffectsEnabled':
        final enabled = extras?['enabled'] as bool?;
        if (enabled != null) await _audioEffectsService.setEnabled(enabled);
        break;
        
      case 'getAudioEffectsState':
        return {
          'isEnabled': _audioEffectsService.isEnabled,
          'bassBoost': _audioEffectsService.bassBoost,
          'reverb': _audioEffectsService.reverb,
          'is8DMode': _audioEffectsService.is8DMode,
          'eightDIntensity': _audioEffectsService.eightDIntensity,
          'equalizerBands': _audioEffectsService.equalizerBands,
          'equalizerPresets': _audioEffectsService.equalizerPresets,
          'frequencyBands': _audioEffectsService.frequencyBands,
          'currentPreset': _audioEffectsService.getCurrentPresetName(),
        };
        
      default:
        debugPrint("ImprovedAudioHandler: Unknown custom action: $name");
        break;
    }
    return null;
  }

  /// Handle update media item metadata
  Future<dynamic> _handleUpdateMediaItemMetadata(Map<String, dynamic>? extras) async {
    final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
    if (mediaMap == null) return null;
    
    final currentItem = mediaItem.nvalue;
    final currentQueue = queue.nvalue ?? [];
    
    if (currentItem != null && _currentIndex >= 0 && _currentIndex < currentQueue.length) {
      final newArtUri = mediaMap['artUri'] as String?;
      final updatedItem = currentItem.copyWith(
        title: mediaMap['title'] as String? ?? currentItem.title,
        artist: mediaMap['artist'] as String? ?? currentItem.artist,
        album: mediaMap['album'] as String? ?? currentItem.album,
        artUri: (newArtUri != null && newArtUri.isNotEmpty)
            ? Uri.tryParse(newArtUri)
            : currentItem.artUri,
        duration: (mediaMap['duration'] != null)
            ? Duration(milliseconds: mediaMap['duration'] as int)
            : currentItem.duration,
        extras: (mediaMap['extras'] as Map<String, dynamic>?) ?? currentItem.extras,
      );
      
      final updatedQueue = List<MediaItem>.from(currentQueue);
      updatedQueue[_currentIndex] = updatedItem;
      
      queue.add(updatedQueue);
      _queueSubject.add(updatedQueue);
      mediaItem.add(updatedItem);
    }
    return null;
  }
}
