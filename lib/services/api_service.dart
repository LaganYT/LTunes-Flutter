import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/song.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();

  factory ApiService() {
    return _instance;
  }

  ApiService._internal(); // Private constructor

  static const String baseUrl = 'https://ltn-api.vercel.app/api/';

  // Caches
  final Map<String, List<Song>> _songCache = {};
  final Map<String, List<dynamic>> _radioStationCache = {};

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
}

