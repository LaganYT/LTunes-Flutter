import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/song.dart'; // Assuming Song model can give necessary info
import 'package:audio_session/audio_session.dart';
import '../screens/download_queue_screen.dart'; // Import DownloadQueueScreen

// Global navigator key for showing dialogs from anywhere
final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

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
  bool _isIOS = Platform.isIOS;
  bool _audioSessionConfigured = false;
  bool _isBackgroundMode = false;
  bool _isPlayingLocalFile = false;
  Timer? _backgroundSessionTimer;

  AudioPlayerHandler() {
    // Initialize audio session properly for iOS background playback
    _initializeAudioSession();

    _notifyAudioHandlerAboutPlaybackEvents();

    // Listen for app lifecycle changes
    _setupAppLifecycleListener();
  }

  void _setupAppLifecycleListener() {
    // This will be called by the main app when lifecycle changes
    // We'll handle it through custom actions
  }

  Future<void> _initializeAudioSession() async {
    if (_audioSessionConfigured) return; // Already configured
    
    try {
      _audioSession = await AudioSession.instance;
      
      // Enhanced audio session configuration for iOS background playback
      await _audioSession!.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
      
      // For iOS, also configure the session to be more persistent
      if (_isIOS) {
        try {
          // Set the session to be more aggressive about staying active
          await _audioSession!.setActive(true);
          debugPrint("iOS audio session configured for persistent background playback");
          
          // For local files, we need to be even more aggressive about session persistence
          // This is because iOS treats local files differently from remote files
          debugPrint("iOS audio session configured with enhanced local file support");
        } catch (e) {
          debugPrint("Error configuring iOS audio session for persistence: $e");
        }
      }
      
      // For iOS, activate the session immediately
      if (_isIOS) {
        await _audioSession!.setActive(true);
        debugPrint("iOS audio session activated for background playback");
        
        // Listen for audio session interruptions
        _audioSession!.interruptionEventStream.listen(_handleAudioInterruption);
        _audioSession!.becomingNoisyEventStream.listen((_) => _handleBecomingNoisy());
        
        // Start background session maintenance timer for iOS
        _startBackgroundSessionTimer();
      }
      
      _audioSessionConfigured = true;
      debugPrint("Audio session configured for background playback");
    } catch (e) {
      debugPrint("Error configuring audio session: $e");
      // Continue anyway - let just_audio handle the session
    }
  }

  void _startBackgroundSessionTimer() {
    if (!_isIOS) return;
    
    // Cancel existing timer if any
    _backgroundSessionTimer?.cancel();
    
    // Start a timer that periodically ensures the audio session stays active
    // This is especially important for local files in background mode
    _backgroundSessionTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (_isBackgroundMode && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS background session maintenance: session reactivated");
          
          // For local files, add additional persistence
          if (_isPlayingLocalFile) {
            // Add a small delay and reactivate again for local files
            await Future.delayed(const Duration(milliseconds: 100));
            await _audioSession!.setActive(true);
            debugPrint("iOS background session maintenance: additional persistence for local files");
          }
        } catch (e) {
          debugPrint("iOS background session maintenance error: $e");
        }
      }
    });
  }

  void _stopBackgroundSessionTimer() {
    _backgroundSessionTimer?.cancel();
    _backgroundSessionTimer = null;
  }

  Timer? _continuousBackgroundTimer;
  
  void _startContinuousBackgroundSessionMaintenance() {
    if (!_isIOS || !_isBackgroundMode || _audioSession == null) return;
    
    // Cancel existing continuous timer if any
    _continuousBackgroundTimer?.cancel();
    
    // Start a more aggressive timer for background mode
    _continuousBackgroundTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_isBackgroundMode && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS continuous background session maintenance: session reactivated");
          
          // For local files, add additional persistence
          if (_isPlayingLocalFile) {
            await Future.delayed(const Duration(milliseconds: 50));
            await _audioSession!.setActive(true);
            debugPrint("iOS continuous background session maintenance: additional persistence");
          }
        } catch (e) {
          debugPrint("iOS continuous background session maintenance error: $e");
        }
      } else {
        // Stop the timer if we're no longer in background mode
        timer.cancel();
        _continuousBackgroundTimer = null;
      }
    });
  }

  void _stopContinuousBackgroundSessionMaintenance() {
    _continuousBackgroundTimer?.cancel();
    _continuousBackgroundTimer = null;
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    debugPrint("Audio interruption: ${event.type} - ${event.begin}");
    
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          // Lower volume but continue playing
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // Pause playback
          if (_audioPlayer.playing) {
            _audioPlayer.pause();
          }
          break;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          // Restore volume
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // Resume playback if it was playing before
          if (!_audioPlayer.playing && _currentIndex >= 0) {
            _audioPlayer.play();
          }
          break;
      }
    }
  }

  void _handleBecomingNoisy() {
    debugPrint("Audio becoming noisy - pausing playback");
    if (_audioPlayer.playing) {
      _audioPlayer.pause();
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
    _isPlayingLocalFile = itemToPlay.extras?['isLocal'] as bool? ?? false;
    
    // Enhanced debugging for iOS background playback
    if (_isIOS) {
      debugPrint("iOS: Preparing to play - Local: $_isPlayingLocalFile, Background: $_isBackgroundMode, Title: ${itemToPlay.title}");
    }
    
    AudioSource source;
    if (_isPlayingLocalFile) {
      // Use AudioSource.file for local files - more reliable on iOS
      final filePath = itemToPlay.id;
      final file = File(filePath);
      final exists = await file.exists();
      debugPrint("Preparing local file: ${itemToPlay.title} at path: $filePath, exists: $exists");
      
      if (!exists) {
        debugPrint("ERROR: Local file does not exist: $filePath");
        throw Exception("Local file not found: $filePath");
      }
      
      source = AudioSource.file(filePath);
      
      // For iOS local files, ensure audio session is active and properly configured
      if (_isIOS && _audioSession != null) {
        try {
          // Ensure audio session is active for local file playback
          await _audioSession!.setActive(true);
          debugPrint("iOS audio session activated for local file playback");
          
          // For background playback, we need to ensure the session stays active
          if (_isBackgroundMode) {
            debugPrint("iOS background mode detected for local file");
            // Add a longer delay for background mode to ensure session persistence
            await Future.delayed(const Duration(milliseconds: 200));
          }
        } catch (e) {
          debugPrint("Error activating iOS audio session for local file: $e");
          // Don't throw - let just_audio handle it
        }
      }
    } else {
      source = AudioSource.uri(Uri.parse(itemToPlay.id));
      debugPrint("Preparing remote file: ${itemToPlay.title} at URL: ${itemToPlay.id}");
    }

    try {
      // Set source but do not play.
      await _audioPlayer.setAudioSource(source);
      
      // Reset position to 0:00 when a new song is prepared
      // This ensures the seekbar shows the beginning of the song
      playbackState.add(playbackState.value.copyWith(
        updatePosition: Duration.zero,
      ));
      
      debugPrint("Successfully prepared audio source for: ${itemToPlay.title}");
      
      // For iOS local files, ensure audio session is maintained after setting source
      if (_isIOS && _isPlayingLocalFile && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS: Audio session maintained after setting local file source");
          
          // For background mode, add additional session persistence
          if (_isBackgroundMode) {
            debugPrint("iOS background mode: ensuring persistent session after source set");
            await Future.delayed(const Duration(milliseconds: 150));
            await _audioSession!.setActive(true);
            
            // For local files in background mode, add even more persistence
            await Future.delayed(const Duration(milliseconds: 300));
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode with local file: enhanced session persistence");
            
            // Add even more aggressive session maintenance for background mode
            await Future.delayed(const Duration(milliseconds: 500));
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: final session persistence after source set");
            
            // Start continuous session maintenance for background mode
            _startContinuousBackgroundSessionMaintenance();
          }
        } catch (e) {
          debugPrint("iOS: Error maintaining audio session after setting source: $e");
        }
      }
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
    _audioPlayer.playerStateStream.listen((playerState) async {
      final playing = playerState.playing;
      final processingState = playerState.processingState;
      
      // Debug logging for iOS background playback
      if (_isIOS) {
        debugPrint("iOS Player State - Playing: $playing, ProcessingState: $processingState");
        
        // For iOS local files in background mode, ensure session stays active
        if (_isBackgroundMode && _isPlayingLocalFile && _audioSession != null && playing) {
          try {
            await _audioSession!.setActive(true);
            debugPrint("iOS background session check: session maintained during playback");
            
            // Add additional session maintenance for background mode
            await Future.delayed(const Duration(milliseconds: 50));
            await _audioSession!.setActive(true);
            debugPrint("iOS background session check: additional maintenance during playback");
            
            // Start continuous session maintenance if not already running
            _startContinuousBackgroundSessionMaintenance();
          } catch (e) {
            debugPrint("iOS background session check error: $e");
          }
        }
      }
      
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

    _audioPlayer.positionStream.listen((position) async {
      final currentItem = mediaItem.value;
      final isStreaming = currentItem?.extras?['isLocal'] == false;
      
      // For iOS local files in background mode, periodically ensure session stays active
      if (_isIOS && _isPlayingLocalFile && _isBackgroundMode && _audioSession != null) {
        // Only check every 10 seconds to avoid too frequent calls
        if (position.inSeconds % 10 == 0 && position.inSeconds > 0) {
          try {
            await _audioSession!.setActive(true);
            debugPrint("iOS background session check during playback at ${position.inSeconds}s");
            
            // Add additional session maintenance for background mode
            await Future.delayed(const Duration(milliseconds: 50));
            await _audioSession!.setActive(true);
            debugPrint("iOS background session check: additional maintenance");
          } catch (e) {
            debugPrint("iOS background session check error during playback: $e");
          }
        }
        
        // For background mode, also check every 30 seconds for more aggressive maintenance
        if (position.inSeconds % 30 == 0 && position.inSeconds > 0) {
          try {
            await _audioSession!.setActive(true);
            debugPrint("iOS background session aggressive maintenance at ${position.inSeconds}s");
            
            // Start continuous session maintenance if not already running
            _startContinuousBackgroundSessionMaintenance();
          } catch (e) {
            debugPrint("iOS background session aggressive maintenance error: $e");
          }
        }
      }
      
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
      // Debug logging for iOS background playback
      if (_isIOS) {
        debugPrint("iOS Processing State: $state");
      }
      
              // For iOS local files in background mode, ensure session stays active when ready
        if (_isIOS && _isPlayingLocalFile && _isBackgroundMode && _audioSession != null && state == ProcessingState.ready) {
          try {
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: session maintained when ready");
          } catch (e) {
            debugPrint("Error maintaining iOS session when ready: $e");
          }
        }
      
      if (state == ProcessingState.completed) {
        debugPrint("Song completed, handling next track...");
        
        // Enhanced iOS audio session handling for track transitions
        if (_isIOS && _audioSession != null) {
          try {
            // Ensure audio session stays active during track transitions
            await _audioSession!.setActive(true);
            debugPrint("iOS audio session maintained for track transition");
            
            // For local files in background mode, ensure stronger session persistence
            if (_isBackgroundMode && _isPlayingLocalFile) {
              debugPrint("iOS background mode with local file: ensuring audio session persistence");
              // Add a longer delay for background mode to ensure session persistence
              await Future.delayed(const Duration(milliseconds: 300));
              // Reactivate session again after delay
              await _audioSession!.setActive(true);
              debugPrint("iOS background mode: session reactivated after delay");
              
              // For local files, add additional session maintenance
              await Future.delayed(const Duration(milliseconds: 500));
              await _audioSession!.setActive(true);
              debugPrint("iOS background mode with local file: additional session maintenance");
              
              // Add even more aggressive session maintenance for background mode
              await Future.delayed(const Duration(milliseconds: 1000));
              await _audioSession!.setActive(true);
              debugPrint("iOS background mode: final session maintenance check");
              
              // Start a continuous session maintenance loop for background mode
              _startContinuousBackgroundSessionMaintenance();
            }
          } catch (e) {
            debugPrint("Error maintaining iOS audio session during track transition: $e");
            // Don't throw - let just_audio handle it
          }
        }
        
        // Handle song completion based on repeat mode
        final repeatMode = playbackState.value.repeatMode;
        
        if (repeatMode == AudioServiceRepeatMode.one) {
          // For repeat one, the just_audio loop mode should handle this automatically
          // But we need to ensure the UI state is correct
          if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
            try {
              await _prepareToPlay(_currentIndex);
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
            await skipToNext();
            debugPrint("Skipped to next song");
            
            // For iOS local files in background mode, ensure session stays active after transition
            if (_isIOS && _isPlayingLocalFile && _isBackgroundMode && _audioSession != null) {
              try {
                await Future.delayed(const Duration(milliseconds: 500));
                await _audioSession!.setActive(true);
                debugPrint("iOS background mode: session maintained after track transition");
                
                // Add another check after a longer delay
                await Future.delayed(const Duration(seconds: 2));
                await _audioSession!.setActive(true);
                debugPrint("iOS background mode: session maintained after 2 second delay");
                
                // Add even more aggressive session maintenance for background mode
                await Future.delayed(const Duration(seconds: 3));
                await _audioSession!.setActive(true);
                debugPrint("iOS background mode: final session maintenance after track transition");
                
                // Start continuous session maintenance for background mode
                _startContinuousBackgroundSessionMaintenance();
              } catch (e) {
                debugPrint("Error maintaining iOS session after track transition: $e");
              }
            }
          } catch (e) {
            debugPrint("Error skipping to next song: $e");
            if (_isRadioStream && _currentIndex >= 0 && _currentIndex < _playlist.length) {
              _showRadioErrorDialog(_playlist[_currentIndex].title);
            }
          }
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

    // Enhanced iOS audio session handling before playing
    if (_isIOS && _audioSession != null) {
      try {
        await _audioSession!.setActive(true);
        debugPrint("iOS audio session activated before play");
        
        // For local files in background mode, ensure stronger session activation
        if (_isBackgroundMode && _isPlayingLocalFile) {
          debugPrint("iOS background mode with local file: ensuring strong session activation");
          // Add a small delay to ensure the session is properly activated
          await Future.delayed(const Duration(milliseconds: 50));
        }
      } catch (e) {
        debugPrint("Error activating iOS audio session before play: $e");
        // Don't throw - let just_audio handle it
      }
    }

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
        // Enhanced iOS audio session handling before playing
        if (_isIOS && _audioSession != null) {
          try {
            await _audioSession!.setActive(true);
            debugPrint("iOS audio session activated before skip to queue item");
            
            // For local files in background mode, ensure stronger session activation
            if (_isBackgroundMode && _isPlayingLocalFile) {
              debugPrint("iOS background mode with local file: ensuring strong session activation for skip");
              // Add a longer delay for background mode to ensure session persistence
              await Future.delayed(const Duration(milliseconds: 200));
              // Reactivate session again after delay
              await _audioSession!.setActive(true);
              debugPrint("iOS background mode: session reactivated before play");
            }
          } catch (e) {
            debugPrint("Error activating iOS audio session before skip: $e");
            // Don't throw - let just_audio handle it
          }
        }

        await _audioPlayer.play();
        
        // Ensure the playback state is correctly set to playing
        playbackState.add(playbackState.value.copyWith(
          playing: true,
          processingState: AudioProcessingState.ready,
        ));
        
        // For iOS local files in background mode, ensure session stays active after play
        if (_isIOS && _isPlayingLocalFile && _isBackgroundMode && _audioSession != null) {
          try {
            await Future.delayed(const Duration(milliseconds: 100));
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: session maintained after play");
          } catch (e) {
            debugPrint("Error maintaining iOS audio session after play: $e");
          }
        }
        
        // For iOS local files in background mode, ensure session stays active
        if (_isIOS && _isPlayingLocalFile && _isBackgroundMode && _audioSession != null) {
          try {
            await Future.delayed(const Duration(milliseconds: 200));
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: session maintained after skip to queue item");
          } catch (e) {
            debugPrint("Error maintaining iOS audio session after skip to queue item: $e");
          }
        }
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

  // Playback speed control methods
  Future<void> setPlaybackSpeed(double speed) async {
    try {
      // Set speed and let pitch change naturally (like vinyl/tape)
      await _audioPlayer.setSpeed(speed);
      // Set pitch to match speed change (pitch up when speeding up, pitch down when slowing down)
      await _audioPlayer.setPitch(speed);
      debugPrint("Playback speed set to: $speed with natural pitch change");
    } catch (e) {
      debugPrint("Error setting playback speed: $e");
    }
  }

  double get currentPlaybackSpeed {
    return _audioPlayer.speed;
  }

  Future<void> resetPlaybackSpeed() async {
    try {
      await _audioPlayer.setSpeed(1.0);
      await _audioPlayer.setPitch(1.0);
      debugPrint("Playback speed and pitch reset to normal");
    } catch (e) {
      debugPrint("Error resetting playback speed: $e");
    }
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
    // Let audio_service handle background playback automatically
    return super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Don't pause when notification is deleted to allow background playback
    return super.onNotificationDeleted();
  }

  // Enhanced method to ensure background playback
  Future<void> ensureBackgroundPlayback() async {
    try {
      debugPrint("Ensuring background playback...");
      
      // For iOS, ensure audio session is properly configured for background
      if (_isIOS && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          _isBackgroundMode = true;
          debugPrint("iOS audio session activated for background playback");
          
          // For local files, ensure stronger background session persistence
          if (_isPlayingLocalFile) {
            debugPrint("iOS background mode with local file: ensuring persistent session");
            // Add a longer delay to ensure the session is properly maintained
            await Future.delayed(const Duration(milliseconds: 200));
            // Reactivate session again after delay
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: session reactivated after delay");
          }
          
          // Restart background session timer
          _startBackgroundSessionTimer();
        } catch (e) {
          debugPrint("Error activating iOS audio session for background: $e");
        }
      }
      
      debugPrint("Background playback ensured");
    } catch (e) {
      debugPrint("Error ensuring background playback: $e");
    }
  }

  // Enhanced method to handle app coming back to foreground
  Future<void> handleAppForeground() async {
    try {
      debugPrint("App coming to foreground...");
      
      _isBackgroundMode = false;
      
      // Stop background session timers when app comes to foreground
      _stopBackgroundSessionTimer();
      _stopContinuousBackgroundSessionMaintenance();
      
      // For iOS, ensure audio session is active if playing
      if (_isIOS && _audioSession != null && _audioPlayer.playing) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS audio session reactivated for foreground");
          
          // For local files, ensure session is properly reactivated
          if (_isPlayingLocalFile) {
            debugPrint("iOS foreground with local file: ensuring session reactivation");
            // Add a small delay to ensure the session is properly reactivated
            await Future.delayed(const Duration(milliseconds: 50));
          }
        } catch (e) {
          debugPrint("Error reactivating iOS audio session: $e");
          // Don't throw - let just_audio handle it
        }
      }
      
      debugPrint("App foreground handling completed");
    } catch (e) {
      debugPrint("Error handling app foreground: $e");
    }
  }

  // Clean up resources when the handler is disposed
  Future<void> dispose() async {
    _stopBackgroundSessionTimer();
    _stopContinuousBackgroundSessionMaintenance();
    await _audioPlayer.dispose();
  }

  // Enhanced method to handle app entering background
  Future<void> handleAppBackground() async {
    try {
      debugPrint("App entering background...");
      
      _isBackgroundMode = true;
      
      // For iOS, ensure audio session stays active for background playback
      if (_isIOS && _audioSession != null && _audioPlayer.playing) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS audio session maintained for background");
          
          // For local files, ensure stronger background session persistence
          if (_isPlayingLocalFile) {
            debugPrint("iOS background mode with local file: ensuring persistent background session");
            // Add a longer delay to ensure the session is properly maintained
            await Future.delayed(const Duration(milliseconds: 200));
            // Reactivate session again after delay
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: session reactivated for background");
            
            // Add even more aggressive session maintenance for background mode
            await Future.delayed(const Duration(milliseconds: 500));
            await _audioSession!.setActive(true);
            debugPrint("iOS background mode: final session maintenance for background");
          }
          
          // Restart background session timer
          _startBackgroundSessionTimer();
          
          // Start continuous session maintenance for background mode
          _startContinuousBackgroundSessionMaintenance();
        } catch (e) {
          debugPrint("Error maintaining iOS audio session for background: $e");
        }
      }
      
      debugPrint("App background handling completed");
    } catch (e) {
      debugPrint("Error handling app background: $e");
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
    } else if (name == 'handleAppBackground') {
      // Handle app entering background
      await handleAppBackground();
    } else if (name == 'forceSessionActivation') {
      // Force audio session activation for iOS background playback
      if (_isIOS && _audioSession != null) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS: Forced audio session activation");
          
          // For local files in background mode, add additional persistence
          if (_isBackgroundMode && _isPlayingLocalFile) {
            await Future.delayed(const Duration(milliseconds: 200));
            await _audioSession!.setActive(true);
            debugPrint("iOS: Forced audio session activation with persistence");
            
            // Start continuous session maintenance for background mode
            _startContinuousBackgroundSessionMaintenance();
          }
        } catch (e) {
          debugPrint("Error forcing iOS audio session activation: $e");
        }
      }
    } else if (name == 'ensureBackgroundPlaybackContinuity') {
      // Ensure background playback continuity for iOS
      if (_isIOS && _audioSession != null && _isBackgroundMode) {
        try {
          await _audioSession!.setActive(true);
          debugPrint("iOS: Ensuring background playback continuity");
          
          // For local files, add additional persistence
          if (_isPlayingLocalFile) {
            await Future.delayed(const Duration(milliseconds: 100));
            await _audioSession!.setActive(true);
            debugPrint("iOS: Background playback continuity with persistence");
            
            // Start continuous session maintenance
            _startContinuousBackgroundSessionMaintenance();
          }
        } catch (e) {
          debugPrint("Error ensuring background playback continuity: $e");
        }
      }
    }
    return null;
  }
}