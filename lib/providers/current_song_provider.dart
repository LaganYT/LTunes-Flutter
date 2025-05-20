import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/song.dart';

class CurrentSongProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Song? _currentSong;
  bool _isPlaying = false;
  bool _isLooping = false;
  bool _isShuffling = false;
  List<Song> _queue = [];
  int _currentIndex = -1;
  final Map<String, String> _urlCache = {}; // Cache for song URLs
  bool isLoading = false;

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  bool get isShuffling => _isShuffling;
  List<Song> get queue => _queue;

  void playSong(Song song) async {
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
      notifyListeners();

      // Pre-fetch the next 3 songs in the queue
      _prefetchNextSongs();
    } catch (e) {
      debugPrint('Error playing song: $e');
      stopSong();
      // Notify the user about the error
      notifyListeners();
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
    notifyListeners();
  }

  void resumeSong() async {
    if (currentSong != null) {
      await _audioPlayer.resume();
      _isPlaying = true;
      notifyListeners();
    }
  }

  void stopSong() async {
    await _audioPlayer.stop();
    _currentSong = null;
    _isPlaying = false;
    notifyListeners();
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
    isLoading = true;
    notifyListeners();
    // Implement download logic here
    debugPrint('Downloading song: ${song.title}');
    isLoading = false;
    notifyListeners();
  }

  void addToQueue(Song song) {
    _queue.add(song);
    notifyListeners();
  }
}
