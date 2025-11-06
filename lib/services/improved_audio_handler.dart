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

/// Improved audio handler with robust queue management and state handling
/// Based on BaseAudioHandler and QueueHandler patterns
class ImprovedAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final List<MediaItem> _queue = <MediaItem>[];
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

  // Prevent duplicate completion handling
  DateTime? _lastCompletionTime;
  static const Duration _completionCooldown = Duration(milliseconds: 500);

  // Simplified session management
  DateTime? _lastSessionActivation;
  static const Duration _sessionActivationCooldown =
      Duration(milliseconds: 500);
  bool _isSessionActive = false;

  // Improved error handling
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;
  Timer? _errorRecoveryTimer;

  // Audio session optimization
  DateTime? _lastSessionConfig;
  static const Duration _sessionConfigThrottle =
      Duration(seconds: 10); // Don't reconfigure too often

  // Track loop reset state
  bool _justResetForLoop = false;

  // Track local file completion to prevent infinite loops
  String? _lastLocalFileCompleted;
  int _localFileCompletionCount = 0;
  static const int _maxLocalFileCompletions = 3;

  // Throttling for background continuity checks
  DateTime? _lastContinuityCheck;
  static const Duration _continuityCheckThrottle = Duration(seconds: 5);

  // Gapless playback settings
  bool _gaplessModeEnabled = true; // Enable by default for better UX
  static const Duration _gaplessTransitionDelay =
      Duration(milliseconds: 10); // Minimal delay

  // Internal state tracking
  late StreamSubscription<Duration?> _durationSubscription;
  late StreamSubscription<Duration> _positionSubscription;
  late StreamSubscription<PlayerState> _playerStateSubscription;
  late StreamSubscription<ProcessingState> _processingStateSubscription;

  // Internal subjects for better state management
  final BehaviorSubject<int> _queueIndexSubject = BehaviorSubject.seeded(-1);
  final BehaviorSubject<bool> _shuffleEnabledSubject =
      BehaviorSubject.seeded(false);

  ImprovedAudioHandler() {
    _initializeAudioSession();
    _configureAudioPlayer();
    _setupStreamListeners();
    _initializeAudioEffects();
    _initializeDefaultState();
  }

  /// Initialize default playback state based on BaseAudioHandler pattern
  void _initializeDefaultState() {
    final now = DateTime.now();
    playbackState.add(PlaybackState(
      updateTime: now,
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
      playing: false,
      processingState: AudioProcessingState.idle,
      repeatMode: AudioServiceRepeatMode.none,
      shuffleMode: AudioServiceShuffleMode.none,
    ));

    // Initialize queue with empty list
    queue.add(<MediaItem>[]);
    queueTitle.add('');
    mediaItem.add(null);
  }

  /// Setup all stream listeners in one place for better organization
  void _setupStreamListeners() {
    _playerStateSubscription = _audioPlayer.playerStateStream.listen(
      _handlePlayerStateChanged,
      onError: (error) => debugPrint('Player state stream error: $error'),
    );

    _durationSubscription = _audioPlayer.durationStream.listen(
      _handleDurationChanged,
      onError: (error) => debugPrint('Duration stream error: $error'),
    );

    _positionSubscription = _audioPlayer.positionStream.listen(
      _handlePositionChanged,
      onError: (error) => debugPrint('Position stream error: $error'),
    );

    _processingStateSubscription = _audioPlayer.processingStateStream.listen(
      _handleProcessingStateChanged,
      onError: (error) => debugPrint('Processing state stream error: $error'),
    );
  }

  /// Handle player state changes with improved logic
  void _handlePlayerStateChanged(PlayerState playerState) {
    final playing = playerState.playing;
    final processingState = playerState.processingState;

    playbackState.add(playbackState.nvalue!.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      playing: playing,
      processingState: _mapProcessingState(processingState),
      updateTime: DateTime.now(),
    ));

    // Log state changes for debugging
    debugPrint(
        'ImprovedAudioHandler: Player state changed - Playing: $playing, State: $processingState');
  }

  /// Handle duration changes
  void _handleDurationChanged(Duration? newDuration) {
    if (newDuration != null && newDuration > Duration.zero) {
      final currentItem = mediaItem.nvalue;
      if (currentItem != null && currentItem.duration != newDuration) {
        final updatedItem = currentItem.copyWith(duration: newDuration);
        mediaItem.add(updatedItem);
        
        // Update queue item as well
        if (_currentIndex >= 0 && _currentIndex < _queue.length) {
          _queue[_currentIndex] = updatedItem;
          queue.add(List.unmodifiable(_queue));
        }
      }
    }
  }

  /// Handle position changes with improved completion detection
  void _handlePositionChanged(Duration position) {
    // Check if this is a streaming URL (not local file)
    final currentItem = mediaItem.nvalue;
    final isStreaming = currentItem?.extras?['isLocal'] != true;

    // For streaming URLs, be more careful about position updates
    if (isStreaming &&
        position == Duration.zero &&
        _audioPlayer.playing &&
        !_justResetForLoop) {
      // Don't emit zero position for streaming URLs while playing
      return;
    }

    // Reset the loop flag after processing the position update
    if (_justResetForLoop && position == Duration.zero) {
      _justResetForLoop = false;
    }

    // Track the last known position for foreground sync fallback
    if (position > Duration.zero) {
      _lastKnownPosition = position;
    }

    // Always emit the actual position from the audio player
    playbackState.add(playbackState.nvalue!.copyWith(
      updatePosition: position,
      updateTime: DateTime.now(),
    ));

    // Handle song completion detection
    _checkForSongCompletion(position, currentItem);
  }

  /// Handle processing state changes
  void _handleProcessingStateChanged(ProcessingState state) {
    playbackState.add(playbackState.nvalue!.copyWith(
      processingState: _mapProcessingState(state),
      updateTime: DateTime.now(),
    ));

    // Handle completion state
    if (state == ProcessingState.completed && !_isHandlingCompletion) {
      _handleCompletionState();
    }
  }

  /// Check for song completion based on position
  void _checkForSongCompletion(Duration position, MediaItem? currentItem) {
    if (position > Duration.zero &&
        _audioPlayer.playing &&
        _audioPlayer.processingState == ProcessingState.ready) {
      if (currentItem != null && currentItem.duration != null) {
        final duration = currentItem.duration!;
        final timeRemaining = duration - position;

        // Use different completion thresholds for local vs streaming files
        final isLocalFile = currentItem.extras?['isLocal'] as bool? ?? false;
        final completionThreshold =
            isLocalFile ? 300 : 100; // 300ms for local, 100ms for streaming

        // For local files, also check if we're not in a loop state
        if (isLocalFile && _justResetForLoop) {
          return; // Skip completion detection if we just reset for a loop
        }

        if (timeRemaining.inMilliseconds <= completionThreshold) {
          _handleSongCompletionByPosition(currentItem);
        }
      }
    }
  }

  /// Handle song completion detected by position
  Future<void> _handleSongCompletionByPosition(MediaItem currentItem) async {
    final songId = currentItem.extras?['songId'] as String?;
    final now = DateTime.now();

    // Check if enough time has passed since last completion
    if (_lastCompletionTime != null &&
        now.difference(_lastCompletionTime!) < _completionCooldown) {
      return;
    }

    if (songId != null &&
        songId != _lastCompletedSongId &&
        !_isHandlingCompletion) {
      _lastCompletedSongId = songId;
      _lastCompletionTime = now;
      _isHandlingCompletion = true;

      debugPrint(
          'ImprovedAudioHandler: Position-based completion detected for song: $songId');

      // Ensure audio session is active before handling completion
      if (_isBackgroundMode) {
        await _ensureAudioSessionActive();
      }

      await _handleSongCompletion();
      _isHandlingCompletion = false;
    }
  }

  /// Handle completion state from processing state
  Future<void> _handleCompletionState() async {
    final now = DateTime.now();

    // Check if enough time has passed since last completion
    if (_lastCompletionTime != null &&
        now.difference(_lastCompletionTime!) < _completionCooldown) {
      return;
    }

    _lastCompletionTime = now;
    _isHandlingCompletion = true;

    // Ensure audio session stays active in background mode
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    debugPrint(
        'ImprovedAudioHandler: ProcessingState.completed detected - handling song completion');
    await _handleSongCompletion();
    _isHandlingCompletion = false;
  }

  /// Map just_audio ProcessingState to AudioProcessingState
  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  bool get shouldBePaused => _shouldBePaused;

  set shouldBePaused(bool value) {
    _shouldBePaused = value;
    if (value && _audioPlayer.playing) {
      _audioPlayer.pause();
      playbackState.add(playbackState.nvalue!.copyWith(playing: false));
    }
  }

  /// Configure audio player for optimal playback performance
  void _configureAudioPlayer() {
    // Configure player settings for better performance
    // Note: Most audio player optimizations are handled by just_audio automatically
    // but we can add any app-specific configurations here
  }

  /// Enable or disable gapless playback mode
  void setGaplessMode(bool enabled) {
    _gaplessModeEnabled = enabled;
    debugPrint(
        'ImprovedAudioHandler: Gapless mode ${enabled ? 'enabled' : 'disabled'}');
  }

  /// Get current gapless mode status
  bool get gaplessModeEnabled => _gaplessModeEnabled;

  Duration get currentPosition => _audioPlayer.position;

  Future<void> _initializeAudioSession() async {
    if (_audioSessionConfigured) return;

    try {
      _audioSession = await AudioSession.instance;

      // Single, comprehensive iOS audio session configuration
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

        // Set up event listeners
        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream
            .listen((_) => _handleBecomingNoisy());

        // Initial activation - don't fail if it doesn't work immediately
        try {
          await Future.delayed(const Duration(milliseconds: 100));
          await _audioSession!.setActive(true);
          _isSessionActive = true;
        } catch (e) {
          debugPrint(
              'Initial audio session activation failed (non-critical): $e');
          _isSessionActive = false;
        }
      } else {
        // Android configuration
        await _audioSession!.configure(const AudioSessionConfiguration.music());
      }

      _audioSessionConfigured = true;
      debugPrint('ImprovedAudioHandler: Audio session initialized successfully');
    } catch (e) {
      debugPrint('Error configuring audio session: $e');
      // Don't set _audioSessionConfigured to true if initialization failed
    }
  }

  Future<void> _ensureAudioSessionActive() async {
    if (!_isIOS || _audioSession == null || !_audioSessionConfigured) return;

    // Skip session activation if we're not playing and not in background mode
    if (!_audioPlayer.playing && !_isBackgroundMode) {
      return;
    }

    final now = DateTime.now();
    if (_lastSessionActivation != null &&
        now.difference(_lastSessionActivation!) < _sessionActivationCooldown) {
      return;
    }

    // Don't try to activate if we have too many consecutive errors
    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      debugPrint(
          'ImprovedAudioHandler: Too many consecutive errors, skipping activation');
      return;
    }

    if (!_isSessionActive) {
      try {
        await _audioSession!.setActive(true);
        _isSessionActive = true;
        _lastSessionActivation = now;
        _consecutiveErrors = 0; // Reset error count on successful activation
        debugPrint(
            'ImprovedAudioHandler: Audio session activated successfully');
      } catch (e) {
        final errorMessage = e.toString();
        debugPrint(
            'ImprovedAudioHandler: Error activating audio session: $errorMessage');
        _consecutiveErrors++;

        // Check for -50 error (paramErr) which indicates the session is in a bad state
        if (errorMessage.contains('-50') || errorMessage.contains('paramErr')) {
          debugPrint(
              'ImprovedAudioHandler: Detected paramErr (-50), marking session as invalid');
          _isSessionActive = false;
          _audioSessionConfigured = false; // Force re-initialization
        }

        _scheduleErrorRecovery();
      }
    }
  }

  void _scheduleErrorRecovery() {
    if (_consecutiveErrors >= _maxConsecutiveErrors &&
        _errorRecoveryTimer == null) {
      _errorRecoveryTimer?.cancel();
      _errorRecoveryTimer = Timer(const Duration(seconds: 10), () async {
        debugPrint(
            'ImprovedAudioHandler: Attempting comprehensive audio session recovery');
        _errorRecoveryTimer = null;

        try {
          // Reset session state
          _isSessionActive = false;
          _audioSessionConfigured = false;
          _consecutiveErrors = 0;

          // Re-initialize audio session completely
          await _initializeAudioSession();

          // Wait for the session to stabilize
          await Future.delayed(const Duration(seconds: 2));

          // If we're in background mode and should be playing, try to restore
          if (_isBackgroundMode && _queue.isNotEmpty && _currentIndex >= 0) {
            try {
              if (playbackState.nvalue!.playing) {
                debugPrint(
                    'ImprovedAudioHandler: Restoring playback after session recovery');
                await _ensureBackgroundPlaybackContinuity();
              }
            } catch (e) {
              debugPrint(
                  'ImprovedAudioHandler: Error during background playback recovery: $e');
            }
          }
        } catch (e) {
          debugPrint('ImprovedAudioHandler: Comprehensive recovery failed: $e');
        }
      });
    }
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      if (event.type == AudioInterruptionType.pause ||
          event.type == AudioInterruptionType.unknown) {
        if (_audioPlayer.playing) _audioPlayer.pause();
      }
    } else {
      if (event.type == AudioInterruptionType.pause ||
          event.type == AudioInterruptionType.unknown) {
        // When interruption ends, ensure audio session is active before resuming
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

  void _handleBecomingNoisy() {
    if (_audioPlayer.playing) _audioPlayer.pause();
  }

  Future<void> _initializeAudioEffects() async {
    _audioEffectsService.setAudioPlayer(_audioPlayer);
    await _audioEffectsService.loadSettings();
  }

  Future<void> _syncMetadata() async {
    final currentItem = mediaItem.nvalue;
    if (currentItem != null) {
      mediaItem.add(currentItem);
    }
  }

  Future<void> _prepareToPlay(int index) async {
    if (index < 0 || index >= _queue.length) {
      debugPrint('ImprovedAudioHandler: Invalid index in _prepareToPlay');
      return;
    }

    _currentIndex = index;
    MediaItem itemToPlay = _queue[_currentIndex];

    // Reset completion state for new song
    _isHandlingCompletion = false;
    _lastCompletionTime = null;

    // Reset local file completion tracking for new song
    if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
      _localFileCompletionCount = 0;
      _lastLocalFileCompleted = null;
    }

    mediaItem.add(itemToPlay);
    playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
    _queueIndexSubject.add(_currentIndex);

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
        // For local files, use the localFilePath from extras
        final filePath =
            itemToPlay.extras?['localFilePath'] as String? ?? itemToPlay.id;
        final file = File(filePath);
        if (!await file.exists()) {
          throw Exception('Local file not found: $filePath');
        }
        source = AudioSource.file(filePath);
      } else {
        source = AudioSource.uri(
          Uri.parse(itemToPlay.id),
          tag: MediaItem(
            id: itemToPlay.id,
            title: itemToPlay.title,
            artist: itemToPlay.artist,
            album: itemToPlay.album,
            artUri: itemToPlay.artUri,
            duration: itemToPlay.duration,
            extras: itemToPlay.extras,
          ),
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
        throw Exception(
            'Audio player failed to become ready within ${maxAttempts * checkInterval.inMilliseconds}ms');
      }

      playbackState.add(playbackState.nvalue!.copyWith(updatePosition: Duration.zero));
      mediaItem.add(itemToPlay);
      _audioEffectsService.reapplyEffects();

      // Resolve artwork asynchronously
      _resolveArtworkAsync(itemToPlay);
    } catch (e) {
      debugPrint('Error preparing audio source: $e');
      if (_isRadioStream) _showRadioErrorDialog(itemToPlay.title);
      rethrow;
    }
  }

  Future<void> _resolveArtworkAsync(MediaItem item) async {
    try {
      MediaItem resolvedItem = await _resolveArtForItem(item);

      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        _queue[_currentIndex] = resolvedItem;
      }

      mediaItem.add(resolvedItem);
      queue.add(List.unmodifiable(_queue));
    } catch (e) {
      debugPrint('Error resolving artwork for ${item.title}: $e');
    }
  }

  void _showRadioErrorDialog(String stationName) {
    final navigator = globalNavigatorKey.currentState;
    if (navigator != null) {
      showDialog(
        context: navigator.context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Radio Stream Error'),
            content: Text('Failed to load radio station "$stationName".'),
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

  Future<MediaItem> _resolveArtForItem(MediaItem item) async {
    String? artFileNameToResolve;
    final isHttp = item.artUri?.toString().startsWith('http') ?? false;
    final isFileUri = item.artUri?.isScheme('file') ?? false;

    if (item.artUri != null && !isHttp && !isFileUri) {
      artFileNameToResolve = item.artUri.toString();
    } else if (item.artUri == null &&
        item.extras?['localArtFileName'] != null) {
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

  // Queue management methods following BaseAudioHandler + QueueHandler pattern
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _queue.addAll(mediaItems);
    queue.add(List.unmodifiable(_queue));
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _queue.add(mediaItem);
    queue.add(List.unmodifiable(_queue));
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    _queue.insert(index, mediaItem);
    queue.add(List.unmodifiable(_queue));
    
    // Adjust current index if necessary
    if (_currentIndex >= index) {
      _currentIndex++;
      _queueIndexSubject.add(_currentIndex);
      playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    _queue.clear();
    _queue.addAll(newQueue);
    queue.add(List.unmodifiable(_queue));
    
    if (_currentIndex >= _queue.length) {
      _currentIndex = _queue.isNotEmpty ? 0 : -1;
      _queueIndexSubject.add(_currentIndex);
      playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    
    _queue.removeAt(index);
    queue.add(List.unmodifiable(_queue));

    if (_currentIndex == index) {
      if (_queue.isEmpty) {
        _currentIndex = -1;
        await stop();
      } else if (_currentIndex >= _queue.length) {
        _currentIndex = _queue.length - 1;
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    
    _queueIndexSubject.add(_currentIndex);
    playbackState.add(playbackState.nvalue!.copyWith(queueIndex: _currentIndex));
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    final index = _queue.indexWhere((item) => item.id == mediaItem.id);
    if (index >= 0) {
      _queue[index] = mediaItem;
      queue.add(List.unmodifiable(_queue));
      
      // Update current media item if it's the one being updated
      if (index == _currentIndex) {
        mediaItem.add(mediaItem);
      }
    }
  }

  // Playback control methods
  @override
  Future<void> play() async {
    if (_audioPlayer.playing || _shouldBePaused) {
      return;
    }

    // Log audio event
    BugReportService().logAudioEvent('play_requested', data: {
      'current_index': _currentIndex,
      'queue_length': _queue.length,
      'should_be_paused': _shouldBePaused,
    });

    await _incrementPlayCounts();
    await _ensureAudioSessionActive();

    try {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        if (_currentIndex >= 0 && _currentIndex < _queue.length) {
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
        if (_currentIndex >= 0 && _currentIndex < _queue.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _syncMetadata();
        }
      } else {
        await _audioPlayer.play();
      }
    } catch (e) {
      debugPrint('Error during play operation: $e');
      if (_isRadioStream &&
          _currentIndex >= 0 &&
          _currentIndex < _queue.length) {
        _showRadioErrorDialog(_queue[_currentIndex].title);
      }
    }
  }

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    mediaItem.add(null);
    _currentIndex = -1;
    _queueIndexSubject.add(_currentIndex);
    
    playbackState.add(playbackState.nvalue!.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
      updatePosition: Duration.zero,
      queueIndex: _currentIndex,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _audioPlayer.seek(position);

      // For streaming URLs, wait a bit for the position to stabilize
      if (_audioPlayer.processingState == ProcessingState.ready) {
        // Force immediate position update after seek
        playbackState.add(playbackState.nvalue!.copyWith(
          updatePosition: position,
          updateTime: DateTime.now(),
        ));

        // Wait a short time and then verify the position
        await Future.delayed(const Duration(milliseconds: 100));
        final actualPosition = _audioPlayer.position;

        // If the position is significantly different from what we expected,
        // update with the actual position
        if ((actualPosition - position).abs() > const Duration(seconds: 1)) {
          playbackState.add(playbackState.nvalue!.copyWith(
            updatePosition: actualPosition,
            updateTime: DateTime.now(),
          ));
        }
      } else {
        // For non-streaming, just update immediately
        playbackState.add(playbackState.nvalue!.copyWith(
          updatePosition: position,
          updateTime: DateTime.now(),
        ));
      }
    } catch (e) {
      debugPrint('Error during seek operation: $e');
      // If seek fails, get the actual position and update
      final currentPosition = _audioPlayer.position;
      playbackState.add(playbackState.nvalue!.copyWith(
        updatePosition: currentPosition,
        updateTime: DateTime.now(),
      ));
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;

    // Ensure audio session is active before any skip operation in background
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    int newIndex = _currentIndex + 1;
    if (newIndex >= _queue.length) {
      if (playbackState.nvalue!.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        // When loop is off, loop to first song
        newIndex = 0;
      }
    }

    debugPrint(
        'ImprovedAudioHandler: skipToNext from $_currentIndex to $newIndex');
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;

    // Ensure audio session is active before any skip operation in background
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    int newIndex = _currentIndex - 1;
    if (newIndex < 0) {
      if (playbackState.nvalue!.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = _queue.length - 1;
      } else {
        // When loop is off, loop to last song
        newIndex = _queue.length - 1;
      }
    }

    debugPrint(
        'ImprovedAudioHandler: skipToPrevious from $_currentIndex to $newIndex');
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) {
      await stop();
      return;
    }

    try {
      // Ensure audio session is active before any transition
      await _ensureAudioSessionActive();

      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await _prepareToPlay(index);

      // Ensure audio session is still active after preparing to play
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
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_audioPlayer.processingState == ProcessingState.ready) {
          await _audioPlayer.play();
          await _syncMetadata();
        }
      }
    } catch (e) {
      debugPrint('Error during skipToQueueItem: $e');
      playbackState.add(playbackState.nvalue!.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
      ));
      if (_isRadioStream &&
          _currentIndex >= 0 &&
          _currentIndex < _queue.length) {
        _showRadioErrorDialog(_queue[_currentIndex].title);
      }
    }
  }

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

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    _shuffleEnabledSubject.add(enabled);
    playbackState.add(playbackState.nvalue!.copyWith(shuffleMode: shuffleMode));
  }

  // Additional methods from original handler
  Future<void> setPlaybackSpeed(double speed) async {
    try {
      await _audioPlayer.setSpeed(speed);
      await _audioPlayer.setPitch(speed);
    } catch (_) {}
  }

  double get currentPlaybackSpeed => _audioPlayer.speed;

  Future<void> resetPlaybackSpeed() async {
    await setPlaybackSpeed(1.0);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    int index = _queue.indexWhere((element) => element.id == mediaItem.id);
    if (index == -1) {
      _queue.clear();
      _queue.add(mediaItem);
      queue.add(List.unmodifiable(_queue));
      index = 0;
    } else {
      _queue[index] = mediaItem;
    }
    await skipToQueueItem(index);
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    final index = _queue.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      await skipToQueueItem(index);
    } else {
      if (Uri.tryParse(mediaId)?.isAbsolute ?? false) {
        final newItem = MediaItem(
          id: mediaId,
          title: extras?['title'] as String? ?? mediaId.split('/').last,
          artist: extras?['artist'] as String? ?? 'Unknown Artist',
          album: extras?['album'] as String?,
          artUri: extras?['artUri'] is String
              ? Uri.tryParse(extras!['artUri'])
              : null,
          extras: extras,
        );
        _queue.add(newItem);
        queue.add(List.unmodifiable(_queue));
        await skipToQueueItem(_queue.length - 1);
      }
    }
  }

  Future<void> ensureBackgroundPlayback() async {
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
      _isBackgroundMode = true;
    }
  }

  Future<void> _ensureBackgroundPlaybackContinuity() async {
    if (!_isIOS || _audioSession == null) return;

    // Throttle continuity checks to prevent excessive operations
    final now = DateTime.now();
    if (_lastContinuityCheck != null &&
        now.difference(_lastContinuityCheck!) < _continuityCheckThrottle) {
      return;
    }
    _lastContinuityCheck = now;

    try {
      // Only ensure audio session active if we haven't checked recently
      if (_lastSessionActivation == null ||
          now.difference(_lastSessionActivation!) >
              const Duration(seconds: 30)) {
        await _ensureAudioSessionActive();
      }

      // If we're in background mode and have a queue, ensure continuity
      if (_isBackgroundMode && _queue.isNotEmpty) {
        final currentState = _audioPlayer.processingState;
        final currentItem =
            _currentIndex >= 0 && _currentIndex < _queue.length
                ? _queue[_currentIndex]
                : null;
        final isLocalFile = currentItem?.extras?['isLocal'] as bool? ?? false;

        // If audio player is completed but we should continue playing
        if (currentState == ProcessingState.completed &&
            _currentIndex >= 0 &&
            _currentIndex < _queue.length) {
          final repeatMode = playbackState.nvalue!.repeatMode;

          // If repeat is on or we're not at the last song, continue to next
          if (repeatMode == AudioServiceRepeatMode.all ||
              _currentIndex < _queue.length - 1) {
            debugPrint(
                'ImprovedAudioHandler: Ensuring background playback continuity - moving to next song');
            await skipToNext();
          } else if (repeatMode == AudioServiceRepeatMode.one) {
            // If repeat one is on, restart current song
            debugPrint(
                'ImprovedAudioHandler: Ensuring background playback continuity - restarting current song');
            await _prepareToPlay(_currentIndex);
            await _audioPlayer.play();
            await _syncMetadata();
          }
        }
      }
    } catch (e) {
      debugPrint('Error ensuring background playback continuity: $e');
    }
  }

  Future<void> handleAppForeground() async {
    _isBackgroundMode = false;

    // Always ensure audio session is active when coming to foreground
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
    }

    // Enhanced position sync when app comes to foreground
    final isPlaying = _audioPlayer.playing;
    final processingState = _audioPlayer.processingState;

    // Check for audio session inconsistency during transitions
    if (isPlaying && _isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
        debugPrint(
            'ImprovedAudioHandler: Audio session verified as active during foreground');
      } catch (e) {
        debugPrint(
            'ImprovedAudioHandler: Audio session was inactive during foreground, fixing state: $e');
        await _audioPlayer.pause();
      }
    }

    // Get stable position with multiple readings
    Duration? stablePosition;
    final lastKnownPos = _lastKnownPosition ?? Duration.zero;
    final actualIsPlaying = _audioPlayer.playing;

    for (int attempt = 0; attempt < 6; attempt++) {
      await Future.delayed(Duration(milliseconds: 200 + (attempt * 200)));
      final currentPos = _audioPlayer.position;

      if (!actualIsPlaying) {
        stablePosition = currentPos;
        break;
      }

      if (currentPos > Duration.zero) {
        stablePosition = currentPos;
        break;
      }

      if (currentPos == Duration.zero &&
          lastKnownPos > Duration.zero &&
          actualIsPlaying &&
          attempt < 5) {
        continue;
      }

      if (attempt == 5) {
        stablePosition =
            lastKnownPos > Duration.zero ? lastKnownPos : currentPos;
      }
    }

    // Fall back to last known position if all readings were 0 and we were playing
    if (stablePosition == Duration.zero &&
        lastKnownPos > Duration.zero &&
        actualIsPlaying) {
      stablePosition = lastKnownPos;
    }

    final finalPosition = stablePosition ?? Duration.zero;
    _lastKnownPosition = finalPosition;

    debugPrint(
        'ImprovedAudioHandler: App foregrounded - Position: ${finalPosition.inSeconds}s, Playing: $actualIsPlaying');

    // Force comprehensive playback state update
    playbackState.add(playbackState.nvalue!.copyWith(
      updatePosition: finalPosition,
      playing: actualIsPlaying,
      processingState: _mapProcessingState(processingState),
      updateTime: DateTime.now(),
    ));
  }

  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS) {
      await _ensureAudioSessionActive();
    }
  }

  Future<void> _incrementPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final statsEnabled = prefs.getBool('listeningStatsEnabled') ?? true;
    if (!statsEnabled ||
        _currentIndex < 0 ||
        _currentIndex >= _queue.length) {
      return;
    }

    final item = _queue[_currentIndex];
    final songId = item.extras?['songId'] as String?;
    final artist = item.artist ?? '';
    final album = item.album ?? '';

    if (songId == null || songId.isEmpty) return;

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

    if (artist.isNotEmpty) {
      final artistPlayCountsKey = 'artist_play_counts';
      final artistPlayCountsJson = prefs.getString(artistPlayCountsKey);
      Map<String, int> artistPlayCounts = {};
      if (artistPlayCountsJson != null) {
        artistPlayCounts =
            _safeJsonDecode(artistPlayCountsJson)?.cast<String, int>() ?? {};
      }
      artistPlayCounts[artist] = (artistPlayCounts[artist] ?? 0) + 1;
      await prefs.setString(artistPlayCountsKey, jsonEncode(artistPlayCounts));
    }

    final now = DateTime.now();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final dailyPlayCountsJson = prefs.getString('daily_play_counts');
    Map<String, int> dailyPlayCounts = {};
    if (dailyPlayCountsJson != null) {
      dailyPlayCounts =
          _safeJsonDecode(dailyPlayCountsJson)?.cast<String, int>() ?? {};
    }
    dailyPlayCounts[todayKey] = (dailyPlayCounts[todayKey] ?? 0) + 1;
    await prefs.setString('daily_play_counts', jsonEncode(dailyPlayCounts));
  }

  Map<String, dynamic>? _safeJsonDecode(String json) {
    try {
      return Map<String, dynamic>.from(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleSongCompletion() async {
    final repeatMode = playbackState.nvalue!.repeatMode;
    final currentItem = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    final isLocalFile = currentItem?.extras?['isLocal'] as bool? ?? false;
    final songId = currentItem?.extras?['songId'] as String?;

    debugPrint(
        'ImprovedAudioHandler: Song completion - Repeat: $repeatMode, Index: $_currentIndex, Local: $isLocalFile');

    // Single session check at start of completion handling
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    // For local files, check if we're stuck in a completion loop
    if (isLocalFile && songId != null) {
      if (_lastLocalFileCompleted == songId) {
        _localFileCompletionCount++;
        debugPrint(
            'ImprovedAudioHandler: Local file completion count: $_localFileCompletionCount for song: $songId');

        // If we've completed the same local file too many times, force move to next
        if (_localFileCompletionCount >= _maxLocalFileCompletions) {
          debugPrint(
              'ImprovedAudioHandler: Too many completions for local file, forcing next song');
          _localFileCompletionCount = 0;
          _lastLocalFileCompleted = null;

          if (_currentIndex < _queue.length - 1) {
            await skipToNext();
            return;
          } else if (repeatMode == AudioServiceRepeatMode.all) {
            await _prepareToPlay(0);
            _currentIndex = 0;
            _queueIndexSubject.add(_currentIndex);
            playbackState.add(playbackState.nvalue!.copyWith(
              queueIndex: _currentIndex,
              playing: true,
            ));
            await _audioPlayer.play();
            await _syncMetadata();
            return;
          } else {
            // Stop playback at end of queue
            await stop();
            return;
          }
        }
      } else {
        _localFileCompletionCount = 1;
        _lastLocalFileCompleted = songId;
      }
    }

    if (repeatMode == AudioServiceRepeatMode.one) {
      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        debugPrint('ImprovedAudioHandler: Repeating single song');
        await _prepareToPlay(_currentIndex);
        // Reset position to 0 when looping a single song
        _justResetForLoop = true;
        await _audioPlayer.seek(Duration.zero);
        // Force position update to 0 for UI
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
      // Check if we're at the end of the queue
      if (_currentIndex == _queue.length - 1) {
        if (repeatMode == AudioServiceRepeatMode.all) {
          // Loop to first song and continue playing
          debugPrint(
              'ImprovedAudioHandler: Looping queue - moving from last song to first');

          // Ensure audio session stays active during queue loop in background
          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
          }

          await _prepareToPlay(0);
          _currentIndex = 0;
          _queueIndexSubject.add(_currentIndex);
          playbackState.add(playbackState.nvalue!.copyWith(
            queueIndex: _currentIndex,
            playing: true,
          ));

          // Additional session check before playing first song in loop
          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
          }

          await _audioPlayer.play();
          await _syncMetadata();
        } else {
          // When loop is off and we're at the last song, handle end of queue
          debugPrint('ImprovedAudioHandler: End of queue reached');

          // In background mode, pause instead of stopping to maintain session
          if (_isBackgroundMode) {
            await _audioPlayer.pause();
            playbackState.add(playbackState.nvalue!.copyWith(
              playing: false,
              processingState: AudioProcessingState.ready,
            ));
            await _ensureAudioSessionActive();
          } else {
            await stop();
          }
          return;
        }
      } else {
        // Direct transition to next song
        await _transitionToNextSong();
      }
    }
  }

  /// Direct transition to next song with minimal overhead
  Future<void> _transitionToNextSong() async {
    if (_queue.isEmpty) return;

    int newIndex = _currentIndex + 1;
    if (newIndex >= _queue.length) {
      if (playbackState.nvalue!.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        return;
      }
    }

    debugPrint(
        'ImprovedAudioHandler: Direct transition from $_currentIndex to $newIndex');

    try {
      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        // Use minimal delay in gapless mode for seamless transitions
        await Future.delayed(_gaplessModeEnabled
            ? _gaplessTransitionDelay
            : const Duration(milliseconds: 50));
      }

      await _prepareToPlay(newIndex);

      // Start playing immediately
      if (_shouldBePaused) {
        _shouldBePaused = false;
      }

      if (_audioPlayer.volume == 0.0) {
        await _audioPlayer.setVolume(1.0);
      }

      await _audioPlayer.play();
      await _syncMetadata();
    } catch (e) {
      debugPrint('ImprovedAudioHandler: Error in direct transition: $e');
      // Fallback to regular skipToNext
      await skipToNext();
    }
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {
      // All existing custom actions from the original handler
      // ... (copy all the custom actions from the original handler)
      
      case 'detectAndFixAudioSessionBug':
        try {
          final isPlaying = _audioPlayer.playing;
          final processingState = _audioPlayer.processingState;

          debugPrint(
              'ImprovedAudioHandler: Detecting audio session bug - Playing: $isPlaying, State: $processingState');

          if (isPlaying && _isIOS && _audioSession != null) {
            try {
              await _audioSession!.setActive(true);
              return {'bugDetected': false, 'fixed': false};
            } catch (e) {
              debugPrint(
                  'ImprovedAudioHandler: Audio session bug detected! $e');
              await _audioPlayer.pause();
              return {'bugDetected': true, 'fixed': true};
            }
          }
          return {'bugDetected': false, 'fixed': false};
        } catch (e) {
          return {
            'bugDetected': false,
            'fixed': false,
            'error': e.toString()
          };
        }

      case 'setGaplessMode':
        final enabled = extras?['enabled'] as bool? ?? true;
        setGaplessMode(enabled);
        return {'gaplessMode': enabled};

      case 'getGaplessMode':
        return {'gaplessMode': _gaplessModeEnabled};

      // Queue inspection methods from BaseAudioHandler pattern
      case 'getCurrentQueueIndex':
        return _currentIndex;

      case 'getQueueLength':
        return _queue.length;

      case 'getQueueItem':
        final index = extras?['index'] as int?;
        if (index != null && index >= 0 && index < _queue.length) {
          return _queue[index].toJson();
        }
        return null;

      // Enhanced state management
      case 'getPlaybackState':
        return {
          'playing': playbackState.nvalue?.playing ?? false,
          'processingState': playbackState.nvalue?.processingState.toString(),
          'position': playbackState.nvalue?.updatePosition?.inMilliseconds ?? 0,
          'queueIndex': _currentIndex,
          'repeatMode': playbackState.nvalue?.repeatMode.toString(),
          'shuffleMode': playbackState.nvalue?.shuffleMode.toString(),
        };

      // Session management
      case 'ensureAudioSessionActive':
        await _ensureAudioSessionActive();
        return {'sessionActive': _isSessionActive};

      case 'handleAppForeground':
        await handleAppForeground();
        return {'handled': true};

      case 'handleAppBackground':
        await handleAppBackground();
        return {'handled': true};

      // Audio effects integration
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
        return super.customAction(name, extras);
    }
  }

  /// Clean up resources
  @override
  Future<void> onTaskRemoved() async {
    debugPrint('ImprovedAudioHandler: Task removed - cleaning up');
    await dispose();
    super.onTaskRemoved();
  }

  /// Dispose of resources properly
  Future<void> dispose() async {
    debugPrint('ImprovedAudioHandler: Disposing resources');
    
    _errorRecoveryTimer?.cancel();
    
    // Cancel all stream subscriptions
    await _playerStateSubscription.cancel();
    await _durationSubscription.cancel();
    await _positionSubscription.cancel();
    await _processingStateSubscription.cancel();
    
    // Close subjects
    await _queueIndexSubject.close();
    await _shuffleEnabledSubject.close();
    
    // If we're in background mode, ensure audio session stays active
    if (_isBackgroundMode && _isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
        debugPrint(
            'ImprovedAudioHandler: Audio session maintained during disposal');
      } catch (e) {
        debugPrint('Error maintaining audio session during disposal: $e');
      }
    }

    await _audioPlayer.dispose();
  }

  // Default implementations for remaining BaseAudioHandler methods
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId) async {
    return <MediaItem>[];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    return _queue.cast<MediaItem?>().firstWhere(
      (item) => item?.id == mediaId,
      orElse: () => null,
    );
  }

  @override
  Future<List<MediaItem>> search(String query) async {
    // Implement search logic if needed
    return <MediaItem>[];
  }

  // Click handler implementation from BaseAudioHandler pattern
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
}
