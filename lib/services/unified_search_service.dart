import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/song.dart';
import '../models/album.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart';

// Simple RadioStation model for search
class RadioStation {
  final String id;
  final String name;
  final String imageUrl;
  final String streamUrl;

  RadioStation({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.streamUrl,
  });

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    return RadioStation(
      id: json['id'] as String,
      name: json['name'] as String,
      imageUrl: json['imageUrl'] as String,
      streamUrl: json['streamUrl'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'imageUrl': imageUrl,
      'streamUrl': streamUrl,
    };
  }
}

// Search result types
enum SearchResultType {
  song,
  album,
  playlist,
  radioStation,
}

// Unified search result
class SearchResult {
  final SearchResultType type;
  final dynamic item;
  final double relevanceScore;
  final List<String> matchedFields;

  SearchResult({
    required this.type,
    required this.item,
    required this.relevanceScore,
    required this.matchedFields,
  });
}

class UnifiedSearchService extends ChangeNotifier {
  static final UnifiedSearchService _instance = UnifiedSearchService._internal();
  factory UnifiedSearchService() => _instance;
  UnifiedSearchService._internal();

  // Cache for search results
  final Map<String, List<SearchResult>> _searchCache = {};
  static const int _maxCacheSize = 100;

  // Search weights for different fields
  static const Map<String, double> _fieldWeights = {
    'title': 1.0,
    'artist': 0.9,
    'album': 0.8,
    'name': 1.0, // For playlists and radio stations
    'lyrics': 0.6,
    'genre': 0.7,
    'releaseDate': 0.5,
    'composer': 0.6,
    'playCount': 0.3,
  };

  /// Perform unified search across all library items
  Future<List<SearchResult>> search(String query) async {
    if (query.trim().isEmpty) {
      return [];
    }

    final normalizedQuery = query.toLowerCase().trim();
    
    // Check cache first
    if (_searchCache.containsKey(normalizedQuery)) {
      return _searchCache[normalizedQuery]!;
    }

    try {
      final results = <SearchResult>[];
      
      // Search songs
      final songs = await _loadDownloadedSongs();
      debugPrint('Loaded ${songs.length} songs for search');
      results.addAll(_searchSongs(songs, normalizedQuery));
      
      // Search albums
      final albums = await _loadSavedAlbums();
      debugPrint('Loaded ${albums.length} albums for search');
      results.addAll(_searchAlbums(albums, normalizedQuery));
      
      // Search playlists
      final playlists = await _loadPlaylists();
      debugPrint('Loaded ${playlists.length} playlists for search');
      results.addAll(_searchPlaylists(playlists, normalizedQuery));
      
      // Search radio stations
      final radioStations = await _loadRecentRadioStations();
      debugPrint('Loaded ${radioStations.length} radio stations for search');
      results.addAll(_searchRadioStations(radioStations, normalizedQuery));

      debugPrint('Found ${results.length} total search results for query: "$normalizedQuery"');

      // Sort by relevance score
      results.sort((a, b) => b.relevanceScore.compareTo(a.relevanceScore));

      // Cache results
      _cacheResults(normalizedQuery, results);
      
      return results;
    } catch (e) {
      debugPrint('Error in unified search: $e');
      return [];
    }
  }

  /// Search songs by metadata
  List<SearchResult> _searchSongs(List<Song> songs, String query) {
    final results = <SearchResult>[];
    
    for (final song in songs) {
      final matchedFields = <String>[];
      double totalScore = 0.0;
      
      // Search in title
      if (song.title.toLowerCase().contains(query)) {
        matchedFields.add('title');
        totalScore += _fieldWeights['title']! * _calculateRelevance(song.title, query);
        debugPrint('Song match - title: "${song.title}" for query: "$query"');
      }
      
      // Search in artist
      if (song.artist.toLowerCase().contains(query)) {
        matchedFields.add('artist');
        totalScore += _fieldWeights['artist']! * _calculateRelevance(song.artist, query);
        debugPrint('Song match - artist: "${song.artist}" for query: "$query"');
      }
      
      // Search in album
      if (song.album != null && song.album!.toLowerCase().contains(query)) {
        matchedFields.add('album');
        totalScore += _fieldWeights['album']! * _calculateRelevance(song.album!, query);
        debugPrint('Song match - album: "${song.album}" for query: "$query"');
      }
      
      // Search in lyrics
      if (song.plainLyrics != null && song.plainLyrics!.toLowerCase().contains(query)) {
        matchedFields.add('lyrics');
        totalScore += _fieldWeights['lyrics']! * _calculateRelevance(song.plainLyrics!, query);
        debugPrint('Song match - lyrics for query: "$query"');
      }
      
      // Search in release date
      if (song.releaseDate != null && song.releaseDate!.toLowerCase().contains(query)) {
        matchedFields.add('releaseDate');
        totalScore += _fieldWeights['releaseDate']! * _calculateRelevance(song.releaseDate!, query);
        debugPrint('Song match - release date: "${song.releaseDate}" for query: "$query"');
      }
      
      // Search in extras (genre, composer, etc.)
      if (song.extras != null) {
        for (final entry in song.extras!.entries) {
          if (entry.value.toString().toLowerCase().contains(query)) {
            matchedFields.add(entry.key);
            totalScore += (_fieldWeights[entry.key] ?? 0.5) * _calculateRelevance(entry.value.toString(), query);
            debugPrint('Song match - ${entry.key}: "${entry.value}" for query: "$query"');
          }
        }
      }
      
      // Bonus for play count (popularity)
      if (song.playCount > 0) {
        totalScore += _fieldWeights['playCount']! * (song.playCount / 100.0); // Normalize play count
      }
      
      if (matchedFields.isNotEmpty) {
        results.add(SearchResult(
          type: SearchResultType.song,
          item: song,
          relevanceScore: totalScore,
          matchedFields: matchedFields,
        ));
      }
    }
    
    debugPrint('Found ${results.length} song matches for query: "$query"');
    return results;
  }

  /// Search albums by metadata
  List<SearchResult> _searchAlbums(List<Album> albums, String query) {
    final results = <SearchResult>[];
    
    for (final album in albums) {
      final matchedFields = <String>[];
      double totalScore = 0.0;
      
      // Search in album title
      if (album.title.toLowerCase().contains(query)) {
        matchedFields.add('title');
        totalScore += _fieldWeights['title']! * _calculateRelevance(album.title, query);
      }
      
      // Search in artist name
      if (album.artistName.toLowerCase().contains(query)) {
        matchedFields.add('artist');
        totalScore += _fieldWeights['artist']! * _calculateRelevance(album.artistName, query);
      }
      
      // Search in release date
      if (album.releaseDate.toLowerCase().contains(query)) {
        matchedFields.add('releaseDate');
        totalScore += _fieldWeights['releaseDate']! * _calculateRelevance(album.releaseDate, query);
      }
      
      // Search in tracks
      for (final track in album.tracks) {
        if (track.title.toLowerCase().contains(query) || 
            track.artist.toLowerCase().contains(query)) {
          matchedFields.add('tracks');
          totalScore += _fieldWeights['title']! * 0.5; // Lower weight for track matches
          break;
        }
      }
      
      // Bonus for play count
      if (album.playCount > 0) {
        totalScore += _fieldWeights['playCount']! * (album.playCount / 100.0);
      }
      
      if (matchedFields.isNotEmpty) {
        results.add(SearchResult(
          type: SearchResultType.album,
          item: album,
          relevanceScore: totalScore,
          matchedFields: matchedFields,
        ));
      }
    }
    
    return results;
  }

  /// Search playlists by metadata
  List<SearchResult> _searchPlaylists(List<Playlist> playlists, String query) {
    final results = <SearchResult>[];
    
    for (final playlist in playlists) {
      final matchedFields = <String>[];
      double totalScore = 0.0;
      
      // Search in playlist name
      if (playlist.name.toLowerCase().contains(query)) {
        matchedFields.add('name');
        totalScore += _fieldWeights['name']! * _calculateRelevance(playlist.name, query);
      }
      
      // Search in playlist songs
      for (final song in playlist.songs) {
        if (song.title.toLowerCase().contains(query) || 
            song.artist.toLowerCase().contains(query) ||
            (song.album != null && song.album!.toLowerCase().contains(query))) {
          matchedFields.add('songs');
          totalScore += _fieldWeights['title']! * 0.3; // Lower weight for song matches
          break;
        }
      }
      
      if (matchedFields.isNotEmpty) {
        results.add(SearchResult(
          type: SearchResultType.playlist,
          item: playlist,
          relevanceScore: totalScore,
          matchedFields: matchedFields,
        ));
      }
    }
    
    return results;
  }

  /// Search radio stations by metadata
  List<SearchResult> _searchRadioStations(List<RadioStation> stations, String query) {
    final results = <SearchResult>[];
    
    for (final station in stations) {
      final matchedFields = <String>[];
      double totalScore = 0.0;
      
      // Search in station name
      if (station.name.toLowerCase().contains(query)) {
        matchedFields.add('name');
        totalScore += _fieldWeights['name']! * _calculateRelevance(station.name, query);
      }
      
      if (matchedFields.isNotEmpty) {
        results.add(SearchResult(
          type: SearchResultType.radioStation,
          item: station,
          relevanceScore: totalScore,
          matchedFields: matchedFields,
        ));
      }
    }
    
    return results;
  }

  /// Calculate relevance score between text and query
  double _calculateRelevance(String text, String query) {
    final textLower = text.toLowerCase();
    final queryLower = query.toLowerCase();
    
    // Exact match gets highest score
    if (textLower == queryLower) {
      return 1.0;
    }
    
    // Starts with query gets high score
    if (textLower.startsWith(queryLower)) {
      return 0.9;
    }
    
    // Contains query gets medium score
    if (textLower.contains(queryLower)) {
      return 0.7;
    }
    
    // Word boundary matches get lower score
    final words = textLower.split(' ');
    for (final word in words) {
      if (word.startsWith(queryLower)) {
        return 0.6;
      }
    }
    
    return 0.3; // Default low score for partial matches
  }

  /// Load downloaded songs from SharedPreferences
  Future<List<Song>> _loadDownloadedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> keys = prefs.getKeys();
      final List<Song> loadedSongs = [];
      final appDocDir = await getApplicationDocumentsDirectory();
      const String downloadsSubDir = 'ltunes_downloads';

      for (String key in keys) {
        if (key.startsWith('song_')) {
          final String? songJson = prefs.getString(key);
          if (songJson != null) {
            try {
              Map<String, dynamic> songMap = jsonDecode(songJson) as Map<String, dynamic>;
              Song song = Song.fromJson(songMap);
              
              if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
                final checkFile = File(p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
                if (await checkFile.exists()) {
                  loadedSongs.add(song);
                }
              }
            } catch (e) {
              debugPrint('Error decoding song from SharedPreferences for key $key: $e');
            }
          }
        }
      }
      
      return loadedSongs;
    } catch (e) {
      debugPrint('Error loading downloaded songs: $e');
      return [];
    }
  }

  /// Load saved albums from AlbumManagerService
  Future<List<Album>> _loadSavedAlbums() async {
    try {
      final albumManager = AlbumManagerService();
      return List.from(albumManager.savedAlbums);
    } catch (e) {
      debugPrint('Error loading saved albums: $e');
      return [];
    }
  }

  /// Load playlists from PlaylistManagerService
  Future<List<Playlist>> _loadPlaylists() async {
    try {
      final playlistManager = PlaylistManagerService();
      return List.from(playlistManager.playlists);
    } catch (e) {
      debugPrint('Error loading playlists: $e');
      return [];
    }
  }

  /// Load recent radio stations from SharedPreferences
  Future<List<RadioStation>> _loadRecentRadioStations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stationsJson = prefs.getStringList('recent_radio_stations') ?? [];
      return stationsJson
          .map((json) => RadioStation.fromJson(jsonDecode(json) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading recent radio stations: $e');
      return [];
    }
  }

  /// Cache search results
  void _cacheResults(String query, List<SearchResult> results) {
    if (_searchCache.length >= _maxCacheSize) {
      // Remove oldest entry
      final oldestKey = _searchCache.keys.first;
      _searchCache.remove(oldestKey);
    }
    _searchCache[query] = results;
  }

  /// Clear search cache
  void clearCache() {
    _searchCache.clear();
    notifyListeners();
  }

  /// Get search suggestions based on recent searches or popular terms
  Future<List<String>> getSearchSuggestions(String partialQuery) async {
    if (partialQuery.trim().isEmpty) {
      return [];
    }

    final suggestions = <String>[];
    final normalizedQuery = partialQuery.toLowerCase().trim();

    try {
      // Get suggestions from song titles
      final songs = await _loadDownloadedSongs();
      for (final song in songs) {
        if (song.title.toLowerCase().contains(normalizedQuery) && 
            !suggestions.contains(song.title)) {
          suggestions.add(song.title);
        }
        if (song.artist.toLowerCase().contains(normalizedQuery) && 
            !suggestions.contains(song.artist)) {
          suggestions.add(song.artist);
        }
      }

      // Get suggestions from album titles
      final albums = await _loadSavedAlbums();
      for (final album in albums) {
        if (album.title.toLowerCase().contains(normalizedQuery) && 
            !suggestions.contains(album.title)) {
          suggestions.add(album.title);
        }
        if (album.artistName.toLowerCase().contains(normalizedQuery) && 
            !suggestions.contains(album.artistName)) {
          suggestions.add(album.artistName);
        }
      }

      // Limit suggestions
      return suggestions.take(10).toList();
    } catch (e) {
      debugPrint('Error getting search suggestions: $e');
      return [];
    }
  }
} 