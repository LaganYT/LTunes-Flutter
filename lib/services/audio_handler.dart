import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/song.dart'; // Assuming Song model can give necessary info
import 'package:audio_session/audio_session.dart';
import '../main.dart'; // Import to access globalNavigatorKey
import '../screens/download_queue_screen.dart'; // Import DownloadQueueScreen

// Helper function to convert Song to MediaItem
MediaItem songToMediaItem(Song song, String playableUrl, Duration? duration) {
  Uri? artUri;
  if (song.albumArtUrl.isNotEmpty) {
    // If albumArtUrl is an absolute URL (http/https), parse it.
    if (song.albumArtUrl.startsWith('http')) {
      artUri = Uri.tryParse(song.albumArtUrl);
    }
    // For local files, we leave artUri as null. It will be resolved later
    // by _resolveArtForItem into a proper file:// URI.
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

  AudioPlayerHandler() {
    _audioPlayer.setAndroidAudioAttributes(
      const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
    );

    _initializeAudioSession();

    _notifyAudioHandlerAboutPlaybackEvents();

    // Listen to OS audio interruptions and resume playback when interruption ends
    _audioSession?.interruptionEventStream.listen((event) {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            if (_audioPlayer.volume > 0) _audioPlayer.setVolume(_audioPlayer.volume / 2);
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            pause();
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _audioPlayer.setVolume(
                (_audioPlayer.volume * 2).clamp(0.0, 1.0));
            break;
          case AudioInterruptionType.pause:
            // Resume playback after interruption ends
            if (playbackState.value.playing) {
              play();
            }
            break;
          case AudioInterruptionType.unknown:
            pause();
            break;
        }
      }
    });

    // Listen to becoming noisy events (e.g., headphones unplugged)
    _audioSession?.becomingNoisyEventStream.listen((_) {
      pause();
    });

    // Set up periodic audio session maintenance
    _setupAudioSessionMaintenance();

    // Load the queue from persistent storage if necessary (not implemented here)
    // For now, queue is managed by CurrentSongProvider sending updates.
  }

  Future<void> _initializeAudioSession() async {
    try {
      _audioSession = await AudioSession.instance;
      await _audioSession!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowAirPlay |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      
      debugPrint("Audio session initialized successfully");
    } catch (e) {
      debugPrint("Error initializing audio session: $e");
    }
  }

  Future<void> configureAudioSession() async {
    if (_audioSession == null) {
      await _initializeAudioSession();
      return;
    }
    
    try {
      await _audioSession!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowAirPlay |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
    }
  }

  Future<void> _ensureAudioSessionActive() async {
    try {
      if (_audioSession == null) {
        await _initializeAudioSession();
        return;
      }
      
      await _audioSession!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowAirPlay |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
    } catch (e) {
      debugPrint("Error ensuring audio session is active: $e");
    }
  }

  Future<void> _prepareToPlay(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;

    MediaItem itemToPlay = _playlist[_currentIndex];
    itemToPlay = await _resolveArtForItem(itemToPlay);
    _playlist[_currentIndex] = itemToPlay;
    mediaItem.add(itemToPlay);

    playbackState.add(playbackState.value.copyWith(
        queueIndex: _currentIndex,
    ));

    _isRadioStream = itemToPlay.extras?['isRadio'] as bool? ?? false;
    
    AudioSource source;
    if (itemToPlay.extras?['isLocal'] as bool? ?? false) {
      // Using Uri.file for local files is generally more robust.
      source = AudioSource.uri(Uri.file(itemToPlay.id));
      debugPrint("Preparing local file: ${itemToPlay.title} at path: ${itemToPlay.id}");
    } else {
      source = AudioSource.uri(Uri.parse(itemToPlay.id));
      debugPrint("Preparing remote file: ${itemToPlay.title} at URL: ${itemToPlay.id}");
    }

    try {
      // Ensure audio session is active before setting source
      await ensureBackgroundPlayback();
      
      // Set source but do not play.
      await _audioPlayer.setAudioSource(source);
      
      // Reset position to 0:00 when a new song is prepared
      // This ensures the seekbar shows the beginning of the song
      playbackState.add(playbackState.value.copyWith(
        updatePosition: Duration.zero,
      ));
      
      // Ensure background playback is maintained when preparing new songs
      await ensureBackgroundPlayback();
      
      debugPrint("Successfully prepared audio source for: ${itemToPlay.title}");
    } catch (e) {
      debugPrint("Error setting source for ${itemToPlay.id}: $e");
      
      // Show error dialog for radio streams
      if (_isRadioStream) {
        _showRadioErrorDialog(itemToPlay.title);
      }
    }
  }

  // Helper method to show radio error dialog
  void _showRadioErrorDialog(String stationName) {
    // Use the global navigator key to show dialog from anywhere
    final navigator = globalNavigatorKey.currentState;
    if (navigator != null) {
      showDialog(
        context: navigator.context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Radio Stream Error'),
            content: Text('Failed to load radio station "$stationName". The stream may be temporarily unavailable or the URL may be invalid.'),
            actions: <Widget>[
              TextButton(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    }
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
    _audioPlayer.playerStateStream.listen((playerState) {
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
      // Always update if we get a valid duration for a non-radio stream.
      // This handles cases where the initial duration was null or zero.
      if (!isRadio && newDuration != null && newDuration > Duration.zero) {
        final newItem = currentItem.copyWith(duration: newDuration);
        if (mediaItem.value != newItem) {
          mediaItem.add(newItem);
        }
      }
    });

    _audioPlayer.positionStream.listen((position) {
      final currentItem = mediaItem.value;
      final isStreaming = currentItem?.extras?['isLocal'] == false;
      
      // For streaming URLs, be more careful about position updates
      if (isStreaming) {
        final lastSeekPosition = playbackState.value.updatePosition;
        
        // Don't update to 0 if we just performed a seek and the position is 0
        // But allow it if the last position was also 0 (new song)
        if (position == Duration.zero && lastSeekPosition != Duration.zero && lastSeekPosition > Duration.zero) {
          // Don't update to 0, maintain the last known position
          // This prevents the UI from showing 0:00 after seeking
          return;
        }
        
        // If we get a valid position that's close to our seek position, update it
        // This ensures the seekbar eventually syncs with the actual audio position
        if (position != Duration.zero && lastSeekPosition != Duration.zero) {
          final difference = (position.inMilliseconds - lastSeekPosition.inMilliseconds).abs();
          // If the difference is small (within 1 second), update to the actual position
          if (difference < 1000) {
            playbackState.add(playbackState.value.copyWith(
              updatePosition: position,
            ));
            return;
          }
        }
      }
      
      // For local files or normal streaming updates, always update
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
      ));
    });

    _audioPlayer.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        debugPrint("Song completed, handling next track...");
        
        // Handle song completion based on repeat mode
        final repeatMode = playbackState.value.repeatMode;
        
        if (repeatMode == AudioServiceRepeatMode.one) {
          // For repeat one, the just_audio loop mode should handle this automatically
          // But we need to ensure the UI state is correct
          if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
            try {
              await _prepareToPlay(_currentIndex);
              await ensureBackgroundPlayback(); // Ensure background playback is maintained
              await _audioPlayer.play();
              debugPrint("Repeating song: ${_playlist[_currentIndex].title}");
            } catch (e) {
              debugPrint("Error repeating song: $e");
              if (_isRadioStream) {
                _showRadioErrorDialog(_playlist[_currentIndex].title);
              }
            }
          }
        } else {
          // For other modes, try to play next song
          try {
            // Ensure background playback is maintained before transitioning
            await ensureBackgroundPlayback();
            await skipToNext();
            debugPrint("Skipped to next song");
          } catch (e) {
            debugPrint("Error skipping to next song: $e");
            if (_isRadioStream && _currentIndex >= 0 && _currentIndex < _playlist.length) {
              _showRadioErrorDialog(_playlist[_currentIndex].title);
            }
          }
        }
        
        // Ensure background playback is maintained after song completion
        await ensureBackgroundPlayback();
      }
    });
  }
  
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    _playlist.addAll(mediaItems);
    queue.add(List.unmodifiable(_playlist)); // Broadcast an unmodifiable copy
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
    if (_audioPlayer.playing) return;

    // Ensure audio session is active and configured for background playback
    await ensureBackgroundPlayback();

    try {
      // If we are idle (e.g., stopped or just started), we need to prepare the source.
      if (_audioPlayer.processingState == ProcessingState.idle) {
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          await _prepareToPlay(_currentIndex);
          await _audioPlayer.play();
        }
      } 
      // If we are paused or have completed a seek, we can just play.
      else if (_audioPlayer.processingState == ProcessingState.ready) {
        await _audioPlayer.play();
      } 
      // If we are in any other state (loading, buffering, completed), and not playing,
      // it's safest to just call play and let just_audio handle it.
      // This covers resuming from a completed state to replay, or from buffering.
      else {
        await _audioPlayer.play();
      }
    } catch (e) {
      debugPrint("Error playing audio: $e");
      
      // Show error dialog for radio streams
      if (_isRadioStream && _currentIndex >= 0 && _currentIndex < _playlist.length) {
        _showRadioErrorDialog(_playlist[_currentIndex].title);
      }
    }
  }

  @override
  Future<void> pause() async {
    await _audioPlayer.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    // Immediately broadcast the new position so the UI feels responsive.
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
    await _audioPlayer.seek(position);
  }

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
    
    int newIndex = _currentIndex + 1;
    
    if (newIndex >= _playlist.length) {
        if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
            newIndex = 0; // Wrap around for repeat all
        } else {
            // Stop playback when reaching the end and not repeating
            await stop();
            return;
        }
    }
    try {
      await skipToQueueItem(newIndex);
    } catch (e) {
      debugPrint("Error skipping to next: $e");
      if (_isRadioStream && newIndex >= 0 && newIndex < _playlist.length) {
        _showRadioErrorDialog(_playlist[newIndex].title);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    int newIndex = _currentIndex - 1;

    if (newIndex < 0) {
        if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
            newIndex = _playlist.length - 1; // Wrap around for repeat all
        } else {
            // Stop playback when reaching the beginning and not repeating
            await stop();
            return;
        }
    }
    try {
      await skipToQueueItem(newIndex);
    } catch (e) {
      debugPrint("Error skipping to previous: $e");
      if (_isRadioStream && newIndex >= 0 && newIndex < _playlist.length) {
        _showRadioErrorDialog(_playlist[newIndex].title);
      }
    }
  }
  
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) {
      // Invalid index, stop playback
      await stop();
      return;
    }
    
    await _prepareToPlay(index);
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
      try {
        // Ensure audio session is active and configured for background playback
        await ensureBackgroundPlayback();

        await _audioPlayer.play();
      } catch (e) {
        debugPrint("Error playing source ${_playlist[_currentIndex].id}: $e");
        playbackState.add(playbackState.value.copyWith(
          playing: false,
        ));
        
        // Show error dialog for radio streams
        if (_isRadioStream) {
          _showRadioErrorDialog(_playlist[_currentIndex].title);
        }
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
        case AudioServiceRepeatMode.group: // Treat group as all for now
            await _audioPlayer.setLoopMode(LoopMode.off); // Handled by skipToNext
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
  Future<void> playMediaItem(MediaItem mediaItem) async {
    try {
      // The passed 'mediaItem' might have an unresolved artUri.
      // It will be resolved by skipToQueueItem after being placed in the playlist.
      int index = _playlist.indexWhere((element) => element.id == mediaItem.id);
      
      if (index == -1) {
        // Item not in queue. For simplicity, clear current queue and add this item.
        // App specific logic might differ (e.g. add to end, play next, etc.)
        _playlist.clear();
        _playlist.add(mediaItem); // Add the original item (art will be resolved by skipToQueueItem)
        queue.add(List.unmodifiable(_playlist)); // Broadcast new queue
        index = 0; // It's now the first (and only) item
      } else {
        // Item already in queue. We could update it if 'mediaItem' has new metadata.
        _playlist[index] = mediaItem; // Replace existing item with potentially new metadata
                                 // Art will be resolved by skipToQueueItem.
      }
      
      await skipToQueueItem(index);
    } catch (e) {
      debugPrint("Error playing media item ${mediaItem.title}: $e");
      
      // Show error dialog for radio streams
      if (mediaItem.extras?['isRadio'] as bool? ?? false) {
        _showRadioErrorDialog(mediaItem.title);
      }
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    try {
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
    } catch (e) {
      debugPrint("Error playing from media ID $mediaId: $e");
      
      // Show error dialog for radio streams
      if (extras?['isRadio'] as bool? ?? false) {
        final title = extras?['title'] as String? ?? mediaId.split('/').last;
        _showRadioErrorDialog(title);
      }
    }
  }

  // Optional: Override other methods like fastForward, rewind, etc.
  // By default, they call seek.

  @override
  Future<void> onTaskRemoved() async {
    // Ensure background playback is maintained when task is removed
    await ensureBackgroundPlayback();
    return super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Don't pause when notification is deleted to allow background playback
    return super.onNotificationDeleted();
  }

  // Method to ensure audio session is maintained during background playback
  Future<void> ensureBackgroundPlayback() async {
    try {
      await _ensureAudioSessionActive();
      
      // For iOS, use the specific background audio session activation
      await _activateIOSBackgroundAudioSession();
      
      // For iOS, ensure the audio session is active and properly configured
      // This is especially important for local files in background
      if (_audioPlayer.playing) {
        // Force a small audio operation to keep the session active
        final currentVolume = _audioPlayer.volume;
        await _audioPlayer.setVolume(currentVolume);
        
        // For local files, ensure the audio source is properly loaded
        final currentItem = mediaItem.value;
        if (currentItem != null && currentItem.extras?['isLocal'] == true) {
          // Re-ensure the audio source is properly set for local files
          try {
            final source = AudioSource.uri(Uri.file(currentItem.id));
            await _audioPlayer.setAudioSource(source, preload: false);
            debugPrint("Re-ensured audio source for local file: ${currentItem.title}");
          } catch (e) {
            debugPrint("Error re-ensuring audio source for local file: $e");
          }
        }
      }
      
      debugPrint("Background playback session configured successfully");
      
      // Log current playback state for debugging
      debugPrint("Current playback state: playing=${_audioPlayer.playing}, "
          "processingState=${_audioPlayer.processingState}, "
          "currentIndex=$_currentIndex, "
          "playlistLength=${_playlist.length}, "
          "isLocal=${mediaItem.value?.extras?['isLocal']}");
    } catch (e) {
      debugPrint("Error ensuring background playback: $e");
    }
  }

  // Method to handle app coming back to foreground
  Future<void> handleAppForeground() async {
    try {
      debugPrint("App coming to foreground, reactivating audio session...");
      
      // Reconfigure the audio session when app comes to foreground
      await _audioSession?.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowAirPlay |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      
      // If audio was playing, ensure it's still properly configured
      if (_audioPlayer.playing && _currentIndex >= 0 && _currentIndex < _playlist.length) {
        final currentItem = mediaItem.value;
        if (currentItem != null && currentItem.extras?['isLocal'] == true) {
          // For local files, ensure the audio source is still valid
          try {
            final source = AudioSource.uri(Uri.file(currentItem.id));
            await _audioPlayer.setAudioSource(source, preload: false);
            debugPrint("Re-ensured audio source for local file on foreground: ${currentItem.title}");
          } catch (e) {
            debugPrint("Error re-ensuring audio source for local file on foreground: $e");
          }
        }
        
        debugPrint("Forcing audio session reactivation to ensure audio is audible...");
        await forceAudioSessionReactivation();
      }
      
      debugPrint("Audio session reactivated for foreground");
    } catch (e) {
      debugPrint("Error handling app foreground: $e");
    }
  }

  // Set up periodic audio session maintenance
  void _setupAudioSessionMaintenance() {
    // Check audio session every 15 seconds when playing (more frequent for iOS)
    Timer.periodic(Duration(seconds: 15), (timer) async {
      if (_audioPlayer.playing && _currentIndex >= 0 && _currentIndex < _playlist.length) {
        try {
          await ensureBackgroundPlayback();
          
          // Additional check for local files to ensure they're still properly loaded
          final currentItem = mediaItem.value;
          if (currentItem != null && currentItem.extras?['isLocal'] == true) {
            // Verify the audio source is still valid for local files
            try {
              final source = AudioSource.uri(Uri.file(currentItem.id));
              await _audioPlayer.setAudioSource(source, preload: false);
              debugPrint("Periodic maintenance: Re-ensured local file source for ${currentItem.title}");
            } catch (e) {
              debugPrint("Periodic maintenance: Error re-ensuring local file source: $e");
            }
          }
        } catch (e) {
          debugPrint("Error in periodic audio session maintenance: $e");
        }
      }
    });
  }

  // Method to force audio session reactivation
  Future<void> forceAudioSessionReactivation() async {
    try {
      debugPrint("Forcing audio session reactivation...");
      
      // Pause and resume to force audio session reactivation
      if (_audioPlayer.playing) {
        final wasPlaying = _audioPlayer.playing;
        final position = _audioPlayer.position;
        
        await _audioPlayer.pause();
        await Future.delayed(Duration(milliseconds: 200));
        
        await ensureBackgroundPlayback();
        
        if (wasPlaying) {
          await _audioPlayer.seek(position);
          await _audioPlayer.play();
        }
        
        debugPrint("Audio session reactivation completed");
      }
    } catch (e) {
      debugPrint("Error forcing audio session reactivation: $e");
    }
  }

  // Method to specifically handle iOS background audio session activation
  Future<void> _activateIOSBackgroundAudioSession() async {
    try {
      if (_audioSession == null) {
        await _initializeAudioSession();
        return;
      }
      
      // Configure audio session for iOS background playback
      await _audioSession!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowAirPlay |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      
      // Log current state for debugging
      final currentItem = mediaItem.value;
      debugPrint("iOS background audio session activated - "
          "Playing: ${_audioPlayer.playing}, "
          "ProcessingState: ${_audioPlayer.processingState}, "
          "CurrentItem: ${currentItem?.title}, "
          "IsLocal: ${currentItem?.extras?['isLocal']}");
      
    } catch (e) {
      debugPrint("Error activating iOS background audio session: $e");
    }
  }

  // Handle metadata‐update requests so MediaSession (and Bluetooth) sees new metadata
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'updateCurrentMediaItemMetadata') {
      final mediaMap = extras?['mediaItem'] as Map<String, dynamic>?;
      if (mediaMap != null) {
        final currentItem = mediaItem.value;
        // Ensure we have a current item and a valid index
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
          // Update the item in the playlist to maintain state consistency
          _playlist[_currentIndex] = updatedItem;
          // Broadcast the updated media item
          mediaItem.add(updatedItem);
          // Broadcast the updated queue to reflect the metadata change
          queue.add(List.unmodifiable(_playlist));
        }
      }
    } else if (name == 'setQueueIndex') {
      final index = extras?['index'] as int?;
      if (index != null && index >= 0 && index < _playlist.length) {
        // Only update the index, do not trigger playback.
        // This is used for things like shuffle where the song should continue playing.
        _currentIndex = index;
        playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
      }
    } else if (name == 'prepareToPlay') {
      final index = extras?['index'] as int?;
      if (index != null) {
        await _prepareToPlay(index);
      }
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
        // Logic from playMediaItem but without playing
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
      // Navigate to download queue screen using global navigator key
      final navigator = globalNavigatorKey.currentState;
      if (navigator != null) {
        navigator.push(
          MaterialPageRoute(
            builder: (context) => const DownloadQueueScreen(),
          ),
        );
      }
    } else if (name == 'ensureBackgroundPlayback') {
      // Ensure background playback is properly configured
      await ensureBackgroundPlayback();
    } else if (name == 'handleAppForeground') {
      // Handle app coming back to foreground
      await handleAppForeground();
    
      // Force audio session reactivation
      await forceAudioSessionReactivation();
    } else if (name == 'activateIOSBackgroundAudio') {
      // Specifically activate iOS background audio session
      await _activateIOSBackgroundAudioSession();
    }
    return null;
  }
}