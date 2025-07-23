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

final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

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
    duration: (duration != null && duration > Duration.zero) ? duration : song.duration,
    extras: {
      'songId': song.id,
      'isLocal': song.isDownloaded,
      'localArtFileName': (!song.albumArtUrl.startsWith('http') && song.albumArtUrl.isNotEmpty)
          ? song.albumArtUrl
          : null,
      'isRadio': song.isRadio,
    },
  );
}

class AudioPlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
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

  AudioPlayerHandler() {
    _initializeAudioSession();
    _notifyAudioHandlerAboutPlaybackEvents();
  }

  Future<void> _initializeAudioSession() async {
    if (_audioSessionConfigured) return;
    try {
      _audioSession = await AudioSession.instance;
      
      // Configure audio session for both local and streaming content
      await _audioSession!.configure(const AudioSessionConfiguration.music());
      
      if (_isIOS) {
        await _audioSession!.setActive(true);
        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream.listen((_) => _handleBecomingNoisy());
      }
      _audioSessionConfigured = true;
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
    }
  }

  Future<void> _safeActivateSession() async {
    if (_isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
      } catch (_) {}
    }
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      if (event.type == AudioInterruptionType.pause || event.type == AudioInterruptionType.unknown) {
        if (_audioPlayer.playing) _audioPlayer.pause();
      }
    } else {
      if (event.type == AudioInterruptionType.pause || event.type == AudioInterruptionType.unknown) {
        if (!_audioPlayer.playing && _currentIndex >= 0) _audioPlayer.play();
      }
    }
  }

  void _handleBecomingNoisy() {
    if (_audioPlayer.playing) _audioPlayer.pause();
  }

  Future<void> _prepareToPlay(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    // Stop previous audio before loading new one
    await _audioPlayer.stop();
    _currentIndex = index;
    MediaItem itemToPlay = await _resolveArtForItem(_playlist[_currentIndex]);
    _playlist[_currentIndex] = itemToPlay;
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
    if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
      final filePath = itemToPlay.id;
      final file = File(filePath);
      if (!await file.exists()) throw Exception("Local file not found: $filePath");
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
    try {
      await _audioPlayer.setAudioSource(source);
      playbackState.add(playbackState.value.copyWith(updatePosition: Duration.zero));
      // Ensure metadata is properly synchronized after setting audio source
      mediaItem.add(itemToPlay);
      // Add a small delay and re-broadcast metadata to ensure lock screen/notification update
      await Future.delayed(const Duration(milliseconds: 50));
      mediaItem.add(itemToPlay);
      if (_isIOS && _audioSession != null) {
        await _safeActivateSession();
      }
    } catch (e) {
      debugPrint("Error preparing audio source: $e");
      if (_isRadioStream) _showRadioErrorDialog(itemToPlay.title);
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
    bool isHttp = item.artUri?.toString().startsWith('http') ?? false;
    bool isFileUri = item.artUri?.isScheme('file') ?? false;
    if (item.artUri != null && !isHttp && !isFileUri) {
      artFileNameToResolve = item.artUri.toString();
    } else if (item.artUri == null && item.extras?['localArtFileName'] != null) {
      artFileNameToResolve = item.extras!['localArtFileName'] as String;
    }
    if (artFileNameToResolve != null && artFileNameToResolve.isNotEmpty && (item.extras?['isLocal'] as bool? ?? false)) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final fullPath = p.join(directory.path, artFileNameToResolve);
        if (await File(fullPath).exists()) {
          return item.copyWith(artUri: Uri.file(fullPath));
        } else {
          return item.copyWith(artUri: null);
        }
      } catch (_) {
        return item.copyWith(artUri: null);
      }
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
      
      if (position == Duration.zero && _audioPlayer.playing && _lastKnownPosition != null && _lastKnownPosition! > Duration.zero) {
        // Only use last known position if we're actually playing and current position is zero
        // This prevents the seekbar from jumping to zero during normal playback
        positionToEmit = _lastKnownPosition!;
        debugPrint("AudioHandler: Using last known position: ${_lastKnownPosition!.inSeconds}s (stream position was zero)");
      } else if (position > Duration.zero) {
        // Update last known position when we have a valid position
        _lastKnownPosition = position;
      }
      
      // Log position updates for debugging
      if (!(currentItem?.extras?['isLocal'] as bool? ?? false)) {
        debugPrint("AudioHandler: Online song position update - stream: ${position.inSeconds}s, emitting: ${positionToEmit.inSeconds}s, playing: ${_audioPlayer.playing}");
      }
      
      // Emit the position update
      playbackState.add(playbackState.value.copyWith(updatePosition: positionToEmit));
      
      // Handle song completion logic
      if (position > Duration.zero && currentItem != null && currentItem.duration != null) {
        final duration = currentItem.duration!;
        final timeRemaining = duration - position;
        
        final completionThreshold = 100; // 100ms for all songs
        
        if (timeRemaining.inMilliseconds <= completionThreshold && 
            _audioPlayer.playing && 
            _audioPlayer.processingState == ProcessingState.ready) {
          final songId = currentItem.extras?['songId'] as String?;
          if (songId != null && songId != _lastCompletedSongId && !_isHandlingCompletion) {
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
    
    debugPrint("AudioHandler: Play requested (processingState: ${_audioPlayer.processingState})");
    
    // Increment play counts only when actually starting playback
    await _incrementPlayCounts();
    
    if (_isIOS && _audioSession != null) await _safeActivateSession();
    try {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        debugPrint("AudioHandler: Starting playback from idle state");
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          
          // Ensure metadata is properly synchronized after starting playback
          final currentItem = mediaItem.value;
          if (currentItem != null) {
            mediaItem.add(currentItem);
          }
          debugPrint("AudioHandler: Playback started from idle state");
        }
      } else if (_audioPlayer.processingState == ProcessingState.ready) {
        debugPrint("AudioHandler: Resuming playback from ready state");
        await _audioPlayer.play();
        
        // Ensure metadata is properly synchronized when resuming
        final currentItem = mediaItem.value;
        if (currentItem != null) {
          mediaItem.add(currentItem);
        }
        debugPrint("AudioHandler: Playback resumed from ready state");
      } else {
        debugPrint("AudioHandler: Starting playback from other state: ${_audioPlayer.processingState}");
        await _audioPlayer.play();
        debugPrint("AudioHandler: Playback started from other state");
      }
    } catch (e) {
      debugPrint("AudioHandler: Error during play operation: $e");
      if (_isRadioStream && _currentIndex >= 0 && _currentIndex < _playlist.length) {
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
      try {
        final songMap = Map<String, dynamic>.from(await Future.value(jsonDecode(songJson)));
        int playCount = (songMap['playCount'] as int?) ?? 0;
        playCount++;
        songMap['playCount'] = playCount;
        await prefs.setString(songKey, jsonEncode(songMap));
      } catch (_) {}
    }
    if (album.isNotEmpty) {
      final albumKeys = prefs.getKeys().where((k) => k.startsWith('album_'));
      for (final key in albumKeys) {
        final albumJson = prefs.getString(key);
        if (albumJson != null) {
          try {
            final albumMap = Map<String, dynamic>.from(await Future.value(jsonDecode(albumJson)));
            if ((albumMap['title'] as String?) == album) {
              int playCount = (albumMap['playCount'] as int?) ?? 0;
              playCount++;
              albumMap['playCount'] = playCount;
              await prefs.setString(key, jsonEncode(albumMap));
            }
          } catch (_) {}
        }
      }
    }
    if (artist.isNotEmpty) {
      final artistPlayCountsKey = 'artist_play_counts';
      final artistPlayCountsJson = prefs.getString(artistPlayCountsKey);
      Map<String, int> artistPlayCounts = {};
      if (artistPlayCountsJson != null) {
        try {
          artistPlayCounts = Map<String, int>.from(jsonDecode(artistPlayCountsJson));
        } catch (_) {}
      }
      artistPlayCounts[artist] = (artistPlayCounts[artist] ?? 0) + 1;
      await prefs.setString(artistPlayCountsKey, jsonEncode(artistPlayCounts));
    }
    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final dailyPlayCountsJson = prefs.getString('daily_play_counts');
    Map<String, int> dailyPlayCounts = {};
    if (dailyPlayCountsJson != null) {
      try {
        dailyPlayCounts = Map<String, int>.from(jsonDecode(dailyPlayCountsJson));
      } catch (_) {}
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
      playbackState.add(playbackState.value.copyWith(updatePosition: currentPosition));
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
            await _prepareToPlay(index);
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          try {
            if (_isIOS && _audioSession != null) await _safeActivateSession();
            await _audioPlayer.play();
            
            // Ensure metadata is properly broadcast to audio session after skip
            final currentItem = mediaItem.value;
            if (currentItem != null) {
              // Force a metadata update to ensure iOS Control Center gets the new track info
              mediaItem.add(currentItem);
              
              // Add a small delay to ensure metadata propagation
              await Future.delayed(const Duration(milliseconds: 50));
              mediaItem.add(currentItem);
            }
          } catch (e) {
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.error,
        ));
        if (_isRadioStream) _showRadioErrorDialog(_playlist[_currentIndex].title);
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
    try {
      await _audioPlayer.setSpeed(1.0);
      await _audioPlayer.setPitch(1.0);
    } catch (_) {}
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
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
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
          artUri: extras?['artUri'] is String ? Uri.tryParse(extras!['artUri']) : null,
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
    if (_isIOS && _audioSession != null && _audioPlayer.playing) await _safeActivateSession();
  }

  Future<void> handleAppBackground() async {
    _isBackgroundMode = true;
    if (_isIOS && _audioSession != null && _audioPlayer.playing) await _safeActivateSession();
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
        final currentItem = mediaItem.value;
        if (currentItem != null) {
          mediaItem.add(currentItem);
          
          // Add a small delay to ensure metadata propagation
          await Future.delayed(const Duration(milliseconds: 50));
          mediaItem.add(currentItem);
        }
      }
    } else {
      await skipToNext();
    }
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'updateCurrentMediaItemMetadata') {
      final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
      if (mediaMap != null) {
        final currentItem = mediaItem.value;
        if (currentItem != null && _currentIndex >= 0 && _currentIndex < _playlist.length) {
          final newArtUri = mediaMap['artUri'] as String?;
          final updatedItem = currentItem.copyWith(
            title: mediaMap['title'] as String? ?? currentItem.title,
            artist: mediaMap['artist'] as String? ?? currentItem.artist,
            album: mediaMap['album'] as String? ?? currentItem.album,
            artUri: (newArtUri != null && newArtUri.isNotEmpty) ? Uri.tryParse(newArtUri) : currentItem.artUri,
            duration: (mediaMap['duration'] != null) ? Duration(milliseconds: mediaMap['duration'] as int) : currentItem.duration,
            extras: (mediaMap['extras'] as Map<String, dynamic>?) ?? currentItem.extras,
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
        playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
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
          duration: durationMillis != null ? Duration(milliseconds: durationMillis) : null,
          extras: mediaMap['extras'] as Map<String, dynamic>?,
        );
        int index = _playlist.indexWhere((element) => element.id == mediaItemToPrepare.id);
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
      if (_isIOS && _audioSession != null && _isBackgroundMode) await _safeActivateSession();
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
    }
    return null;
  }
}