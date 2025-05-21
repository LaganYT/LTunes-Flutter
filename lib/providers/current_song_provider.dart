import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../models/song.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class CurrentSongProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Song? _currentSong;
  bool _isPlaying = false;
  bool _isLooping = false;
  bool _isShuffling = false;
  List<Song> _queue = [];
  int _currentIndex = -1;
  final Map<String, String> _urlCache = {}; // Cache for song URLs
  bool _isDownloadingSong = false; // Renamed from isLoading
  bool _isLoadingAudio = false; // New property for audio loading
  final Map<String, double> _downloadProgress = {}; // Track download progress

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  bool get isShuffling => _isShuffling;
  List<Song> get queue => _queue;
  Map<String, double> get downloadProgress => _downloadProgress;
  bool get isDownloadingSong => _isDownloadingSong; // Getter for renamed property
  bool get isLoadingAudio => _isLoadingAudio; // Getter for new property

  CurrentSongProvider() {
    _loadCurrentSongFromStorage(); // Load the last playing song on initialization
  }

  Future<void> _saveCurrentSongToStorage() async {
    if (_currentSong != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_song', jsonEncode(_currentSong!.toJson()));
    }
  }

  Future<void> _loadCurrentSongFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('current_song');
    if (songJson != null) {
      try {
        _currentSong = Song.fromJson(jsonDecode(songJson));
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading current song: $e');
      }
    }
  }

  void playSong(Song song) async {
    _isLoadingAudio = true;
    notifyListeners();

    try {
      _currentSong = song;
      String sourceUrl = _urlCache[song.id] ?? song.effectiveAudioUrl;

      if (sourceUrl.isEmpty) {
        // Fetch and cache the URL if not already cached
        sourceUrl = await fetchSongUrl(song);
        _urlCache[song.id] = sourceUrl;
      }

      // Validate the URL
      final parsedUri = Uri.tryParse(sourceUrl);
      if (parsedUri == null || !parsedUri.hasAbsolutePath) {
        throw Exception('Invalid audio URL: $sourceUrl');
      }

      if (song.isDownloaded) {
        await _audioPlayer.play(DeviceFileSource(sourceUrl));
      } else {
        await _audioPlayer.play(UrlSource(sourceUrl));
      }

      _isPlaying = true;
      _isLoadingAudio = false;
      notifyListeners();

      // Pre-fetch the next 3 songs in the queue
      _prefetchNextSongs();
      _saveCurrentSongToStorage(); // Save the current song when it starts playing
    } catch (e) {
      debugPrint('Error playing song: $e');
      _isLoadingAudio = false;
      stopSong(); // stopSong will also notifyListeners
      // Notify the user about the error
      // notifyListeners(); // Already notified by stopSong or explicitly if stopSong doesn't
    }
  }

  Future<String> fetchSongUrl(Song song) async {
    // Simulate fetching the song URL (replace with actual API call if needed)
    return song.audioUrl;
  }

  void _prefetchNextSongs() async {
    if (_queue.isEmpty || _currentIndex == -1) return;

    for (int i = 1; i <= 3; i++) {
      final nextIndex = _currentIndex + i;
      if (nextIndex < _queue.length) {
        final nextSong = _queue[nextIndex];
        if (!_urlCache.containsKey(nextSong.id)) {
          final url = await fetchSongUrl(nextSong);
          _urlCache[nextSong.id] = url;
        }
      }
    }
  }

  void pauseSong() async {
    await _audioPlayer.pause();
    _isPlaying = false;
    _isLoadingAudio = false; // No longer loading when paused
    notifyListeners();
  }

  void resumeSong() async {
    if (currentSong != null) {
      _isLoadingAudio = true;
      notifyListeners();
      try {
        await _audioPlayer.resume();
        _isPlaying = true;
        _isLoadingAudio = false;
        notifyListeners();
      } catch (e) {
        debugPrint('Error resuming song: $e');
        _isLoadingAudio = false;
        notifyListeners();
      }
    }
  }

  void stopSong() async {
    await _audioPlayer.stop();
    _currentSong = null;
    _isPlaying = false;
    _isLoadingAudio = false;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_song'); // Clear the saved song when playback stops
  }

  void toggleLoop() {
    _isLooping = !_isLooping;
    _audioPlayer.setReleaseMode(
      _isLooping ? ReleaseMode.loop : ReleaseMode.stop,
    );
    notifyListeners();
  }

  void toggleShuffle() {
    _isShuffling = !_isShuffling;
    notifyListeners();
  }

  void setQueue(List<Song> songs) {
    _queue = songs;
    _currentIndex = songs.isNotEmpty ? 0 : -1;
    notifyListeners();
  }

  void playPrevious() {
    if (_queue.isNotEmpty && _currentIndex > 0) {
      _currentIndex--;
      playSong(_queue[_currentIndex]);
    }
  }

  void playNext() {
    if (_queue.isNotEmpty && _currentIndex < _queue.length - 1) {
      _currentIndex++;
      playSong(_queue[_currentIndex]);
    }
  }

  void downloadSong(Song song) {
    _isDownloadingSong = true;
    notifyListeners();
    // Implement download logic here
    debugPrint('Downloading song: ${song.title}');
    _isDownloadingSong = false;
    notifyListeners();
  }

  void addToQueue(Song song) {
    _queue.add(song);
    notifyListeners();
  }

  Future<void> downloadSongInBackground(Song song) async {
    _isDownloadingSong = true;
    notifyListeners();
    String? audioUrl;
    try {
      final apiService = ApiService();
      audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
      if (audioUrl == null) {
        debugPrint('Failed to fetch audio URL.');
        _isDownloadingSong = false;
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('Error fetching audio URL: $e');
      _isDownloadingSong = false;
      notifyListeners();
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/${song.title}.mp3';
      final url = audioUrl;

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          if (totalBytes != null) {
            _downloadProgress[song.title] = bytes.length / totalBytes;
            notifyListeners(); // Notify listeners to update UI
          }
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          song.localFilePath = filePath;
          song.isDownloaded = true;
          _downloadProgress.remove(song.title);
          _isDownloadingSong = false;
          notifyListeners();
          debugPrint('Download complete!');
        },
        onError: (e) {
          debugPrint('Download failed: $e');
          _downloadProgress.remove(song.title);
          _isDownloadingSong = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('Error downloading song: $e');
      _downloadProgress.remove(song.title);
      _isDownloadingSong = false;
      notifyListeners();
    }
  }

  void playStream(String streamUrl, {required String stationName, String? stationFavicon}) {
    _isLoadingAudio = true;
    notifyListeners();

    _currentSong = Song(
      id: DateTime.now().toString(),
      title: stationName,
      artist: 'Radio Station',
      albumArtUrl: stationFavicon ?? '',
      audioUrl: streamUrl,
      localFilePath: null,
      isDownloaded: false,
    );
    notifyListeners();

    _audioPlayer.play(UrlSource(streamUrl));
    _isPlaying = true;
    _isLoadingAudio = false;
    notifyListeners();

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        if (_isLooping) {
          playStream(streamUrl, stationName: stationName, stationFavicon: stationFavicon);
        } else {
          stopSong();
        }
      }
    });
  }

  void playUrl(String url) {
    // Implement the logic to play the audio from the given URL
    print('Playing URL: $url');
    // Notify listeners if needed
    notifyListeners();
  }

  void setCurrentSong(Song song) {
    _currentSong = song;
    notifyListeners();
  }
}

