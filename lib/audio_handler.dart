import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import '/models/song.dart'; // Your Song model
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '/services/api_service.dart'; // Your ApiService

// Helper function to convert your Song model to MediaItem
MediaItem songToMediaItem(Song song, {Duration? duration}) {
  return MediaItem(
    id: song.id,
    album: song.album ?? "Unknown Album",
    title: song.title,
    artist: song.artist.isNotEmpty ? song.artist : "Unknown Artist",
    artUri: song.albumArtUrl.startsWith('http')
        ? Uri.parse(song.albumArtUrl)
        : (song.albumArtUrl.isNotEmpty ? Uri.file(song.albumArtUrl) : null), // Handle local file paths correctly if they are full paths
    duration: duration,
    extras: {
      'audioUrl': song.audioUrl, // Store original audioUrl if needed
      'localFilePath': song.localFilePath,
      'isDownloaded': song.isDownloaded,
      'isRadio': song.id.startsWith('radio_'), // Example: identify radio streams
    },
  );
}

Song mediaItemToSong(MediaItem mediaItem) {
  return Song(
    id: mediaItem.id,
    title: mediaItem.title,
    artist: mediaItem.artist ?? "Unknown Artist",
    album: mediaItem.album ?? "Unknown Album",
    albumArtUrl: mediaItem.artUri?.toString() ?? "",
    audioUrl: mediaItem.extras?['audioUrl'] as String? ?? "",
    localFilePath: mediaItem.extras?['localFilePath'] as String? ?? null,
    isDownloaded: mediaItem.extras?['isDownloaded'] as bool? ?? false,
    // releaseDate, etc., if needed and stored in extras
  );
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final ApiService _apiService = ApiService();
  List<Song> _internalQueue = [];
  int _currentIndex = -1;
  // Removed unused _debounceTimer field


  MyAudioHandler() {
    _notifyAudioHandlerAboutPlaybackEvents();
    // Load queue, current song, etc., from SharedPreferences if needed
  }

  Future<String> _resolveSongUrl(Song song) async {
    if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final localPath = p.join(appDocDir.path, song.localFilePath!);
      if (await File(localPath).exists()) {
        return localPath;
      }
    }
    if (song.audioUrl.isNotEmpty && Uri.tryParse(song.audioUrl)?.isAbsolute == true) {
      return song.audioUrl;
    }
    final fetchedUrl = await _apiService.fetchAudioUrl(song.artist, song.title);
    return fetchedUrl ?? '';
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      final playing = state == PlayerState.playing;
      playbackState.add(playbackState.value.copyWith(
        playing: playing,
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: {
          PlayerState.stopped: AudioProcessingState.idle,
          PlayerState.playing: AudioProcessingState.ready,
          PlayerState.paused: AudioProcessingState.ready,
          PlayerState.completed: AudioProcessingState.completed,
          // PlayerState.disposed might map to .idle or .stopped
        }[state] ?? AudioProcessingState.idle, // Default to idle
      ));
    });

    _audioPlayer.onDurationChanged.listen((duration) {
      if (mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: duration));
      }
      _audioPlayer.getCurrentPosition().then((position) {
        playbackState.add(playbackState.value.copyWith(updatePosition: position ?? Duration.zero));
      });
    });

    _audioPlayer.onPositionChanged.listen((position) {
      playbackState.add(playbackState.value.copyWith(updatePosition: position));
    });

    _audioPlayer.onPlayerComplete.listen((_) async {
       if (playbackState.value.processingState == AudioProcessingState.completed) {
        if (playbackState.value.repeatMode == AudioServiceRepeatMode.one && mediaItem.value != null) {
            seek(Duration.zero);
            play();
        } else if (_currentIndex + 1 < _internalQueue.length) {
            await skipToNext();
        } else if (playbackState.value.repeatMode == AudioServiceRepeatMode.all && _internalQueue.isNotEmpty) {
            await skipToQueueItem(0);
        } else {
            // No repeat, end of queue
        }
      }
    });
  }
  
  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    _internalQueue = newQueue.map(mediaItemToSong).toList();
    queue.add(newQueue); // Notify audio_service about the new queue
    // Persist queue if necessary
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _internalQueue.addAll(mediaItems.map(mediaItemToSong));
    queue.add(_internalQueue.map((s) => songToMediaItem(s)).toList());
    // Persist queue
  }

  @override
  Future<void> addQueueItem(MediaItem newItem) async {
    _internalQueue.add(mediaItemToSong(newItem));
    queue.add(_internalQueue.map((s) => songToMediaItem(s)).toList());
    // Persist queue
  }


  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _internalQueue.length) return;
    _currentIndex = index;
    final song = _internalQueue[index];
    
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.loading,
      playing: false,
    ));

    mediaItem.add(songToMediaItem(song)); // Update current media item

    try {
      final url = await _resolveSongUrl(song);
      if (url.isEmpty) throw Exception('Could not resolve URL for ${song.title}');
      
      Source sourceToPlay;
      if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty && !url.startsWith('http')) {
        sourceToPlay = DeviceFileSource(url);
      } else {
        sourceToPlay = UrlSource(url);
      }
      await _audioPlayer.play(sourceToPlay);
      // Duration might be fetched by onDurationChanged listener
    } catch (e) {
      debugPrint("Error in skipToQueueItem: $e");
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: e.toString(),
      ));
    }
  }

  @override
  Future<void> play() async {
    if (_audioPlayer.state == PlayerState.paused) {
      await _audioPlayer.resume();
    } else if (_currentIndex != -1 && _currentIndex < _internalQueue.length) {
      // If not paused, and there's a current item, effectively re-play it or start it.
      await skipToQueueItem(_currentIndex);
    }
    // If no current item, play might not do anything until an item is selected.
  }

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentIndex = -1;
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    mediaItem.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (_currentIndex + 1 < _internalQueue.length) {
      await skipToQueueItem(_currentIndex + 1);
    } else if (playbackState.value.repeatMode == AudioServiceRepeatMode.all && _internalQueue.isNotEmpty) {
      await skipToQueueItem(0); // Loop to start if repeat all is on
    }
    // else: end of queue, do nothing or stop based on desired behavior
  }

  @override
  Future<void> skipToPrevious() async {
    if (_currentIndex > 0) {
      await skipToQueueItem(_currentIndex - 1);
    } else if (playbackState.value.repeatMode == AudioServiceRepeatMode.all && _internalQueue.isNotEmpty) {
      await skipToQueueItem(_internalQueue.length - 1); // Loop to end if repeat all is on
    }
    // else: start of queue, do nothing or stop
  }
  
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    // audioplayers doesn't have a direct repeat mode setter for the queue.
    // This logic will be handled in onPlayerComplete.
    // For single track loop, audioplayers has player.setReleaseMode(ReleaseMode.loop)
    if (repeatMode == AudioServiceRepeatMode.one) {
        _audioPlayer.setReleaseMode(ReleaseMode.loop);
    } else {
        _audioPlayer.setReleaseMode(ReleaseMode.stop); // Or ReleaseMode.release
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final newShuffleModeEnabled = shuffleMode == AudioServiceShuffleMode.all;
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
    if (newShuffleModeEnabled) {
      // Shuffle _internalQueue but keep _currentIndex pointing to the same song ID
      final currentSongId = _currentIndex != -1 ? _internalQueue[_currentIndex].id : null;
      _internalQueue.shuffle();
      if (currentSongId != null) {
        _currentIndex = _internalQueue.indexWhere((s) => s.id == currentSongId);
      } else {
        _currentIndex = _internalQueue.isNotEmpty ? 0 : -1;
      }
    } else {
      // Unshuffle: This would require storing the original order.
      // For simplicity, we might just resort by a default criteria or leave as is.
      // Or, if you stored the original queue when updateQueue was called:
      // _internalQueue = originalQueueSnapshot;
      // _currentIndex = _internalQueue.indexWhere((s) => s.id == mediaItem.value?.id);
    }
    // Update the audio_service queue
    queue.add(_internalQueue.map((s) => songToMediaItem(s)).toList());
  }

  // Custom methods
  Future<void> playSongNow(Song song) async {
    // If song is already in queue, just skip to it. Otherwise, add and play.
    int index = _internalQueue.indexWhere((s) => s.id == song.id);
    if (index != -1) {
      await skipToQueueItem(index);
    } else {
      // Add to end of queue and play
      _internalQueue.add(song);
      queue.add(_internalQueue.map((s) => songToMediaItem(s)).toList());
      await skipToQueueItem(_internalQueue.length - 1);
    }
  }

  Future<void> playStreamUrl(String streamUrl, String stationName, String? stationFavicon) async {
    final radioSong = Song(
        id: 'radio_${stationName.hashCode}_${streamUrl.hashCode}',
        title: stationName,
        artist: 'Radio Station',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl,
        isDownloaded: false,
    );

    // Replace queue with just this stream or add it
    _internalQueue = [radioSong];
    _currentIndex = 0;
    queue.add([songToMediaItem(radioSong)]);
    mediaItem.add(songToMediaItem(radioSong));
    
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.loading,
      playing: false,
    ));

    try {
      await _audioPlayer.play(UrlSource(streamUrl));
    } catch (e) {
      debugPrint("Error playing stream: $e");
       playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> updateSongMetadataInHandler(Song updatedSong) async {
    // Update in _internalQueue
    final index = _internalQueue.indexWhere((s) => s.id == updatedSong.id);
    if (index != -1) {
      _internalQueue[index] = updatedSong;
      // If it's the current playing item, update MediaItem
      if (_currentIndex == index) {
        mediaItem.add(songToMediaItem(updatedSong, duration: mediaItem.value?.duration));
      }
      // Update the whole queue for audio_service
      queue.add(_internalQueue.map((s) => songToMediaItem(s, duration: (s.id == mediaItem.value?.id ? mediaItem.value?.duration : null) )).toList());
    }
  }
}

/// Initializes and returns the audio handler.
Future<MyAudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ryanheise.myapp.channel.audio',
      androidNotificationChannelName: 'LTunes Audio Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true, // Or false if you want to keep notification during pause
      // Other configurations...
    ),
  );
}
