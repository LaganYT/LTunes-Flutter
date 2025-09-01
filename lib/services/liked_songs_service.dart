import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

class LikedSongsService with ChangeNotifier {
  static final LikedSongsService _instance = LikedSongsService._internal();
  factory LikedSongsService() => _instance;
  LikedSongsService._internal();

  static const String _likedSongsKey = 'liked_songs';
  List<Song> _likedSongs = [];
  Set<String> _likedSongIds = {};
  bool _isLoaded = false;

  List<Song> get likedSongs => List.unmodifiable(_likedSongs);
  Set<String> get likedSongIds => Set.unmodifiable(_likedSongIds);
  bool get isLoaded => _isLoaded;

  /// Load liked songs from SharedPreferences
  Future<void> loadLikedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_likedSongsKey) ?? [];

      final songs = <Song>[];
      final ids = <String>{};

      for (final songJson in raw) {
        try {
          final songData = jsonDecode(songJson) as Map<String, dynamic>;
          final song = Song.fromJson(songData);
          songs.add(song);
          ids.add(song.id);
        } catch (e) {
          debugPrint('Error decoding liked song: $e');
        }
      }

      _likedSongs = songs;
      _likedSongIds = ids;
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading liked songs: $e');
      _likedSongs = [];
      _likedSongIds = {};
      _isLoaded = true;
    }
  }

  /// Check if a song is liked
  bool isLiked(String songId) {
    return _likedSongIds.contains(songId);
  }

  /// Add a song to liked songs
  Future<void> addLikedSong(Song song) async {
    if (_likedSongIds.contains(song.id)) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_likedSongsKey) ?? [];

      raw.add(jsonEncode(song.toJson()));
      await prefs.setStringList(_likedSongsKey, raw);

      _likedSongs.add(song);
      _likedSongIds.add(song.id);
      notifyListeners();

      debugPrint('Added song ${song.id} to liked songs');
    } catch (e) {
      debugPrint('Error adding song to liked songs: $e');
    }
  }

  /// Remove a song from liked songs
  Future<void> removeLikedSong(String songId) async {
    if (!_likedSongIds.contains(songId)) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_likedSongsKey) ?? [];

      raw.removeWhere((songJson) {
        try {
          return (jsonDecode(songJson) as Map<String, dynamic>)['id'] == songId;
        } catch (_) {
          return false;
        }
      });

      await prefs.setStringList(_likedSongsKey, raw);

      _likedSongs.removeWhere((song) => song.id == songId);
      _likedSongIds.remove(songId);
      notifyListeners();

      debugPrint('Removed song $songId from liked songs');
    } catch (e) {
      debugPrint('Error removing song from liked songs: $e');
    }
  }

  /// Toggle like status of a song
  Future<bool> toggleLike(Song song) async {
    if (isLiked(song.id)) {
      await removeLikedSong(song.id);
      return false;
    } else {
      await addLikedSong(song);
      return true;
    }
  }

  /// Remove a local song from liked songs (used during song deletion)
  /// This method specifically checks if the song is local before removing
  Future<void> removeLocalSongFromLiked(Song song) async {
    if (!song.isDownloaded ||
        song.localFilePath == null ||
        song.localFilePath!.isEmpty) {
      return; // Not a local song, no need to remove
    }

    if (!_likedSongIds.contains(song.id)) {
      return; // Song is not in liked songs
    }

    await removeLikedSong(song.id);
    debugPrint(
        'Removed local song ${song.id} from liked songs (song deletion cleanup)');
  }

  /// Update song details in liked songs (useful when song metadata changes)
  Future<void> updateSongInLikedSongs(Song updatedSong) async {
    if (!_likedSongIds.contains(updatedSong.id)) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_likedSongsKey) ?? [];

      // Replace the song in the raw list
      for (int i = 0; i < raw.length; i++) {
        try {
          final songData = jsonDecode(raw[i]) as Map<String, dynamic>;
          if (songData['id'] == updatedSong.id) {
            raw[i] = jsonEncode(updatedSong.toJson());
            break;
          }
        } catch (_) {
          continue;
        }
      }

      await prefs.setStringList(_likedSongsKey, raw);

      // Update the in-memory list
      final index = _likedSongs.indexWhere((song) => song.id == updatedSong.id);
      if (index != -1) {
        _likedSongs[index] = updatedSong;
        notifyListeners();
      }

      debugPrint('Updated song ${updatedSong.id} in liked songs');
    } catch (e) {
      debugPrint('Error updating song in liked songs: $e');
    }
  }

  /// Get the current list of liked song IDs (useful for UI state)
  Future<Set<String>> getLikedSongIds() async {
    if (!_isLoaded) {
      await loadLikedSongs();
    }
    return Set.from(_likedSongIds);
  }
}
