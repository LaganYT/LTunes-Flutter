import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:path/path.dart' as p; // Import path package
import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart'; // Assumed path to your audio_handler.dart
import 'dart:async';
import '../models/lyrics_data.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:http/http.dart' as http;
import '../services/download_notification_service.dart';

// Define LoopMode enum
enum LoopMode { none, queue, song }

class CurrentSongProvider with ChangeNotifier {
  // final AudioPlayer _audioPlayer = AudioPlayer(); // Removed
  final AudioHandler _audioHandler;
  Song? _currentSongFromAppLogic; // Represents the song our app thinks is current
  bool _isPlaying = false;
  // bool _isLooping = false; // Replaced by LoopMode logic derived from audio_handler
  bool _isShuffling = false; // Manage shuffle state by shuffling queue once
  List<Song> _queue = [];
  // ignore: unused_field
  List<Song> _unshuffledQueue = [];
  int _currentIndexInAppQueue = -1; // Index in the _queue (app's perspective)

  DownloadManager? _downloadManager;
  bool _isDownloadManagerInitialized = false;

  // _activeDownloads will now track the single song actively being processed by the provider's logic
  final Map<String, Song> _activeDownloads = {}; 
  
  // New: Provider-level download queue and processing flag
  final List<Song> _downloadQueue = [];
  // ignore: unused_field
  bool _isProcessingProviderDownload = false;

  int _playRequestCounter = 0;

  bool _isLoadingAudio = false; // For UI feedback when initiating play
  final Map<String, double> _downloadProgress = {}; // songId -> progress (0.0 to 1.0)
  Duration _currentPosition = Duration.zero;
  Duration? _totalDuration;

  // Radio specific, might be derivable from MediaItem
  String? _stationName;
  String? get stationName => _stationName;
  String? _stationFavicon;
  String? get stationFavicon => _stationFavicon;

  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _mediaItemSubscription;
  StreamSubscription? _queueSubscription;
  StreamSubscription? _positionSubscription;
  
  // Download notification service
  final DownloadNotificationService _downloadNotificationService = DownloadNotificationService();

  Song? get currentSong => _currentSongFromAppLogic;
  bool get isPlaying => _isPlaying;

  // Add public getter for audioHandler
  AudioHandler get audioHandler => _audioHandler;

  // Getter for LoopMode based on AudioHandler's state
  LoopMode get loopMode {
    // Always derive from audio_handler's playbackState
    final currentAudioHandlerMode = _audioHandler.playbackState.value.repeatMode;
    switch (currentAudioHandlerMode) {
      case AudioServiceRepeatMode.none:
        return LoopMode.none;
      case AudioServiceRepeatMode.all:
        return LoopMode.queue;
      case AudioServiceRepeatMode.one:
        return LoopMode.song;
      default:
        return LoopMode.none;
    }
  }

  bool get isShuffling => _isShuffling;

  void updateDownloadedSong(Song updatedSong) {
    // Update the current song if it matches the updated song
    if (currentSong?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      notifyListeners();
    }
  }

  void _updateDownloadNotification() async {
    // Check if notifications are enabled before showing
    final notificationsEnabled = await _downloadNotificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      return;
    }
    
    _downloadNotificationService.updateDownloadProgress(
      activeDownloads: _activeDownloads,
      queuedSongs: _downloadQueue,
      downloadProgress: _downloadProgress,
    );
  }

  Future<void> handleDownloadNotificationAction(String action) async {
    switch (action) {
      case 'cancel_all':
        await cancelAllDownloads();
        break;
      case 'view_queue':
        // Send custom action to audio handler for navigation
        _audioHandler.customAction('openDownloadQueue', {});
        break;
      default:
    }
  }

  // Method to request notification permissions
  Future<bool> requestNotificationPermissions() async {
    final notificationsEnabled = await _downloadNotificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      return await _downloadNotificationService.areNotificationsEnabled();
    }
    return true;
  }

  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  // bool get isDownloadingSong => _isDownloadingSong; // Changed
  bool get isDownloadingSong => _downloadProgress.isNotEmpty; // Changed
  Map<String, Song> get activeDownloadTasks => Map.unmodifiable(_activeDownloads); // Added
  List<Song> get songsQueuedForDownload => List.unmodifiable(_downloadQueue); // Added
  bool get isLoadingAudio => _isLoadingAudio;
  Duration? get totalDuration => _totalDuration;
  Duration get currentPosition => _currentPosition;
  // Stream<Duration> get onPositionChanged => _audioPlayer.onPositionChanged; // Replaced
  Stream<Duration> get positionStream => AudioService.position; // UI should listen to this for seekbar

  bool get isCurrentlyPlayingRadio {
    final mediaItem = _audioHandler.mediaItem.value;
    return mediaItem?.extras?['isRadio'] as bool? ?? false;
  }

  CurrentSongProvider(this._audioHandler) {
    _initializeDownloadManager(); // Initialize DownloadManager
    _loadCurrentSongFromStorage(); // Load last playing song and queue
    _listenToAudioHandler();
    
    // Set up download notification action callback
    _downloadNotificationService.setNotificationActionCallback(handleDownloadNotificationAction);
  }

  Future<String?> _downloadAlbumArt(String url, Song song) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      
      String albumIdentifier;
      if (song.album != null && song.album!.isNotEmpty) {
        albumIdentifier = '${song.album}_${song.artist}'.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      } else {
        // Fallback to song ID if no album info, to avoid overwriting art for songs with no album
        albumIdentifier = song.id;
      }

      final uri = Uri.parse(url);
      String extension = p.extension(uri.path);
      if (extension.isEmpty || extension.length > 5 || !extension.startsWith('.')) {
        extension = '.jpg';
      }
      final fileName = 'art_$albumIdentifier$extension';
      final filePath = p.join(directory.path, fileName);
      final file = File(filePath);

      if (await file.exists()) {
        return fileName;
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('Album art downloaded to: $filePath');
        return fileName; // Return just the filename
      } else {
        debugPrint('Failed to download album art. Status code: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("Exception downloading album art from $url: $e");
    }
    return null;
  }

  Future<void> _initializeDownloadManager() async {
    if (_isDownloadManagerInitialized && _downloadManager != null) {
      // Already initialized
      return;
    }
    try {
      final baseDir = await getApplicationDocumentsDirectory();
      _downloadManager = DownloadManager(
        subDir: 'ltunes_downloads',
        baseDirectory: baseDir,
        fileExistsStrategy: FileExistsStrategy.resume,
        maxRetries: 2,
        maxConcurrentDownloads: 1000000,
        delayBetweenRetries: const Duration(seconds: 2),
        logger: (log) => debugPrint('[DownloadManager:${log.level.name}] ${log.message}'),
      );
      // start the internal downloader loop so it will pick up any newly enqueued items
      // No explicit start method required for DownloadManager in this version.
      _isDownloadManagerInitialized = true;
    } catch (e) {
      debugPrint("Failed to initialize DownloadManager: $e");
      _isDownloadManagerInitialized = false;
      _downloadManager = null;
    }
  }

  void _listenToAudioHandler() {
    // Listen to playback state for play/pause/loading
    _playbackStateSubscription = _audioHandler.playbackState.listen((playbackState) {
      final oldIsPlaying = _isPlaying;
      final oldIsLoading = _isLoadingAudio;

      _isPlaying = playbackState.playing;
      _isLoadingAudio = playbackState.processingState == AudioProcessingState.loading ||
          playbackState.processingState == AudioProcessingState.buffering;

      // Save state on pause
      if (oldIsPlaying && !_isPlaying) {
        _saveCurrentSongToStorage();
      }

      // Notify UI if play/pause/loading state changed
      if (oldIsPlaying != _isPlaying || oldIsLoading != _isLoadingAudio) {
        notifyListeners();
      }
    });

    // Listen to media item changes for song/metadata updates
    _mediaItemSubscription = _audioHandler.mediaItem.listen((mediaItem) async {
      bool needsNotification = false;

      // Update _totalDuration.
      // For radio streams, duration will be null, and we handle it as a "live" stream.
      // For regular tracks, this will update when audio_handler gets the duration.
      if (_totalDuration != mediaItem?.duration) {
        _totalDuration = mediaItem?.duration;
        needsNotification = true;
      }

      // Update _currentSongFromAppLogic, _stationName, _stationFavicon
      if (mediaItem == null) {
        if (_currentSongFromAppLogic != null) { _currentSongFromAppLogic = null; needsNotification = true; }
        // _totalDuration already handled above or by radio logic in _positionSubscription
        if (_stationName != null) { _stationName = null; needsNotification = true; }
        if (_stationFavicon != null) { _stationFavicon = null; needsNotification = true; }
      } else {
        Song? newCurrentSongLogicCandidate;
        String? newStationNameCandidate;
        String? newStationFaviconCandidate;

        if (mediaItem.extras?['isRadio'] as bool? ?? false) {
          final radioSongId = mediaItem.extras!['songId'] as String? ?? mediaItem.id;
          newCurrentSongLogicCandidate = Song(
              id: radioSongId,
              title: mediaItem.title,
              artist: mediaItem.artist ?? 'Radio',
              artistId: mediaItem.extras?['artistId'] as String? ?? '',
              albumArtUrl: mediaItem.artUri?.toString() ?? '',
              audioUrl: mediaItem.id,
              isDownloaded: false,
              extras: {'isRadio': true}
          );
          newStationNameCandidate = newCurrentSongLogicCandidate.title;
          newStationFaviconCandidate = newCurrentSongLogicCandidate.albumArtUrl;
          // For radio, _totalDuration is handled in _positionSubscription
        } else{
          final songId = mediaItem.extras?['songId'] as String?;
          if (songId != null) {
            newCurrentSongLogicCandidate = _queue.firstWhere((s) => s.id == songId,
                orElse: () {
                  return Song(
                    id: songId,
                    title: mediaItem.title,
                    artist: mediaItem.artist ?? 'Unknown Artist',
                    artistId: mediaItem.extras?['artistId'] as String? ?? '',
                    album: mediaItem.album,
                    albumArtUrl: mediaItem.artUri?.toString() ?? '',
                    audioUrl: mediaItem.id,
                    isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
                    localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false)
                        ? p.basename(mediaItem.id)
                        : null,
                  );
                });
          } else {
            newCurrentSongLogicCandidate = Song(
              id: mediaItem.id,
              title: mediaItem.title,
              artist: mediaItem.artist ?? 'Unknown Artist',
              artistId: mediaItem.extras?['artistId'] as String? ?? '',
              album: mediaItem.album,
              albumArtUrl: await _resolveArtUriPath(mediaItem),
              audioUrl: mediaItem.id,
              isDownloaded: mediaItem.extras?['isLocal'] as bool? ?? false,
              localFilePath: (mediaItem.extras?['isLocal'] as bool? ?? false)
                  ? p.basename(mediaItem.id)
                  : null,
            );
          }
          newStationNameCandidate = null;
          newStationFaviconCandidate = null;
        }

        if (_currentSongFromAppLogic?.id != newCurrentSongLogicCandidate.id ||
            _currentSongFromAppLogic?.title != newCurrentSongLogicCandidate.title ||
            _currentSongFromAppLogic?.artist != newCurrentSongLogicCandidate.artist ||
            _currentSongFromAppLogic?.albumArtUrl != newCurrentSongLogicCandidate.albumArtUrl) {
          _currentSongFromAppLogic = newCurrentSongLogicCandidate;
          needsNotification = true;
        }
        if (_currentSongFromAppLogic != null) {
          final newIndex = _queue.indexWhere((s) => s.id == _currentSongFromAppLogic!.id);
          if (newIndex != -1 && _currentIndexInAppQueue != newIndex) {
            _currentIndexInAppQueue = newIndex;
            needsNotification = true;
          }
        } else if (_currentSongFromAppLogic == null && _currentIndexInAppQueue != -1) {
          _currentIndexInAppQueue = -1;
          needsNotification = true;
        }
        if (_stationName != newStationNameCandidate) { _stationName = newStationNameCandidate; needsNotification = true; }
        if (_stationFavicon != newStationFaviconCandidate) { _stationFavicon = newStationFaviconCandidate; needsNotification = true; }
      }

      if (needsNotification) {
        notifyListeners();
      }
    });

    // Listen to position stream for seekbar and lyrics sync
    _positionSubscription = AudioService.position.listen((position) {
      _currentPosition = position;
      notifyListeners(); // UI seekbar and lyrics sync
    });
  }

  Future<String> _resolveArtUriPath(MediaItem item) async {
    if (item.artUri != null && item.artUri.toString().startsWith('http')) {
      return item.artUri.toString();
    }
    if (item.extras?['localArtFileName'] != null) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, item.extras!['localArtFileName'] as String);
      if (await File(fullPath).exists()) {
        // For local files, albumArtUrl in Song model should store filename.
        // If artUri was file://, this logic might need adjustment.
        // Here, we return the filename as stored in Song model.
        return item.extras!['localArtFileName'] as String;
      }
    }
    // Fallback to artUri if it exists, otherwise empty.
    return item.artUri?.toString() ?? '';
  }

  // Helper method to find an existing downloaded song by title and artist
  Future<Song?> _findExistingDownloadedSongByTitleArtist(String title, String artist) async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final appDocDir = await getApplicationDocumentsDirectory();
    // Ensure _downloadManager is initialized to get subDir, or use default
    await _initializeDownloadManager();
    final String downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap = jsonDecode(songJson) as Map<String, dynamic>;
            Song songCandidate = Song.fromJson(songMap);

            if (songCandidate.isDownloaded &&
                songCandidate.localFilePath != null &&
                songCandidate.localFilePath!.isNotEmpty &&
                songCandidate.title.toLowerCase() == title.toLowerCase() &&
                songCandidate.artist.toLowerCase() == artist.toLowerCase()) {
              
              final fullPath = p.join(appDocDir.path, downloadsSubDir, songCandidate.localFilePath!);
              if (await File(fullPath).exists()) {
                return songCandidate; // Found a downloaded match with an existing file
              } else {
                debugPrint("Song ${songCandidate.title} (ID: ${songCandidate.id}) matched title/artist and isDownloaded=true, but local file $fullPath missing.");
              }
            }
          } catch (e) {
            debugPrint('Error decoding song from SharedPreferences for key $key during _findExistingDownloadedSongByTitleArtist: $e');
          }
        }
      }
    }
    return null; // No downloaded match found with an existing file
  }

  @override
  void dispose() {
    _downloadManager?.dispose(); // Dispose the download manager
    _activeDownloads.clear();
    _downloadProgress.clear();

    _playbackStateSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _queueSubscription?.cancel();
    _positionSubscription?.cancel();
    // _audioHandler.stop(); // Optional: stop playback when provider is disposed
    super.dispose();
  }

  Future<void> _saveCurrentSongToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (_currentSongFromAppLogic != null) {
      await prefs.setString('current_song_v2', jsonEncode(_currentSongFromAppLogic!.toJson()));
      await prefs.setInt('current_index_v2', _currentIndexInAppQueue);
      await prefs.setInt('current_position_v2', _currentPosition.inMilliseconds);
      List<String> queueJson = _queue.map((song) => jsonEncode(song.toJson())).toList();
      await prefs.setStringList('current_queue_v2', queueJson);
      if (_isShuffling && _unshuffledQueue.isNotEmpty) {
        List<String> unshuffledQueueJson = _unshuffledQueue.map((song) => jsonEncode(song.toJson())).toList();
        await prefs.setStringList('current_unshuffled_queue_v2', unshuffledQueueJson);
      } else {
        await prefs.remove('current_unshuffled_queue_v2');
      }
    } else {
      await prefs.remove('current_song_v2');
      await prefs.remove('current_index_v2');
      await prefs.remove('current_position_v2');
      await prefs.remove('current_queue_v2');
      await prefs.remove('current_unshuffled_queue_v2');
    }
    // Save loop mode
    await prefs.setInt('loop_mode_v2', _audioHandler.playbackState.value.repeatMode.index);
    // Save shuffle mode
    await prefs.setBool('shuffle_mode_v2', _isShuffling);
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song_v2');
    final savedPositionMilliseconds = prefs.getInt('current_position_v2');

    // Load and set loop mode
    final savedLoopModeIndex = prefs.getInt('loop_mode_v2');
    if (savedLoopModeIndex != null && savedLoopModeIndex < AudioServiceRepeatMode.values.length) {
      await _audioHandler.setRepeatMode(AudioServiceRepeatMode.values[savedLoopModeIndex]);
    }

    // Load and set shuffle mode
    final savedShuffleMode = prefs.getBool('shuffle_mode_v2') ?? false;
    _isShuffling = savedShuffleMode;
    await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none); // Always none, we manage it.

    if (songJson != null) {
      try {
        Map<String, dynamic> songMap = jsonDecode(songJson);
        Song loadedSong = Song.fromJson(songMap);
        // Migration logic for file paths (if any) should be in Song.fromJson or here

        // Check if the loaded song is a radio stream
        bool isRadioStream = loadedSong.id.startsWith('radio_') || (loadedSong.extras?['isRadio'] as bool? ?? false);


        _currentSongFromAppLogic = loadedSong;
        _currentIndexInAppQueue = prefs.getInt('current_index_v2') ?? -1;
        List<String>? queueJsonStrings = prefs.getStringList('current_queue_v2');
        if (queueJsonStrings != null) {
          _queue = queueJsonStrings.map((sJson) => Song.fromJson(jsonDecode(sJson))).toList();
        }

        if (_isShuffling) {
          List<String>? unshuffledQueueJsonStrings = prefs.getStringList('current_unshuffled_queue_v2');
          if (unshuffledQueueJsonStrings != null) {
            _unshuffledQueue = unshuffledQueueJsonStrings.map((sJson) => Song.fromJson(jsonDecode(sJson))).toList();
          } else if (_queue.isNotEmpty) {
            // Fallback: if shuffled but no unshuffled queue saved, it means something went wrong or it's an old version.
            // We can't perfectly reconstruct the original order. We can leave _unshuffledQueue empty,
            // so toggling shuffle off will just keep the current order.
            _unshuffledQueue = List.from(_queue); // At least have something to revert to.
          }
        }

        // Restore state to audio_handler
        if (!isRadioStream && _queue.isNotEmpty && _currentIndexInAppQueue != -1 && _currentIndexInAppQueue < _queue.length) {
          final mediaItems = await Future.wait(_queue.map((s) async => await _prepareMediaItem(s)).toList());
          await _audioHandler.updateQueue(mediaItems);
          // Prepare the item at the saved index without playing it.
          await _audioHandler.customAction('prepareToPlay', {'index': _currentIndexInAppQueue});

          if (savedPositionMilliseconds != null) {
            await _audioHandler.seek(Duration(milliseconds: savedPositionMilliseconds));
          }

        } else if (_currentSongFromAppLogic != null) { // Handles single song or radio stream
          // For radio, fetchSongUrl will just return its existing audioUrl (the stream URL)
          // For regular song, it will fetch if necessary.
          final playableUrl = await fetchSongUrl(_currentSongFromAppLogic!);
          final mediaItem = songToMediaItem(_currentSongFromAppLogic!, playableUrl, null);

          // If it's a radio stream, set its specific properties from the loaded song
          if (isRadioStream) {
            _stationName = _currentSongFromAppLogic!.title;
            _stationFavicon = _currentSongFromAppLogic!.albumArtUrl;
            // Ensure mediaItem for radio has 'isRadio' extra
            final radioExtras = Map<String, dynamic>.from(mediaItem.extras ?? {});
            radioExtras['isRadio'] = true;
            radioExtras['songId'] = _currentSongFromAppLogic!.id; // Ensure original radio songId is used
            final radioMediaItem = mediaItem.copyWith(extras: radioExtras, id: _currentSongFromAppLogic!.audioUrl, title: _stationName ?? 'Unknown Station', artist: "Radio Station");
            // Prepare the radio item without playing it.
            await _audioHandler.customAction('prepareMediaItem', {
              'mediaItem': {
                'id': radioMediaItem.id,
                'title': radioMediaItem.title,
                'artist': radioMediaItem.artist,
                'album': radioMediaItem.album,
                'artUri': radioMediaItem.artUri?.toString(),
                'duration': radioMediaItem.duration?.inMilliseconds,
                'extras': radioMediaItem.extras,
              }
            });


          } else {
            // Prepare the single song item without playing it.
            await _audioHandler.customAction('prepareMediaItem', {
              'mediaItem': {
                'id': mediaItem.id,
                'title': mediaItem.title,
                'artist': mediaItem.artist,
                'album': mediaItem.album,
                'artUri': mediaItem.artUri?.toString(),
                'duration': mediaItem.duration?.inMilliseconds,
                'extras': mediaItem.extras,
              }
            });
            if (savedPositionMilliseconds != null) {
              await _audioHandler.seek(Duration(milliseconds: savedPositionMilliseconds));
            }
          }
        }
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song/queue from storage (v2): $e');
        await prefs.remove('current_song_v2');
        await prefs.remove('current_index_v2');
        await prefs.remove('current_position_v2');
        await prefs.remove('current_queue_v2');
      }
    }
  }

  Future<MediaItem> _prepareMediaItem(Song song) async {
    Song effectiveSong = song; 

    // Only scan SharedPreferences if we DON'T already have a localFilePath
    if (!(song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false))) {
      final existingDownloadedSong = await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);
      if (existingDownloadedSong != null) {
        debugPrint("Found existing downloaded version for ${song.title} (ID: ${song.id}) by ${song.artist}. Consolidating with downloaded song ID: ${existingDownloadedSong.id}.");
        
        String albumArtToUse = song.albumArtUrl; // Default to incoming song's art
        if (existingDownloadedSong.albumArtUrl.isNotEmpty && !existingDownloadedSong.albumArtUrl.startsWith('http')) {
          // If downloaded song has local art, prefer it.
          final appDocDir = await getApplicationDocumentsDirectory();
          final localArtPath = p.join(appDocDir.path, existingDownloadedSong.albumArtUrl);
          if (await File(localArtPath).exists()) {
            albumArtToUse = existingDownloadedSong.albumArtUrl;
          }
        }

        effectiveSong = song.copyWith( // Start with incoming song's display data
          id: existingDownloadedSong.id, // CRITICAL: Use ID of the existing downloaded song
          isDownloaded: true, // CRITICAL: Mark as downloaded
          localFilePath: existingDownloadedSong.localFilePath, // CRITICAL: Use downloaded song's path
          duration: existingDownloadedSong.duration ?? song.duration, // Prefer downloaded duration, fallback to incoming
          albumArtUrl: albumArtToUse,
          // audioUrl will be determined/confirmed by fetchSongUrl based on isDownloaded status
        );
        
        // Persist this "merged" song information. This is important.
        // It ensures that SharedPreferences has the correct ID and download status.
        await _persistSongMetadata(effectiveSong);
        // Update this song in all playlists to consolidate around the existing ID
        // This assumes PlaylistManagerService can handle ID changes or find by old ID/title/artist.
        PlaylistManagerService().updateSongInPlaylists(effectiveSong);
      }
    }

    // 'effectiveSong' is now the definitive version to work with.
    // 'fetchSongUrl' will use local path if 'effectiveSong.isDownloaded' is true and file exists.
    // If local file is missing, 'fetchSongUrl' will attempt to get a stream URL.
    String playableUrl = await fetchSongUrl(effectiveSong);
    
    bool metadataToPersistChanged = false;

    if (playableUrl.isEmpty) {
      // Fallback: if fetchSongUrl couldn't get a local path (even if marked downloaded but file missing)
      // and original audioUrl was also empty/invalid, try API.
      final apiService = ApiService();
      final fetchedApiUrl = await apiService.fetchAudioUrl(effectiveSong.artist, effectiveSong.title);

      if (fetchedApiUrl != null && fetchedApiUrl.isNotEmpty) {
        playableUrl = fetchedApiUrl;
        // If we got here, it means the song is NOT playable locally.
        // If it was marked as downloaded (either originally or after merging), its status is now incorrect because the file is missing.
        // We should update 'effectiveSong' to reflect it's streaming.
        effectiveSong = effectiveSong.copyWith(
          isDownloaded: false, 
          localFilePath: null, 
          audioUrl: playableUrl // Set audioUrl to the fetched stream URL
        );
        metadataToPersistChanged = true; 
      } else {
         throw Exception('Could not resolve playable URL for ${effectiveSong.title} (ID: ${effectiveSong.id}) after API fallback.');
      }
    } else {
      // Playable URL was found by fetchSongUrl.
      // If 'effectiveSong' is downloaded, 'playableUrl' is its local file path.
      // We need to ensure 'effectiveSong.audioUrl' reflects this local path if it's different
      // (e.g., if original 'song' had a streaming URL but we merged with a downloaded version).
      if (effectiveSong.isDownloaded && effectiveSong.audioUrl != playableUrl) {
        effectiveSong = effectiveSong.copyWith(audioUrl: playableUrl);
        metadataToPersistChanged = true;
      }
      // If not downloaded, and fetchSongUrl returned a (possibly new) stream URL
      else if (!effectiveSong.isDownloaded && effectiveSong.audioUrl != playableUrl) {
        effectiveSong = effectiveSong.copyWith(audioUrl: playableUrl);
        metadataToPersistChanged = true;
      }
    }

    Duration? songDuration = effectiveSong.duration;
    if (songDuration == null || songDuration == Duration.zero) {
      final audioPlayer = just_audio.AudioPlayer();
      try {
        final fetchedDuration = await audioPlayer.setUrl(playableUrl); // Use the confirmed playableUrl
        songDuration = fetchedDuration;
        if (songDuration != null && songDuration != Duration.zero && effectiveSong.duration != songDuration) {
            effectiveSong = effectiveSong.copyWith(duration: songDuration);
            metadataToPersistChanged = true;
        }
      } catch (e) {
        debugPrint("Error getting duration for ${effectiveSong.title} (ID: ${effectiveSong.id}) using URL $playableUrl: $e");
        songDuration = effectiveSong.duration ?? Duration.zero; // Keep existing or zero
      } finally {
        await audioPlayer.dispose();
      }
    }
    
    if (metadataToPersistChanged) {
      await _persistSongMetadata(effectiveSong);
      // Update in-memory representations if they exist
      final qIndex = _queue.indexWhere((s) => s.id == effectiveSong.id);
      if (qIndex != -1) {
        _queue[qIndex] = effectiveSong;
      }
      if (_currentSongFromAppLogic?.id == effectiveSong.id) {
        _currentSongFromAppLogic = effectiveSong;
      }
      // If the song's download status changed from downloaded to not-downloaded
      if (song.isDownloaded && !effectiveSong.isDownloaded) {
          PlaylistManagerService().updateSongInPlaylists(effectiveSong);
      }
    }

    final extras = Map<String, dynamic>.from(effectiveSong.extras ?? {});
    extras['isRadio'] = effectiveSong.artist == 'Radio Station';
    extras['songId'] = effectiveSong.id; // CRITICAL: ensure this is the ID of effectiveSong
    extras['isLocal'] = effectiveSong.isDownloaded;
    if (effectiveSong.isDownloaded && effectiveSong.localFilePath != null && effectiveSong.albumArtUrl.isNotEmpty && !effectiveSong.albumArtUrl.startsWith('http')) {
      // Ensure localArtFileName is only set if albumArtUrl is indeed a local filename
      extras['localArtFileName'] = effectiveSong.albumArtUrl;
    }

    return songToMediaItem(effectiveSong, playableUrl, songDuration).copyWith(extras: extras);
  }

  Future<void> playSong(Song songToPlay, {bool isResumingOrLooping = false}) async {
    _playRequestCounter++;
    final int currentPlayRequest = _playRequestCounter;

    _isLoadingAudio = true;
    // Tentatively update _currentSongFromAppLogic. This might be refined if the song
    // is found in _queue (and that instance is more up-to-date), or if _prepareMediaItem updates it.
    if (!isResumingOrLooping || _currentSongFromAppLogic?.id != songToPlay.id) {
      _currentSongFromAppLogic = songToPlay;
    }
    _stationName = null;
    _stationFavicon = null;
    notifyListeners(); // Notify for initial UI update (e.g. show new song title, clear radio info, show loading)

    try {
      if (currentPlayRequest != _playRequestCounter) return;

      if (!isResumingOrLooping) {
        int indexInExistingQueue = _queue.indexWhere((s) => s.id == songToPlay.id);

        if (indexInExistingQueue != -1) {
          // Song is part of the existing _queue. Play from this queue.
          _currentIndexInAppQueue = indexInExistingQueue;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];

          // Prepare queue for handler, ensuring MediaItems are up to date
          List<MediaItem> fullQueueMediaItems = await Future.wait(
            _queue.map((sInQueue) => _prepareMediaItem(sInQueue)).toList()
          );
          if (currentPlayRequest != _playRequestCounter) return;
          await _audioHandler.updateQueue(fullQueueMediaItems);

        } else {
          // Song not in current _queue, treat as a new single-item queue.
          // _currentSongFromAppLogic was set to songToPlay.
          // Call _prepareMediaItem for this song. It will update _currentSongFromAppLogic
          // if its URL changes (due to the side effect in _prepareMediaItem).
          MediaItem mediaItem = await _prepareMediaItem(_currentSongFromAppLogic!);
          if (currentPlayRequest != _playRequestCounter) return;
          _queue = [_currentSongFromAppLogic!];
          _currentIndexInAppQueue = 0;
          await _audioHandler.updateQueue([mediaItem]);
        }
        if (currentPlayRequest != _playRequestCounter) return;
        await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
      }

      if (currentPlayRequest != _playRequestCounter) return;
      await _audioHandler.play();
      _prefetchNextSongs();
      _saveCurrentSongToStorage(); // Save state including potentially updated queue/song

    } catch (e) {
      if (currentPlayRequest == _playRequestCounter) {
        // Use _currentSongFromAppLogic for the title in error, as it's the most up-to-date version.
        debugPrint('Error playing song (${_currentSongFromAppLogic?.title ?? songToPlay.title}): $e');
        _isLoadingAudio = false;
        notifyListeners();
      } else {
        debugPrint('Error in stale play request for ${songToPlay.title}, ignoring.');
      }
    }
  }

  Future<String> fetchSongUrl(Song song) async {
    // FAST PATH for offline songs: avoid DownloadManager init & long file checks
    if (song.isDownloaded && (song.localFilePath?.isNotEmpty ?? false)) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
      if (await File(filePath).exists()) {
        return filePath;
      }
      // Song was marked downloaded but the file is gone: reset its download state
      {
        final updatedSong = song.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(updatedSong);
        updateSongDetails(updatedSong);
        PlaylistManagerService().updateSongInPlaylists(updatedSong);
      }
      if (song.isImported) {
        debugPrint('Imported song "${song.title}" missing, cannot stream.');
        return ''; 
      }
      debugPrint('Local file for ${song.title} missing at $filePath, falling back to streaming.');
    }

    // If song is imported and we reached here, it means its local file is missing.
    // We should not attempt to fetch a URL from API for an imported song.
    if (song.isImported) {
        debugPrint('Imported song "${song.title}" does not have a valid local file path or file is missing. Cannot stream.');
        return '';
    }

    if (song.audioUrl.isNotEmpty && (Uri.tryParse(song.audioUrl)?.isAbsolute ?? false) && !song.audioUrl.startsWith('file:/')) {
      return song.audioUrl;
    }

    final apiService = ApiService();
    final fetchedUrl = await apiService.fetchAudioUrl(song.artist, song.title);
    return fetchedUrl ?? '';
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndexInAppQueue == -1) return;
    // Prefetching logic can be complex with audio_service as it manages its own state.
    // For now, this is simplified. The handler might do its own prefetching if designed to.
    // This example focuses on pre-caching URLs in CurrentSongProvider if needed.
  }

  void pauseSong() async {
    await _audioHandler.pause();
  }

  void resumeSong() async {
    if (_currentSongFromAppLogic != null) {
      _isLoadingAudio = true;
      notifyListeners();
      await _audioHandler.seek(_currentPosition);
      await _audioHandler.play();
      // _isLoadingAudio will be set to false by _listenToAudioHandler
    }
  }

  void stopSong() async {
    await _audioHandler.stop();
    _currentSongFromAppLogic = null;
    _totalDuration = null;
    _currentIndexInAppQueue = -1;
    _isLoadingAudio = false;
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  void toggleLoop() {
    final currentMode = _audioHandler.playbackState.value.repeatMode;
    AudioServiceRepeatMode nextMode;
    switch (currentMode) {
      case AudioServiceRepeatMode.none:
        nextMode = AudioServiceRepeatMode.all;
        break;
      case AudioServiceRepeatMode.all:
        nextMode = AudioServiceRepeatMode.one;
        break;
      case AudioServiceRepeatMode.one:
        nextMode = AudioServiceRepeatMode.none;
        break;
      default:
        nextMode = AudioServiceRepeatMode.none;
        break;
    }
    _audioHandler.setRepeatMode(nextMode);
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> toggleShuffle() async {
    final newShuffleState = !_isShuffling;
    _isShuffling = newShuffleState;

    if (_queue.isEmpty) {
      notifyListeners();
      _saveCurrentSongToStorage();
      return;
    }

    final currentSongBeforeAction = _currentSongFromAppLogic;

    if (newShuffleState) {
      _unshuffledQueue = List.from(_queue);
      _queue.shuffle();
    } else {
      if (_unshuffledQueue.isNotEmpty) {
        _queue = List.from(_unshuffledQueue);
      }
    }

    // Find the new index of the current song
    if (currentSongBeforeAction != null) {
      _currentIndexInAppQueue = _queue.indexWhere((s) => s.id == currentSongBeforeAction.id);
      if (_currentIndexInAppQueue == -1) {
        _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
        _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
      }
    } else {
      _currentIndexInAppQueue = _queue.isNotEmpty ? 0 : -1;
      _currentSongFromAppLogic = _queue.isNotEmpty ? _queue.first : null;
    }

    // Don't update the audio handler's queue immediately to avoid position interference
    // The queue will be updated when the next song plays or when explicitly needed
    
    // The audio_handler's shuffle mode should always be NONE now.
    await _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
    
    notifyListeners();
    await _saveCurrentSongToStorage();
  }

  Future<void> setQueue(List<Song> songs, {int initialIndex = 0}) async {
    // Always use canonical downloaded version for each song
    List<Song> canonicalSongs = [];
    for (final s in songs) {
      final downloaded = await _findExistingDownloadedSongByTitleArtist(s.title, s.artist);
      if (downloaded != null) {
        canonicalSongs.add(s.copyWith(
          id: downloaded.id,
          isDownloaded: true,
          localFilePath: downloaded.localFilePath,
          duration: downloaded.duration ?? s.duration,
          albumArtUrl: downloaded.albumArtUrl.isNotEmpty && !downloaded.albumArtUrl.startsWith('http')
              ? downloaded.albumArtUrl
              : s.albumArtUrl,
        ));
      } else {
        canonicalSongs.add(s);
      }
    }
    _unshuffledQueue = List.from(canonicalSongs); // Always save the natural order
    _queue = List.from(canonicalSongs);

    if (_isShuffling) {
      _queue.shuffle();
    }

    if (_queue.isNotEmpty) {
      Song? initialSong;
      if (initialIndex >= 0 && initialIndex < _unshuffledQueue.length) {
        initialSong = _unshuffledQueue[initialIndex];
      }

      if (initialSong != null) {
        _currentIndexInAppQueue = _queue.indexWhere((s) => s.id == initialSong!.id);
        if (_currentIndexInAppQueue == -1) {
          // Fallback if song not found (should not happen)
          _currentIndexInAppQueue = 0;
        }
      } else {
        _currentIndexInAppQueue = 0;
      }
      _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
    } else {
      _currentIndexInAppQueue = -1;
      _currentSongFromAppLogic = null;
    }

    final mediaItems = await Future.wait(
        _queue.map((s) async => _prepareMediaItem(s)).toList()
    );
    await _audioHandler.updateQueue(mediaItems);

    if (_currentSongFromAppLogic != null && _currentIndexInAppQueue != -1) {
      await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
    } else if (_queue.isEmpty) {
      await _audioHandler.stop();
    }

    notifyListeners();
    _saveCurrentSongToStorage();
  }

  void playPrevious() {
    // The handler now manages shuffle/repeat logic for skipToPrevious
    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();
      
      // Update the audio handler's queue with current provider queue order
      // This ensures shuffle order is respected when moving to previous song
      _updateAudioHandlerQueue().then((_) {
        _audioHandler.skipToPrevious();
      });
    } else {
      _audioHandler.skipToPrevious();
    }
  }

  void playNext() {
    // The handler now manages shuffle/repeat logic for skipToNext
    if (_queue.isNotEmpty) {
      _isLoadingAudio = true;
      notifyListeners();
      
      // Update the audio handler's queue with current provider queue order
      // This ensures shuffle order is respected when moving to next song
      _updateAudioHandlerQueue().then((_) {
        _audioHandler.skipToNext().then((_) {
          // If the current song is not downloaded, notify listeners so UI can update position/state.
          notifyListeners();
        });
      });
    } else {
      _audioHandler.skipToNext().then((_) {
        notifyListeners();
      });
    }
  }

  Future<void> _updateAudioHandlerQueue() async {
    if (_queue.isEmpty) return;
    
    final mediaItems = await Future.wait(
        _queue.map((s) => _prepareMediaItem(s)).toList()
    );
    await _audioHandler.updateQueue(mediaItems);
    
    // Update the current playing item's index in the handler
    if (_currentIndexInAppQueue != -1) {
        await _audioHandler.customAction('setQueueIndex', {'index': _currentIndexInAppQueue});
    }
  }

  Future<void> queueSongForDownload(Song song) async {
    await _initializeDownloadManager();
    if (_downloadManager == null) {
      debugPrint("DownloadManager unavailable after initialization. Cannot queue \"${song.title}\".");
      return;
    }

    Song songToProcess = song;

    // Skip if song is imported
    if (songToProcess.isImported) {
      debugPrint('Song "${songToProcess.title}" is imported. Skipping download queue.');
      // Optionally, ensure its download progress is marked as 1.0 if it's considered "complete" by being imported.
      // This depends on how `isImported` interacts with `isDownloaded`.
      // If imported implies downloaded and available, then:
      if (_downloadProgress[songToProcess.id] != 1.0) {
        _downloadProgress[songToProcess.id] = 1.0; // Mark as complete
        if (_activeDownloads.containsKey(songToProcess.id)) {
          _activeDownloads.remove(songToProcess.id);
        }
        notifyListeners();
      }
      return;
    }

    // Check for existing downloaded version by title and artist
    final existingDownloadedSong = await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);

    if (existingDownloadedSong != null) {
      debugPrint("Song \"${song.title}\" by ${song.artist} is already downloaded (found as ID ${existingDownloadedSong.id}). Updating metadata and skipping download queue.");
      
      String albumArtToUse = song.albumArtUrl;
      if (existingDownloadedSong.albumArtUrl.isNotEmpty && !existingDownloadedSong.albumArtUrl.startsWith('http')) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final localArtPath = p.join(appDocDir.path, existingDownloadedSong.albumArtUrl);
        if (await File(localArtPath).exists()) {
          albumArtToUse = existingDownloadedSong.albumArtUrl;
        }
      }
      
      songToProcess = song.copyWith(
        id: existingDownloadedSong.id, 
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        audioUrl: existingDownloadedSong.localFilePath, // Or construct full path after ensuring file exists
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: albumArtToUse,
      );

      await _persistSongMetadata(songToProcess);
      updateSongDetails(songToProcess); 
      PlaylistManagerService().updateSongInPlaylists(songToProcess); 

      _downloadProgress[songToProcess.id] = 1.0;
      if (_activeDownloads.containsKey(songToProcess.id)) { 
          _activeDownloads.remove(songToProcess.id);
      }
      notifyListeners();
      return; 
    }

    // Check 1 (modified): Already downloaded (based on current songToProcess state) and file exists?
    if (songToProcess.isDownloaded && songToProcess.localFilePath != null && songToProcess.localFilePath!.isNotEmpty) {
      final appDocDir = await getApplicationDocumentsDirectory();
      // Ensure _downloadManager is initialized to get subDir, or hardcode if always the same
      await _initializeDownloadManager(); // Ensures _downloadManager and its subDir are available
      final String downloadsSubDir = _downloadManager?.subDir ?? 'ltunes_downloads';
      final filePath = p.join(appDocDir.path, downloadsSubDir, songToProcess.localFilePath!);
      if (await File(filePath).exists()) {
        debugPrint('Song "${songToProcess.title}" is already downloaded and file exists. Skipping queueing.');
        if (_downloadProgress[songToProcess.id] != 1.0) {
          _downloadProgress[songToProcess.id] = 1.0;
          if (_activeDownloads.containsKey(songToProcess.id)) {
            _activeDownloads.remove(songToProcess.id);
          }
          notifyListeners();
        }
        return;
      } else {
        debugPrint('Song "${songToProcess.title}" marked downloaded but file missing. Resetting metadata.');
        songToProcess = songToProcess.copyWith(isDownloaded: false, localFilePath: null);
        await _persistSongMetadata(songToProcess);
        updateSongDetails(songToProcess);
      }
    }

    // Check 2: Already actively being downloaded by this provider?
    if (_activeDownloads.containsKey(songToProcess.id)) {
      debugPrint('Song "${songToProcess.title}" is already in active downloads by provider. Skipping queueing.');
      return;
    }

    // Check 3: Already in the provider's download queue?
    if (_downloadQueue.any((s) => s.id == songToProcess.id)) {
      debugPrint('Song "${songToProcess.title}" is already in the provider download queue. Skipping queueing.');
      return;
    }

    // Add to provider's queue
    _downloadQueue.add(songToProcess);
    debugPrint('Song "${songToProcess.title}" added to provider download queue. Queue size: ${_downloadQueue.length}');
    notifyListeners(); // Notify that queue has changed, UI might show "queued"
    _updateDownloadNotification(); // Update download notification
    _triggerNextDownloadInProviderQueue();
  }

  void _triggerNextDownloadInProviderQueue() {
    // only start a new download if none is processing and queue isn't empty
    if (_isProcessingProviderDownload || _downloadQueue.isEmpty) {
      return;
    }

    _isProcessingProviderDownload = true;
    // For O(1) performance, _downloadQueue should be a `Queue` from `dart:collection`.
    final Song songToDownload = _downloadQueue.removeAt(0);
    _activeDownloads[songToDownload.id] = songToDownload;
    _downloadProgress[songToDownload.id] = _downloadProgress[songToDownload.id] ?? 0.0;
    notifyListeners();
    _updateDownloadNotification(); // Update download notification
    _processAndSubmitDownload(songToDownload);
  }

  Future<void> _processAndSubmitDownload(Song song) async {
    // Note: _activeDownloads and _downloadProgress are now set by _triggerNextDownloadInProviderQueue
    // This method assumes it's been called for a song that is now the "current" provider-managed download.

    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint("DownloadManager not initialized. Cannot process download for ${song.title}.");
      // _handleDownloadError needs song.id, which is available.
      // The error handling will also trigger the next download from queue.
      _handleDownloadError(song.id, Exception("DownloadManager not initialized"));
      return;
    }

    // _activeDownloads[song.id] = song; // Moved to _triggerNextDownloadInProviderQueue
    // _downloadProgress[song.id] = _downloadProgress[song.id] ?? 0.0; // Moved
    // notifyListeners(); // Moved

    String? audioUrl;
    try {
      audioUrl = await fetchSongUrl(song); // Use the passed song object
      if (audioUrl.isEmpty || audioUrl.startsWith('file://') || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        final apiService = ApiService();
        audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      }
      if (audioUrl == null || audioUrl.isEmpty || !(Uri.tryParse(audioUrl)?.isAbsolute ?? false)) {
        throw Exception('Failed to fetch a valid audio URL for download.');
      }
    } catch (e) {
      debugPrint('Error fetching audio URL for download of "${song.title}": $e');
      _handleDownloadError(song.id, e);
      return;
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac'];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle = sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
        break;
      }
    }
    
    final String uniqueFileNameBase = '${song.id}_$sanitizedTitle';

    final queueItem = QueueItem(
      url: audioUrl,
      fileName: uniqueFileNameBase,
      progressCallback: (progressDetails) {
        if (_activeDownloads.containsKey(song.id)) {
          _downloadProgress[song.id] = progressDetails.progress;
          notifyListeners();
          _updateDownloadNotification(); // Update download notification
        }
      },
    );

    try {
      debugPrint('Submitting download for ${song.title} (base filename: $uniqueFileNameBase) to DownloadManager.');
      final downloadedFile = await _downloadManager!.getFile(queueItem);

      if (downloadedFile != null && await downloadedFile.exists()) {
        _handleDownloadSuccess(song.id, p.basename(downloadedFile.path));
      } else {
        // Attempt to clean up potential partial file if DownloadManager didn't.
        // This part is speculative as DownloadManager should handle its files.
        final appDocDir = await getApplicationDocumentsDirectory();
        final String potentialPartialPath = p.join(appDocDir.path, _downloadManager!.subDir, queueItem.fileName!);
        final File partialFile = File(potentialPartialPath);
        if (await partialFile.exists()) {
          try {
            await partialFile.delete();
            debugPrint('Deleted potential partial file: $potentialPartialPath');
          } catch (deleteError) {
            debugPrint('Error deleting potential partial file $potentialPartialPath: $deleteError');
          }
        }
        _handleDownloadError(song.id, Exception('DownloadManager.getFile completed but file is null or does not exist.'));
      }
    } catch (e) {
      debugPrint('Error from DownloadManager for ${song.title}: $e');
      _handleDownloadError(song.id, e);
    }
  }


  void _handleDownloadSuccess(String songId, String actualLocalFileName) async {
    Song? song = _activeDownloads[songId];

    if (song == null) {
      // Attempt to find it in the queue or persisted data if it's an update for an existing item
      // This part might need more robust handling if song can be null here.
      // For now, let's assume the caller (queueSongForDownload's "already downloaded" path)
      // handles providing the correct, updated song object to _persistSongMetadata, etc.
      // and this _handleDownloadSuccess is primarily for actual network downloads.
      // For immediate UI feedback of cancellation:
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId); // Proactively remove from provider's active list
      }
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
      }
      // _isProcessingProviderDownload will be set to false by _handleDownloadError/Success
      // when the `await _downloadManager.getFile()` call finally unblocks.
      // Then _triggerNextDownloadInProviderQueue will be called.
      return;
    }

    try {
      Song updatedSong = song.copyWith(
        isDownloaded: true,
        localFilePath: actualLocalFileName, // Use the actual filename from DownloadManager
        isDownloading: false,
        downloadProgress: 1.0,
      );

      // Download album art if it's a network URL
      if (updatedSong.albumArtUrl.startsWith('http')) {
        final localArtFileName = await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
        if (localArtFileName != null) {
          updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        }
      }

      // Fetch lyrics after successful download
      final apiService = ApiService();
      final lyricsData = await apiService.fetchLyrics(updatedSong.artist, updatedSong.title);
      if (lyricsData != null) {
        updatedSong = updatedSong.copyWith(
          plainLyrics: lyricsData.plainLyrics,
          syncedLyrics: lyricsData.syncedLyrics,
        );
      }

      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong); 
      PlaylistManagerService().updateSongInPlaylists(updatedSong);
      debugPrint('Download complete: ${updatedSong.title}. Lyrics fetched: ${lyricsData != null && (lyricsData.plainLyrics != null || lyricsData.syncedLyrics != null)}');
    } catch (e) {
      debugPrint("Error during post-download success processing for ${song.title}: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _isProcessingProviderDownload = false;
      notifyListeners();
      _updateDownloadNotification(); // Update download notification
      _triggerNextDownloadInProviderQueue();
    }
  }

  void _handleDownloadError(String songId, dynamic error) {
    final song = _activeDownloads[songId]; // Get the song being processed

    try {
      if (song != null) {
        debugPrint('Download failed for ${song.title}: $error');
      } else {
        debugPrint('Handling download error for songId $songId (not in _activeDownloads by provider). Error: $error');
        // If song is null, it means it wasn't the one _isProcessingProviderDownload was true for,
        // or state is inconsistent.
      }
    } catch (e) {
      debugPrint("Internal error in _handleDownloadError for songId $songId: $e");
    } finally {
      if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId);
        _downloadProgress.remove(songId);
      }
      _isProcessingProviderDownload = false;
      notifyListeners();
      _updateDownloadNotification(); // Update download notification
      _triggerNextDownloadInProviderQueue();
    }
  }

  Future<void> cancelDownload(String songId) async {
    // Check if the song is in the provider's manual queue
    int queueIndex = _downloadQueue.indexWhere((s) => s.id == songId);
    if (queueIndex != -1) {
      _downloadQueue.removeAt(queueIndex);
      debugPrint("Song ID $songId removed from provider's download queue.");
      // If it was only in the queue, no need to interact with DownloadManager yet.
      // Clean up progress if it was somehow set.
      if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
      }
      notifyListeners();
      _updateDownloadNotification(); // Update download notification
      return; // Song was only in queue, not yet given to DownloadManager by provider logic.
    }

    // If not in queue, check if it's the one actively being processed by the provider
    final song = _activeDownloads[songId];
    if (song == null) {
      debugPrint("Song ID $songId not found in active downloads by provider for cancellation.");
      if (_downloadProgress.containsKey(songId)) {
          _downloadProgress.remove(songId);
          notifyListeners();
          _updateDownloadNotification(); // Update download notification
      }
      return;
    }
    
    // If actively being processed by provider, attempt to cancel with DownloadManager
    if (!_isDownloadManagerInitialized || _downloadManager == null) {
      debugPrint("DownloadManager not initialized. Cannot cancel active download.");
      // Even if DM is not init, we should clean up provider state for this song.
      // _handleDownloadError will set _isProcessingProviderDownload = false and trigger next.
      _handleDownloadError(songId, Exception("Cancel attempted but DownloadManager not initialized"));
      return;
    }
    
    String? originalAudioUrl = song.audioUrl; 
    if (originalAudioUrl.isEmpty) { 
        try {
            originalAudioUrl = await fetchSongUrl(song);
             if (originalAudioUrl.isEmpty || originalAudioUrl.startsWith('file://') || !(Uri.tryParse(originalAudioUrl)?.isAbsolute ?? false) ) {
                final apiService = ApiService();
                originalAudioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
            }
        } catch (e) {
            debugPrint("Could not determine URL for cancelling download of ${song.title}: $e");
            // Still attempt filename cancel below if URL fetch fails
        }
    }

    String sanitizedTitle = song.title
        .replaceAll(RegExp(r'[^\w\s.-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');

    const commonAudioExtensions = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac'];
    for (var ext in commonAudioExtensions) {
      if (sanitizedTitle.toLowerCase().endsWith(ext)) {
        sanitizedTitle = sanitizedTitle.substring(0, sanitizedTitle.length - ext.length);
        break;
      }
    }
    
    final String uniqueFileNameBaseForCancellation = '${song.id}_$sanitizedTitle';

    if (originalAudioUrl != null && originalAudioUrl.isNotEmpty) {
        try {
          debugPrint('Attempting to cancel download for ${song.title} via URL: $originalAudioUrl');
          await _downloadManager!.cancelDownload(originalAudioUrl);
          debugPrint('URL-based cancel request sent for ${song.title}.');
        } catch (e) {
          debugPrint('URL-based cancel failed for ${song.title}: $e. Will attempt filename cancel.');
        }
    } else {
        debugPrint("URL for cancelling download of ${song.title} is empty. Attempting filename cancel.");
    }

    try {
      debugPrint('Attempting to cancel download for ${song.title} via base filename: $uniqueFileNameBaseForCancellation');
      await _downloadManager!.cancelDownload(uniqueFileNameBaseForCancellation); 
      debugPrint('Filename-based cancel request sent for ${song.title}.');
    } catch (e) {
      debugPrint('Filename-based cancel also failed for ${song.title}: $e');
    }
    
    // Regardless of DownloadManager's cancel success, treat this as an error/completion locally.
    // The DownloadManager's getFile() Future should complete (often with an error) if cancelled.
    // _handleDownloadError will be called when that Future completes.
    // For immediate UI feedback of cancellation:
    if (_activeDownloads.containsKey(songId)) {
        _activeDownloads.remove(songId); // Proactively remove from provider's active list
    }
    if (_downloadProgress.containsKey(songId)) {
        _downloadProgress.remove(songId);
    }
    // _isProcessingProviderDownload will be set to false by _handleDownloadError/Success
    // when the `await _downloadManager.getFile()` call finally unblocks.
    // Then _triggerNextDownloadInProviderQueue will be called.
    notifyListeners();
    _updateDownloadNotification(); // Update download notification
  }

  Future<void> cancelAllDownloads() async {
    debugPrint("Attempting to cancel all downloads.");

    // Create a combined list of all song IDs to cancel to avoid issues with modifying collections while iterating.
    final List<String> songIdsToCancel = [];
    songIdsToCancel.addAll(_activeDownloads.keys);
    songIdsToCancel.addAll(_downloadQueue.map((s) => s.id).toList());

    // Remove duplicates, though activeDownloads and downloadQueue should ideally not have overlaps
    // if logic is correct, but good for safety.
    final uniqueSongIdsToCancel = songIdsToCancel.toSet().toList();

    if (uniqueSongIdsToCancel.isEmpty) {
      debugPrint("No downloads to cancel.");
      return;
    }

    debugPrint("Found ${uniqueSongIdsToCancel.length} unique downloads to cancel.");

    // Call cancelDownload for each. cancelDownload handles DownloadManager interaction and state updates.
    for (final songId in uniqueSongIdsToCancel) {
      // We don't need to await each individual cancelDownload here if we want to fire them off
      // and let them complete asynchronously. The UI will update as each one finishes.
      // However, cancelDownload itself is async.
      // For simplicity in managing _isProcessingProviderDownload and _triggerNextDownloadInProviderQueue,
      // it might be better to let them run.
      // The current cancelDownload logic already handles removing from _activeDownloads
      // and _downloadProgress, and triggering the next download if one was active.
      // If we clear _downloadQueue here, _triggerNextDownloadInProviderQueue won't pick up new items from it.

      // If a download is active (_activeDownloads contains it), cancelDownload will handle it.
      // If it's only in _downloadQueue, cancelDownload will remove it from there.
      await cancelDownload(songId);
    }

    // Explicitly clear the provider's queue as cancelDownload only removes one at a time
    // or the active one.
    _downloadQueue.clear();

    // _activeDownloads and _downloadProgress should be cleared by the individual cancelDownload calls
    // as they complete or error out.
    // If there was an active download, its cancellation will set _isProcessingProviderDownload to false
    // and attempt to trigger the next download. Since _downloadQueue is now empty, nothing new will start.

    debugPrint("All download cancellation requests initiated. Provider queue cleared.");
    notifyListeners(); // Notify for the queue clearing and any immediate state changes.
    _updateDownloadNotification(); // Update download notification
  }

  Future<void> playStream(String streamUrl, {required String stationName, String? stationFavicon}) async {
    _playRequestCounter++;
    final int currentPlayRequest = _playRequestCounter;

    _isLoadingAudio = true;
    // _currentSongFromAppLogic = null; // Clear regular song // This will be set to the radio song object
    _stationName = stationName;
    _stationFavicon = stationFavicon ?? '';


    final radioSongId = 'radio_${stationName.hashCode}_${streamUrl.hashCode}';
    // final mediaItem = MediaItem( // This is defined later
    //   id: streamUrl, // Playable URL
    //   title: stationName,
    //   artist: 'Radio Station',
    //   artUri: stationFavicon != null && stationFavicon.isNotEmpty ? Uri.tryParse(stationFavicon) : null,
    //   extras: {'isRadio': true, 'songId': radioSongId}, // Ensure songId is set for radio
    // );

    // Update app's notion of current song to this radio stream
    _currentSongFromAppLogic = Song(
        id: radioSongId, // Use the unique radioSongId
        title: stationName,
        artist: 'Radio Station',
        artistId: '',
        albumArtUrl: stationFavicon ?? '',
        audioUrl: streamUrl, // Store the actual stream URL
        isDownloaded: false,
        extras: {'isRadio': true} // Add extras to Song model if it supports it, or handle this distinction another way
    );
    notifyListeners(); // Notify after _currentSongFromAppLogic and station details are set, and to show loading

    if (currentPlayRequest != _playRequestCounter) return;

    // Update the queue in the handler to just this radio stream
    // Or, if you want radio to be outside the main queue, handle accordingly.
    // For now, let's make it the current item.
    // Re-create mediaItem here as it was commented out above for clarity of _isLoadingAudio and notifyListeners() timing
    final mediaItem = MediaItem(
      id: streamUrl, // Playable URL
      title: stationName,
      artist: 'Radio Station',
      artUri: stationFavicon != null && stationFavicon.isNotEmpty ? Uri.tryParse(stationFavicon) : null,
      extras: {'isRadio': true, 'songId': radioSongId},
    );
    await _audioHandler.playMediaItem(mediaItem);

    if (currentPlayRequest != _playRequestCounter) return;

    _saveCurrentSongToStorage(); // Save that we are playing a radio stream
    // _isLoadingAudio will be set to false by _listenToAudioHandler
  }

  void addToQueue(Song song) async {
    // Prevent duplicates by ID
    if (_queue.any((s) => s.id == song.id)) {
      return;
    }
    // Always use canonical downloaded version if available
    final existingDownloadedSong = await _findExistingDownloadedSongByTitleArtist(song.title, song.artist);
    Song songToAdd = song;
    if (existingDownloadedSong != null) {
      songToAdd = song.copyWith(
        id: existingDownloadedSong.id,
        isDownloaded: true,
        localFilePath: existingDownloadedSong.localFilePath,
        duration: existingDownloadedSong.duration ?? song.duration,
        albumArtUrl: existingDownloadedSong.albumArtUrl.isNotEmpty && !existingDownloadedSong.albumArtUrl.startsWith('http')
            ? existingDownloadedSong.albumArtUrl
            : song.albumArtUrl,
      );
    }
    _queue.add(songToAdd);
    final mediaItem = await _prepareMediaItem(songToAdd);
    await _audioHandler.addQueueItem(mediaItem);

    if (_currentIndexInAppQueue == -1 && _queue.length == 1) {
      _currentIndexInAppQueue = 0;
      _currentSongFromAppLogic = songToAdd;
    }
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> clearQueue() async {
    _queue.clear();
    _currentIndexInAppQueue = -1;
    // If a song is playing, it might continue if it was the current item.
    // To stop it and clear handler queue:
    // await _audioHandler.stop(); // This also clears handler's current item
    await _audioHandler.updateQueue([]); // Clears handler's queue

    // If current song was part of the cleared queue, nullify it
    // _currentSongFromAppLogic = null; // Or decide based on desired behavior
    notifyListeners();
    _saveCurrentSongToStorage();
  }

  Future<void> _persistSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  Future<void> processSongLibraryRemoval(String songId) async {
    bool providerStateChanged = false;

    // If the removed song was the current song, update _currentSongFromAppLogic
    if (_currentSongFromAppLogic?.id == songId) {
      _currentSongFromAppLogic = null;
      providerStateChanged = true;
    }

    // Remove from the provider's internal queue
    final int initialQueueLength = _queue.length;
    _queue.removeWhere((s) => s.id == songId);
    if (_queue.length != initialQueueLength) {
      providerStateChanged = true;
    }

    // If the provider's state changed (current song or queue), update audio_handler's queue
    if (providerStateChanged) {
      if (_queue.isNotEmpty) {
        final mediaItems = await Future.wait(
            _queue.map((s) async => _prepareMediaItem(s)).toList()
        );
        await _audioHandler.updateQueue(mediaItems);

        // If _currentSongFromAppLogic is now null but queue is not empty,
        // set to first item and advance handler
        if (_currentSongFromAppLogic == null && _queue.isNotEmpty) {
          _currentIndexInAppQueue = 0;
          _currentSongFromAppLogic = _queue[_currentIndexInAppQueue];
          await _audioHandler.skipToQueueItem(_currentIndexInAppQueue);
        } else if (_queue.isEmpty) {
          _currentIndexInAppQueue = -1;
          await _audioHandler.stop();
        }
      } else {
        _currentIndexInAppQueue = -1;
        _currentSongFromAppLogic = null;
        await _audioHandler.stop();
        await _audioHandler.updateQueue([]);
      }
    }

    if (providerStateChanged) {
      notifyListeners();
      await _saveCurrentSongToStorage();
    }
  }

  void updateSongDetails(Song updatedSong) {
    bool providerStateChanged = false;
    // ignore: unused_local_variable
    bool currentSongWasUpdated = false;

    // Update in the provider's own queue
    final indexInProviderQueue = _queue.indexWhere((s) => s.id == updatedSong.id);
    if (indexInProviderQueue != -1) {
      _queue[indexInProviderQueue] = updatedSong;
      providerStateChanged = true;
    }

    // Update the provider's current song if it's the one being changed
    if (_currentSongFromAppLogic?.id == updatedSong.id) {
      _currentSongFromAppLogic = updatedSong;
      providerStateChanged = true;
      currentSongWasUpdated = true;
    }

    // Update handler's queue and current item if needed
    if (providerStateChanged) {
      _prepareMediaItem(updatedSong).then((newMediaItem) async {
        final handlerQueue = List<MediaItem>.from(_audioHandler.queue.value);
        int itemIndexInHandlerQueue = handlerQueue.indexWhere((mi) => mi.extras?['songId'] == updatedSong.id);

        if (itemIndexInHandlerQueue != -1) {
          handlerQueue[itemIndexInHandlerQueue] = newMediaItem;
          await _audioHandler.updateQueue(handlerQueue);
        }
        // Optionally update current media item metadata if playing
        final currentHandlerMediaItem = _audioHandler.mediaItem.value;
        if (currentHandlerMediaItem != null &&
            currentHandlerMediaItem.extras?['songId'] == updatedSong.id) {
          _audioHandler.customAction('updateCurrentMediaItemMetadata', {
            'mediaItem': {
              'id': newMediaItem.id,
              'title': newMediaItem.title,
              'artist': newMediaItem.artist,
              'album': newMediaItem.album,
              'artUri': newMediaItem.artUri?.toString(),
              'duration': newMediaItem.duration?.inMilliseconds,
              'extras': newMediaItem.extras,
            }
          });
        }
      }).catchError((e, stackTrace) {
        debugPrint("Error preparing or updating media item in handler for song ${updatedSong.id}: $e");
        debugPrintStack(stackTrace: stackTrace);
      });
    }

    if (providerStateChanged) {
      notifyListeners();
      _saveCurrentSongToStorage();
    }
  }

  void setCurrentSong(Song song) async {
    // This method is likely for UI purposes to show details before playing.
    // It shouldn't trigger playback directly.
    _currentSongFromAppLogic = song;
    // If you want to update the audio_handler's current item without playing:
    // final mediaItem = await _prepareMediaItem(song);
    // _audioHandler.mediaItem.add(mediaItem);
    // final qIndex = _queue.indexWhere((s) => s.id == song.id);
    // _audioHandler.playbackState.add(_audioHandler.playbackState.value.copyWith(queueIndex: qIndex != -1 ? qIndex : null));
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _audioHandler.seek(position);
  }

  Future<void> updateMissingMetadata(Song song) async {
    if (!song.isDownloaded) return;

    Song updatedSong = song;
    bool needsUpdate = false;

    // Check and download album art if it's a network URL
    if (updatedSong.albumArtUrl.startsWith('http')) {
      final localArtFileName = await _downloadAlbumArt(updatedSong.albumArtUrl, updatedSong);
      if (localArtFileName != null) {
        updatedSong = updatedSong.copyWith(albumArtUrl: localArtFileName);
        needsUpdate = true;
      }
    }

    // Check for lyrics

    if (updatedSong.plainLyrics == null && updatedSong.syncedLyrics == null) {
      final apiService = ApiService();
      final newLyrics = await apiService.fetchLyrics(updatedSong.artist, updatedSong.title);
      if (newLyrics != null) {
        updatedSong = updatedSong.copyWith(
          plainLyrics: newLyrics.plainLyrics,
          syncedLyrics: newLyrics.syncedLyrics,
        );
        needsUpdate = true;
      }
    }

    if (song.isDownloaded && song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, 'ltunes_downloads', song.albumArtUrl);
      if (!await File(fullPath).exists()) {
        final downloadedArt = await _downloadAlbumArt(song.albumArtUrl, song);
        if (downloadedArt != null) {
          final updatedSong = song.copyWith(albumArtUrl: downloadedArt);
          updateSongDetails(updatedSong);
        }
      }
    }

    if (needsUpdate) {
      await _persistSongMetadata(updatedSong);
      updateSongDetails(updatedSong);
    }
  }

  // playUrl is not used by current app structure, can be removed or adapted
  void playUrl(String url) {
    // This would need to create a MediaItem and call _audioHandler.playMediaItem
    debugPrint('Playing URL directly: $url - This method might need adaptation for audio_service');
    final tempSong = Song(id: url, title: "Direct URL", artist: "", artistId: "", albumArtUrl: "", audioUrl: url);
    playSong(tempSong); // Or a more direct handler call
  }

  Future<void> updateSongLyrics(String songId, LyricsData lyricsData) async {
    Song? songToUpdate;
    int queueIndex = _queue.indexWhere((s) => s.id == songId);

    if (queueIndex != -1) {
      songToUpdate = _queue[queueIndex];
    } else if (_currentSongFromAppLogic?.id == songId) {
      songToUpdate = _currentSongFromAppLogic;
    }

    if (songToUpdate != null) {
      final updatedSong = songToUpdate.copyWith(
        plainLyrics: lyricsData.plainLyrics,
        syncedLyrics: lyricsData.syncedLyrics,
      );

      // Persist the metadata for the individual song
      await _persistSongMetadata(updatedSong);

      // Update the song in the provider's state and notify audio_handler and UI
      // updateSongDetails handles updating _queue, _currentSongFromAppLogic,
      // notifying listeners, and updating AudioHandler's state.
      updateSongDetails(updatedSong);
      
      debugPrint("Lyrics updated for song: ${updatedSong.title} (ID: ${updatedSong.id})");
    } else {
      debugPrint("Song with ID $songId not found for updating lyrics.");
    }
  }
}