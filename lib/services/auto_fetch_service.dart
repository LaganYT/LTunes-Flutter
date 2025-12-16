import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'api_service.dart';

class AutoFetchService {
  static final AutoFetchService _instance = AutoFetchService._internal();
  factory AutoFetchService() => _instance;
  AutoFetchService._internal();

  final ApiService _apiService = ApiService();

  // Check if auto-fetch is enabled
  Future<bool> isAutoFetchEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('auto_fetch_metadata') ?? false;
    } catch (e) {
      return false;
    }
  }

  // Check for exact match (case-insensitive)
  bool _isExactMatch(Song localSong, Song apiSong) {
    return localSong.title.toLowerCase() == apiSong.title.toLowerCase() &&
           localSong.artist.toLowerCase() == apiSong.artist.toLowerCase();
  }

  // Auto-fetch metadata for a newly imported song
  Future<void> autoFetchMetadataForNewImport(Song song) async {
    if (!await isAutoFetchEnabled()) return;
    
    try {
      final searchResults = await _apiService.fetchSongs('${song.title} ${song.artist}');
      
      if (searchResults.isNotEmpty) {
        // Look for exact match (case-insensitive)
        Song? exactMatch;
        for (final result in searchResults) {
          if (_isExactMatch(song, result)) {
            exactMatch = result;
            break;
          }
        }
        
        if (exactMatch != null) {
          // Convert the local song to a native song with fetched metadata
          await _convertToNativeSong(song, exactMatch);
          debugPrint('Auto-fetched metadata for "${song.title}" by ${song.artist}');
        }
      }
    } catch (e) {
      debugPrint('Error auto-fetching metadata for ${song.title}: $e');
    }
  }

  // Convert local song to native song with fetched metadata
  Future<void> _convertToNativeSong(Song localSong, Song apiSong) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Create a new native song with the fetched metadata
      final nativeSong = Song(
        id: apiSong.id, // Use the API song's ID
        title: apiSong.title,
        artists: apiSong.artists,
        artistIds: apiSong.artistIds,
        album: apiSong.album,
        albumArtUrl: apiSong.albumArtUrl,
        releaseDate: apiSong.releaseDate,
        audioUrl: apiSong.audioUrl,
        duration: apiSong.duration,
        isDownloaded: true, // Keep it as downloaded since we have the local file
        localFilePath: localSong.localFilePath, // Keep the local file path
        extras: apiSong.extras,
        isImported: false, // Mark as native now
        plainLyrics: apiSong.plainLyrics,
        syncedLyrics: apiSong.syncedLyrics,
        playCount: localSong.playCount, // Preserve play count
      );
      
      // Save the new native song metadata
      await prefs.setString('song_${nativeSong.id}', jsonEncode(nativeSong.toJson()));
      
      // Remove the old local song metadata
      await prefs.remove('song_${localSong.id}');
      
    } catch (e) {
      debugPrint('Error converting song to native: $e');
      rethrow;
    }
  }
} 