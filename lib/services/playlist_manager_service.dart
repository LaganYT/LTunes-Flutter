import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class PlaylistManagerService {
  static const _playlistsKey = 'playlists';
  static final PlaylistManagerService _instance = PlaylistManagerService._internal();
  factory PlaylistManagerService() => _instance;
  PlaylistManagerService._internal();

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
        _playlists.map((playlist) => jsonEncode(playlist.toJson())).toList();
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
    playlist.songs.removeWhere((s) => s.title == song.title && s.artist == song.artist);
  }
  
  Future<void> downloadAllSongsInPlaylist(Playlist playlist) async {
    for (var song in playlist.songs) {
      if (!song.isDownloaded) {
        // Simulate download.
        song.isDownloaded = true;
        song.localFilePath = '/downloads/${song.title}.mp3';
      }
    }
    await savePlaylists();
  }
}

class PlaylistManager {
  List<Playlist> playlists = [];

  Future<void> loadPlaylists() async {
    // Mock implementation for loading playlists
    playlists = [
    ];
  }
}