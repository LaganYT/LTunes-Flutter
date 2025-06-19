import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/song.dart'; // Assuming Song model can give necessary info
import 'package:audio_session/audio_session.dart';

// Helper function to convert Song to MediaItem
MediaItem songToMediaItem(Song song, String playableUrl, Duration? duration) {
  Uri? artUri;
  if (song.albumArtUrl.isNotEmpty) {
    // If albumArtUrl is an absolute URL (http/https), parse it.
    artUri = Uri.tryParse(song.albumArtUrl);
  }

  return MediaItem(
    id: playableUrl, // This MUST be the playable URL or local file path
    title: song.title,
    artist: song.artist,
    album: song.album,
    artUri: artUri,
    duration: (duration != null && duration > Duration.zero)
        ? duration
        : song.duration, // Use song duration from API if not provided
    extras: {
      'songId': song.id, // Original song ID from your app's model
      'isLocal': song.isDownloaded,
      // Only set localArtFileName if albumArtUrl is not an http/https URL and is not empty.
      'localArtFileName': (!song.albumArtUrl.startsWith('http') && song.albumArtUrl.isNotEmpty)
          ? song.albumArtUrl
          : null,
      'isRadio': song.isRadio, // Use the new getter from Song model
    },
  );
}

class AudioPlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _lastPlayerState = PlayerState.stopped;
  final _playlist = <MediaItem>[];
  int _currentIndex = -1;
  bool _isRadioStream = false;

  // Stream controllers for custom events or states if needed later
  // final _customEventController = StreamController<dynamic>.broadcast();
  // Stream<dynamic> get customEventStream => _customEventController.stream;

  AudioPlayerHandler() {
    _notifyAudioHandlerAboutPlaybackEvents();

    // Listen to OS audio interruptions and resume playback when interruption ends
    AudioSession.instance.then((session) {
      session.interruptionEventStream.listen((event) {
        if (!event.begin // interruption ended
            && (event.type == AudioInterruptionType.pause ||
                event.type == AudioInterruptionType.unknown)) {
          _audioPlayer.resume();
        }
      });
    });

    // Load the queue from persistent storage if necessary (not implemented here)
    // For now, queue is managed by CurrentSongProvider sending updates.
  }

  // Renamed and repurposed _resolveArtUri to _resolveArtForItem
  // This method tries to resolve art URI for local files if it's not already a file URI.
  Future<MediaItem> _resolveArtForItem(MediaItem item) async {
    String? artFileNameToResolve;
    bool isHttp = item.artUri?.toString().startsWith('http') ?? false;
    bool isFileUri = item.artUri?.isScheme('file') ?? false;

    if (item.artUri != null && !isHttp && !isFileUri) {
        // artUri is present but is not http and not a file URI, implies it might be a relative path
        artFileNameToResolve = item.artUri.toString();
    } else if (item.artUri == null && item.extras?['localArtFileName'] != null) {
        // artUri is null, but localArtFileName is available
        artFileNameToResolve = item.extras!['localArtFileName'] as String;
    }

    if (artFileNameToResolve != null && artFileNameToResolve.isNotEmpty && (item.extras?['isLocal'] as bool? ?? false)) {
        try {
            final directory = await getApplicationDocumentsDirectory();
            final fullPath = p.join(directory.path, artFileNameToResolve);
            if (await File(fullPath).exists()) {
                return item.copyWith(artUri: Uri.file(fullPath));
            } else {
                debugPrint("Local art file not found: $fullPath");
                return item.copyWith(artUri: null); // Art not found, clear URI
            }
        } catch (e) {
            debugPrint("Error resolving local art URI for ${artFileNameToResolve}: $e");
            return item.copyWith(artUri: null); // Error, clear URI
        }
    }
    return item; // Return original item if no resolution needed/possible or if it's an HTTP URI
  }


  void _notifyAudioHandlerAboutPlaybackEvents() {
    _audioPlayer.onPlayerStateChanged.listen((state) async {
     _lastPlayerState = state;
      final playing = state == PlayerState.playing;
      // Get current position safely
      Duration currentPosition = Duration.zero;
      try {
        currentPosition = await _audioPlayer.getCurrentPosition() ?? Duration.zero;
      } catch (e) {
        // Handle error, e.g. player not initialized
        debugPrint("Error getting current position: $e");
      }

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
        updatePosition: currentPosition, // Use fetched position
        bufferedPosition: Duration.zero, // Placeholder as audioplayers does not provide bufferedPosition
        speed: _audioPlayer.playbackRate, // Consider safety if player can be uninitialized
        queueIndex: _currentIndex,
        // Removed invalid 'duration' parameter
      ));
    });

    _audioPlayer.onDurationChanged.listen((newDuration) {
      final currentItem = mediaItem.value;
      
      if (currentItem == null) return; // No current item to update

      // Use currentItem.extras first, then fallback to handler's _isRadioStream as a secondary check.
      bool isRadio = currentItem.extras?['isRadio'] as bool? ?? _isRadioStream;
      
      if (!isRadio) {
        // Only update if duration is valid and different
        if (newDuration > Duration.zero && currentItem.duration != newDuration) {
          final updatedItem = currentItem.copyWith(duration: newDuration);
          mediaItem.add(updatedItem); // Broadcast the change

          // Update in _playlist if _currentIndex is valid and points to this item
          if (_currentIndex >= 0 && _currentIndex < _playlist.length && 
              _playlist[_currentIndex].id == updatedItem.id) {
            _playlist[_currentIndex] = updatedItem;
          }
        
          
        }
      }
      // If it IS a radio stream, we let onPositionChanged handle setting the duration
      // to the current position. This prevents potentially incorrect fixed durations (like 0:00)
      // from stream metadata from being set on the MediaItem for radio.
    });

    _audioPlayer.onPositionChanged.listen((position) {
       final currentMediaItem = mediaItem.value;

       if (_isRadioStream && currentMediaItem != null) {
         final updatedItem = currentMediaItem.copyWith(duration: position);
         mediaItem.add(updatedItem);

         // Update in _playlist if _currentIndex is valid and points to this item
         if (_currentIndex >= 0 && _currentIndex < _playlist.length &&
             _playlist[_currentIndex].id == updatedItem.id) {
           _playlist[_currentIndex] = updatedItem;
         }
       }
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
      ));
    });

    _audioPlayer.onPlayerComplete.listen((_) async {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
        await seek(Duration.zero);
        // Explicitly update playback state to playing and position zero
        playbackState.add(playbackState.value.copyWith(
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration.zero,
        ));
        await play();
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
    queue.add(List.unmodifiable(_playlist)); // Broadcast an unmodifiable copy
  }

  @override
  Future<void> addQueueItem(MediaItem item) async {
    _playlist.add(item);
    queue.add(List.unmodifiable(_playlist));
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem item) async {
    _playlist.insert(index, item);
    queue.add(List.unmodifiable(_playlist));
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    _playlist.clear();
    _playlist.addAll(newQueue);
    queue.add(List.unmodifiable(_playlist));
    // If current index is out of bounds, reset it
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
    if (playbackState.value.playing) return;
   // if previously paused, just resume at current position
   if (_lastPlayerState == PlayerState.paused) {
     await _audioPlayer.resume();
     return;
   }
    // fresh start or first play
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
      await skipToQueueItem(_currentIndex);
    } else {
      debugPrint("Play called, but no valid current item is selected or playlist is empty. Current index: $_currentIndex, Playlist length: ${_playlist.length}");
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
    // _currentIndex = -1; // Keep current index to allow resume from same spot? Or reset.
                         // Resetting is common for a full stop.
    mediaItem.add(null); // Clear the current media item
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
        // Explicitly clear duration on stop (removed invalid parameter)
        updatePosition: Duration.zero // Reset position on stop
        // queueIndex: _currentIndex // Keep or reset queueIndex based on desired UX for stop
    ));
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;
    
    int newIndex = _currentIndex; // Start with current index

    if (playbackState.value.shuffleMode == AudioServiceShuffleMode.all && _playlist.length > 1) {
        int tempIndex;
        do {
            tempIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
        } while (tempIndex == _currentIndex && _playlist.length > 1); // Ensure different if possible
        newIndex = tempIndex;
    } else {
        newIndex++; // Move to next
    }
    
    if (newIndex >= _playlist.length) {
        if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
            newIndex = 0; // Wrap around for repeat all
        } else {
            // Reached end of queue, not repeating all.
            // Optionally, stop playback or mark as completed.
            // For now, let's stop, consistent with onPlayerComplete behavior for non-repeating queue end.
            await _audioPlayer.stop(); // Stop the player
            playbackState.add(playbackState.value.copyWith(
                processingState: AudioProcessingState.completed, // Or idle if stopping
                playing: false));
            // mediaItem.add(null); // Optionally clear media item
            return; // Do not proceed to play
        }
    }
    await skipToQueueItem(newIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    int newIndex = _currentIndex; // Start with current index

    if (playbackState.value.shuffleMode == AudioServiceShuffleMode.all && _playlist.length > 1) {
        int tempIndex;
        do {
            tempIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
        } while (tempIndex == _currentIndex && _playlist.length > 1);
        newIndex = tempIndex;
    } else {
        newIndex--; // Move to previous
    }

    if (newIndex < 0) {
        if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
            newIndex = _playlist.length - 1; // Wrap around for repeat all
        } else {
            // Reached beginning of queue, not repeating all.
            // Behavior can vary: stop, go to first item and pause, or seek to 0 of current.
            // For now, let's stop.
            await _audioPlayer.stop();
            playbackState.add(playbackState.value.copyWith(
                processingState: AudioProcessingState.completed, // Or idle
                playing: false));
            // mediaItem.add(null);
            return; // Do not proceed to play
        }
    }
    await skipToQueueItem(newIndex);
  }
  
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;

    MediaItem itemToPlay = _playlist[_currentIndex];
    itemToPlay = await _resolveArtForItem(itemToPlay);
    _playlist[_currentIndex] = itemToPlay;
    mediaItem.add(itemToPlay);

    // Update playback state with the new queue index BEFORE playing.
    // The playing state will be updated by the onPlayerStateChanged listener.
    playbackState.add(playbackState.value.copyWith(
        queueIndex: _currentIndex,
        // Removed invalid 'duration' parameter
        // Reset processing state to loading/buffering if needed, or let onPlayerStateChanged handle it
    ));

    _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;
    Source source = (itemToPlay.extras?['isLocal'] as bool? ?? false)
        ? DeviceFileSource(itemToPlay.id)
        : UrlSource(itemToPlay.id);

    try {
      // Ensure playback starts from the beginning of the track.
      await _audioPlayer.play(source, position: Duration.zero);
      // onPlayerStateChanged will update playing state
      // immediately fetch the duration if available
      final initialDur = await _audioPlayer.getDuration();
      if (!_isRadioStream && initialDur != null && initialDur > Duration.zero) {
        final cur = mediaItem.value;
        if (cur != null && cur.duration != initialDur) {
          final updated = cur.copyWith(duration: initialDur);
          _playlist[_currentIndex] = updated;
          mediaItem.add(updated);
        }
      }
    } catch (e) {
      debugPrint("Error playing source ${itemToPlay.id}: $e");
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
      ));
    }
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
    // If you have custom shuffle logic for the queue itself, apply it here.
    // For example, if shuffleMode is on, you might reorder _playlist.
    // However, typical shuffle behavior is often just picking a random next track.
  }

  // Handle playing a specific media item, potentially adding it to queue
  @override
  Future<void> playMediaItem(MediaItem item) async {
    // The passed 'item' might have an unresolved artUri.
    // It will be resolved by skipToQueueItem after being placed in the playlist.
    int index = _playlist.indexWhere((element) => element.id == item.id);
    
    if (index == -1) {
      // Item not in queue. For simplicity, clear current queue and add this item.
      // App specific logic might differ (e.g. add to end, play next, etc.)
      _playlist.clear();
      _playlist.add(item); // Add the original item (art will be resolved by skipToQueueItem)
      queue.add(List.unmodifiable(_playlist)); // Broadcast new queue
      index = 0; // It's now the first (and only) item
    } else {
      // Item already in queue. We could update it if 'item' has new metadata.
      _playlist[index] = item; // Replace existing item with potentially new metadata
                               // Art will be resolved by skipToQueueItem.
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
      if (Uri.tryParse(mediaId)?.isAbsolute ?? false) {
        final newItem = MediaItem(
          id: mediaId, 
          title: extras?['title'] as String? ?? mediaId.split('/').last, 
          artist: extras?['artist'] as String? ?? "Unknown Artist",
          album: extras?['album'] as String?,
          artUri: extras?['artUri'] is String ? Uri.tryParse(extras!['artUri']) : null,
          extras: extras, // Pass along all extras
        );
        // Add to queue (art will be resolved by skipToQueueItem)
        _playlist.add(newItem);
        queue.add(List.unmodifiable(_playlist));
        await skipToQueueItem(_playlist.length - 1); // Play the newly added item
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

  // Handle metadata‐update requests so MediaSession (and Bluetooth) sees new metadata
  @override
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'updateCurrentMediaItemMetadata') {
      final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
      if (mediaMap != null) {
        final updated = MediaItem(
          id: mediaMap['id'] as String,
          title: mediaMap['title'] as String,
          artist: mediaMap['artist'] as String?,
          album: mediaMap['album'] as String?,
          artUri: mediaMap['artUri'] != null
              ? Uri.tryParse(mediaMap['artUri'] as String)
              : null,
          duration: mediaMap['duration'] != null
              ? Duration(milliseconds: mediaMap['duration'] as int)
              : null,
          extras: Map<String, dynamic>.from(mediaMap['extras'] as Map),
        );
        // update current item
        mediaItem.add(updated);
        // also sync into the queue list
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _playlist[_currentIndex] = updated;
          queue.add(List.unmodifiable(_playlist));
        }
      }
    }
    return null;
  }
}
