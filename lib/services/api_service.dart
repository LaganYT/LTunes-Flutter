import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/song.dart';

class ApiService {
  static const String baseUrl = 'https://ltn-api.vercel.app/api/';

  Future<List<Song>> fetchSongs(String query) async {
    final Uri url;
    if (query.isNotEmpty) {
      url = Uri.parse('${baseUrl}search/?query=${Uri.encodeComponent(query)}');
    } else {
      url = Uri.parse('${baseUrl}topCharts');
    }
    print('Fetching songs from URL: $url');

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
          items = data['tracks'] ?? [];
        }

        // Ensure correct mapping to Song model
        return items.map<Song>((json) => Song.fromJson(json)).toList();
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
}

