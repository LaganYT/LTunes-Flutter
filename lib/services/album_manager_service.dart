import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/album.dart';

class AlbumManagerService with ChangeNotifier {
  static final AlbumManagerService _instance = AlbumManagerService._internal();
  factory AlbumManagerService() => _instance;
  AlbumManagerService._internal() {
    loadSavedAlbums();
  }

  static const _savedAlbumsKey = 'saved_albums_v1'; // Added versioning
  List<Album> _savedAlbums = [];

  List<Album> get savedAlbums => List.unmodifiable(_savedAlbums);

  Future<void> loadSavedAlbums() async {
    final prefs = await SharedPreferences.getInstance();
    final albumsJsonList = prefs.getStringList(_savedAlbumsKey) ?? [];
    try {
      _savedAlbums = albumsJsonList
          .map((jsonStr) => Album.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint("Error loading saved albums: $e. Clearing corrupted data.");
      _savedAlbums = [];
      await prefs.setStringList(_savedAlbumsKey, []); // Clear corrupted data
    }
    notifyListeners();
  }

  Future<void> _saveAlbumsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final albumsJsonList =
        _savedAlbums.map((album) => jsonEncode(album.toJson())).toList();
    await prefs.setStringList(_savedAlbumsKey, albumsJsonList);
  }

  Future<void> addSavedAlbum(Album album) async {
    if (!_savedAlbums.any((a) => a.id == album.id)) {
      final albumToSave = album.copyWith(isSaved: true);
      _savedAlbums.add(albumToSave);
      await _saveAlbumsToPrefs();
      notifyListeners();
    } else { // If album exists, ensure its isSaved status is true
      int index = _savedAlbums.indexWhere((a) => a.id == album.id);
      if (index != -1 && !_savedAlbums[index].isSaved) {
        _savedAlbums[index] = _savedAlbums[index].copyWith(isSaved: true);
        await _saveAlbumsToPrefs();
        notifyListeners();
      }
    }
  }

  Future<void> removeSavedAlbum(String albumId) async {
    _savedAlbums.removeWhere((album) => album.id == albumId);
    await _saveAlbumsToPrefs();
    notifyListeners();
  }

  bool isAlbumSaved(String albumId) {
    return _savedAlbums.any((album) => album.id == albumId && album.isSaved);
  }
}
