import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import '../models/album.dart';
import '../models/song.dart';

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

  /// Downloads and saves album artwork locally
  Future<String?> _downloadAlbumArtwork(Album album) async {
    if (album.fullAlbumArtUrl.isEmpty) return null;
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      
      // Create a unique filename for the album artwork
      final albumIdentifier = '${album.id}_${album.title.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
      final fileName = 'album_art_$albumIdentifier.jpg';
      final filePath = p.join(directory.path, fileName);
      final file = File(filePath);
      
      // Check if file already exists
      if (await file.exists()) {
        debugPrint('Album artwork already exists: $fileName');
        return fileName;
      }
      
      // Download the artwork
      final response = await http.get(Uri.parse(album.fullAlbumArtUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('Album artwork downloaded successfully: $fileName');
        return fileName;
      } else {
        debugPrint('Failed to download album artwork. Status code: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error downloading album artwork: $e');
      return null;
    }
  }

  Future<void> addSavedAlbum(Album album) async {
    if (!_savedAlbums.any((a) => a.id == album.id)) {
      // Download album artwork if not already present
      String? localArtUrl;
      if (album.localAlbumArtUrl == null || album.localAlbumArtUrl!.isEmpty) {
        localArtUrl = await _downloadAlbumArtwork(album);
      } else {
        localArtUrl = album.localAlbumArtUrl;
      }
      
      final albumToSave = album.copyWith(isSaved: true, localAlbumArtUrl: localArtUrl);
      _savedAlbums.add(albumToSave);
      await _saveAlbumsToPrefs();
      notifyListeners();
    } else { // If album exists, ensure its isSaved status is true
      int index = _savedAlbums.indexWhere((a) => a.id == album.id);
      if (index != -1 && !_savedAlbums[index].isSaved) {
        // Download album artwork if not already present
        String? localArtUrl = _savedAlbums[index].localAlbumArtUrl;
        if (localArtUrl == null || localArtUrl.isEmpty) {
          localArtUrl = await _downloadAlbumArtwork(album);
        }
        
        _savedAlbums[index] = _savedAlbums[index].copyWith(isSaved: true, localAlbumArtUrl: localArtUrl);
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

  // Updates a song's download status in all saved albums that contain it
  Future<void> updateSongInAlbums(Song updatedSong) async {
    bool changed = false;
    for (int i = 0; i < _savedAlbums.length; i++) {
      Album album = _savedAlbums[i];
      List<Song> newTracks = List.from(album.tracks);
      bool albumChanged = false;
      for (int j = 0; j < newTracks.length; j++) {
        if (newTracks[j].id == updatedSong.id) {
          if (newTracks[j].isDownloaded != updatedSong.isDownloaded ||
              newTracks[j].localFilePath != updatedSong.localFilePath) {
            newTracks[j] = updatedSong;
            albumChanged = true;
          }
        }
      }
      if (albumChanged) {
        _savedAlbums[i] = album.copyWith(tracks: newTracks);
        changed = true;
      }
    }
    if (changed) {
      await _saveAlbumsToPrefs();
      notifyListeners();
    }
  }
}
