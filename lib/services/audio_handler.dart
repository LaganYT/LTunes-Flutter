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
import 'bug_report_service.dart';

final GlobalKey<NavigatorState> globalNavigatorKey =
    GlobalKey<NavigatorState>();

/// Converts a Song to a MediaItem for use with audio_service.
/// This is the canonical function for this conversion - use this throughout the app.
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
      'artistId': song.artistId,
      'isLocal': song.isDownloaded,
      'localArtFileName':
          (!song.albumArtUrl.startsWith('http') && song.albumArtUrl.isNotEmpty)
              ? song.albumArtUrl
              : null,
      'isRadio': song.isRadio,
    },
  );
}

class AudioPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final _playlist = <MediaItem>[];
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

  // Track loop reset state
  bool _justResetForLoop = false;

  // Track local file completion to prevent infinite loops
  String? _lastLocalFileCompleted;
  int _localFileCompletionCount = 0;
  static const int _maxLocalFileCompletions = 3;

  // Throttling for background continuity checks
  DateTime? _lastContinuityCheck;
  static const Duration _continuityCheckThrottle = Duration(seconds: 5);

  AudioPlayerHandler() {
    _initializeAudioSession();
    _notifyAudioHandlerAboutPlaybackEvents();
  }

  bool get shouldBePaused => _shouldBePaused;

  set shouldBePaused(bool value) {
    _shouldBePaused = value;
    if (value && _audioPlayer.playing) {
      _audioPlayer.pause();
      playbackState.add(playbackState.value.copyWith(playing: false));
    }
  }

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
              "Initial audio session activation failed (non-critical): $e");
          _isSessionActive = false;
        }
      } else {
        // Android configuration
        await _audioSession!.configure(const AudioSessionConfiguration.music());
      }

      _audioSessionConfigured = true;
      debugPrint("AudioHandler: Audio session initialized successfully");
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
      // Don't set _audioSessionConfigured to true if initialization failed
    }
  }

  Future<void> _ensureAudioSessionActive() async {
    if (!_isIOS || _audioSession == null || !_audioSessionConfigured) return;

    // OPTIMIZED: Skip session activation if we're not playing and not in background mode
    // This reduces unnecessary session operations
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
          "AudioHandler: Too many consecutive errors, skipping activation");
      return;
    }

    if (!_isSessionActive) {
      try {
        await _audioSession!.setActive(true);
        _isSessionActive = true;
        _lastSessionActivation = now;
        _consecutiveErrors = 0; // Reset error count on successful activation
        debugPrint("AudioHandler: Audio session activated successfully");
      } catch (e) {
        final errorMessage = e.toString();
        debugPrint(
            "AudioHandler: Error activating audio session: $errorMessage");
        _consecutiveErrors++;

        // Check for -50 error (paramErr) which indicates the session is in a bad state
        if (errorMessage.contains('-50') || errorMessage.contains('paramErr')) {
          debugPrint(
              "AudioHandler: Detected paramErr (-50), marking session as invalid");
          _isSessionActive = false;
          _audioSessionConfigured = false; // Force re-initialization
        }

        _scheduleErrorRecovery();
      }
    } else if (_isBackgroundMode) {
      // In background mode, gently verify session is still active (less aggressive)
      try {
        // Use a more gentle check - just verify the session state without forcing activation
        // This avoids the -50 errors that occur when trying to setActive on an already active session
        await _audioSession!.setActive(true);
        debugPrint("AudioHandler: Background audio session verified as active");
      } catch (e) {
        final errorMessage = e.toString();
        debugPrint(
            "AudioHandler: Background session verification failed: $errorMessage");

        // For -50 errors, mark session as invalid
        if (errorMessage.contains('-50') || errorMessage.contains('paramErr')) {
          _isSessionActive = false;
          _audioSessionConfigured = false;
        }
      }
    }
  }

  Future<void> _restoreAudioSessionIfNeeded() async {
    if (!_isIOS || _audioSession == null) return;

    try {
      // Check if session is still active
      await _audioSession!.setActive(true);
      debugPrint("AudioHandler: Audio session restored successfully");
    } catch (e) {
      debugPrint(
          "AudioHandler: Audio session restoration failed, attempting full reactivation: $e");
      _isSessionActive = false;
      await _ensureAudioSessionActive();
    }
  }

  void _scheduleErrorRecovery() {
    if (_consecutiveErrors >= _maxConsecutiveErrors &&
        _errorRecoveryTimer == null) {
      _errorRecoveryTimer?.cancel();
      _errorRecoveryTimer = Timer(const Duration(seconds: 10), () async {
        debugPrint(
            "AudioHandler: Attempting comprehensive audio session recovery");
        _errorRecoveryTimer = null;

        try {
          // Reset session state
          _isSessionActive = false;
          _audioSessionConfigured = false;
          _consecutiveErrors = 0;

          // Step 1: Re-initialize audio session completely
          await _initializeAudioSession();

          // Step 2: Wait a bit for the session to stabilize
          await Future.delayed(const Duration(seconds: 2));

          // Step 3: If we're in background mode and should be playing, try to restore
          if (_isBackgroundMode && _playlist.isNotEmpty && _currentIndex >= 0) {
            try {
              // Only attempt recovery if we should be playing
              if (playbackState.value.playing) {
                debugPrint(
                    "AudioHandler: Restoring playback after session recovery");
                await _ensureBackgroundPlaybackContinuity();
              }
            } catch (e) {
              debugPrint(
                  "AudioHandler: Error during background playback recovery: $e");
            }
          }
        } catch (e) {
          debugPrint("AudioHandler: Comprehensive recovery failed: $e");
          // Don't prevent further attempts - just log and continue
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

  Future<void> _syncMetadata() async {
    final currentItem = mediaItem.value;
    if (currentItem != null) {
      mediaItem.add(currentItem);
    }
  }

  Future<void> _prepareToPlay(int index) async {
    if (index < 0 || index >= _playlist.length) {
      debugPrint("AudioHandler: Invalid index in _prepareToPlay");
      return;
    }

    _currentIndex = index;
    MediaItem itemToPlay = _playlist[_currentIndex];

    // Reset completion state for new song
    _isHandlingCompletion = false;
    _lastCompletionTime = null;

    // Reset local file completion tracking for new song
    if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
      _localFileCompletionCount = 0;
      _lastLocalFileCompleted = null;
    }

    mediaItem.add(itemToPlay);
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));

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
          throw Exception("Local file not found: $filePath");
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

      // OPTIMIZED: Wait for ready state with reduced timeout and smaller delays
      int attempts = 0;
      const int maxAttempts = 20; // Reduced from 30
      const Duration checkInterval =
          Duration(milliseconds: 50); // Reduced from 100ms

      while (_audioPlayer.processingState != ProcessingState.ready &&
          attempts < maxAttempts) {
        await Future.delayed(checkInterval);
        attempts++;
      }

      if (_audioPlayer.processingState != ProcessingState.ready) {
        throw Exception(
            "Audio player failed to become ready within ${maxAttempts * checkInterval.inMilliseconds}ms");
      }

      playbackState
          .add(playbackState.value.copyWith(updatePosition: Duration.zero));
      mediaItem.add(itemToPlay);

      // Resolve artwork asynchronously
      _resolveArtworkAsync(itemToPlay);
    } catch (e) {
      debugPrint("Error preparing audio source: $e");
      if (_isRadioStream) _showRadioErrorDialog(itemToPlay.title);

      // Only auto-skip if we're already playing and this is not the first song attempt
      // For the first song in a new playback session, let the caller handle the error
      final isFirstSongAttempt = !_audioPlayer.playing &&
          playbackState.value.processingState == AudioProcessingState.idle;

      if (!isFirstSongAttempt &&
          _playlist.isNotEmpty &&
          _currentIndex >= 0 &&
          _currentIndex < _playlist.length) {
        debugPrint(
            "AudioHandler: Auto-skipping to next song due to playback error (not first song)");
        try {
          // Try to skip to next song
          if (_currentIndex < _playlist.length - 1) {
            await skipToNext();
          } else if (playbackState.value.repeatMode ==
              AudioServiceRepeatMode.all) {
            // Loop to beginning if repeat is enabled
            await skipToQueueItem(0);
          } else {
            // Stop playback if no more songs
            await stop();
          }
        } catch (skipError) {
          debugPrint("AudioHandler: Error skipping to next song: $skipError");
          await stop();
        }
      }

      rethrow;
    }
  }

  Future<void> _resolveArtworkAsync(MediaItem item) async {
    try {
      MediaItem resolvedItem = await _resolveArtForItem(item);

      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        _playlist[_currentIndex] = resolvedItem;
      }

      mediaItem.add(resolvedItem);
    } catch (e) {
      debugPrint("Error resolving artwork for ${item.title}: $e");
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

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _audioPlayer.playerStateStream.listen((playerState) async {
      final playing = playerState.playing;
      final processingState = playerState.processingState;

      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        playing: playing,
        processingState: {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[processingState]!,
      ));
    });

    _audioPlayer.durationStream.listen((newDuration) {
      if (newDuration != null && newDuration > Duration.zero) {
        final currentItem = mediaItem.value;
        if (currentItem != null && currentItem.duration != newDuration) {
          final updatedItem = currentItem.copyWith(duration: newDuration);
          mediaItem.add(updatedItem);
        }
      }
    });

    _audioPlayer.positionStream.listen((position) async {
      // Check if this is a streaming URL (not local file)
      final currentItem = mediaItem.value;
      final isStreaming = currentItem?.extras?['isLocal'] != true;

      // For streaming URLs, be more careful about position updates
      if (isStreaming &&
          position == Duration.zero &&
          _audioPlayer.playing &&
          !_justResetForLoop) {
        // Don't emit zero position for streaming URLs while playing
        // This prevents the seekbar from jumping to 0
        // EXCEPT when we just reset for a loop
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
      playbackState.add(playbackState.value.copyWith(updatePosition: position));

      // Check if position exceeds duration and restart if so
      if (currentItem != null &&
          currentItem.duration != null &&
          position > currentItem.duration! &&
          _audioPlayer.playing) {
        debugPrint(
            "Position ${position.inSeconds}s exceeds duration ${currentItem.duration!.inSeconds}s, restarting song");
        await _audioPlayer.seek(Duration.zero);
        playbackState
            .add(playbackState.value.copyWith(updatePosition: Duration.zero));
        return;
      }

      // Handle song completion
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
            final songId = currentItem.extras?['songId'] as String?;
            final now = DateTime.now();

            // Check if enough time has passed since last completion
            if (_lastCompletionTime != null &&
                now.difference(_lastCompletionTime!) < _completionCooldown) {
              debugPrint(
                  "AudioHandler: Skipping completion - too soon since last completion");
              return;
            }

            if (songId != null &&
                songId != _lastCompletedSongId &&
                !_isHandlingCompletion) {
              _lastCompletedSongId = songId;
              _lastCompletionTime = now;
              _isHandlingCompletion = true;

              debugPrint(
                  "AudioHandler: Position-based completion detected for song: $songId");

              // Ensure audio session is active before handling completion
              if (_isBackgroundMode) {
                await _ensureAudioSessionActive();
              }

              await _handleSongCompletion();
              _isHandlingCompletion = false;
            }
          }
        }
      }
    });

    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed && !_isHandlingCompletion) {
        final now = DateTime.now();

        // Check if enough time has passed since last completion
        if (_lastCompletionTime != null &&
            now.difference(_lastCompletionTime!) < _completionCooldown) {
          debugPrint(
              "AudioHandler: Skipping ProcessingState.completed - too soon since last completion");
          return;
        }

        _lastCompletionTime = now;
        _isHandlingCompletion = true;

        // If we're in background mode, ensure audio session stays active
        if (_isBackgroundMode) {
          await _ensureAudioSessionActive();
        }

        debugPrint(
            "AudioHandler: ProcessingState.completed detected - handling song completion");
        await _handleSongCompletion();
        _isHandlingCompletion = false;
      }
    });
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _playlist.addAll(mediaItems);
    queue.add(List.unmodifiable(_playlist));
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _playlist.add(mediaItem);
    queue.add(List.unmodifiable(_playlist));
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    _playlist.insert(index, mediaItem);
    queue.add(List.unmodifiable(_playlist));
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    _playlist.clear();
    _playlist.addAll(queue);
    this.queue.add(List.unmodifiable(_playlist));
    if (_currentIndex >= _playlist.length) {
      _currentIndex = _playlist.isNotEmpty ? 0 : -1;
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    queue.add(List.unmodifiable(_playlist));

    if (_currentIndex == index) {
      if (_playlist.isEmpty) {
        _currentIndex = -1;
        await stop();
      } else if (_currentIndex >= _playlist.length) {
        _currentIndex = _playlist.length - 1;
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
  }

  @override
  Future<void> play() async {
    if (_audioPlayer.playing || _shouldBePaused) {
      return;
    }

    // Log audio event
    BugReportService().logAudioEvent('play_requested', data: {
      'current_index': _currentIndex,
      'playlist_length': _playlist.length,
      'should_be_paused': _shouldBePaused,
    });

    await _incrementPlayCounts();
    await _ensureAudioSessionActive();

    try {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
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
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _syncMetadata();
        }
      } else {
        await _audioPlayer.play();
      }
    } catch (e) {
      debugPrint("Error during play operation: $e");
      if (_isRadioStream &&
          _currentIndex >= 0 &&
          _currentIndex < _playlist.length) {
        _showRadioErrorDialog(_playlist[_currentIndex].title);
      }
    }
  }

  Future<void> _incrementPlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final statsEnabled = prefs.getBool('listeningStatsEnabled') ?? true;
    if (!statsEnabled ||
        _currentIndex < 0 ||
        _currentIndex >= _playlist.length) {
      return;
    }

    final item = _playlist[_currentIndex];
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

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _audioPlayer.seek(position);

      // For streaming URLs, wait a bit for the position to stabilize
      if (_audioPlayer.processingState == ProcessingState.ready) {
        // Force immediate position update after seek
        playbackState
            .add(playbackState.value.copyWith(updatePosition: position));

        // Wait a short time and then verify the position
        await Future.delayed(const Duration(milliseconds: 100));
        final actualPosition = _audioPlayer.position;

        // If the position is significantly different from what we expected,
        // update with the actual position
        if ((actualPosition - position).abs() > const Duration(seconds: 1)) {
          playbackState.add(
              playbackState.value.copyWith(updatePosition: actualPosition));
        }
      } else {
        // For non-streaming, just update immediately
        playbackState
            .add(playbackState.value.copyWith(updatePosition: position));
      }
    } catch (e) {
      debugPrint("Error during seek operation: $e");
      // If seek fails, get the actual position and update
      final currentPosition = _audioPlayer.position;
      playbackState
          .add(playbackState.value.copyWith(updatePosition: currentPosition));
    }
  }

  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
      updatePosition: Duration.zero,
    ));
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;

    // CRITICAL FIX: Ensure audio session is active before any skip operation in background
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
      debugPrint("AudioHandler: Background session verified before skipToNext");

      // ADDITIONAL FIX: Extra aggressive session verification for iOS
      if (_isIOS && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint(
              "AudioHandler: Extra iOS session activation before skipToNext");
        } catch (e) {
          debugPrint("AudioHandler: Extra iOS session activation failed: $e");
        }
      }
    }

    int newIndex = _currentIndex + 1;
    if (newIndex >= _playlist.length) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        // When loop is off, loop to first song
        newIndex = 0;
      }
    }

    debugPrint(
        "AudioHandler: skipToNext from $_currentIndex to $newIndex (background: $_isBackgroundMode)");
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    // CRITICAL FIX: Ensure audio session is active before any skip operation in background
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
      debugPrint(
          "AudioHandler: Background session verified before skipToPrevious");

      // ADDITIONAL FIX: Extra aggressive session verification for iOS
      if (_isIOS && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint(
              "AudioHandler: Extra iOS session activation before skipToPrevious");
        } catch (e) {
          debugPrint("AudioHandler: Extra iOS session activation failed: $e");
        }
      }
    }

    int newIndex = _currentIndex - 1;
    if (newIndex < 0) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = _playlist.length - 1;
      } else {
        // When loop is off, loop to last song
        newIndex = _playlist.length - 1;
      }
    }

    debugPrint(
        "AudioHandler: skipToPrevious from $_currentIndex to $newIndex (background: $_isBackgroundMode)");
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) {
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

      // CRITICAL FIX: Ensure audio session is still active after preparing to play
      // This is especially important during background/foreground transitions
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

        // Gentle final verification that audio session is still active
        if (_isIOS && _isBackgroundMode) {
          try {
            await _ensureAudioSessionActive();
          } catch (e) {
            debugPrint(
                "AudioHandler: Audio session verification failed after skipToQueueItem: $e");
            // Don't try to recover aggressively here - let the background timers handle it
          }
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_audioPlayer.processingState == ProcessingState.ready) {
          await _audioPlayer.play();
          await _syncMetadata();

          // Same verification for the delayed case
          if (_isIOS && _audioSession != null) {
            try {
              await _audioSession!.setActive(true);
              debugPrint(
                  "AudioHandler: Audio session verified active after delayed skipToQueueItem");
            } catch (e) {
              debugPrint(
                  "AudioHandler: Audio session issue after delayed skipToQueueItem: $e");
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error during skipToQueueItem: $e");
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.error,
      ));
      if (_isRadioStream &&
          _currentIndex >= 0 &&
          _currentIndex < _playlist.length) {
        _showRadioErrorDialog(_playlist[_currentIndex].title);
      }
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
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
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

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
    int index = _playlist.indexWhere((element) => element.id == mediaItem.id);
    if (index == -1) {
      _playlist.clear();
      _playlist.add(mediaItem);
      queue.add(List.unmodifiable(_playlist));
      index = 0;
    } else {
      _playlist[index] = mediaItem;
    }
    await skipToQueueItem(index);
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    final index = _playlist.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      await skipToQueueItem(index);
    } else {
      if (Uri.tryParse(mediaId)?.isAbsolute ?? false) {
        final newItem = MediaItem(
          id: mediaId,
          title: extras?['title'] as String? ?? mediaId.split('/').last,
          artist: extras?['artist'] as String? ?? "Unknown Artist",
          album: extras?['album'] as String?,
          artUri: extras?['artUri'] is String
              ? Uri.tryParse(extras!['artUri'])
              : null,
          extras: extras,
        );
        _playlist.add(newItem);
        queue.add(List.unmodifiable(_playlist));
        await skipToQueueItem(_playlist.length - 1);
      }
    }
  }

  Future<void> ensureBackgroundPlayback() async {
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
      _isBackgroundMode = true;
    }
  }

  Future<void> _ensureAudioSessionInitialized() async {
    debugPrint(
        "AudioHandler: Ensuring audio session is initialized when app opens");
    await _initializeAudioSession();
    if (_isIOS) {
      await _ensureAudioSessionActive();
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

      // If we're in background mode and have a playlist, ensure continuity
      if (_isBackgroundMode && _playlist.isNotEmpty) {
        final currentState = _audioPlayer.processingState;
        final currentItem =
            _currentIndex >= 0 && _currentIndex < _playlist.length
                ? _playlist[_currentIndex]
                : null;
        final isLocalFile = currentItem?.extras?['isLocal'] as bool? ?? false;

        // If audio player is completed but we should continue playing
        if (currentState == ProcessingState.completed &&
            _currentIndex >= 0 &&
            _currentIndex < _playlist.length) {
          final repeatMode = playbackState.value.repeatMode;

          // If repeat is on or we're not at the last song, continue to next
          if (repeatMode == AudioServiceRepeatMode.all ||
              _currentIndex < _playlist.length - 1) {
            debugPrint(
                "AudioHandler: Ensuring background playback continuity - moving to next song (local: $isLocalFile)");
            await skipToNext();
          } else if (repeatMode == AudioServiceRepeatMode.one) {
            // If repeat one is on, restart current song
            debugPrint(
                "AudioHandler: Ensuring background playback continuity - restarting current song (local: $isLocalFile)");
            await _prepareToPlay(_currentIndex);
            await _audioPlayer.play();
            await _syncMetadata();
          }
        }

        // Special handling for local files that might not report completion properly
        // Only check this every few continuity checks to reduce overhead
        if (isLocalFile &&
            currentState == ProcessingState.ready &&
            _audioPlayer.playing &&
            currentItem?.duration != null &&
            now.second % 3 == 0) {
          // Only check every 3rd second
          final position = _audioPlayer.position;
          final duration = currentItem!.duration!;

          // If we're very close to the end of a local file, force completion
          if (position > Duration.zero &&
              (duration - position).inMilliseconds <= 50) {
            debugPrint(
                "AudioHandler: Local file near end, forcing completion check");
            if (!_isHandlingCompletion) {
              _isHandlingCompletion = true;
              await _handleSongCompletion();
              _isHandlingCompletion = false;
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error ensuring background playback continuity: $e");
    }
  }

  Future<void> handleAppForeground() async {
    _isBackgroundMode = false;

    // CRITICAL FIX: Always ensure audio session is active when coming to foreground
    // This prevents the bug where audio stops but UI shows as playing
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
    }

    // Enhanced position sync when app comes to foreground
    // The audio player often reports 0 immediately after foreground, so we need to be smart about this

    final isPlaying = _audioPlayer.playing;
    final processingState = _audioPlayer.processingState;

    // CRITICAL FIX: Check for audio session inconsistency during transitions
    // If we think we're playing but audio session is not active, fix the state
    if (isPlaying && _isIOS && _audioSession != null) {
      try {
        // Test if audio session is actually active by trying to set it active
        await _audioSession!.setActive(true);
        debugPrint(
            "AudioHandler: Audio session verified as active during foreground");
      } catch (e) {
        debugPrint(
            "AudioHandler: Audio session was inactive during foreground, fixing state: $e");
        // If audio session was inactive, we need to stop the "fake" playing state
        await _audioPlayer.pause();
        playbackState.add(playbackState.value.copyWith(playing: false));
        // Don't return here - continue with position sync to get accurate state
      }
    }

    // Get multiple position readings to find the stable one
    Duration? stablePosition;
    final lastKnownPos = _lastKnownPosition ?? Duration.zero;
    final actualIsPlaying =
        _audioPlayer.playing; // Get fresh playing state after session check

    // Try multiple readings with longer delays to find stable position
    // iOS audio player may take longer to stabilize after foreground
    for (int attempt = 0; attempt < 6; attempt++) {
      // Use longer delays: 200ms, 400ms, 600ms, 800ms, 1000ms, 1200ms
      await Future.delayed(Duration(milliseconds: 200 + (attempt * 200)));
      final currentPos = _audioPlayer.position;

      debugPrint(
          "AudioHandler: Foreground position attempt ${attempt + 1}: ${currentPos.inSeconds}s (last known: ${lastKnownPos.inSeconds}s, playing: $actualIsPlaying)");

      // If we're not playing, any position is acceptable (usually 0)
      if (!actualIsPlaying) {
        stablePosition = currentPos;
        debugPrint(
            "AudioHandler: Not playing, using position ${currentPos.inSeconds}s");
        break;
      }

      // If position is reasonable (> 0), use it
      if (currentPos > Duration.zero) {
        stablePosition = currentPos;
        debugPrint(
            "AudioHandler: Found reasonable position ${currentPos.inSeconds}s");
        break;
      }

      // If position is 0 but we have a last known position and are playing,
      // this might be an incorrect reading - continue trying
      if (currentPos == Duration.zero &&
          lastKnownPos > Duration.zero &&
          actualIsPlaying &&
          attempt < 5) {
        debugPrint(
            "AudioHandler: Position is 0 but should be playing, trying again...");
        continue;
      }

      // On final attempt, use last known position if available, otherwise use current
      if (attempt == 5) {
        stablePosition =
            lastKnownPos > Duration.zero ? lastKnownPos : currentPos;
        debugPrint(
            "AudioHandler: Final attempt, using position ${stablePosition.inSeconds}s");
      }
    }

    // Fall back to last known position if all readings were 0 and we were playing
    if (stablePosition == Duration.zero &&
        lastKnownPos > Duration.zero &&
        actualIsPlaying) {
      debugPrint(
          "AudioHandler: All position readings were 0, using last known position: ${lastKnownPos.inSeconds}s");
      stablePosition = lastKnownPos;
    }

    final finalPosition = stablePosition ?? Duration.zero;
    _lastKnownPosition = finalPosition;

    debugPrint(
        "AudioHandler: App foregrounded - Final Position: ${finalPosition.inSeconds}s, Playing: $actualIsPlaying, State: $processingState");

    // Force comprehensive playback state update with stable position and corrected playing state
    playbackState.add(playbackState.value.copyWith(
      updatePosition: finalPosition,
      playing: actualIsPlaying, // Use the corrected playing state
      processingState: {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[processingState] ??
          AudioProcessingState.idle,
    ));

    // Final verification after everything stabilizes - only check for critical issues
    Future.delayed(const Duration(milliseconds: 1500), () async {
      final verifyPosition = _audioPlayer.position;
      final verifyPlaying = _audioPlayer.playing;

      // Only check for significant position drift (> 5 seconds) to avoid UI flickering
      if (verifyPosition > Duration.zero &&
          (verifyPosition - finalPosition).abs() > const Duration(seconds: 5)) {
        debugPrint(
            "AudioHandler: Significant position drift detected - updating from ${finalPosition.inSeconds}s to ${verifyPosition.inSeconds}s");
        _lastKnownPosition = verifyPosition;
        playbackState
            .add(playbackState.value.copyWith(updatePosition: verifyPosition));
      }

      // Check for playing state drift (critical for the bug fix)
      if (verifyPlaying != actualIsPlaying) {
        debugPrint(
            "AudioHandler: Playing state drift detected - correcting from $actualIsPlaying to $verifyPlaying");
        playbackState.add(playbackState.value.copyWith(playing: verifyPlaying));
      }
    });
  }

  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS) {
      // Gently ensure audio session is ready for background mode
      await _ensureAudioSessionActive();
    }
  }

  Future<void> dispose() async {
    _errorRecoveryTimer?.cancel();

    // If we're in background mode, ensure audio session stays active
    if (_isBackgroundMode && _isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
        debugPrint("AudioHandler: Audio session maintained during disposal");
      } catch (e) {
        debugPrint("Error maintaining audio session during disposal: $e");
      }
    }

    await _audioPlayer.dispose();
  }

  Future<void> _handleSongCompletion() async {
    final repeatMode = playbackState.value.repeatMode;
    final currentItem = _currentIndex >= 0 && _currentIndex < _playlist.length
        ? _playlist[_currentIndex]
        : null;
    final isLocalFile = currentItem?.extras?['isLocal'] as bool? ?? false;
    final songId = currentItem?.extras?['songId'] as String?;

    debugPrint(
        "AudioHandler: Song completion - Repeat: $repeatMode, Index: $_currentIndex, Local: $isLocalFile");

    // Ensure audio session is active in background mode
    if (_isBackgroundMode) {
      await _ensureAudioSessionActive();
    }

    // For local files, check if we're stuck in a completion loop
    if (isLocalFile && songId != null) {
      if (_lastLocalFileCompleted == songId) {
        _localFileCompletionCount++;
        debugPrint(
            "AudioHandler: Local file completion count: $_localFileCompletionCount for song: $songId");

        // If we've completed the same local file too many times, force move to next
        if (_localFileCompletionCount >= _maxLocalFileCompletions) {
          debugPrint(
              "AudioHandler: Too many completions for local file, forcing next song");
          _localFileCompletionCount = 0;
          _lastLocalFileCompleted = null;

          if (_currentIndex < _playlist.length - 1) {
            await skipToNext();
            return;
          } else if (repeatMode == AudioServiceRepeatMode.all) {
            await _prepareToPlay(0);
            _currentIndex = 0;
            playbackState.add(playbackState.value.copyWith(
              queueIndex: _currentIndex,
              playing: true,
            ));
            await _audioPlayer.play();
            await _syncMetadata();
            return;
          } else {
            // Stop playback at end of queue
            await _audioPlayer.stop();
            playbackState.add(playbackState.value.copyWith(
              playing: false,
              processingState: AudioProcessingState.completed,
            ));
            return;
          }
        }
      } else {
        _localFileCompletionCount = 1;
        _lastLocalFileCompleted = songId;
      }
    }

    if (repeatMode == AudioServiceRepeatMode.one) {
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        debugPrint("AudioHandler: Repeating single song (local: $isLocalFile)");
        await _prepareToPlay(_currentIndex);
        // Reset position to 0 when looping a single song
        _justResetForLoop = true; // Set flag before seeking
        await _audioPlayer.seek(Duration.zero);
        // Force position update to 0 for UI
        playbackState.add(playbackState.value.copyWith(
          updatePosition: Duration.zero,
          playing: true,
        ));
        await _audioPlayer.play();
        await _syncMetadata();
        return;
      }
    } else {
      // Check if we're at the end of the queue
      if (_currentIndex == _playlist.length - 1) {
        if (repeatMode == AudioServiceRepeatMode.all) {
          // Loop to first song and continue playing
          debugPrint(
              "AudioHandler: Looping queue - moving from last song to first (local: $isLocalFile)");

          // CRITICAL FIX: Ensure audio session stays active during queue loop in background
          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
            debugPrint(
                "AudioHandler: Background session verified during queue loop");
          }

          await _prepareToPlay(0);
          _currentIndex = 0;
          playbackState.add(playbackState.value.copyWith(
            queueIndex: _currentIndex,
            playing: true,
          ));

          // CRITICAL FIX: Additional session check before playing first song in loop
          if (_isBackgroundMode) {
            await _ensureAudioSessionActive();
          }

          await _audioPlayer.play();
          await _syncMetadata();
        } else {
          // When loop is off and we're at the last song, handle end of queue
          debugPrint(
              "AudioHandler: End of queue reached - handling end state (local: $isLocalFile, background: $_isBackgroundMode)");

          // CRITICAL FIX: In background mode, stopping audio can deactivate the session
          // Instead of stopping completely, pause to maintain the session
          if (_isBackgroundMode) {
            debugPrint(
                "AudioHandler: Background mode - pausing instead of stopping to maintain session");
            await _audioPlayer.pause();
            playbackState.add(playbackState.value.copyWith(
              playing: false,
              processingState:
                  AudioProcessingState.ready, // Keep as ready, not completed
            ));

            // Ensure the audio session stays active even though we're paused
            await _ensureAudioSessionActive();
            debugPrint(
                "AudioHandler: Background session maintained after queue end");
          } else {
            // In foreground mode, it's safe to stop completely
            await _audioPlayer.stop();
            playbackState.add(playbackState.value.copyWith(
              playing: false,
              processingState: AudioProcessingState.completed,
            ));
          }
          return;
        }
      } else {
        // OPTIMIZED: Direct transition to next song to minimize gap
        debugPrint("AudioHandler: Direct transition to next song");
        await _transitionToNextSong();
      }
    }
  }

  /// OPTIMIZED: Direct transition to next song with minimal overhead
  Future<void> _transitionToNextSong() async {
    if (_playlist.isEmpty) return;

    int newIndex = _currentIndex + 1;
    if (newIndex >= _playlist.length) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        // End of queue - let completion handler deal with this
        return;
      }
    }

    debugPrint(
        "AudioHandler: Direct transition from $_currentIndex to $newIndex");

    // Streamlined version of skipToQueueItem optimized for gapless playback
    try {
      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        // Use minimal delay for seamless transitions
        await Future.delayed(const Duration(milliseconds: 10));
      }

      await _prepareToPlay(newIndex);

      // Start playing immediately without extra session checks
      if (_shouldBePaused) {
        _shouldBePaused = false;
      }

      if (_audioPlayer.volume == 0.0) {
        await _audioPlayer.setVolume(1.0);
      }

      await _audioPlayer.play();
      await _syncMetadata();
    } catch (e) {
      debugPrint("AudioHandler: Error in direct transition: $e");
      // Fallback to regular skipToNext
      await skipToNext();
    }
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'updateCurrentMediaItemMetadata':
        final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
        if (mediaMap != null) {
          final currentItem = mediaItem.value;
          if (currentItem != null &&
              _currentIndex >= 0 &&
              _currentIndex < _playlist.length) {
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
              extras: (mediaMap['extras'] as Map<String, dynamic>?) ??
                  currentItem.extras,
            );
            _playlist[_currentIndex] = updatedItem;
            mediaItem.add(updatedItem);
            queue.add(List.unmodifiable(_playlist));
          }
        }
        break;

      case 'setQueueIndex':
        final index = extras?['index'] as int?;
        if (index != null && index >= 0 && index < _playlist.length) {
          _currentIndex = index;
          playbackState
              .add(playbackState.value.copyWith(queueIndex: _currentIndex));
        }
        break;

      case 'prepareToPlay':
        final index = extras?['index'] as int?;
        if (index != null) await _prepareToPlay(index);
        break;

      case 'prepareMediaItem':
        final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
        if (mediaMap != null) {
          final artUriString = mediaMap['artUri'] as String?;
          final durationMillis = mediaMap['duration'] as int?;
          final mediaItemToPrepare = MediaItem(
            id: mediaMap['id'] as String,
            title: mediaMap['title'] as String,
            artist: mediaMap['artist'] as String?,
            album: mediaMap['album'] as String?,
            artUri: artUriString != null ? Uri.tryParse(artUriString) : null,
            duration: durationMillis != null
                ? Duration(milliseconds: durationMillis)
                : null,
            extras: mediaMap['extras'] as Map<String, dynamic>?,
          );
          int index = _playlist
              .indexWhere((element) => element.id == mediaItemToPrepare.id);
          if (index == -1) {
            _playlist.clear();
            _playlist.add(mediaItemToPrepare);
            queue.add(List.unmodifiable(_playlist));
            index = 0;
          } else {
            _playlist[index] = mediaItemToPrepare;
          }
          await _prepareToPlay(index);
        }
        break;

      case 'openDownloadQueue':
        final navigator = globalNavigatorKey.currentState;
        if (navigator != null) {
          navigator.push(MaterialPageRoute(
              builder: (context) => const DownloadQueueScreen()));
        }
        break;

      case 'ensureBackgroundPlayback':
        await ensureBackgroundPlayback();
        break;

      case 'ensureBackgroundPlaybackContinuity':
        await _ensureBackgroundPlaybackContinuity();
        break;

      case 'ensureAudioSessionInitialized':
        await _ensureAudioSessionInitialized();
        break;

      case 'handleAppForeground':
        await handleAppForeground();
        break;

      case 'forcePositionSync':
        // Enhanced position sync - always sync position regardless of playing state
        final currentPosition = _audioPlayer.position;
        final isPlaying = _audioPlayer.playing;
        final processingState = _audioPlayer.processingState;

        debugPrint(
            "AudioHandler: Force position sync - Position: ${currentPosition.inSeconds}s, Playing: $isPlaying");

        // Use smart position logic - if we get 0 but have a last known position and are playing, use the last known
        Duration positionToSync = currentPosition;
        if (currentPosition == Duration.zero &&
            _lastKnownPosition != null &&
            _lastKnownPosition! > Duration.zero &&
            isPlaying) {
          debugPrint(
              "AudioHandler: Using last known position ${_lastKnownPosition!.inSeconds}s instead of 0");
          positionToSync = _lastKnownPosition!;
        }

        // Comprehensive state update to ensure UI reflects current audio state
        playbackState.add(playbackState.value.copyWith(
          updatePosition: positionToSync,
          playing: isPlaying,
          processingState: {
                ProcessingState.idle: AudioProcessingState.idle,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[processingState] ??
              AudioProcessingState.idle,
        ));
        break;

      case 'handleAppBackground':
        await handleAppBackground();
        break;

      case 'forceSessionActivation':
        if (_isIOS && _audioSession != null) await _ensureAudioSessionActive();
        break;

      case 'restoreAudioSession':
        await _restoreAudioSessionIfNeeded();
        break;

      case 'detectAndFixAudioSessionBug':
        // CRITICAL FIX: Detect and fix the specific bug where audio stops but UI shows as playing
        // This happens when the app is opened from background during song transitions
        try {
          final isPlaying = _audioPlayer.playing;
          final processingState = _audioPlayer.processingState;

          debugPrint(
              "AudioHandler: Detecting audio session bug - Playing: $isPlaying, State: $processingState");

          if (isPlaying && _isIOS && _audioSession != null) {
            // Test if audio session is actually active
            try {
              await _audioSession!.setActive(true);
              debugPrint(
                  "AudioHandler: Audio session is active, no bug detected");
              return {'bugDetected': false, 'fixed': false};
            } catch (e) {
              debugPrint(
                  "AudioHandler: Audio session bug detected! Audio session inactive while playing: $e");

              // Fix the bug by stopping the fake playing state
              await _audioPlayer.pause();
              playbackState.add(playbackState.value.copyWith(playing: false));

              debugPrint(
                  "AudioHandler: Audio session bug fixed - stopped fake playing state");
              return {'bugDetected': true, 'fixed': true};
            }
          } else if (!isPlaying && processingState == ProcessingState.ready) {
            // Another case: UI might show as not playing but audio session is active
            // This is less critical but we can still verify
            if (_isIOS && _audioSession != null) {
              try {
                await _audioSession!.setActive(true);
                debugPrint(
                    "AudioHandler: Audio session verified as active for paused state");
              } catch (e) {
                debugPrint(
                    "AudioHandler: Audio session issue in paused state: $e");
                await _ensureAudioSessionActive();
              }
            }
            return {'bugDetected': false, 'fixed': false};
          }

          return {'bugDetected': false, 'fixed': false};
        } catch (e) {
          debugPrint("AudioHandler: Error detecting audio session bug: $e");
          return {'bugDetected': false, 'fixed': false, 'error': e.toString()};
        }
    }
    return null;
  }
}
