import 'dart:convert';
import 'dart:collection';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../models/update_info.dart'; // Import the new model
import '../models/album.dart'; // Import the new Album model
import '../models/lyrics_data.dart'; // Import LyricsData
import 'error_handler_service.dart';
import 'dart:async';

// Performance: Cache entry with TTL
class _CacheEntry<T> {
  final T data;
  final DateTime timestamp;
  
  _CacheEntry(this.data, this.timestamp);
  
  bool get isExpired => DateTime.now().difference(timestamp) > const Duration(minutes: 15);
  bool get isAlbumExpired => DateTime.now().difference(timestamp) > const Duration(hours: 1);
}

// Performance: Pending request queue
class _PendingRequest {
  final String url;
  final Completer<http.Response> completer;
  
  _PendingRequest(this.url, this.completer);
}

class ApiService {
  static final ApiService _instance = ApiService._internal();

  factory ApiService() {
    return _instance;
  }

  ApiService._internal(); // Private constructor

  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  static const String baseUrl = 'https://ltn-api.vercel.app/api/';
  static const String updateUrl = 'https://ltn-api.vercel.app/updates/update.json';

  // Performance: Enhanced caching with TTL
  final Map<String, _CacheEntry<List<Song>>> _songCache = {};
  final Map<String, _CacheEntry<List<dynamic>>> _radioStationCache = {};
  final Map<String, _CacheEntry<String>> _audioUrlCache = {};
  final Map<String, _CacheEntry<Album>> _albumDetailCache = {};
  
  // Performance: HTTP client with connection pooling
  static final http.Client _httpClient = http.Client();
  
  // Performance: Request debouncing
  final Map<String, Timer> _debounceTimers = {};
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  
  // Performance: Concurrent request limiting
  static const int _maxConcurrentRequests = 5;
  int _activeRequests = 0;
  final Queue<_PendingRequest> _pendingRequests = Queue<_PendingRequest>();

  // Performance: Enhanced HTTP GET with connection pooling and request limiting
  Future<http.Response> _get(String url) async {
    // Check if we're at the request limit
    if (_activeRequests >= _maxConcurrentRequests) {
      final completer = Completer<http.Response>();
      _pendingRequests.add(_PendingRequest(url, completer));
      return completer.future;
    }
    
    _activeRequests++;
    
    int retries = 0;
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 500);
    
    try {
      while (true) {
        final response = await _httpClient.get(Uri.parse(url));
        if (response.statusCode == 200) {
          return response;
        } else if (response.statusCode == 404) {
          throw Exception('Resource not found (404) for URL: $url');
        } else if (response.statusCode == 500 && retries < maxRetries) {
          retries++;
          await Future.delayed(retryDelay * retries); // Exponential backoff
          continue;
        } else {
          throw Exception('Failed to load data from $url, Status Code: ${response.statusCode}');
        }
      }
    } catch (e) {
      throw Exception('Error connecting to $url: $e');
    } finally {
      _activeRequests--;
      _processPendingRequests();
    }
  }
  
  // Performance: Process pending requests
  void _processPendingRequests() {
    if (_pendingRequests.isNotEmpty && _activeRequests < _maxConcurrentRequests) {
      final request = _pendingRequests.removeFirst();
      _get(request.url).then(request.completer.complete).catchError(request.completer.completeError);
    }
  }

  // Performance: Debounced search
  Future<List<Song>> _debouncedFetchSongs(String query) async {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;
    
    // Check cache first
    final cached = _songCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }
    
    // Cancel existing timer for this query
    _debounceTimers[cacheKey]?.cancel();
    
    final completer = Completer<List<Song>>();
    
    _debounceTimers[cacheKey] = Timer(_debounceDelay, () async {
      try {
        final songs = await _fetchSongsInternal(query);
        completer.complete(songs);
      } catch (e) {
        completer.completeError(e);
      }
    });
    
    return completer.future;
  }
  
  // Performance: Internal fetch method
  Future<List<Song>> _fetchSongsInternal(String query) async {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;
    
    final Uri url;
    if (query.isNotEmpty) {
      url = Uri.parse('${baseUrl}search/?query=${Uri.encodeComponent(query)}');
    } else {
      url = Uri.parse('${baseUrl}topCharts');
    }

    try {
      final response = await _get(url.toString());
      dynamic data = json.decode(response.body);

      List<dynamic> items;
      if (query.isNotEmpty) {
        items = data;
      } else {
        if (data is Map && data.containsKey('tracks') && data['tracks'] is List) {
          items = data['tracks'];
        } else if (data is List) {
          items = data;
        } else {
          items = [];
        }
      }

      final songs = items.map<Song>((json) => Song.fromJson(json)).toList();
      
      // Performance: Cache with TTL
      _songCache[cacheKey] = _CacheEntry(songs, DateTime.now());
      
      return songs;
    } catch (e) {
      rethrow;
    }
  }

  Future<String?> _searchForAlbumId(String albumName, String artistName) async {
    final query = '${albumName.trim()} ${artistName.trim()}';
    final url = '${baseUrl}search/albums?query=${Uri.encodeComponent(query)}';
    try {
      final response = await _get(url);
      List<dynamic> searchResults = jsonDecode(response.body);
      if (searchResults.isNotEmpty) {
        return searchResults.first['ALB_ID']?.toString();
      }
      return null;
    } catch (e) {
      _errorHandler.logError(e, context: 'searchForAlbumId');
      return null;
    }
  }

  Future<Album?> fetchAlbumDetailsById(String albumId) async {
    final cached = _albumDetailCache[albumId];
    if (cached != null && !cached.isAlbumExpired) {
      return cached.data;
    }
    
    final url = '${baseUrl}album/$albumId';
    try {
      final response = await _get(url);
      Map<String, dynamic> data = jsonDecode(response.body);
      final album = Album.fromJson(data);
      
      // Performance: Cache with longer TTL for albums
      _albumDetailCache[albumId] = _CacheEntry(album, DateTime.now());
      
      return album;
    } catch (e) {
      _errorHandler.logError(e, context: 'fetchAlbumDetailsById');
      return null;
    }
  }

  Future<Album?> getAlbum(String albumName, String artistName) async {
    final albumId = await _searchForAlbumId(albumName, artistName);
    if (albumId != null) {
      return await fetchAlbumDetailsById(albumId);
    }
    return null;
  }

  // Performance: Use debounced fetch
  Future<List<Song>> fetchSongs(String query) async {
    return _debouncedFetchSongs(query);
  }

  Future<String> downloadSong(String url, String fileName) async {
    return url;
  }

  Future<String?> fetchAudioUrl(String artist, String musicName) async {
    final cacheKey = '${artist}_$musicName';
    final cached = _audioUrlCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }
    
    final Uri url = Uri.parse(
        '${baseUrl}audio/?artist=${Uri.encodeComponent(artist)}&musicName=${Uri.encodeComponent(musicName)}');
    try {
      final response = await _get(url.toString());
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data != null && data['audioURL'] != null) {
          final audioUrl = data['audioURL'] as String;
          
          // Performance: Cache audio URLs
          _audioUrlCache[cacheKey] = _CacheEntry(audioUrl, DateTime.now());
          
          return audioUrl;
        }
      }
      return null;
    } catch (e) {
      _errorHandler.logError(e, context: 'fetchAudioUrl');
      return null;
    }
  }

  Future<List<dynamic>> fetchStationsByCountry(String country, {String name = ''}) async {
    final String cacheKey = "${country}_$name";
    final cached = _radioStationCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }

    final queryParams = <String, String>{};
    if (country.isNotEmpty) queryParams['country'] = country;
    if (name.isNotEmpty) queryParams['name'] = name;
    
    final url = Uri.https('ltn-api.vercel.app', '/api/radio', queryParams.isEmpty ? null : queryParams);
    
    try {
      final response = await _get(url.toString());
      if (response.statusCode == 200) {
        try {
          final stations = json.decode(response.body) as List<dynamic>;
          
          // Performance: Cache radio stations
          _radioStationCache[cacheKey] = _CacheEntry(stations, DateTime.now());
          
          return stations;
        } catch (e) {
          throw Exception('Error decoding JSON: $e\nResponse body: ${response.body}');
        }
      } else if (response.statusCode == 404) {
        final emptyStations = <dynamic>[];
        _radioStationCache[cacheKey] = _CacheEntry(emptyStations, DateTime.now());
        return emptyStations;
      } else {
        throw Exception('Failed to load radio stations. Status code: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching radio stations: $e');
    }
  }

  // Performance: Enhanced cache clearing with TTL
  void clearSongCache(String query) {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;
    _songCache.remove(cacheKey);
    _debounceTimers[cacheKey]?.cancel();
    _debounceTimers.remove(cacheKey);
  }

  void clearRadioStationCache(String country, String name) {
    final String cacheKey = "${country}_$name";
    _radioStationCache.remove(cacheKey);
  }

  // Performance: Clear all caches
  void clearAllCaches() {
    _songCache.clear();
    _radioStationCache.clear();
    _audioUrlCache.clear();
    _albumDetailCache.clear();
    
    // Cancel all debounce timers
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
  }

  // Performance: Cleanup expired cache entries
  void _cleanupExpiredCache() {
    _songCache.removeWhere((key, entry) => entry.isExpired);
    _radioStationCache.removeWhere((key, entry) => entry.isExpired);
    _audioUrlCache.removeWhere((key, entry) => entry.isExpired);
    _albumDetailCache.removeWhere((key, entry) => entry.isAlbumExpired);
  }

  // Performance: Periodic cache cleanup
  void startCacheCleanup() {
    Timer.periodic(const Duration(minutes: 5), (timer) {
      _cleanupExpiredCache();
    });
  }

  // Performance: Dispose resources
  void dispose() {
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    _httpClient.close();
  }

  // Method to compare versions (e.g., "1.0.1" vs "1.0.0")
  // Returns > 0 if v1 is greater, < 0 if v2 is greater, 0 if equal
  int _compareVersions(String v1, String v2) {
    List<int> v1Parts = v1.split('.').map(int.parse).toList();
    List<int> v2Parts = v2.split('.').map(int.parse).toList();

    for (int i = 0; i < v1Parts.length || i < v2Parts.length; i++) {
      int part1 = (i < v1Parts.length) ? v1Parts[i] : 0;
      int part2 = (i < v2Parts.length) ? v2Parts[i] : 0;

      if (part1 < part2) return -1;
      if (part1 > part2) return 1;
    }
    return 0;
  }

  Future<UpdateInfo?> checkForUpdate(String currentAppVersion) async {
    try {
      final response = await http.get(Uri.parse(updateUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final updateInfo = UpdateInfo.fromJson(data);

        if (_compareVersions(updateInfo.version, currentAppVersion) > 0) {
          return updateInfo;
        }
      } else {
        debugPrint('Failed to fetch update info: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error checking for update: $e');
    }
    return null;
  }

  Future<LyricsData?> fetchLyrics(String artist, String musicName) async {
    final url = '${baseUrl}lyrics?artist=${Uri.encodeComponent(artist)}&musicName=${Uri.encodeComponent(musicName)}';
    try {
      final response = await _get(url); 
      final data = jsonDecode(response.body);
      
      if (data != null && data['lyrics'] != null && data['lyrics'] is Map) {
        final lyricsMap = data['lyrics'] as Map<String, dynamic>;
        return LyricsData(
          plainLyrics: lyricsMap['plainLyrics'] as String?,
          syncedLyrics: lyricsMap['syncedLyrics'] as String?,
        );
      }
      return null; 
    } catch (e) {
      _errorHandler.logError(e, context: 'fetchLyrics');
      if (e.toString().contains('404')) {
        return null; 
      }
      rethrow; 
    }
  }

  Future<Map<String, dynamic>> getArtistById(String query) async {
    try {
      late String artistId;
      if (RegExp(r'^\d+$').hasMatch(query)) {
        artistId = query;
      } else {
        final searchUrl = '${baseUrl}search/artists?query=${Uri.encodeComponent(query)}';
        final searchResp = await _get(searchUrl);
        final List<dynamic> results = jsonDecode(searchResp.body) as List<dynamic>;
        if (results.isEmpty) {
          throw Exception('No artists found for query: "$query"');
        }
        artistId = results.first['ART_ID']?.toString() ?? '';
        if (artistId.isEmpty) {
          throw Exception('Artist ID missing in search results for "$query"');
        }
      }

      final detailUrl = '${baseUrl}artist/$artistId';
      final detailResp = await _get(detailUrl);
      return jsonDecode(detailResp.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('getArtistById failed for "$query": $e');
    }
  }

  Future<List<Album>> getArtistAlbums(String artistId) async {
    try {
      final response = await _get('${baseUrl}artist/$artistId/albums');
      
      final data = json.decode(response.body);
      
      // Handle different possible response structures
      List<dynamic> albumList = [];
      
      if (data is List) {
        // If the response is directly an array of albums
        albumList = data;
      } else if (data is Map<String, dynamic>) {
        // If the response is an object with albums in a 'data' property
        if (data.containsKey('data') && data['data'] is List) {
          albumList = data['data'];
        } else if (data.containsKey('albums') && data['albums'] is List) {
          albumList = data['albums'];
        } else {
          // If the response object itself contains album data
          return [Album.fromJson(data)];
        }
      }
      
      return albumList
          .map((albumData) => Album.fromJson(albumData as Map<String, dynamic>))
          .toList();
          
    } catch (e) {
      _errorHandler.logError(e, context: 'getArtistAlbums');
      return [];
    }
  }
}
