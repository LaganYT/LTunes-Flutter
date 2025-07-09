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
  bool _isPlayingLocalFile = false;
  String? _lastCompletedSongId;
  bool _isHandlingCompletion = false;

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
    _currentIndex = index;
    MediaItem itemToPlay = await _resolveArtForItem(_playlist[_currentIndex]);
    _playlist[_currentIndex] = itemToPlay;
    
    // Ensure track metadata is passed to audio session for both local and online songs
    mediaItem.add(itemToPlay);
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
    
    _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;
    _isPlayingLocalFile = itemToPlay.extras?['isLocal'] as bool? ?? false;
    final newSongId = itemToPlay.extras?['songId'] as String?;
    if (newSongId != null && newSongId != _lastCompletedSongId) {
      _lastCompletedSongId = null;
      _isHandlingCompletion = false;
    }
    
    AudioSource source;
    if (_isPlayingLocalFile) {
      final filePath = itemToPlay.id;
      final file = File(filePath);
      if (!await file.exists()) throw Exception("Local file not found: $filePath");
      source = AudioSource.file(filePath);
    } else {
      // For online/URL songs, create source with better buffering configuration
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
      
      // Reset position to zero for new tracks
      playbackState.add(playbackState.value.copyWith(updatePosition: Duration.zero));
      
      // For online songs, wait for the source to be ready before proceeding
      if (!_isPlayingLocalFile) {
        // Wait for the audio source to be ready or timeout after 10 seconds
        int attempts = 0;
        while (_audioPlayer.processingState == ProcessingState.loading && attempts < 100) {
          await Future.delayed(const Duration(milliseconds: 100));
          attempts++;
        }
        
        if (_audioPlayer.processingState == ProcessingState.loading) {
          debugPrint("Warning: Online song still loading after 10 seconds");
        }
      }
      
      // Ensure audio session is active for both local and online songs
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
      final currentItem = mediaItem.value;
      if (currentItem == null) return;
      
      bool isRadio = currentItem.extras?['isRadio'] as bool? ?? _isRadioStream;
      if (!isRadio && newDuration != null && newDuration > Duration.zero) {
        final newItem = currentItem.copyWith(duration: newDuration);
        if (mediaItem.value != newItem) {
          mediaItem.add(newItem);
          // Update the item in playlist to maintain consistency
          if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
            _playlist[_currentIndex] = newItem;
          }
          
          // For online songs, ensure metadata is properly synced after duration is available
          if (!(_isPlayingLocalFile)) {
            // Force a metadata update to ensure iOS Control Center gets the duration
            Future.delayed(const Duration(milliseconds: 50), () {
              if (mediaItem.value == newItem) {
                mediaItem.add(newItem);
              }
            });
          }
        }
      }
    });
    _audioPlayer.positionStream.listen((position) async {
      final currentItem = mediaItem.value;
      
      // For online songs, we need to be more careful about position updates
      if (!_isPlayingLocalFile) {
        // Only update position if the audio is in a stable state
        if (_audioPlayer.processingState == ProcessingState.ready || 
            _audioPlayer.processingState == ProcessingState.buffering) {
          playbackState.add(playbackState.value.copyWith(updatePosition: position));
          debugPrint("Online song position update: ${position.inSeconds}s (state: ${_audioPlayer.processingState})");
        }
        // For buffering state, we might want to pause position updates temporarily
        else if (_audioPlayer.processingState == ProcessingState.loading) {
          // Keep the last known position during loading
          // Don't update position to avoid jumping
          debugPrint("Online song loading, keeping position at: ${playbackState.value.updatePosition.inSeconds}s");
        }
      } else {
        // For local files, always update position
        playbackState.add(playbackState.value.copyWith(updatePosition: position));
      }
      
      // Handle song completion logic
      if (position > Duration.zero && currentItem != null && currentItem.duration != null) {
        final duration = currentItem.duration!;
        final timeRemaining = duration - position;
        
        // For online songs, be more lenient with completion detection
        final completionThreshold = _isPlayingLocalFile ? 100 : 500; // 500ms for online songs
        
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
    if (_audioPlayer.playing) return;
    
    // Increment play counts only when actually starting playback
    await _incrementPlayCounts();
    
    if (_isIOS && _audioSession != null) await _safeActivateSession();
    try {
      if (_audioPlayer.processingState == ProcessingState.idle) {
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
          
          // Ensure metadata is properly synced for online songs
          final currentItem = mediaItem.value;
          if (currentItem != null && !(_isPlayingLocalFile)) {
            // Force metadata update for online songs
            mediaItem.add(currentItem);
          }
        }
      } else if (_audioPlayer.processingState == ProcessingState.ready) {
        await _audioPlayer.play();
        
        // Ensure metadata is properly synced when resuming
        final currentItem = mediaItem.value;
        if (currentItem != null && !(_isPlayingLocalFile)) {
          mediaItem.add(currentItem);
        }
      } else {
        await _audioPlayer.play();
      }
    } catch (e) {
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
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      debugPrint("Seek request to: ${position.inSeconds}s (isLocal: $_isPlayingLocalFile)");
      
      // For online songs, we need to be more careful with seeking
      if (!_isPlayingLocalFile) {
        // Check if the audio source is ready for seeking
        if (_audioPlayer.processingState != ProcessingState.ready) {
          debugPrint("Cannot seek: audio not ready for online song (state: ${_audioPlayer.processingState})");
          return;
        }
        
        // For online songs, ensure we're not seeking beyond available duration
        final currentDuration = _audioPlayer.duration;
        if (currentDuration != null && position > currentDuration) {
          position = currentDuration;
          debugPrint("Adjusted seek position to duration limit: ${position.inSeconds}s");
        }
      }
      
      // Update the playback state immediately to show the seek operation
      playbackState.add(playbackState.value.copyWith(updatePosition: position));
      
      // Perform the actual seek
      await _audioPlayer.seek(position);
      debugPrint("Seek completed to: ${position.inSeconds}s");
      
      // For online songs, add a small delay to ensure the seek operation completes
      if (!_isPlayingLocalFile) {
        await Future.delayed(const Duration(milliseconds: 100));
        // Update position again to ensure it's accurate after seeking
        final actualPosition = _audioPlayer.position;
        if (actualPosition != position) {
          debugPrint("Position after seek: ${actualPosition.inSeconds}s (requested: ${position.inSeconds}s)");
          playbackState.add(playbackState.value.copyWith(updatePosition: actualPosition));
        }
      }
    } catch (e) {
      debugPrint("Error during seek operation: $e");
      // Revert to current position if seek fails
      final currentPosition = _audioPlayer.position;
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
        // This is especially important for online songs to prevent metadata loss
        final currentItem = mediaItem.value;
        if (currentItem != null) {
          // Force a metadata update to ensure iOS Control Center gets the new track info
          mediaItem.add(currentItem);
          
          // For online songs, add a small delay to ensure metadata propagation
          if (!(currentItem.extras?['isLocal'] as bool? ?? false)) {
            await Future.delayed(const Duration(milliseconds: 100));
            mediaItem.add(currentItem);
          }
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