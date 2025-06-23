import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../models/update_info.dart'; // Import the new model
import '../models/album.dart'; // Import the new Album model
import '../models/lyrics_data.dart'; // Import LyricsData

class ApiService {
  static final ApiService _instance = ApiService._internal();

  factory ApiService() {
    return _instance;
  }

  ApiService._internal(); // Private constructor

  static const String baseUrl = 'https://ltn-api.vercel.app/api/';
  static const String updateUrl = 'https://ltn-api.vercel.app/updates/update.json';

  // Caches
  final Map<String, List<Song>> _songCache = {};
  final Map<String, List<dynamic>> _radioStationCache = {};
  // ignore: unused_field
  final Map<String, String> _audioUrlCache = {};
  final Map<String, Album> _albumDetailCache = {}; // Cache for album details by ID

  // Helper method to make HTTP GET requests and handle common errors
  Future<http.Response> _get(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return response;
      } else if (response.statusCode == 404) {
        // Handle 404 specifically if needed, e.g., return empty list or null
        throw Exception('Resource not found (404) for URL: $url');
      } else {
        throw Exception('Failed to load data from $url, Status Code: ${response.statusCode}');
      }
    } catch (e) {
      // Catch network errors or other exceptions during the request
      throw Exception('Error connecting to $url: $e');
    }
  }

  Future<String?> _searchForAlbumId(String albumName, String artistName) async {
    final query = '${albumName.trim()} ${artistName.trim()}';
    final url = '${baseUrl}search/albums?query=${Uri.encodeComponent(query)}';
    try {
      final response = await _get(url);
      List<dynamic> searchResults = jsonDecode(response.body);
      if (searchResults.isNotEmpty) {
        // Consider adding more robust matching, e.g., verify artist name from searchResults.first['ARTISTS']
        return searchResults.first['ALB_ID']?.toString();
      }
      return null;
    } catch (e) {
      debugPrint('Error searching for album ID for "$query": $e');
      return null;
    }
  }

  Future<Album?> fetchAlbumDetailsById(String albumId) async {
    if (_albumDetailCache.containsKey(albumId)) {
      return _albumDetailCache[albumId];
    }
    final url = '${baseUrl}album/$albumId';
    try {
      final response = await _get(url);
      Map<String, dynamic> data = jsonDecode(response.body);
      final album = Album.fromJson(data);
      _albumDetailCache[albumId] = album; // Cache the fetched album
      return album;
    } catch (e) {
      debugPrint('Error fetching album details for ID "$albumId": $e');
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

  Future<List<Song>> fetchSongs(String query) async {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;
    if (_songCache.containsKey(cacheKey)) {
      return _songCache[cacheKey]!;
    }

    final Uri url;
    if (query.isNotEmpty) {
      url = Uri.parse('${baseUrl}search/?query=${Uri.encodeComponent(query)}');
    } else {
      url = Uri.parse('${baseUrl}topCharts');
    }

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        dynamic data = json.decode(response.body);

        List<dynamic> items;
        if (query.isNotEmpty) {
          // For search results, the API returns the list directly
          items = data;
        } else {
          // For top charts, the API returns { topArtists: [...], tracks: [...] }
          // Ensure 'tracks' key exists and is a list, otherwise default to empty list
          if (data is Map && data.containsKey('tracks') && data['tracks'] is List) {
            items = data['tracks'];
          } else if (data is List) { // Handle cases where topCharts might directly return a list
            items = data;
          }
          else {
            items = []; // Default to empty if structure is unexpected
          }
        }

        // Ensure correct mapping to Song model
        final songs = items.map<Song>((json) => Song.fromJson(json)).toList();
        _songCache[cacheKey] = songs; // Store in cache
        return songs;
      } else {
        throw Exception('Failed to load songs. Status code: ${response.statusCode}');
      }
    } catch (e) {
      // print('Error fetching songs: $e');
      rethrow;
    }
  }

  Future<String> downloadSong(String url, String fileName) async {
    // Removed file caching. Simply return the provided URL.
    return url;
  }

  Future<String?> fetchAudioUrl(String artist, String musicName) async {
    final Uri url = Uri.parse(
        '${baseUrl}audio/?artist=${Uri.encodeComponent(artist)}&musicName=${Uri.encodeComponent(musicName)}');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data != null && data['audioURL'] != null) {
          return data['audioURL'] as String;
        }
      }
      return null; // Explicitly return null if no valid URL is found
    } catch (e) {
      debugPrint('Error fetching audio URL: $e');
      return null;
    }
  }

  Future<List<dynamic>> fetchStationsByCountry(String country, {String name = ''}) async {
    final String cacheKey = "${country}_${name}";
    if (_radioStationCache.containsKey(cacheKey)) {
      return _radioStationCache[cacheKey]!;
    }

    // Build query parameters based on non-empty country and name values
    final queryParams = <String, String>{};
    if (country.isNotEmpty) queryParams['country'] = country;
    if (name.isNotEmpty) queryParams['name'] = name;
    
    // Use Uri.http or Uri.https for constructing URLs with query parameters
    final url = Uri.https('ltn-api.vercel.app', '/api/radio', queryParams.isEmpty ? null : queryParams);
    
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        try {
          final stations = json.decode(response.body) as List<dynamic>;
          _radioStationCache[cacheKey] = stations; // Store in cache
          return stations;
        } catch (e) {
          throw Exception('Error decoding JSON: $e\nResponse body: ${response.body}');
        }
      } else if (response.statusCode == 404) {
        _radioStationCache[cacheKey] = []; // Cache empty result for 404
        return []; // Return an empty list if no stations are found
      } else {
        throw Exception('Failed to load radio stations. Status code: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching radio stations: $e');
    }
  }

  // Method to clear song cache for a specific query
  void clearSongCache(String query) {
    final String cacheKey = query.isEmpty ? "__topCharts__" : query;
    _songCache.remove(cacheKey);
    // debugPrint('Cleared song cache for key: $cacheKey');
  }

  // Method to clear radio station cache for a specific country and name
  void clearRadioStationCache(String country, String name) {
    final String cacheKey = "${country}_${name}";
    _radioStationCache.remove(cacheKey);
    // debugPrint('Cleared radio station cache for key: $cacheKey');
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
      debugPrint('Error fetching lyrics for "$artist - $musicName": $e');
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
      debugPrint('Error fetching artist albums for ID "$artistId": $e');
      return [];
    }
  }
}
