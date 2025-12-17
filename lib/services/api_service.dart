import 'dart:convert';
import 'dart:collection';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../models/update_info.dart'; // Import the new model
import '../models/album.dart'; // Import the new Album model
import '../models/lyrics_data.dart'; // Import LyricsData
import 'error_handler_service.dart';
import 'version_service.dart'; // Import VersionService
import 'release_channel_service.dart'; // Import ReleaseChannelService
import 'dart:async';

// Performance: Cache entry with TTL
class _CacheEntry<T> {
  final T data;
  final DateTime timestamp;

  _CacheEntry(this.data, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > const Duration(minutes: 15);
  bool get isAlbumExpired =>
      DateTime.now().difference(timestamp) > const Duration(hours: 1);
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

  static const String baseUrl = 'https://apiv2.ltunes.app/api/';
  static const String originalBaseUrl = 'https://ltn-api.vercel.app/api/';

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
        final response = await _httpClient.get(Uri.parse(url)).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw Exception('Request timeout for URL: $url');
          },
        );

        if (response.statusCode == 200) {
          return response;
        } else if (response.statusCode == 404) {
          throw Exception('Resource not found (404) for URL: $url');
        } else if (response.statusCode == 500 && retries < maxRetries) {
          retries++;
          await Future.delayed(retryDelay * retries); // Exponential backoff
          continue;
        } else {
          throw Exception(
              'Failed to load data from $url, Status Code: ${response.statusCode}');
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
    if (_pendingRequests.isNotEmpty &&
        _activeRequests < _maxConcurrentRequests) {
      final request = _pendingRequests.removeFirst();
      _get(request.url).then(request.completer.complete).catchError((error) {
        request.completer.completeError(error);
        // Ensure we process more pending requests even if this one failed
        _processPendingRequests();
      });
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

  // Performance: Internal fetch method with fallback
  Future<List<Song>> _fetchSongsInternal(String query) async {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;

    try {
      // Try primary API first
      return await _fetchSongsFromPrimaryApi(query, cacheKey);
    } catch (e) {
      debugPrint('Primary API failed for query "$query": $e');
      try {
        // Fallback to original API
        return await _fetchSongsFromFallbackApi(query, cacheKey);
      } catch (fallbackError) {
        debugPrint(
            'Fallback API also failed for query "$query": $fallbackError');
        rethrow;
      }
    }
  }

  // Primary API fetch method
  Future<List<Song>> _fetchSongsFromPrimaryApi(
      String query, String cacheKey) async {
    final Uri url;
    if (query.isNotEmpty) {
      url = Uri.parse(
          '${baseUrl}search/tracks?query=${Uri.encodeComponent(query)}');
    } else {
      url = Uri.parse('${baseUrl}topCharts');
    }

    final response = await _get(url.toString());
    dynamic data = json.decode(response.body);

    List<dynamic> items;
    if (query.isNotEmpty) {
      items = data;
    } else {
      // Handle top charts - API v2 returns both topArtists and tracks
      if (data is Map && data.containsKey('tracks') && data['tracks'] is List) {
        // Use tracks directly from topCharts response
        items = data['tracks'];
      } else if (data is List) {
        // Handle array response
        items = data;
      } else {
        throw Exception('Unexpected response format from primary API');
      }
    }

    final songs = items.map<Song>((json) => Song.fromApiV2Json(json)).toList();

    // Performance: Cache with TTL
    _songCache[cacheKey] = _CacheEntry(songs, DateTime.now());

    return songs;
  }

  // Fallback API fetch method (original API)
  Future<List<Song>> _fetchSongsFromFallbackApi(
      String query, String cacheKey) async {
    final Uri url;
    if (query.isNotEmpty) {
      url = Uri.parse(
          '${originalBaseUrl}search/?query=${Uri.encodeComponent(query)}');
    } else {
      url = Uri.parse('${originalBaseUrl}topCharts');
    }

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
  }

  Future<String?> _searchForAlbumId(String albumName, String artistName) async {
    final query = '${albumName.trim()} ${artistName.trim()}';

    try {
      // Try primary API first
      final url = '${baseUrl}search/albums?query=${Uri.encodeComponent(query)}';
      final response = await _get(url);
      List<dynamic> searchResults = jsonDecode(response.body);
      if (searchResults.isNotEmpty) {
        return searchResults.first['ALB_ID']?.toString();
      }
      return null;
    } catch (e) {
      debugPrint('Primary API failed for album search "$query": $e');
      try {
        // Fallback to original API
        final fallbackUrl =
            '${originalBaseUrl}search/albums?query=${Uri.encodeComponent(query)}';
        final fallbackResponse = await _get(fallbackUrl);
        List<dynamic> searchResults = jsonDecode(fallbackResponse.body);
        if (searchResults.isNotEmpty) {
          return searchResults.first['ALB_ID']?.toString();
        }
        return null;
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError,
            context: 'searchForAlbumId fallback');
        return null;
      }
    }
  }

  Future<Album?> fetchAlbumDetailsById(String albumId) async {
    final cached = _albumDetailCache[albumId];
    if (cached != null && !cached.isAlbumExpired) {
      return cached.data;
    }

    try {
      // Try primary API first
      final url = '${baseUrl}album/$albumId';
      final response = await _get(url);
      Map<String, dynamic> data = jsonDecode(response.body);
      final album = Album.fromJson(data);

      // Performance: Cache with longer TTL for albums
      _albumDetailCache[albumId] = _CacheEntry(album, DateTime.now());

      return album;
    } catch (e) {
      debugPrint('Primary API failed for album details $albumId: $e');
      try {
        // Fallback to original API
        final fallbackUrl = '${originalBaseUrl}album/$albumId';
        final fallbackResponse = await _get(fallbackUrl);
        Map<String, dynamic> data = jsonDecode(fallbackResponse.body);
        final album = Album.fromJson(data);

        // Performance: Cache with longer TTL for albums
        _albumDetailCache[albumId] = _CacheEntry(album, DateTime.now());

        return album;
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError,
            context: 'fetchAlbumDetailsById fallback');
        return null;
      }
    }
  }

  Future<Album?> getAlbum(String albumId) async {
    return await fetchAlbumDetailsById(albumId);
  }

  // Search albums by query
  Future<List<Album>> searchAlbums(String query) async {
    try {
      // Try primary API first
      final url = '${baseUrl}search/albums?query=${Uri.encodeComponent(query)}';
      final response = await _get(url);
      final data = jsonDecode(response.body) as List<dynamic>;

      return data.map((albumJson) {
        return Album.fromJson(albumJson as Map<String, dynamic>);
      }).toList();
    } catch (e) {
      debugPrint('Primary API failed for album search "$query": $e');
      try {
        // Fallback to original API
        final fallbackUrl =
            '${originalBaseUrl}search/albums?query=${Uri.encodeComponent(query)}';
        final fallbackResponse = await _get(fallbackUrl);
        final data = jsonDecode(fallbackResponse.body) as List<dynamic>;

        return data.map((albumJson) {
          return Album.fromJson(albumJson as Map<String, dynamic>);
        }).toList();
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError, context: 'searchAlbums fallback');
        return [];
      }
    }
  }

  // Search artists by query
  Future<List<Map<String, dynamic>>> searchArtists(String query) async {
    try {
      // Try primary API first
      final url =
          '${baseUrl}search/artists?query=${Uri.encodeComponent(query)}';
      final response = await _get(url);
      final data = jsonDecode(response.body) as List<dynamic>;

      return data.map((artistJson) {
        return artistJson as Map<String, dynamic>;
      }).toList();
    } catch (e) {
      debugPrint('Primary API failed for artist search "$query": $e');
      try {
        // Fallback to original API
        final fallbackUrl =
            '${originalBaseUrl}search/artists?query=${Uri.encodeComponent(query)}';
        final fallbackResponse = await _get(fallbackUrl);
        final data = jsonDecode(fallbackResponse.body) as List<dynamic>;

        return data.map((artistJson) {
          return artistJson as Map<String, dynamic>;
        }).toList();
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError,
            context: 'searchArtists fallback');
        return [];
      }
    }
  }

  // Performance: Use debounced fetch
  Future<List<Song>> fetchSongs(String query) async {
    return _debouncedFetchSongs(query);
  }

  /// Version-aware song search that tries multiple query variations
  Future<List<Song>> fetchSongsVersionAware(String artist, String title) async {
    final searchQueries =
        VersionService.createAlternativeSearchQueries(artist, title);
    final allResults = <Song>[];
    final seenIds = <String>{};

    // Try each search query and collect unique results
    for (final query in searchQueries) {
      try {
        final results = await fetchSongs(query);
        for (final song in results) {
          if (!seenIds.contains(song.id)) {
            seenIds.add(song.id);
            allResults.add(song);
          }
        }

        // If we found good matches with the first query, we can stop early
        if (allResults.isNotEmpty && query == searchQueries.first) {
          // Check if we found a version-aware match
          final hasVersionMatch = allResults.any((song) =>
              VersionService.calculateVersionAwareSimilarity(
                  song.title, title) >
              0.8);
          if (hasVersionMatch) {
            break;
          }
        }
      } catch (e) {
        debugPrint('Error in version-aware search with query "$query": $e');
        continue;
      }
    }

    // Sort results by version-aware similarity
    allResults.sort((a, b) {
      final similarityA =
          VersionService.calculateVersionAwareSimilarity(a.title, title);
      final similarityB =
          VersionService.calculateVersionAwareSimilarity(b.title, title);
      return similarityB.compareTo(similarityA);
    });

    return allResults;
  }

  Future<String> downloadSong(String url, String fileName) async {
    return url;
  }

  Future<String?> fetchAudioUrl(String songId) async {
    final cacheKey = songId;
    final cached = _audioUrlCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }

    String? audioUrl;

    try {
      // Directly call audio endpoint with songId
      final Uri url = Uri.parse('${baseUrl}audio?trackId=$songId');

      final response = await _get(url.toString());
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data != null && data['audioURL'] != null) {
          audioUrl = data['audioURL'] as String;
        }
      }
    } catch (e) {
      debugPrint(
          'Primary API failed for fetchAudioUrl with songId "$songId": $e');
      // Try fallback API
      try {
        audioUrl = await _fetchAudioUrlFromFallbackApi(songId);
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError,
            context: 'fetchAudioUrl fallback');
      }
    }

    if (audioUrl != null) {
      // Performance: Cache audio URLs
      _audioUrlCache[cacheKey] = _CacheEntry(audioUrl, DateTime.now());
      return audioUrl;
    }

    return null;
  }

  // Fallback method for audio URL fetching using original API
  Future<String?> _fetchAudioUrlFromFallbackApi(String songId) async {
    String? audioUrl;

    try {
      // Try fallback API with songId - assuming the fallback API also supports trackId parameter
      final Uri url = Uri.parse('${originalBaseUrl}audio?trackId=$songId');

      final response = await _get(url.toString());
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data != null && data['audioURL'] != null) {
          audioUrl = data['audioURL'] as String;
        }
      }
    } catch (e) {
      debugPrint('Fallback API failed for audio URL with songId "$songId": $e');
    }

    return audioUrl;
  }

  Future<List<dynamic>> fetchStationsByCountry(String country,
      {String name = ''}) async {
    final String cacheKey = "${country}_$name";
    final cached = _radioStationCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.data;
    }

    final queryParams = <String, String>{};
    if (country.isNotEmpty) queryParams['country'] = country;
    if (name.isNotEmpty) queryParams['name'] = name;

    try {
      // Try primary API first
      final url = Uri.https('apiv2.ltunes.app', '/api/radio',
          queryParams.isEmpty ? null : queryParams);

      final response = await _get(url.toString());
      if (response.statusCode == 200) {
        try {
          final stations = json.decode(response.body) as List<dynamic>;

          // Performance: Cache radio stations
          _radioStationCache[cacheKey] = _CacheEntry(stations, DateTime.now());

          return stations;
        } catch (e) {
          throw Exception(
              'Error decoding JSON: $e\nResponse body: ${response.body}');
        }
      } else if (response.statusCode == 404) {
        final emptyStations = <dynamic>[];
        _radioStationCache[cacheKey] =
            _CacheEntry(emptyStations, DateTime.now());
        return emptyStations;
      } else {
        throw Exception(
            'Failed to load radio stations. Status code: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Primary API failed for radio stations: $e');
      try {
        // Fallback to original API
        final fallbackUrl = Uri.https('ltn-api.vercel.app', '/api/radio',
            queryParams.isEmpty ? null : queryParams);

        final fallbackResponse = await _get(fallbackUrl.toString());
        if (fallbackResponse.statusCode == 200) {
          try {
            final stations =
                json.decode(fallbackResponse.body) as List<dynamic>;

            // Performance: Cache radio stations
            _radioStationCache[cacheKey] =
                _CacheEntry(stations, DateTime.now());

            return stations;
          } catch (e) {
            throw Exception(
                'Error decoding JSON from fallback: $e\nResponse body: ${fallbackResponse.body}');
          }
        } else if (fallbackResponse.statusCode == 404) {
          final emptyStations = <dynamic>[];
          _radioStationCache[cacheKey] =
              _CacheEntry(emptyStations, DateTime.now());
          return emptyStations;
        } else {
          throw Exception(
              'Failed to load radio stations from fallback. Status code: ${fallbackResponse.statusCode}');
        }
      } catch (fallbackError) {
        throw Exception(
            'Error fetching radio stations (both APIs): $fallbackError');
      }
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

  Timer? _cacheCleanupTimer;

  // Performance: Periodic cache cleanup
  void startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _cleanupExpiredCache();
    });
  }

  // Performance: Dispose resources
  void dispose() {
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    _cacheCleanupTimer?.cancel();
    _httpClient.close();
  }

  // Method to compare versions (e.g., "1.0.1" vs "1.0.0" or "2025.11.02-beta")
  // Returns > 0 if v1 is greater, < 0 if v2 is greater, 0 if equal
  int _compareVersions(String v1, String v2) {
    // Extract numeric version by removing beta suffix
    String v1Numeric = v1.replaceAll('-beta', '');
    String v2Numeric = v2.replaceAll('-beta', '');

    // Check if versions are beta
    bool v1IsBeta = v1.contains('-beta');
    bool v2IsBeta = v2.contains('-beta');

    List<int> v1Parts = v1Numeric.split('.').map(int.parse).toList();
    List<int> v2Parts = v2Numeric.split('.').map(int.parse).toList();

    // Compare numeric parts first
    for (int i = 0; i < v1Parts.length || i < v2Parts.length; i++) {
      int part1 = (i < v1Parts.length) ? v1Parts[i] : 0;
      int part2 = (i < v2Parts.length) ? v2Parts[i] : 0;

      if (part1 < part2) return -1;
      if (part1 > part2) return 1;
    }

    // If numeric versions are equal, stable versions are greater than beta versions
    if (v1IsBeta && !v2IsBeta) return -1;
    if (!v1IsBeta && v2IsBeta) return 1;

    return 0;
  }

  Future<UpdateInfo?> checkForUpdate(String currentAppVersion) async {
    try {
      final releaseChannelService = ReleaseChannelService();
      final updateUrl = await releaseChannelService.getCurrentUpdateUrl();

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

  Future<LyricsData?> fetchLyrics(String songId) async {
    try {
      // Directly call lyrics endpoint with songId
      final url = '${baseUrl}lyrics?trackId=$songId';

      final response = await _get(url);
      final data = jsonDecode(response.body);

      if (data != null) {
        // Use the new API v2 format parser
        return LyricsData.fromApiV2Response(data);
      }
      return null;
    } catch (e) {
      debugPrint(
          'Primary API failed for fetchLyrics with songId "$songId": $e');
      try {
        // Fallback to original API - need to get song details first to get artist/title
        // For now, we'll try the fallback API with the trackId parameter if it supports it
        final fallbackUrl = '${originalBaseUrl}lyrics?trackId=$songId';
        final fallbackResponse = await _get(fallbackUrl);
        final data = jsonDecode(fallbackResponse.body);

        if (data != null && data['lyrics'] != null && data['lyrics'] is Map) {
          return LyricsData.fromOriginalApiResponse(data);
        }
        return null;
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError, context: 'fetchLyrics fallback');
        if (fallbackError.toString().contains('404')) {
          return null;
        }
        return null;
      }
    }
  }

  Future<Map<String, dynamic>> getArtistById(String query) async {
    try {
      // Try primary API first
      late String artistId;
      if (RegExp(r'^\d+$').hasMatch(query)) {
        artistId = query;
      } else {
        final searchUrl =
            '${baseUrl}search/artists?query=${Uri.encodeComponent(query)}';
        final searchResp = await _get(searchUrl);
        final List<dynamic> results =
            jsonDecode(searchResp.body) as List<dynamic>;
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
      debugPrint('Primary API failed for getArtistById "$query": $e');
      try {
        // Fallback to original API
        late String artistId;
        if (RegExp(r'^\d+$').hasMatch(query)) {
          artistId = query;
        } else {
          final searchUrl =
              '${originalBaseUrl}search/artists?query=${Uri.encodeComponent(query)}';
          final searchResp = await _get(searchUrl);
          final List<dynamic> results =
              jsonDecode(searchResp.body) as List<dynamic>;
          if (results.isEmpty) {
            throw Exception('No artists found for query: "$query"');
          }
          artistId = results.first['ART_ID']?.toString() ?? '';
          if (artistId.isEmpty) {
            throw Exception('Artist ID missing in search results for "$query"');
          }
        }

        final detailUrl = '${originalBaseUrl}artist/$artistId';
        final detailResp = await _get(detailUrl);
        return jsonDecode(detailResp.body) as Map<String, dynamic>;
      } catch (fallbackError) {
        throw Exception(
            'getArtistById failed for "$query" (both APIs): $fallbackError');
      }
    }
  }

  Future<List<Album>> getArtistAlbums(String artistId) async {
    try {
      // Try primary API first
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
      debugPrint('Primary API failed for getArtistAlbums $artistId: $e');
      try {
        // Fallback to original API
        final fallbackResponse =
            await _get('${originalBaseUrl}artist/$artistId/albums');

        final data = json.decode(fallbackResponse.body);

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
            .map((albumData) =>
                Album.fromJson(albumData as Map<String, dynamic>))
            .toList();
      } catch (fallbackError) {
        _errorHandler.logError(fallbackError,
            context: 'getArtistAlbums fallback');
        return [];
      }
    }
  }
}
