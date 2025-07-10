import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MetadataHistoryService {
  static final MetadataHistoryService _instance = MetadataHistoryService._internal();
  factory MetadataHistoryService() => _instance;
  MetadataHistoryService._internal();

  static const String _historyKey = 'metadata_fetch_history';

  // Add a history entry
  Future<void> addHistoryEntry(MetadataFetchHistory entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_historyKey) ?? '[]';
      final List<dynamic> historyList = jsonDecode(historyJson);
      
      // Add new entry
      historyList.add({
        'originalSongId': entry.originalSongId,
        'originalSongData': entry.originalSongData,
        'newSongId': entry.newSongId,
        'timestamp': entry.timestamp.toIso8601String(),
      });
      
      await prefs.setString(_historyKey, jsonEncode(historyList));
    } catch (e) {
      debugPrint('Error adding history entry: $e');
    }
  }

  // Get all history entries
  Future<List<MetadataFetchHistory>> getHistoryEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_historyKey) ?? '[]';
      final List<dynamic> historyList = jsonDecode(historyJson);
      
      return historyList.map((entry) => MetadataFetchHistory(
        originalSongId: entry['originalSongId'],
        originalSongData: entry['originalSongData'],
        newSongId: entry['newSongId'],
        timestamp: DateTime.parse(entry['timestamp']),
      )).toList();
    } catch (e) {
      debugPrint('Error getting history entries: $e');
      return [];
    }
  }

  // Remove a specific history entry
  Future<void> removeHistoryEntry(MetadataFetchHistory entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_historyKey) ?? '[]';
      final List<dynamic> historyList = jsonDecode(historyJson);
      
      historyList.removeWhere((item) => 
        item['newSongId'] == entry.newSongId &&
        item['originalSongId'] == entry.originalSongId
      );
      
      await prefs.setString(_historyKey, jsonEncode(historyList));
    } catch (e) {
      debugPrint('Error removing history entry: $e');
    }
  }

  // Clear all history (called when app closes)
  Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
      debugPrint('Metadata fetch history cleared');
    } catch (e) {
      debugPrint('Error clearing history: $e');
    }
  }
}

// Class to represent metadata fetch history
class MetadataFetchHistory {
  final String originalSongId;
  final String originalSongData;
  final String newSongId;
  final DateTime timestamp;

  MetadataFetchHistory({
    required this.originalSongId,
    required this.originalSongData,
    required this.newSongId,
    required this.timestamp,
  });
} 