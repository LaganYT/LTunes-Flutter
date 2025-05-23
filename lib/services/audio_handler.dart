import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/song.dart'; // Assuming Song model can give necessary info

// Helper function to convert Song to MediaItem
MediaItem songToMediaItem(Song song, String playableUrl, Duration? duration) {
  return MediaItem(
    id: playableUrl, // This MUST be the playable URL or local file path
    title: song.title,
    artist: song.artist,
    album: song.album,
    // Removed invalid parameter 'updatePosition'
    artUri: song.albumArtUrl.isNotEmpty ? Uri.tryParse(song.albumArtUrl) : null,
    extras: {
      'songId': song.id, // Original song ID from your app's model
      'isLocal': song.isDownloaded,
      // Store the original albumArtUrl if it was a local filename,
      // as artUri might be null if it couldn't be parsed as a Uri.
      'localArtFileName': !song.albumArtUrl.startsWith('http') ? song.albumArtUrl : null,
    },
  );
}

class AudioPlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final _playlist = <MediaItem>[];
  int _currentIndex = -1;
  bool _isRadioStream = false;

  // Stream controllers for custom events or states if needed later
  // final _customEventController = StreamController<dynamic>.broadcast();
  // Stream<dynamic> get customEventStream => _customEventController.stream;

  AudioPlayerHandler() {
    _notifyAudioHandlerAboutPlaybackEvents();
    // Load the queue from persistent storage if necessary (not implemented here)
    // For now, queue is managed by CurrentSongProvider sending updates.
  }

  // ignore: unused_element
  Future<String> _resolveArtUri(MediaItem item) async {
    if (item.artUri != null && item.artUri.toString().startsWith('http')) {
      return item.artUri.toString();
    }
    if (item.extras?['localArtFileName'] != null) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, item.extras!['localArtFileName'] as String);
      if (await File(fullPath).exists()) {
        return Uri.file(fullPath).toString();
      }
    }
    return item.artUri?.toString() ?? '';
  }


  void _notifyAudioHandlerAboutPlaybackEvents() {
    _audioPlayer.onPlayerStateChanged.listen((state) async {
      final playing = state == PlayerState.playing;
      playbackState.add(playbackState.value.copyWith(
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
        androidCompactActionIndices: const [0, 1, 3],
        processingState: {
          PlayerState.stopped: AudioProcessingState.idle,
          PlayerState.playing: AudioProcessingState.ready,
          PlayerState.paused: AudioProcessingState.ready,
          PlayerState.completed: AudioProcessingState.completed,
          PlayerState.disposed: AudioProcessingState.idle, // Or handle appropriately
        }[state] ?? AudioProcessingState.loading, // Default to loading or error
        playing: playing,
        updatePosition: await _audioPlayer.getCurrentPosition() ?? Duration.zero,
        bufferedPosition: Duration.zero, // Placeholder as audioplayers does not provide bufferedPosition
        speed: _audioPlayer.playbackRate,
        queueIndex: _currentIndex,
      ));
    });

    _audioPlayer.onDurationChanged.listen((duration) {
      if (mediaItem.value != null && mediaItem.value!.duration != duration) {
        mediaItem.add(mediaItem.value!.copyWith(duration: duration));
      }
      playbackState.add(playbackState.value.copyWith(
      ));
    });

    _audioPlayer.onPositionChanged.listen((position) {
       if (_isRadioStream && mediaItem.value != null) {
         // For radio streams, update duration to reflect elapsed time
         mediaItem.add(mediaItem.value!.copyWith(duration: position));
       }
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
      ));
    });

    _audioPlayer.onPlayerComplete.listen((_) async {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
        seek(Duration.zero);
        play();
      } else {
        if (_currentIndex + 1 < _playlist.length || playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
          await skipToNext();
        } else {
          // Reached end of queue and not repeating all
          playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.completed));
          // Optionally stop: await stop();
        }
      }
    });
  }
  
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _playlist.addAll(mediaItems);
    queue.add(_playlist);
  }

  @override
  Future<void> addQueueItem(MediaItem item) async {
    _playlist.add(item);
    queue.add(_playlist);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem item) async {
    _playlist.insert(index, item);
    queue.add(_playlist);
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    _playlist.clear();
    _playlist.addAll(newQueue);
    queue.add(_playlist);
    // If current index is out of bounds, reset it
    if (_currentIndex >= _playlist.length) {
        _currentIndex = _playlist.isNotEmpty ? 0 : -1;
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    queue.add(_playlist);
    if (_currentIndex == index) {
      if (_playlist.isEmpty) {
        _currentIndex = -1;
        await stop(); // Stop if current item removed and queue empty
      } else if (_currentIndex >= _playlist.length) {
        // If last item removed, move to new last item or 0
        _currentIndex = _playlist.length - 1;
        // Optionally, auto-play this new current item or just update state
      }
      // If current item removed, and it was playing, decide what to do:
      // play _playlist[_currentIndex] or stop.
      // For now, CurrentSongProvider will likely handle re-triggering play.
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
  }


  @override
  Future<void> play() async {
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
      final itemToPlay = _playlist[_currentIndex];
      mediaItem.add(itemToPlay); // Broadcast current item
      _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;

      Source source;
      if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
        // item.id is already the full local path
        source = DeviceFileSource(itemToPlay.id);
      } else {
        source = UrlSource(itemToPlay.id);
      }
      await _audioPlayer.play(source);
      playbackState.add(playbackState.value.copyWith(playing: true));
    }
  }

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) => _audioPlayer.seek(position);

  @override
  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentIndex = -1;
    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
        queueIndex: _currentIndex
    ));
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;
    
    if (playbackState.value.shuffleMode == AudioServiceShuffleMode.all && _playlist.length > 1) {
        // Basic shuffle: pick a random different index
        int newIndex;
        do {
            newIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
        } while (newIndex == _currentIndex);
        _currentIndex = newIndex;
    } else {
        _currentIndex = (_currentIndex + 1) % _playlist.length;
    }
    
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        mediaItem.add(_playlist[_currentIndex]);
        playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
        await play();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    if (playbackState.value.shuffleMode == AudioServiceShuffleMode.all && _playlist.length > 1) {
        // Basic shuffle: pick a random different index
        int newIndex;
        do {
            newIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
        } while (newIndex == _currentIndex);
        _currentIndex = newIndex;
    } else {
        _currentIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
    }

    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        mediaItem.add(_playlist[_currentIndex]);
        playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
        await play();
    }
  }
  
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;
    mediaItem.add(_playlist[_currentIndex]);
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
    await play(); // Start playing the new item
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    // audioplayers specific loop mode if applicable, or handle in onPlayerComplete
    switch (repeatMode) {
        case AudioServiceRepeatMode.none:
            _audioPlayer.setReleaseMode(ReleaseMode.stop);
            break;
        case AudioServiceRepeatMode.one:
            _audioPlayer.setReleaseMode(ReleaseMode.loop);
            break;
        case AudioServiceRepeatMode.all:
        case AudioServiceRepeatMode.group: // Treat group as all for now
            _audioPlayer.setReleaseMode(ReleaseMode.stop); // Handled by skipToNext logic
            break;
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  // Handle playing a specific media item, potentially adding it to queue
  @override
  Future<void> playMediaItem(MediaItem item) async {
    // Check if item is already in queue
    int index = _playlist.indexWhere((element) => element.id == item.id);
    if (index == -1) {
      // If not in queue, add it. Decide if it replaces queue or adds to it.
      // For simplicity, let's say it becomes the new queue of one.
      // Or, CurrentSongProvider should manage the queue and call updateQueue.
      // For now, let's assume this means "play this item now, it's the current focus".
      _playlist.clear();
      _playlist.add(item);
      queue.add(_playlist); // Broadcast new queue
      index = 0;
    }
    await skipToQueueItem(index);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    // This method is called when a media ID is received, e.g., from a voice command.
    // We need to find the MediaItem with this ID in our playlist or fetch it.
    // For now, assuming mediaId is the playable URL/path.
    final index = _playlist.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      await skipToQueueItem(index);
    } else {
      // If not in queue, we might need to fetch details and create a MediaItem.
      // This part depends on how your app resolves media IDs.
      // For simplicity, if it's a URL, create a basic MediaItem.
      if (Uri.tryParse(mediaId)?.isAbsolute ?? false) {
        final newItem = MediaItem(id: mediaId, title: mediaId.split('/').last, artist: "Unknown Artist");
        await addQueueItem(newItem);
        await skipToQueueItem(_playlist.length - 1);
      } else {
        debugPrint("AudioPlayerHandler: Cannot play from mediaId '$mediaId' - not found in queue and not a URL.");
      }
    }
  }

  // Optional: Override other methods like fastForward, rewind, etc.
  // By default, they call seek.

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    return super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    await stop(); // Or pause, depending on desired behavior
    return super.onNotificationDeleted();
  }
}
