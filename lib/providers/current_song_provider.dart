import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/song.dart';

class CurrentSongProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Song? _currentSong;
  bool _isPlaying = false;

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;

  void playSong(Song song) async {
    try {
      _currentSong = song;
      final sourceUrl = song.effectiveAudioUrl;
      if (sourceUrl.isNotEmpty) {
        // Use appropriate source based on whether the song is downloaded
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
      stopSong(); // Stop playback on error
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
}
