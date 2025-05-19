import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'playlist.dart';
import 'song.dart';

class PlaylistManager {
  static const _playlistsKey = 'playlists';
  List<Playlist> _playlists = [];

  Future<void> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList = prefs.getStringList(_playlistsKey) ?? [];
    _playlists = playlistJsonList.map((jsonStr) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        return Playlist.fromJson(map);
      } catch (e) {
        return null; // Skip invalid playlist.
      }
    }).whereType<Playlist>().toList();
  }

  Future<void> savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList =
        _playlists.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_playlistsKey, playlistJsonList);
  }

  List<Playlist> get playlists => List.unmodifiable(_playlists);

  void addPlaylist(Playlist playlist) {
    _playlists.add(playlist);
  }

  void removePlaylist(Playlist playlist) {
    _playlists.remove(playlist);
  }
  
  void renamePlaylist(String id, String newName) {
    final playlist = _playlists.firstWhere((p) => p.id == id, orElse: () => throw Exception('Playlist not found'));
    playlist.rename(newName);
  }
  
  void addSongToPlaylist(Playlist playlist, Song song) {
    if (!playlist.songs.any((s) => s.title == song.title && s.artist == song.artist)) {
      playlist.songs.add(song);
    }
  }

  void removeSongFromPlaylist(Playlist playlist, Song song) {
    playlist.songs.remove(song);
  }
}
