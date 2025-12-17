import 'dart:developer';
import 'package:flutter/foundation.dart';
import '../models/lyrics_data.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import 'api_service.dart';

class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  final ApiService _apiService = ApiService();

  /// Smart lyrics fetching based on current local state
  ///
  /// Logic:
  /// 1. If synced lyrics are present locally → don't fetch
  /// 2. If plain lyrics are present → fetch and replace with synced if available, otherwise keep plain
  /// 3. If no lyrics are saved → fetch and save result
  Future<LyricsData?> fetchLyricsIfNeeded(
      Song song, CurrentSongProvider provider) async {
    // Check if synced lyrics are already present locally
    if (song.syncedLyrics != null && song.syncedLyrics!.isNotEmpty) {
      debugPrint(
          "Synced lyrics already present for ${song.title}, skipping fetch");
      return LyricsData(
        plainLyrics: song.plainLyrics,
        syncedLyrics: song.syncedLyrics,
      );
    }

    // Check if plain lyrics are present locally
    bool hasPlainLyrics =
        song.plainLyrics != null && song.plainLyrics!.isNotEmpty;

    // Always fetch if no synced lyrics are present
    debugPrint(
        "Fetching lyrics for ${song.title} (has plain: $hasPlainLyrics)");

    try {
      final lyricsData = await _apiService.fetchLyrics(song.id);

      if (lyricsData == null) {
        // Don't log 404s as they're expected for many songs
        // The API service handles 404s gracefully by returning null
        return null;
      }

      // Determine what to save based on what we have and what we fetched
      String? finalPlainLyrics;
      String? finalSyncedLyrics;

      if (lyricsData.syncedLyrics != null &&
          lyricsData.syncedLyrics!.isNotEmpty) {
        // We got synced lyrics - use them and keep existing plain lyrics as fallback
        finalSyncedLyrics = lyricsData.syncedLyrics;
        finalPlainLyrics = lyricsData.plainLyrics ?? song.plainLyrics;
        debugPrint("Got synced lyrics for ${song.title}, replacing/updating");
      } else if (lyricsData.plainLyrics != null &&
          lyricsData.plainLyrics!.isNotEmpty) {
        // We only got plain lyrics
        if (hasPlainLyrics) {
          // Keep existing plain lyrics if we already had them
          finalPlainLyrics = song.plainLyrics;
          debugPrint("Keeping existing plain lyrics for ${song.title}");
        } else {
          // Use the new plain lyrics if we didn't have any
          finalPlainLyrics = lyricsData.plainLyrics;
          debugPrint("Using new plain lyrics for ${song.title}");
        }
      } else {
        // No lyrics found from API, keep existing if any
        finalPlainLyrics = song.plainLyrics;
        debugPrint(
            "No lyrics found from API for ${song.title}, keeping existing if any");
      }

      // Create the final lyrics data
      final finalLyricsData = LyricsData(
        plainLyrics: finalPlainLyrics,
        syncedLyrics: finalSyncedLyrics,
      );

      // Save the updated lyrics if we have any changes
      if (_hasLyricsChanges(song, finalLyricsData)) {
        await provider.updateSongLyrics(song.id, finalLyricsData);
        debugPrint("Updated lyrics for ${song.title}");
      }

      return finalLyricsData;
    } catch (e) {
      debugPrint("Error fetching lyrics for ${song.title}: $e");
      // Return existing lyrics if available, otherwise null
      if (hasPlainLyrics) {
        return LyricsData(
          plainLyrics: song.plainLyrics,
          syncedLyrics: song.syncedLyrics,
        );
      }
      return null;
    }
  }

  /// Check if there are meaningful changes between current and new lyrics
  bool _hasLyricsChanges(Song song, LyricsData newLyrics) {
    // Check if synced lyrics changed
    if (song.syncedLyrics != newLyrics.syncedLyrics) {
      return true;
    }

    // Check if plain lyrics changed
    if (song.plainLyrics != newLyrics.plainLyrics) {
      return true;
    }

    return false;
  }

  /// Force fetch lyrics regardless of current state (for manual refresh)
  Future<LyricsData?> forceFetchLyrics(
      Song song, CurrentSongProvider provider) async {
    debugPrint("Force fetching lyrics for ${song.title}");

    try {
      final lyricsData = await _apiService.fetchLyrics(song.id);

      if (lyricsData != null) {
        await provider.updateSongLyrics(song.id, lyricsData);
        debugPrint("Force updated lyrics for ${song.title}");
      } else {
        // Don't log when lyrics are not found (404s are handled gracefully by API service)
        debugPrint("No lyrics available for ${song.title}");
      }

      return lyricsData;
    } catch (e) {
      debugPrint("Error force fetching lyrics for ${song.title}: $e");
      return null;
    }
  }

  /// Check if a song has any lyrics (local or remote)
  bool hasLyrics(Song song) {
    return (song.syncedLyrics != null && song.syncedLyrics!.isNotEmpty) ||
        (song.plainLyrics != null && song.plainLyrics!.isNotEmpty);
  }

  /// Check if a song has synced lyrics
  bool hasSyncedLyrics(Song song) {
    return song.syncedLyrics != null && song.syncedLyrics!.isNotEmpty;
  }

  /// Check if a song has plain lyrics
  bool hasPlainLyrics(Song song) {
    return song.plainLyrics != null && song.plainLyrics!.isNotEmpty;
  }

  /// Get the best available lyrics for display
  String? getBestLyrics(Song song) {
    if (hasSyncedLyrics(song)) {
      return song.syncedLyrics;
    } else if (hasPlainLyrics(song)) {
      return song.plainLyrics;
    }
    return null;
  }
}
