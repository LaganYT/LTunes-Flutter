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
  final AudioEffectsService _audioEffectsService = AudioEffectsService();

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

  AudioPlayerHandler() {
    _initializeAudioSession();
    _notifyAudioHandlerAboutPlaybackEvents();
    _initializeAudioEffects();
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
      await _audioSession!.configure(const AudioSessionConfiguration.music());

      if (_isIOS) {
        await Future.delayed(const Duration(milliseconds: 100));
        await _audioSession!.setActive(true);
        _isSessionActive = true;

        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream
            .listen((_) => _handleBecomingNoisy());

        // Simplified iOS configuration
        try {
          await _audioSession!.configure(const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionCategoryOptions:
                AVAudioSessionCategoryOptions.allowBluetooth,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            avAudioSessionRouteSharingPolicy:
                AVAudioSessionRouteSharingPolicy.defaultPolicy,
            avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          ));
        } catch (e) {
          debugPrint("Error configuring iOS audio session: $e");
        }
      }
      _audioSessionConfigured = true;
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
    }
  }

  Future<void> _ensureAudioSessionActive() async {
    if (!_isIOS || _audioSession == null) return;

    final now = DateTime.now();
    if (_lastSessionActivation != null &&
        now.difference(_lastSessionActivation!) < _sessionActivationCooldown) {
      return;
    }

    if (!_isSessionActive) {
      try {
        await _audioSession!.setActive(true);
        _isSessionActive = true;
        _lastSessionActivation = now;
        _consecutiveErrors = 0; // Reset error count on successful activation
      } catch (e) {
        debugPrint("Error activating audio session: $e");
        _consecutiveErrors++;
        _scheduleErrorRecovery();
      }
    }
  }

  void _scheduleErrorRecovery() {
    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      _errorRecoveryTimer?.cancel();
      _errorRecoveryTimer = Timer(const Duration(seconds: 5), () {
        debugPrint("Attempting audio session recovery");
        _isSessionActive = false;
        _consecutiveErrors = 0;
        _ensureAudioSessionActive();
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
        if (!_audioPlayer.playing && _currentIndex >= 0) _audioPlayer.play();
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
        final filePath = itemToPlay.id;
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

      // Wait for ready state with timeout
      int attempts = 0;
      while (_audioPlayer.processingState != ProcessingState.ready &&
          attempts < 30) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      if (_audioPlayer.processingState != ProcessingState.ready) {
        throw Exception("Audio player failed to become ready");
      }

      playbackState
          .add(playbackState.value.copyWith(updatePosition: Duration.zero));
      mediaItem.add(itemToPlay);
      _audioEffectsService.reapplyEffects();

      // Resolve artwork asynchronously
      _resolveArtworkAsync(itemToPlay);
    } catch (e) {
      debugPrint("Error preparing audio source: $e");
      if (_isRadioStream) _showRadioErrorDialog(itemToPlay.title);
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
          final completionThreshold = 100; // 100ms

          if (timeRemaining.inMilliseconds <= completionThreshold) {
            final songId = currentItem.extras?['songId'] as String?;
            if (songId != null &&
                songId != _lastCompletedSongId &&
                !_isHandlingCompletion) {
              _lastCompletedSongId = songId;
              _isHandlingCompletion = true;
              await _handleSongCompletion();
              _isHandlingCompletion = false;
            }
          }
        }
      }
    });

    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed && !_isHandlingCompletion) {
        _isHandlingCompletion = true;
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
    if (!statsEnabled || _currentIndex < 0 || _currentIndex >= _playlist.length)
      return;

    final item = _playlist[_currentIndex];
    final songId = item.extras?['songId'] as String?;
    final artist = item.artist ?? '';
    final album = item.album ?? '';

    if (songId == null || songId.isEmpty) return;

    final songKey = 'song_' + songId;
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
    int newIndex = _currentIndex + 1;
    if (newIndex >= _playlist.length) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = 0;
      } else {
        await stop();
        return;
      }
    }
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;
    int newIndex = _currentIndex - 1;
    if (newIndex < 0) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
        newIndex = _playlist.length - 1;
      } else {
        await stop();
        return;
      }
    }
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) {
      await stop();
      return;
    }

    try {
      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

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
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_audioPlayer.processingState == ProcessingState.ready) {
          await _audioPlayer.play();
          await _syncMetadata();
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

  @override
  Future<void> onTaskRemoved() async => super.onTaskRemoved();
  @override
  Future<void> onNotificationDeleted() async => super.onNotificationDeleted();

  Future<void> ensureBackgroundPlayback() async {
    if (_isIOS && _audioSession != null) {
      await _ensureAudioSessionActive();
      _isBackgroundMode = true;
    }
  }

  Future<void> handleAppForeground() async {
    _isBackgroundMode = false;
    if (_isIOS && _audioSession != null && _audioPlayer.playing) {
      await _ensureAudioSessionActive();
    }

    // Force position update when app comes to foreground
    final currentPosition = _audioPlayer.position;
    playbackState
        .add(playbackState.value.copyWith(updatePosition: currentPosition));
  }

  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS && _audioSession != null && _audioPlayer.playing) {
      await _ensureAudioSessionActive();
    }
  }

  Future<void> dispose() async {
    _errorRecoveryTimer?.cancel();
    await _audioPlayer.dispose();
  }

  Future<void> _handleSongCompletion() async {
    final repeatMode = playbackState.value.repeatMode;
    if (repeatMode == AudioServiceRepeatMode.one) {
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        await _ensureAudioSessionActive();
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

      case 'handleAppForeground':
        await handleAppForeground();
        break;

      case 'forcePositionSync':
        // Always sync position regardless of playing state
        final currentPosition = _audioPlayer.position;
        playbackState
            .add(playbackState.value.copyWith(updatePosition: currentPosition));
        break;

      case 'streamingSeek':
        final positionMillis = extras?['position'] as int?;
        if (positionMillis != null) {
          final position = Duration(milliseconds: positionMillis);
          await seek(position);
        }
        break;

      case 'handleAppBackground':
        await handleAppBackground();
        break;

      case 'forceSessionActivation':
        if (_isIOS && _audioSession != null) await _ensureAudioSessionActive();
        break;

      case 'seekToPosition':
        final positionMillis = extras?['position'] as int?;
        if (positionMillis != null) {
          final position = Duration(milliseconds: positionMillis);
          await seek(position);
        }
        break;

      case 'getCurrentPosition':
        return _audioPlayer.position.inMilliseconds;

      case 'getAudioDuration':
        return _audioPlayer.duration?.inMilliseconds;

      case 'isAudioReady':
        return _audioPlayer.processingState == ProcessingState.ready;

      case 'setShouldBePaused':
        final shouldPause = extras?['shouldBePaused'] as bool?;
        if (shouldPause != null) shouldBePaused = shouldPause;
        break;

      case 'getShouldBePaused':
        return shouldBePaused;

      // Audio effects actions
      case 'setAudioEffectsEnabled':
        final enabled = extras?['enabled'] as bool?;
        if (enabled != null) await _audioEffectsService.setEnabled(enabled);
        break;

      case 'setBassBoost':
        final value = extras?['value'] as double?;
        if (value != null) await _audioEffectsService.setBassBoost(value);
        break;

      case 'setReverb':
        final value = extras?['value'] as double?;
        if (value != null) await _audioEffectsService.setReverb(value);
        break;

      case 'set8DMode':
        final enabled = extras?['enabled'] as bool?;
        if (enabled != null) await _audioEffectsService.set8DMode(enabled);
        break;

      case 'set8DIntensity':
        final value = extras?['value'] as double?;
        if (value != null) await _audioEffectsService.set8DIntensity(value);
        break;

      case 'setEqualizerBand':
        final band = extras?['band'] as int?;
        final value = extras?['value'] as double?;
        if (band != null && value != null)
          await _audioEffectsService.setEqualizerBand(band, value);
        break;

      case 'setEqualizerPreset':
        final preset = extras?['preset'] as String?;
        if (preset != null)
          await _audioEffectsService.setEqualizerPreset(preset);
        break;

      case 'resetAudioEffects':
        _audioEffectsService.resetToDefaults();
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

      case 'reapplyAudioEffects':
        _audioEffectsService.reapplyEffects();
        break;
    }
    return null;
  }
}
