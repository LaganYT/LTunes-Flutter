import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart' as xml;
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';

class DataExportImportService {
  static final DataExportImportService _instance =
      DataExportImportService._internal();
  factory DataExportImportService() => _instance;
  DataExportImportService._internal();

  /// Export all app data to a plist file (iOS/macOS) or xml file (Android)
  Future<String?> exportAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Get all SharedPreferences keys and values
      final allData = <String, dynamic>{};
      final keys = prefs.getKeys();

      for (final key in keys) {
        final value = prefs.get(key);
        if (value != null) {
          // Sanitize song data to remove download states
          if (value is String) {
            // Check if it's JSON that might contain song data
            if (key.contains('song') ||
                key.contains('queue') ||
                key.contains('playlist') ||
                key.contains('album') ||
                key.contains('liked')) {
              try {
                final jsonData = jsonDecode(value);
                if (jsonData is Map) {
                  allData[key] =
                      _sanitizeSongData(Map<String, dynamic>.from(jsonData));
                } else if (jsonData is List) {
                  allData[key] = jsonData.map((item) {
                    if (item is Map) {
                      return _sanitizeSongData(Map<String, dynamic>.from(item));
                    }
                    return item;
                  }).toList();
                } else {
                  allData[key] = value;
                }
              } catch (e) {
                // Not JSON, just use the string value
                allData[key] = value;
              }
            } else {
              allData[key] = value;
            }
          } else if (value is List<String>) {
            // Check if list contains JSON strings (like playlists, queues)
            if (key.contains('playlist') ||
                key.contains('queue') ||
                key.contains('album') ||
                key.contains('liked')) {
              allData[key] = value.map((jsonStr) {
                try {
                  final jsonData = jsonDecode(jsonStr);
                  if (jsonData is Map) {
                    return jsonEncode(
                        _sanitizeSongData(Map<String, dynamic>.from(jsonData)));
                  }
                  return jsonStr;
                } catch (e) {
                  return jsonStr;
                }
              }).toList();
            } else {
              allData[key] = value;
            }
          } else {
            // int, double, bool - use as is
            allData[key] = value;
          }
        }
      }

      // Add metadata
      allData['_exportVersion'] = '1.0';
      allData['_exportDate'] = DateTime.now().toIso8601String();

      // Convert to plist XML format
      final plistXml = _jsonToPlistXml(allData);

      // Save to temporary file
      // Use .xml extension on Android, .plist on iOS/macOS
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileExtension = Platform.isAndroid ? 'xml' : 'plist';
      final fileName = 'LTunes_Export_$timestamp.$fileExtension';
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsString(plistXml);

      debugPrint('Data exported successfully to: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('Error exporting data: $e');
      return null;
    }
  }

  /// Import all app data from a plist or xml file (always replaces existing data)
  Future<bool> importAllData({CurrentSongProvider? songProvider}) async {
    try {
      // Pick file - accept both plist and xml files
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['plist', 'xml'],
      );

      if (result == null || result.files.single.path == null) {
        return false;
      }

      final filePath = result.files.single.path!;
      final file = File(filePath);

      if (!await file.exists()) {
        debugPrint('File does not exist: $filePath');
        return false;
      }

      // Read and parse plist
      final plistContent = await file.readAsString();
      final jsonData = _plistXmlToJson(plistContent);

      if (jsonData == null) {
        debugPrint('Failed to parse plist file');
        return false;
      }

      // Import all SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final songsToRedownload = <Song>[];

      // Skip metadata keys
      for (final entry in jsonData.entries) {
        final key = entry.key;
        if (key.startsWith('_') &&
            (key == '_exportVersion' || key == '_exportDate')) {
          continue; // Skip metadata keys, but process _wasDownloaded in song data
        }

        final value = entry.value;

        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is List) {
          // Check if it's a list of strings (for string lists like playlists)
          if (value.isNotEmpty && value.first is String) {
            // This is likely a list of JSON strings (playlists, albums, etc.)
            // Need to check nested songs within these JSON strings
            final processedList = value.map((jsonStr) {
              try {
                final decoded = jsonDecode(jsonStr as String);
                if (decoded is Map) {
                  final decodedMap = Map<String, dynamic>.from(decoded);
                  // Check for nested songs in playlists/albums
                  _extractSongsForRedownload(decodedMap, songsToRedownload);
                  // Remove _wasDownloaded flags and sanitize
                  final sanitized = _sanitizeForJson(decodedMap);
                  if (sanitized is Map) {
                    final sanitizedMap = Map<String, dynamic>.from(sanitized);
                    _removeWasDownloadedFlags(sanitizedMap);
                    return jsonEncode(sanitizedMap);
                  }
                  return jsonEncode(sanitized);
                }
                return jsonStr;
              } catch (e) {
                return jsonStr;
              }
            }).toList();
            await prefs.setStringList(key, List<String>.from(processedList));
          } else {
            // Convert complex objects back to JSON strings
            // This handles cases where we exported JSON strings as parsed Maps/Lists
            final stringList = value.map((e) {
              if (e is Map) {
                final eMap = Map<String, dynamic>.from(e);
                // Track songs that need to be redownloaded
                _extractSongsForRedownload(eMap, songsToRedownload);
                // Sanitize the data before encoding to fix any type issues
                final sanitized = _sanitizeForJson(eMap);
                // Remove _wasDownloaded flag from the sanitized data
                if (sanitized is Map) {
                  final sanitizedMap = Map<String, dynamic>.from(sanitized);
                  _removeWasDownloadedFlags(sanitizedMap);
                  return jsonEncode(sanitizedMap);
                }
                return jsonEncode(sanitized);
              } else if (e is List) {
                final sanitized = _sanitizeForJson(e);
                return jsonEncode(sanitized);
              }
              return e.toString();
            }).toList();
            await prefs.setStringList(key, List<String>.from(stringList));
          }
        } else if (value is Map) {
          final valueMap = Map<String, dynamic>.from(value);
          // Track songs that need to be redownloaded (check nested songs too)
          _extractSongsForRedownload(valueMap, songsToRedownload);
          // Convert Map back to JSON string (for single JSON string values)
          // Sanitize the data before encoding to fix any type issues
          final sanitized = _sanitizeForJson(valueMap);
          // Remove _wasDownloaded flag from the sanitized data
          if (sanitized is Map) {
            final sanitizedMap = Map<String, dynamic>.from(sanitized);
            _removeWasDownloadedFlags(sanitizedMap);
            await prefs.setString(key, jsonEncode(sanitizedMap));
          } else {
            await prefs.setString(key, jsonEncode(sanitized));
          }
        }
      }

      // Queue songs for redownload if provider is available
      if (songProvider != null && songsToRedownload.isNotEmpty) {
        debugPrint('Queueing ${songsToRedownload.length} songs for redownload');
        for (final song in songsToRedownload) {
          try {
            await songProvider.queueSongForDownload(song);
          } catch (e) {
            debugPrint('Error queueing song ${song.title} for download: $e');
          }
        }
      }

      debugPrint('Data imported successfully');
      return true;
    } catch (e) {
      debugPrint('Error importing data: $e');
      return false;
    }
  }

  /// Share exported file
  Future<void> shareExportedFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await Share.shareXFiles([XFile(filePath)], text: 'LTunes Data Export');
      }
    } catch (e) {
      debugPrint('Error sharing file: $e');
    }
  }

  /// Extract songs that need to be redownloaded from nested structures
  void _extractSongsForRedownload(
      Map<String, dynamic> data, List<Song> songsToRedownload) {
    // Check if this is a song with _wasDownloaded flag
    if (data['_wasDownloaded'] == true) {
      try {
        final songData = Map<String, dynamic>.from(data);
        songData.remove('_wasDownloaded');
        final song = Song.fromJson(songData);
        songsToRedownload.add(song);
      } catch (err) {
        debugPrint('Error parsing song for redownload: $err');
      }
    }

    // Check nested songs in playlists/albums
    if (data.containsKey('songs') && data['songs'] is List) {
      for (final songItem in data['songs'] as List) {
        if (songItem is Map) {
          _extractSongsForRedownload(
              Map<String, dynamic>.from(songItem), songsToRedownload);
        }
      }
    }

    if (data.containsKey('tracks') && data['tracks'] is List) {
      for (final trackItem in data['tracks'] as List) {
        if (trackItem is Map) {
          _extractSongsForRedownload(
              Map<String, dynamic>.from(trackItem), songsToRedownload);
        }
      }
    }
  }

  /// Remove _wasDownloaded flags from nested structures
  void _removeWasDownloadedFlags(Map<String, dynamic> data) {
    data.remove('_wasDownloaded');

    if (data.containsKey('songs') && data['songs'] is List) {
      for (final songItem in data['songs'] as List) {
        if (songItem is Map) {
          _removeWasDownloadedFlags(Map<String, dynamic>.from(songItem));
        }
      }
    }

    if (data.containsKey('tracks') && data['tracks'] is List) {
      for (final trackItem in data['tracks'] as List) {
        if (trackItem is Map) {
          _removeWasDownloadedFlags(Map<String, dynamic>.from(trackItem));
        }
      }
    }
  }

  /// Sanitize data for JSON encoding (fixes type issues like empty string extras)
  dynamic _sanitizeForJson(dynamic data) {
    if (data is Map) {
      final sanitized = <String, dynamic>{};
      for (final entry in data.entries) {
        final key = entry.key.toString();
        final value = entry.value;

        // Fix extras field - ensure it's either a Map or null
        if (key == 'extras') {
          if (value == null ||
              value == '' ||
              (value is String && value.isEmpty)) {
            sanitized[key] = null;
          } else if (value is Map) {
            sanitized[key] = _sanitizeForJson(value);
          } else {
            sanitized[key] = null;
          }
        } else {
          sanitized[key] = _sanitizeForJson(value);
        }
      }
      return sanitized;
    } else if (data is List) {
      return data.map((e) => _sanitizeForJson(e)).toList();
    } else {
      return data;
    }
  }

  /// Sanitize song data by removing download states but tracking if it was downloaded
  Map<String, dynamic> _sanitizeSongData(Map<String, dynamic> data) {
    final sanitized = Map<String, dynamic>.from(data);

    // Track if song was downloaded before removing the flag
    final wasDownloaded = sanitized['isDownloaded'] == true;
    if (wasDownloaded) {
      sanitized['_wasDownloaded'] = true;
    }

    // Remove download-related fields
    sanitized['isDownloaded'] = false;
    sanitized['localFilePath'] = null;

    // Fix extras field - ensure it's either a Map or null, not an empty string
    if (sanitized.containsKey('extras')) {
      final extras = sanitized['extras'];
      if (extras == null ||
          extras == '' ||
          (extras is String && extras.isEmpty)) {
        sanitized['extras'] = null;
      } else if (extras is! Map) {
        // If it's not a Map and not null/empty, try to parse it
        try {
          if (extras is String) {
            final parsed = jsonDecode(extras);
            sanitized['extras'] =
                parsed is Map ? Map<String, dynamic>.from(parsed) : null;
          } else {
            sanitized['extras'] = null;
          }
        } catch (e) {
          sanitized['extras'] = null;
        }
      }
    }

    // Handle nested song data in playlists/albums
    if (sanitized.containsKey('songs') && sanitized['songs'] is List) {
      sanitized['songs'] = (sanitized['songs'] as List).map((song) {
        if (song is Map) {
          return _sanitizeSongData(Map<String, dynamic>.from(song));
        }
        return song;
      }).toList();
    }

    if (sanitized.containsKey('tracks') && sanitized['tracks'] is List) {
      sanitized['tracks'] = (sanitized['tracks'] as List).map((track) {
        if (track is Map) {
          return _sanitizeSongData(Map<String, dynamic>.from(track));
        }
        return track;
      }).toList();
    }

    // Unmark albums as saved
    if (sanitized.containsKey('isSaved')) {
      sanitized['isSaved'] = false;
    }

    return sanitized;
  }

  /// Convert JSON data to plist XML format
  String _jsonToPlistXml(Map<String, dynamic> json) {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('plist', attributes: {'version': '1.0'}, nest: () {
      builder.element('dict', nest: () {
        _addDictEntries(builder, json);
      });
    });

    final document = builder.buildDocument();
    return document.toXmlString(pretty: true);
  }

  /// Add dictionary entries to plist XML builder
  void _addDictEntries(xml.XmlBuilder builder, Map<String, dynamic> map) {
    for (final entry in map.entries) {
      builder.element('key', nest: entry.key);
      _addValue(builder, entry.value);
    }
  }

  /// Add value to plist XML builder based on type
  void _addValue(xml.XmlBuilder builder, dynamic value) {
    if (value == null) {
      // Plist doesn't have null, use empty string
      builder.element('string');
    } else if (value is String) {
      builder.element('string', nest: value);
    } else if (value is int) {
      builder.element('integer', nest: value.toString());
    } else if (value is double) {
      builder.element('real', nest: value.toString());
    } else if (value is bool) {
      builder.element(value ? 'true' : 'false');
    } else if (value is List) {
      builder.element('array', nest: () {
        for (final item in value) {
          _addValue(builder, item);
        }
      });
    } else if (value is Map) {
      builder.element('dict', nest: () {
        _addDictEntries(builder, Map<String, dynamic>.from(value));
      });
    } else {
      // Fallback: convert to string
      builder.element('string', nest: value.toString());
    }
  }

  /// Convert plist XML to JSON
  Map<String, dynamic>? _plistXmlToJson(String plistXml) {
    try {
      final document = xml.XmlDocument.parse(plistXml);
      final dictElement = document.findAllElements('dict').firstOrNull;
      if (dictElement == null) {
        return null;
      }
      return _parseDict(dictElement);
    } catch (e) {
      debugPrint('Error parsing plist XML: $e');
      return null;
    }
  }

  /// Parse dict element from plist XML
  Map<String, dynamic> _parseDict(xml.XmlElement dictElement) {
    final map = <String, dynamic>{};
    final children = dictElement.children.whereType<xml.XmlElement>().toList();

    for (int i = 0; i < children.length - 1; i += 2) {
      final keyElement = children[i];
      final valueElement = children[i + 1];

      if (keyElement.name.local == 'key') {
        final key = keyElement.innerText;
        final value = _parseValue(valueElement);
        // Ensure value is properly typed
        if (value is Map) {
          map[key] = Map<String, dynamic>.from(value);
        } else {
          map[key] = value;
        }
      }
    }

    return map;
  }

  /// Parse value element from plist XML
  dynamic _parseValue(xml.XmlElement element) {
    final tagName = element.name.local;

    switch (tagName) {
      case 'string':
        return element.innerText;
      case 'integer':
        return int.tryParse(element.innerText) ?? 0;
      case 'real':
        return double.tryParse(element.innerText) ?? 0.0;
      case 'true':
        return true;
      case 'false':
        return false;
      case 'array':
        return element.children
            .whereType<xml.XmlElement>()
            .map((e) => _parseValue(e))
            .toList();
      case 'dict':
        final dict = _parseDict(element);
        return Map<String, dynamic>.from(dict);
      default:
        return element.innerText;
    }
  }
}
