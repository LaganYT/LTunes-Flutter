import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class PlaylistManagerService with ChangeNotifier {
  static final PlaylistManagerService _instance = PlaylistManagerService._internal();
  factory PlaylistManagerService() => _instance;

  PlaylistManagerService._internal() {
    _loadPlaylists(); // Load playlists on initialization
  }

  static const _playlistsKey = 'playlists_v2'; // Use a distinct key for storage
  List<Playlist> _playlists = [];
  bool _isLoading = false;
  bool _playlistsLoaded = false;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  bool get isLoading => _isLoading;
  bool get playlistsLoaded => _playlistsLoaded;

  Future<void> _loadPlaylists() async {
    if (_playlistsLoaded && !_isLoading) return; // Already loaded and not currently loading
    if (_isLoading) return; // Already loading, wait for it to complete

    _isLoading = true;
    // Do not notify listeners here for initial load triggered by constructor,
    // as widgets might not be ready to listen yet.
    // If called by ensurePlaylistsLoaded, that method can handle notifications if needed.

    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList = prefs.getStringList(_playlistsKey) ?? [];
    try {
      _playlists = playlistJsonList.map((jsonStr) {
        try {
          final map = jsonDecode(jsonStr) as Map<String, dynamic>;
          return Playlist.fromJson(map);
        } catch (e) {
          debugPrint('Error decoding playlist: $e. JSON: $jsonStr');
          return null;
        }
      }).whereType<Playlist>().toList();
    } catch (e) {
      debugPrint('Error processing playlist JSON list: $e');
      _playlists = []; // Default to empty list on error
    }

    _playlistsLoaded = true;
    _isLoading = false;
    notifyListeners(); // Notify after loading is complete
  }

  Future<void> ensurePlaylistsLoaded() async {
    if (!_playlistsLoaded) {
      await _loadPlaylists(); // This will load and notify
    } else if (_isLoading) {
      // If currently loading, wait for it to complete.
      // This can be achieved by listening to a Completer or checking _isLoading in a loop with delay.
      // For simplicity, we'll rely on the fact that subsequent calls to _loadPlaylists are guarded.
      // A more robust solution might involve a Completer.
      while(_isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJsonList = _playlists.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_playlistsKey, playlistJsonList);
    notifyListeners();
  }

  Future<void> addPlaylist(Playlist playlist) async {
    // Ensure playlist with same ID doesn't already exist
    if (!_playlists.any((p) => p.id == playlist.id)) {
      _playlists.add(playlist);
      await _savePlaylists();
    }
  }

  Future<void> removePlaylist(Playlist playlist) async {
    _playlists.removeWhere((p) => p.id == playlist.id);
    await _savePlaylists();
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1) {
      _playlists[index] = _playlists[index].copyWith(name: newName);
      await _savePlaylists();
    }
  }

  Future<void> addSongToPlaylist(Playlist playlist, Song song) async {
    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      Playlist existingPlaylist = _playlists[index];
      if (!existingPlaylist.songs.any((s) => s.id == song.id)) {
        List<Song> updatedSongs = List.from(existingPlaylist.songs)..add(song);
        _playlists[index] = existingPlaylist.copyWith(songs: updatedSongs);
        await _savePlaylists();
      }
    }
  }

  Future<void> removeSongFromPlaylist(Playlist playlist, Song song) async {
    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      Playlist existingPlaylist = _playlists[index];
      List<Song> updatedSongs = List.from(existingPlaylist.songs)..removeWhere((s) => s.id == song.id);
      _playlists[index] = existingPlaylist.copyWith(songs: updatedSongs);
      await _savePlaylists();
    }
  }

  Song? findDownloadedSongByTitleArtist(String title, String artist) {
    final String targetTitle = title.toLowerCase();
    final String targetArtist = artist.toLowerCase();

    for (final playlist in _playlists) {
      for (final songInPlaylist in playlist.songs) {
        if (songInPlaylist.isDownloaded &&
            songInPlaylist.localFilePath != null &&
            songInPlaylist.localFilePath!.isNotEmpty &&
            songInPlaylist.title.toLowerCase() == targetTitle &&
            songInPlaylist.artist.toLowerCase() == targetArtist) {
          return songInPlaylist;
        }
      }
    }
    return null;
  }

  void updateSongInPlaylists(Song updatedSong) {
    bool changed = false;
    for (int i = 0; i < _playlists.length; i++) {
      Playlist p = _playlists[i];
      List<Song> newSongs = List.from(p.songs);
      bool playlistChanged = false;
      for (int j = 0; j < newSongs.length; j++) {
        if (newSongs[j].id == updatedSong.id) {
          // Only update if there's a meaningful change to avoid unnecessary saves/notifies
          if (newSongs[j].isDownloaded != updatedSong.isDownloaded ||
              newSongs[j].localFilePath != updatedSong.localFilePath ||
              newSongs[j].title != updatedSong.title ||
              newSongs[j].artist != updatedSong.artist ||
              newSongs[j].albumArtUrl != updatedSong.albumArtUrl) {
            newSongs[j] = updatedSong;
            playlistChanged = true;
          }
        }
      }
      if (playlistChanged) {
        _playlists[i] = p.copyWith(songs: newSongs);
        changed = true;
      }
    }
    if (changed) {
      _savePlaylists();
    }
  }
}
