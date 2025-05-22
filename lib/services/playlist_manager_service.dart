import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class PlaylistManagerService extends ChangeNotifier {
  static const _playlistsKey = 'playlists';
  static final PlaylistManagerService _instance = PlaylistManagerService._internal();
  factory PlaylistManagerService() => _instance;
  PlaylistManagerService._internal() {
    loadPlaylists(); // Load playlists when the service is initialized.
  }

  List<Playlist> _playlists = [];
  
  Future<void> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList = prefs.getStringList(_playlistsKey) ?? [];
    _playlists = playlistJsonList.map((jsonStr) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        return Playlist.fromJson(map);
      } catch (e) {
        debugPrint('Error decoding playlist: $e. JSON: $jsonStr');
        return null; // Skip invalid playlist.
      }
    }).whereType<Playlist>().toList();
    notifyListeners();
  }

  Future<void> savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList = _playlists.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_playlistsKey, playlistJsonList);
    notifyListeners();
  }

  List<Playlist> get playlists => List.unmodifiable(_playlists);

  Future<void> addPlaylist(Playlist playlist) async {
    _playlists.add(playlist);
    await savePlaylists();
  }

  Future<void> removePlaylist(Playlist playlist) async {
    _playlists.removeWhere((p) => p.id == playlist.id);
    await savePlaylists();
  }
  
  Future<void> renamePlaylist(String id, String newName) async {
    try {
      final playlist = _playlists.firstWhere((p) => p.id == id);
      playlist.rename(newName);
      await savePlaylists();
    } catch (e) {
      debugPrint('Playlist not found for renaming: $id');
      // Optionally rethrow or handle as a silent failure
    }
  }
  
  Future<void> addSongToPlaylist(Playlist playlist, Song song) async {
    try {
      final targetPlaylist = _playlists.firstWhere((p) => p.id == playlist.id);
      if (!targetPlaylist.songs.any((s) => s.id == song.id)) {
        targetPlaylist.songs.add(song);
        await savePlaylists();
      }
    } catch (e) {
      debugPrint('Playlist not found for adding song: ${playlist.id}');
    }
  }

  Future<void> removeSongFromPlaylist(Playlist playlist, Song song) async {
    try {
      final targetPlaylist = _playlists.firstWhere((p) => p.id == playlist.id);
      targetPlaylist.songs.removeWhere((s) => s.id == song.id);
      await savePlaylists();
    } catch (e) {
      debugPrint('Playlist not found for removing song: ${playlist.id}');
    }
  }
  
  Future<void> updateSongInPlaylists(Song updatedSong) async {
    bool changed = false;
    for (var playlist in _playlists) {
      final songIndex = playlist.songs.indexWhere((s) => s.id == updatedSong.id);
      if (songIndex != -1) {
        playlist.songs[songIndex] = updatedSong;
        changed = true;
      }
    }
    if (changed) {
      await savePlaylists();
    }
  }

  Future<void> downloadAllSongsInPlaylist(Playlist playlist) async {
    // Implementation for downloading all songs in a playlist
    // This would likely involve iterating through playlist.songs
    // and calling a download method (perhaps from CurrentSongProvider or ApiService)
    // for each song not yet downloaded.
    // Remember to call notifyListeners() if this operation changes playlist state
    // or related song states that the UI should react to.
    debugPrint('Download all songs in playlist "${playlist.name}" - Not yet implemented.');
    // Example:
    // for (var song in playlist.songs) {
    //   if (!song.isDownloaded) {
    //     // await downloadService.download(song);
    //   }
    // }
    // await savePlaylists(); // If song metadata within playlists is updated
  }
}
