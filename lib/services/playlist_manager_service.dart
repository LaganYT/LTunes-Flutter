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
    // Prevent adding playlist with duplicate ID or name (optional, based on requirements)
    if (!_playlists.any((p) => p.id == playlist.id || p.name == playlist.name)) {
      _playlists.add(playlist);
      savePlaylists(); // Save after adding
    }
  }

  void removePlaylist(Playlist playlist) {
    _playlists.removeWhere((p) => p.id == playlist.id);
    savePlaylists(); // Save after removing
  }
  
  void renamePlaylist(String id, String newName) {
    final playlist = _playlists.firstWhere((p) => p.id == id, orElse: () => throw Exception('Playlist not found'));
    // Optionally check if another playlist with newName already exists
    playlist.rename(newName);
    savePlaylists(); // Save after renaming
  }
  
  void addSongToPlaylist(Playlist playlist, Song song) {
    final targetPlaylist = _playlists.firstWhere((p) => p.id == playlist.id, orElse: () => throw Exception('Playlist not found'));
    if (!targetPlaylist.songs.any((s) => s.id == song.id)) {
      targetPlaylist.songs.add(song);
      savePlaylists(); // Save after adding song
    }
  }

  void removeSongFromPlaylist(Playlist playlist, Song song) {
    final targetPlaylist = _playlists.firstWhere((p) => p.id == playlist.id, orElse: () => throw Exception('Playlist not found'));
    targetPlaylist.songs.removeWhere((s) => s.id == song.id);
    savePlaylists(); // Save after removing song
  }
  
  void updateSongInPlaylists(Song updatedSong) {
    bool changed = false;
    for (int i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      final songIndex = playlist.songs.indexWhere((s) => s.id == updatedSong.id);
      if (songIndex != -1) {
        // Replace the song instance
        playlist.songs[songIndex] = updatedSong;
        changed = true;
      }
    }
    if (changed) {
      savePlaylists(); // Save if any playlist was modified
    }
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