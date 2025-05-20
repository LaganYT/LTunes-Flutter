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

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  bool get isShuffling => _isShuffling;
  List<Song> get queue => _queue;

  void playSong(Song song) async {
    try {
      _currentSong = song;
      final sourceUrl = song.effectiveAudioUrl;
      if (sourceUrl.isNotEmpty) {
        if (song.isDownloaded) {
          await _audioPlayer.play(DeviceFileSource(sourceUrl));
        } else {
          await _audioPlayer.play(UrlSource(sourceUrl));
        }
        _isPlaying = true;
        notifyListeners();
      } else {
        debugPrint('No valid audio URL for song: ${song.title}');
        stopSong();
      }
    } catch (e) {
      debugPrint('Error playing song: $e');
      stopSong();
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
    // Implement download logic here
    debugPrint('Downloading song: ${song.title}');
  }

  void addToQueue(Song song) {
    _queue.add(song);
    notifyListeners();
  }
}
