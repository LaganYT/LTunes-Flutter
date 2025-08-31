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
  Duration? _lastKnownPosition; // Store last known position for online songs
  bool _shouldBePaused = false; // Track if audio should be paused
  final AudioEffectsService _audioEffectsService = AudioEffectsService();
  DateTime? _lastSessionActivation; // Track last audio session activation
  DateTime? _lastSkipOperation; // Track last skip operation
  int _consecutiveRapidSkips = 0; // Track consecutive rapid skips
  int _sessionActivationCount = 0; // Track session activation attempts
  bool _isBackgroundSkipOperation =
      false; // Track if skip is from background audio session

  AudioPlayerHandler() {
    _initializeAudioSession();
    _notifyAudioHandlerAboutPlaybackEvents();
    _initializeAudioEffects();
  }

  // Getter for shouldBePaused
  bool get shouldBePaused => _shouldBePaused;

  // Setter for shouldBePaused
  set shouldBePaused(bool value) {
    _shouldBePaused = value;
    // If shouldBePaused is true and audio is playing, pause it
    if (value && _audioPlayer.playing) {
      _audioPlayer.pause();
      playbackState.add(playbackState.value.copyWith(playing: false));
    }
  }

  Future<void> _initializeAudioSession() async {
    if (_audioSessionConfigured) return;
    try {
      _audioSession = await AudioSession.instance;

      // Configure audio session for both local and streaming content
      await _audioSession!.configure(const AudioSessionConfiguration.music());

      if (_isIOS) {
        // Add a small delay before activating the session
        await Future.delayed(const Duration(milliseconds: 100));
        await _audioSession!.setActive(true);
        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream
            .listen((_) => _handleBecomingNoisy());

        // Set up iOS-specific audio session options for better background handling
        try {
          // These options help with background audio session stability
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
          debugPrint(
              "Error configuring iOS-specific audio session options: $e");
        }
      }
      _audioSessionConfigured = true;
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
    }
  }

  // Helper method to check if this is a rapid skip operation
  bool _isRapidSkip() {
    if (_lastSkipOperation == null) return false;
    final now = DateTime.now();
    final timeSinceLastSkip = now.difference(_lastSkipOperation!);
    return timeSinceLastSkip.inMilliseconds < 1000;
  }

  // Helper method to check if audio session was recently activated
  bool _wasSessionRecentlyActivated(int thresholdMs) {
    if (_lastSessionActivation == null) return false;
    final now = DateTime.now();
    final timeSinceLastActivation = now.difference(_lastSessionActivation!);
    return timeSinceLastActivation.inMilliseconds < thresholdMs;
  }

  Future<void> _safeActivateSession() async {
    if (_isIOS && _audioSession != null) {
      final isRapidSkip = _isRapidSkip();

      // During rapid skips or background operations, be very conservative about audio session activation
      if ((isRapidSkip && _consecutiveRapidSkips > 0) ||
          _isBackgroundAudioSessionOperation()) {
        debugPrint(
            "AudioHandler: Skipping audio session activation (rapid skip or background operation in progress)");
        return;
      }

      // Debounce audio session activation to prevent overwhelming the system
      if (_wasSessionRecentlyActivated(500)) {
        debugPrint(
            "AudioHandler: Skipping audio session activation (debounced)");
        return;
      }

      try {
        debugPrint("AudioHandler: Activating audio session");
        _lastSessionActivation = DateTime.now();
        _sessionActivationCount++;
        await _audioSession!.setActive(true);
        debugPrint("AudioHandler: Audio session activated successfully");
      } catch (e) {
        debugPrint("AudioHandler: Error activating audio session: $e");
        // Don't throw the error, just log it to prevent crashes
      }
    }
  }

  Future<bool> _ensureAudioSessionActive() async {
    if (_isIOS && _audioSession != null) {
      final isRapidSkip = _isRapidSkip();

      if (_wasSessionRecentlyActivated(200)) {
        debugPrint(
            "AudioHandler: Audio session very recently activated, skipping");
        return true;
      }

      // For rapid skips, be more aggressive about avoiding session activation
      if (isRapidSkip && _wasSessionRecentlyActivated(500)) {
        debugPrint(
            "AudioHandler: Rapid skip detected, skipping audio session activation");
        return true;
      }

      // If we have consecutive rapid skips, be even more conservative
      if (_consecutiveRapidSkips > 1 && _wasSessionRecentlyActivated(1000)) {
        debugPrint(
            "AudioHandler: Multiple consecutive rapid skips, skipping audio session activation");
        return true;
      }

      try {
        debugPrint("AudioHandler: Ensuring audio session is active");
        _lastSessionActivation = DateTime.now();
        await _audioSession!.setActive(true);
        debugPrint("AudioHandler: Audio session ensured active");
        return true;
      } catch (e) {
        debugPrint("AudioHandler: Error ensuring audio session active: $e");
        // For rapid skips, don't try to reset the session as it might cause more issues
        if (isRapidSkip) {
          debugPrint(
              "AudioHandler: Rapid skip - not attempting session reset to avoid conflicts");
          return false;
        }

        // Try to reset the audio session if it's in an error state
        try {
          debugPrint("AudioHandler: Attempting to reset audio session");
          await _audioSession!.setActive(false);
          await Future.delayed(const Duration(milliseconds: 200));
          await _audioSession!.setActive(true);
          debugPrint("AudioHandler: Audio session reset successful");
          return true;
        } catch (resetError) {
          debugPrint(
              "AudioHandler: Failed to reset audio session: $resetError");
          return false;
        }
      }
    }
    return true;
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
    // Set the audio player reference in the effects service
    _audioEffectsService.setAudioPlayer(_audioPlayer);

    // Load saved audio effects settings
    await _audioEffectsService.loadSettings();
  }

  // Helper method to ensure metadata is properly synchronized
  Future<void> _syncMetadata() async {
    final currentItem = mediaItem.value;
    if (currentItem != null) {
      mediaItem.add(currentItem);
      // Add a small delay to ensure metadata propagation
      await Future.delayed(const Duration(milliseconds: 50));
      mediaItem.add(currentItem);
    }
  }

  // Helper method to reapply audio effects and sync metadata
  Future<void> _reapplyEffectsAndSyncMetadata() async {
    _audioEffectsService.reapplyEffects();
    await _syncMetadata();
  }

  // Helper method to verify playback started successfully
  Future<void> _verifyPlayback() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_audioPlayer.playing) {
      debugPrint("AudioHandler: Playback confirmed - audio player is playing");
    } else {
      debugPrint(
          "AudioHandler: WARNING - Playback failed to start despite no error");
    }
  }

  // Helper method to safely decode JSON
  Map<String, dynamic>? _safeJsonDecode(String json) {
    try {
      return Map<String, dynamic>.from(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  Future<void> _prepareToPlay(int index) async {
    debugPrint("AudioHandler: _prepareToPlay called with index: $index");

    if (index < 0 || index >= _playlist.length) {
      debugPrint("AudioHandler: Invalid index in _prepareToPlay");
      return;
    }

    _currentIndex = index;

    // Start with the current item without waiting for artwork resolution
    MediaItem itemToPlay = _playlist[_currentIndex];

    // Ensure track metadata is passed to audio session for both local and online songs
    mediaItem.add(itemToPlay);
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));

    _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;
    final newSongId = itemToPlay.extras?['songId'] as String?;
    if (newSongId != null && newSongId != _lastCompletedSongId) {
      _lastCompletedSongId = null;
      _isHandlingCompletion = false;
      _lastKnownPosition = null; // Reset last known position for new song
    }

    AudioSource source;
    // Use the same simple approach for all songs
    if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
      debugPrint("AudioHandler: Preparing local file: ${itemToPlay.id}");
      final filePath = itemToPlay.id;
      final file = File(filePath);
      if (!await file.exists())
        throw Exception("Local file not found: $filePath");
      source = AudioSource.file(filePath);
    } else {
      debugPrint("AudioHandler: Preparing online stream: ${itemToPlay.id}");
      // For online songs, we need the tag for proper metadata display
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

    try {
      debugPrint("AudioHandler: Setting audio source");
      await _audioPlayer.setAudioSource(source);
      debugPrint("AudioHandler: Audio source set successfully");

      // Wait for the audio player to be ready
      debugPrint("AudioHandler: Waiting for audio player to be ready...");
      int attempts = 0;
      while (_audioPlayer.processingState != ProcessingState.ready &&
          attempts < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
        debugPrint(
            "AudioHandler: Processing state: ${_audioPlayer.processingState}, attempt: $attempts");
      }

      if (_audioPlayer.processingState == ProcessingState.ready) {
        debugPrint("AudioHandler: Audio player is ready");
      } else {
        debugPrint(
            "AudioHandler: Audio player failed to become ready, current state: ${_audioPlayer.processingState}");
      }

      // Reset position to zero for new tracks
      playbackState
          .add(playbackState.value.copyWith(updatePosition: Duration.zero));

      // Ensure metadata is properly synchronized after setting audio source
      mediaItem.add(itemToPlay);

      // Reapply audio effects after setting new audio source
      _audioEffectsService.reapplyEffects();

      debugPrint("AudioHandler: _prepareToPlay completed successfully");

      // Now resolve artwork asynchronously without blocking playback
      _resolveArtworkAsync(itemToPlay);
    } catch (e) {
      debugPrint("Error preparing audio source: $e");
      if (_isRadioStream) _showRadioErrorDialog(itemToPlay.title);
    }
  }

  // New method to resolve artwork asynchronously
  Future<void> _resolveArtworkAsync(MediaItem item) async {
    try {
      debugPrint(
          "AudioHandler: Resolving artwork asynchronously for: ${item.title}");
      MediaItem resolvedItem = await _resolveArtForItem(item);

      // Update the playlist with resolved artwork
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        _playlist[_currentIndex] = resolvedItem;
      }

      // Update the media item with resolved artwork
      mediaItem.add(resolvedItem);

      debugPrint(
          "AudioHandler: Artwork resolved successfully for: ${item.title}");
    } catch (e) {
      debugPrint("AudioHandler: Error resolving artwork for ${item.title}: $e");
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
          debugPrint("Duration updated: ${newDuration.inSeconds}s");
        }
      }
    });
    _audioPlayer.positionStream.listen((position) async {
      final currentItem = mediaItem.value;

      // Always use the actual position from the stream as the source of truth
      // Only use last known position as a fallback when position is zero and we're playing
      Duration positionToEmit = position;

      if (position == Duration.zero &&
          _audioPlayer.playing &&
          _lastKnownPosition != null &&
          _lastKnownPosition! > Duration.zero) {
        // Only use last known position if we're actually playing and current position is zero
        // This prevents the seekbar from jumping to zero during normal playback
        positionToEmit = _lastKnownPosition!;
        debugPrint(
            "AudioHandler: Using last known position: ${_lastKnownPosition!.inSeconds}s (stream position was zero)");
      } else if (position > Duration.zero) {
        // Update last known position when we have a valid position
        _lastKnownPosition = position;
      }

      // Log position updates for debugging
      if (!(currentItem?.extras?['isLocal'] as bool? ?? false)) {
        debugPrint(
            "AudioHandler: Online song position update - stream: ${position.inSeconds}s, emitting: ${positionToEmit.inSeconds}s, playing: ${_audioPlayer.playing}");
      }

      // Emit the position update
      playbackState
          .add(playbackState.value.copyWith(updatePosition: positionToEmit));

      // Handle song completion logic
      if (position > Duration.zero &&
          currentItem != null &&
          currentItem.duration != null) {
        final duration = currentItem.duration!;
        final timeRemaining = duration - position;

        final completionThreshold = 100; // 100ms for all songs

        if (timeRemaining.inMilliseconds <= completionThreshold &&
            _audioPlayer.playing &&
            _audioPlayer.processingState == ProcessingState.ready) {
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
    });
    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (!_isHandlingCompletion) {
          _isHandlingCompletion = true;
          await _handleSongCompletion();
          _isHandlingCompletion = false;
        }
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
    if (_audioPlayer.playing) {
      debugPrint("AudioHandler: Play requested but already playing, ignoring");
      return;
    }

    // Check if audio should be paused
    if (_shouldBePaused) {
      debugPrint(
          "AudioHandler: Play requested but shouldBePaused is true, ignoring");
      return;
    }

    debugPrint(
        "AudioHandler: Play requested (processingState: ${_audioPlayer.processingState})");

    // Increment play counts only when actually starting playback
    await _incrementPlayCounts();

    if (_isIOS && _audioSession != null) await _safeActivateSession();
    try {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        debugPrint("AudioHandler: Starting playback from idle state");
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _reapplyEffectsAndSyncMetadata();
          debugPrint("AudioHandler: Playback started from idle state");
        }
      } else if (_audioPlayer.processingState == ProcessingState.ready) {
        debugPrint("AudioHandler: Resuming playback from ready state");
        await _audioPlayer.play();
        await _reapplyEffectsAndSyncMetadata();
        debugPrint("AudioHandler: Playback resumed from ready state");
      } else if (_audioPlayer.processingState == ProcessingState.completed) {
        debugPrint(
            "AudioHandler: Audio player in completed state, resetting and preparing");
        // Reset the audio player if it's in completed state
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          await _reapplyEffectsAndSyncMetadata();
          debugPrint(
              "AudioHandler: Playback started after reset from completed state");
        }
      } else {
        debugPrint(
            "AudioHandler: Starting playback from other state: ${_audioPlayer.processingState}");
        await _audioPlayer.play();
        debugPrint("AudioHandler: Playback started from other state");
      }
    } catch (e) {
      debugPrint("AudioHandler: Error during play operation: $e");
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
    if (!statsEnabled) return;
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) return;
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

  @override
  Future<void> pause() async {
    debugPrint("AudioHandler: Pause requested");
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
    debugPrint("AudioHandler: Pause completed");
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      debugPrint("Seek request to: ${position.inSeconds}s");

      // Perform the actual seek
      await _audioPlayer.seek(position);
      debugPrint("Seek completed to: ${position.inSeconds}s");

      // Update last known position and let the position stream handle the update
      _lastKnownPosition = position;

      // Emit the position immediately for responsive UI
      playbackState.add(playbackState.value.copyWith(updatePosition: position));
    } catch (e) {
      debugPrint("Error during seek operation: $e");
      // Revert to current position if seek fails
      final currentPosition = _audioPlayer.position;
      _lastKnownPosition = currentPosition;
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
    debugPrint("AudioHandler: skipToQueueItem called with index: $index");
    debugPrint("AudioHandler: shouldBePaused: $_shouldBePaused");

    // Track skip operations for audio session management
    final now = DateTime.now();
    final isRapidSkip = _isRapidSkip();
    final isBackgroundOperation = _isBackgroundAudioSessionOperation();

    if (isRapidSkip) {
      _consecutiveRapidSkips++;
      debugPrint(
          "AudioHandler: Rapid skip detected (consecutive: $_consecutiveRapidSkips)");
    } else {
      if (_consecutiveRapidSkips > 0) {
        debugPrint("AudioHandler: Resetting consecutive rapid skips counter");
      }
      _consecutiveRapidSkips = 0;

      // Also reset session activation counter if there's been a pause
      if (_sessionActivationCount > 0) {
        debugPrint("AudioHandler: Resetting session activation counter");
        _sessionActivationCount = 0;
      }
    }

    _lastSkipOperation = now;

    // For background operations, handle audio session differently
    if (isBackgroundOperation) {
      debugPrint("AudioHandler: Background skip operation detected");
      _isBackgroundSkipOperation = true;
    }

    if (index < 0 || index >= _playlist.length) {
      debugPrint("AudioHandler: Invalid index, stopping playback");
      await stop();
      return;
    }

    try {
      // Reset audio player if it's in a completed state
      if (_audioPlayer.processingState == ProcessingState.completed) {
        debugPrint("AudioHandler: Resetting audio player from completed state");
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      debugPrint("AudioHandler: Preparing to play index: $index");
      await _prepareToPlay(index);

      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        debugPrint(
            "AudioHandler: Activating audio session and starting playback");

        // Add a small delay to let the audio system stabilize
        await Future.delayed(const Duration(milliseconds: 100));

        // Handle background audio session operations specially
        if (_isBackgroundSkipOperation) {
          debugPrint("AudioHandler: Handling background skip operation");
          final backgroundHandled =
              await _handleBackgroundAudioSessionOperation();
          if (!backgroundHandled) {
            debugPrint(
                "AudioHandler: Background operation failed, but continuing with skip");
          }
          _isBackgroundSkipOperation = false;
        } else {
          // For foreground operations, use the existing logic
          if ((_consecutiveRapidSkips >= 3 || _sessionActivationCount >= 5) &&
              _isIOS &&
              _audioSession != null) {
            debugPrint(
                "AudioHandler: Too many consecutive rapid skips ($_consecutiveRapidSkips) or session activations ($_sessionActivationCount), resetting audio session");
            try {
              await _audioSession!.setActive(false);
              await Future.delayed(const Duration(milliseconds: 300));
              await _audioSession!.setActive(true);
              _consecutiveRapidSkips = 0;
              _sessionActivationCount = 0;
              debugPrint(
                  "AudioHandler: Audio session reset after rapid skips/session activations");
            } catch (e) {
              debugPrint(
                  "AudioHandler: Error resetting audio session after rapid skips: $e");
            }
          }

          // Ensure audio session is active before playing
          final sessionActive = await _ensureAudioSessionActive();
          if (!sessionActive) {
            // For rapid skips, continue anyway as the session might still be functional
            if (isRapidSkip) {
              debugPrint(
                  "AudioHandler: Rapid skip - continuing despite session activation failure");
            } else {
              debugPrint(
                  "AudioHandler: Failed to ensure audio session is active, aborting skip");
              return;
            }
          }
        }

        // Check if shouldBePaused is preventing playback
        if (_shouldBePaused) {
          debugPrint(
              "AudioHandler: shouldBePaused is true, resetting to false for skip operation");
          _shouldBePaused = false;
        }

        // Check audio volume
        debugPrint("AudioHandler: Current volume: ${_audioPlayer.volume}");
        if (_audioPlayer.volume == 0.0) {
          debugPrint(
              "AudioHandler: WARNING - Audio volume is 0, setting to 1.0");
          await _audioPlayer.setVolume(1.0);
        }

        // Check if audio player is ready before playing
        if (_audioPlayer.processingState == ProcessingState.ready) {
          // Start playback
          await _audioPlayer.play();
          debugPrint("AudioHandler: Playback started successfully");
          await _verifyPlayback();
        } else {
          debugPrint(
              "AudioHandler: Audio player not ready, current state: ${_audioPlayer.processingState}");
          // Try to wait a bit more and then play
          await Future.delayed(const Duration(milliseconds: 500));
          if (_audioPlayer.processingState == ProcessingState.ready) {
            await _audioPlayer.play();
            debugPrint("AudioHandler: Playback started after delay");
            await _verifyPlayback();
          } else {
            debugPrint(
                "AudioHandler: Failed to start playback - audio player still not ready");
          }
        }

        // Ensure metadata is properly broadcast to audio session after skip
        await _syncMetadata();

        // Verify playback state
        debugPrint(
            "AudioHandler: Final playback state - playing: ${_audioPlayer.playing}, processingState: ${_audioPlayer.processingState}");
      } else {
        debugPrint(
            "AudioHandler: Invalid current index after prepare: $_currentIndex");
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
      await _safeActivateSession();
      _isBackgroundMode = true;
    }
  }

  Future<void> handleAppForeground() async {
    _isBackgroundMode = false;
    if (_isIOS && _audioSession != null && _audioPlayer.playing)
      await _safeActivateSession();
  }

  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS && _audioSession != null && _audioPlayer.playing)
      await _safeActivateSession();
  }

  bool _isBackgroundAudioSessionOperation() {
    // Check if we're in background mode and this is likely a background audio session operation
    return _isBackgroundMode && _isIOS;
  }

  Future<bool> _handleBackgroundAudioSessionOperation() async {
    if (!_isBackgroundAudioSessionOperation()) {
      return true; // Not a background operation, proceed normally
    }

    debugPrint("AudioHandler: Background audio session operation detected");

    // For background operations on iOS, we need to be very careful about audio session management
    try {
      // Ensure the audio session is active but don't overwhelm it
      if (_audioSession != null && !_wasSessionRecentlyActivated(1000)) {
        debugPrint(
            "AudioHandler: Activating audio session for background operation");
        await _audioSession!.setActive(true);
        _lastSessionActivation = DateTime.now();
        debugPrint(
            "AudioHandler: Background audio session activated successfully");
      } else {
        debugPrint(
            "AudioHandler: Audio session recently activated, skipping for background operation");
      }

      return true;
    } catch (e) {
      debugPrint(
          "AudioHandler: Error in background audio session operation: $e");
      // For background operations, we'll try to recover gracefully
      return false;
    }
  }

  Future<void> dispose() async {
    await _audioPlayer.dispose();
  }

  Future<void> _handleSongCompletion() async {
    final repeatMode = playbackState.value.repeatMode;
    if (repeatMode == AudioServiceRepeatMode.one) {
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        if (_isIOS && _audioSession != null) await _safeActivateSession();
        await _prepareToPlay(_currentIndex);
        await _audioPlayer.play();

        // Ensure metadata is properly broadcast for repeat one mode
        await _syncMetadata();
      }
    } else {
      await skipToNext();
    }
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name == 'updateCurrentMediaItemMetadata') {
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
    } else if (name == 'setQueueIndex') {
      final index = extras?['index'] as int?;
      if (index != null && index >= 0 && index < _playlist.length) {
        _currentIndex = index;
        playbackState
            .add(playbackState.value.copyWith(queueIndex: _currentIndex));
      }
    } else if (name == 'prepareToPlay') {
      final index = extras?['index'] as int?;
      if (index != null) await _prepareToPlay(index);
    } else if (name == 'prepareMediaItem') {
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
    } else if (name == 'openDownloadQueue') {
      final navigator = globalNavigatorKey.currentState;
      if (navigator != null) {
        navigator.push(
          MaterialPageRoute(
            builder: (context) => const DownloadQueueScreen(),
          ),
        );
      }
    } else if (name == 'ensureBackgroundPlayback') {
      await ensureBackgroundPlayback();
    } else if (name == 'handleAppForeground') {
      await handleAppForeground();
    } else if (name == 'handleAppBackground') {
      await handleAppBackground();
    } else if (name == 'forceSessionActivation') {
      if (_isIOS && _audioSession != null) await _safeActivateSession();
    } else if (name == 'ensureBackgroundPlaybackContinuity') {
      if (_isIOS && _audioSession != null && _isBackgroundMode)
        await _safeActivateSession();
    } else if (name == 'seekToPosition') {
      final positionMillis = extras?['position'] as int?;
      if (positionMillis != null) {
        final position = Duration(milliseconds: positionMillis);
        await seek(position);
      }
    } else if (name == 'getCurrentPosition') {
      return _audioPlayer.position.inMilliseconds;
    } else if (name == 'getAudioDuration') {
      return _audioPlayer.duration?.inMilliseconds;
    } else if (name == 'isAudioReady') {
      return _audioPlayer.processingState == ProcessingState.ready;
    } else if (name == 'setShouldBePaused') {
      final shouldPause = extras?['shouldBePaused'] as bool?;
      if (shouldPause != null) shouldBePaused = shouldPause;
    } else if (name == 'getShouldBePaused') {
      return shouldBePaused;
    } else if (name == 'setAudioEffectsEnabled') {
      final enabled = extras?['enabled'] as bool?;
      if (enabled != null) await _audioEffectsService.setEnabled(enabled);
    } else if (name == 'setBassBoost') {
      final value = extras?['value'] as double?;
      if (value != null) await _audioEffectsService.setBassBoost(value);
    } else if (name == 'setReverb') {
      final value = extras?['value'] as double?;
      if (value != null) await _audioEffectsService.setReverb(value);
    } else if (name == 'set8DMode') {
      final enabled = extras?['enabled'] as bool?;
      if (enabled != null) await _audioEffectsService.set8DMode(enabled);
    } else if (name == 'set8DIntensity') {
      final value = extras?['value'] as double?;
      if (value != null) await _audioEffectsService.set8DIntensity(value);
    } else if (name == 'setEqualizerBand') {
      final band = extras?['band'] as int?;
      final value = extras?['value'] as double?;
      if (band != null && value != null)
        await _audioEffectsService.setEqualizerBand(band, value);
    } else if (name == 'setEqualizerPreset') {
      final preset = extras?['preset'] as String?;
      if (preset != null) await _audioEffectsService.setEqualizerPreset(preset);
    } else if (name == 'resetAudioEffects') {
      _audioEffectsService.resetToDefaults();
    } else if (name == 'getAudioEffectsState') {
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
    } else if (name == 'reapplyAudioEffects') {
      _audioEffectsService.reapplyEffects();
    }
    return null;
  }
}
