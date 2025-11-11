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

/// Callback for progress updates during export/import operations
typedef ProgressCallback = void Function(
    String operation, double progress, String? message);

/// Data categories for selective export/import
enum DataCategory {
  settings('Settings', 'App settings and preferences'),
  playlists('Playlists', 'User-created playlists'),
  likedSongs('Liked Songs', 'Liked songs list'),
  downloadHistory('Download History', 'Downloaded songs metadata'),
  queue('Queue', 'Current playback queue'),
  albums('Albums', 'Saved albums'),
  listeningStats('Listening Stats', 'Play counts and statistics');

  const DataCategory(this.displayName, this.description);
  final String displayName;
  final String description;
}

/// Export formats supported by the system
enum ExportFormat {
  plist('Plist', 'Property List (iOS/macOS)', ['plist', 'xml']),
  json('JSON', 'JavaScript Object Notation', ['json']);

  const ExportFormat(this.displayName, this.description, this.extensions);
  final String displayName;
  final String description;
  final List<String> extensions;
}

/// Validation result for imported data
class ValidationResult {
  final bool isValid;
  final List<String> errors;
  final List<String> warnings;
  final Map<String, int> statistics;

  const ValidationResult({
    required this.isValid,
    this.errors = const [],
    this.warnings = const [],
    this.statistics = const {},
  });

  bool get hasWarnings => warnings.isNotEmpty;
  bool get hasErrors => errors.isNotEmpty;
}

class DataExportImportService {
  static final DataExportImportService _instance =
      DataExportImportService._internal();
  factory DataExportImportService() => _instance;
  DataExportImportService._internal();

  /// Validate imported data for integrity and correctness
  Future<ValidationResult> validateImportedData(
    Map<String, dynamic> data,
  ) async {
    final errors = <String>[];
    final warnings = <String>[];
    final statistics = <String, int>{};

    try {
      // Check for required metadata
      final exportVersion = data['_exportVersion'] as String?;
      if (exportVersion == null) {
        errors.add('Missing export version information');
      } else {
        final version = double.tryParse(exportVersion);
        if (version == null) {
          errors.add('Invalid export version format: $exportVersion');
        } else if (version > 1.1) {
          warnings.add(
            'Export version ($exportVersion) is newer than current app version (1.1). Some data may not be compatible.',
          );
        }
      }

      final exportDate = data['_exportDate'] as String?;
      if (exportDate != null) {
        try {
          DateTime.parse(exportDate);
        } catch (e) {
          warnings.add('Invalid export date format: $exportDate');
        }
      }

      int totalKeys = 0;
      int validSongs = 0;
      int validPlaylists = 0;
      int validAlbums = 0;

      // Validate each data entry
      for (final entry in data.entries) {
        final key = entry.key;
        if (key.startsWith('_')) continue; // Skip metadata

        totalKeys++;
        final value = entry.value;

        try {
          if (value is String) {
            await _validateStringValue(
              key,
              value,
              errors,
              warnings,
              statistics,
            );
            if (_isSongRelatedKey(key)) {
              validSongs++;
            }
          } else if (value is int) {
            _validateIntValue(key, value, errors, warnings);
          } else if (value is double) {
            _validateDoubleValue(key, value, errors, warnings);
          } else if (value is bool) {
            _validateBoolValue(key, value, errors, warnings);
          } else if (value is List) {
            await _validateListValue(key, value, errors, warnings, statistics);
            if (key.toLowerCase().contains('playlist')) {
              validPlaylists++;
            } else if (_isAlbumListKey(key)) {
              validAlbums++;
            }
          } else if (value is Map) {
            await _validateMapValue(key, value, errors, warnings, statistics);
            if (key.toLowerCase().contains('playlist')) {
              validPlaylists++;
            } else if (_isAlbumListKey(key) ||
                (key.toLowerCase().contains('album') &&
                    !key.toLowerCase().contains('saved'))) {
              validAlbums++;
            }
          } else {
            warnings.add(
              'Unsupported data type for key "$key": ${value.runtimeType}',
            );
          }
        } catch (e) {
          errors.add('Error validating key "$key": $e');
        }
      }

      // Update statistics
      statistics.addAll({
        'total_keys': totalKeys,
        'valid_songs': validSongs,
        'valid_playlists': validPlaylists,
        'valid_albums': validAlbums,
        'errors_count': errors.length,
        'warnings_count': warnings.length,
      });

      // Check for data consistency
      _validateDataConsistency(data, errors, warnings);
    } catch (e) {
      errors.add('Critical validation error: $e');
    }

    return ValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
      statistics: statistics,
    );
  }

  /// Validate string value
  Future<void> _validateStringValue(
    String key,
    String value,
    List<String> errors,
    List<String> warnings,
    Map<String, int> statistics,
  ) async {
    if (value.isEmpty && !_isOptionalKey(key)) {
      warnings.add('Empty value for key "$key"');
    }

    // Check if it's JSON that should be valid
    if (_shouldBeJson(key)) {
      try {
        jsonDecode(value);
      } catch (e) {
        errors.add('Invalid JSON in key "$key": $e');
      }
    }

    // Check for potentially problematic content
    if (value.contains('\x00')) {
      errors.add('Key "$key" contains null bytes');
    }
  }

  /// Validate integer value
  void _validateIntValue(
    String key,
    int value,
    List<String> errors,
    List<String> warnings,
  ) {
    // Check for reasonable bounds on known keys
    if (key.toLowerCase().contains('playcount') && value < 0) {
      warnings.add('Negative play count for key "$key": $value');
    }

    if (key.toLowerCase().contains('volume') && (value < 0 || value > 100)) {
      warnings.add('Volume value out of range for key "$key": $value');
    }
  }

  /// Validate double value
  void _validateDoubleValue(
    String key,
    double value,
    List<String> errors,
    List<String> warnings,
  ) {
    if (!value.isFinite) {
      errors.add('Non-finite double value for key "$key": $value');
    }

    if (key.toLowerCase().contains('progress') &&
        (value < 0.0 || value > 1.0)) {
      warnings.add('Progress value out of range for key "$key": $value');
    }
  }

  /// Validate boolean value
  void _validateBoolValue(
    String key,
    bool value,
    List<String> errors,
    List<String> warnings,
  ) {
    // Boolean values are generally safe, but we can add specific validations if needed
  }

  /// Validate list value
  Future<void> _validateListValue(
    String key,
    List value,
    List<String> errors,
    List<String> warnings,
    Map<String, int> statistics,
  ) async {
    if (value.isEmpty && !_isOptionalKey(key)) {
      warnings.add('Empty list for key "$key"');
    }

    // Validate list items based on key type
    if (_isSongListKey(key)) {
      int validItems = 0;
      for (int i = 0; i < value.length; i++) {
        final item = value[i];
        if (item is String) {
          try {
            final decoded = jsonDecode(item);
            if (decoded is Map) {
              await _validateSongData(
                Map<String, dynamic>.from(decoded),
                'key "$key" item $i',
                errors,
                warnings,
              );
              validItems++;
            } else {
              warnings.add('Non-object JSON in "$key" item $i');
            }
          } catch (e) {
            errors.add('Invalid JSON in "$key" item $i: $e');
          }
        } else if (item is Map) {
          await _validateSongData(Map<String, dynamic>.from(item),
              'key "$key" item $i', errors, warnings);
          validItems++;
        } else {
          warnings.add(
            'Unexpected type in "$key" item $i: ${item.runtimeType}',
          );
        }
      }
      statistics['${key}_valid_items'] = validItems;
    } else if (_isAlbumListKey(key)) {
      int validItems = 0;
      for (int i = 0; i < value.length; i++) {
        final item = value[i];
        if (item is String) {
          try {
            final decoded = jsonDecode(item);
            if (decoded is Map) {
              await _validateAlbumData(
                Map<String, dynamic>.from(decoded),
                'key "$key" item $i',
                errors,
                warnings,
              );
              validItems++;
            } else {
              warnings.add('Non-object JSON in "$key" item $i');
            }
          } catch (e) {
            errors.add('Invalid JSON in "$key" item $i: $e');
          }
        } else if (item is Map) {
          await _validateAlbumData(Map<String, dynamic>.from(item),
              'key "$key" item $i', errors, warnings);
          validItems++;
        } else {
          warnings.add(
            'Unexpected type in "$key" item $i: ${item.runtimeType}',
          );
        }
      }
      statistics['${key}_valid_items'] = validItems;
    }
  }

  /// Validate map value
  Future<void> _validateMapValue(
    String key,
    Map value,
    List<String> errors,
    List<String> warnings,
    Map<String, int> statistics,
  ) async {
    if (value.isEmpty && !_isOptionalKey(key)) {
      warnings.add('Empty map for key "$key"');
    }

    // Validate map structure based on key type
    if (_isSongRelatedKey(key)) {
      await _validateSongData(
        Map<String, dynamic>.from(value),
        'key "$key"',
        errors,
        warnings,
      );
    }
  }

  /// Validate song data structure
  Future<void> _validateSongData(
    Map<String, dynamic> songData,
    String context,
    List<String> errors,
    List<String> warnings,
  ) async {
    // Required fields for a song
    const requiredFields = ['title', 'id', 'artist', 'albumArtUrl'];
    for (final field in requiredFields) {
      if (!songData.containsKey(field) || songData[field] == null) {
        errors.add('Missing required field "$field" in $context');
      } else if (songData[field] is String &&
          (songData[field] as String).isEmpty) {
        errors.add('Empty required field "$field" in $context');
      }
    }

    // Validate URL fields
    if (songData.containsKey('albumArtUrl') &&
        songData['albumArtUrl'] is String) {
      final url = songData['albumArtUrl'] as String;
      if (!url.startsWith('http') && !url.startsWith('/')) {
        warnings.add('Suspicious album art URL format in $context: $url');
      }
    }

    if (songData.containsKey('audioUrl') && songData['audioUrl'] is String) {
      final url = songData['audioUrl'] as String;
      if (url.isNotEmpty && !url.startsWith('http') && !url.startsWith('/')) {
        warnings.add('Suspicious audio URL format in $context: $url');
      }
    }

    // Validate extras field
    if (songData.containsKey('extras') && songData['extras'] != null) {
      final extras = songData['extras'];
      if (extras is! Map && extras is! String) {
        warnings.add(
          'Unexpected extras type in $context: ${extras.runtimeType}',
        );
      }
    }
  }

  /// Validate album data structure
  Future<void> _validateAlbumData(
    Map<String, dynamic> albumData,
    String context,
    List<String> errors,
    List<String> warnings,
  ) async {
    // Required fields for an album
    const requiredFields = ['id', 'title', 'artistName', 'albumArtPictureId'];
    for (final field in requiredFields) {
      if (!albumData.containsKey(field) || albumData[field] == null) {
        errors.add('Missing required field "$field" in $context');
      } else if (albumData[field] is String &&
          (albumData[field] as String).isEmpty) {
        errors.add('Empty required field "$field" in $context');
      }
    }

    // Validate tracks field
    if (albumData.containsKey('tracks')) {
      final tracks = albumData['tracks'];
      if (tracks != null) {
        if (tracks is List) {
          // Validate each track as a song
          for (int i = 0; i < tracks.length; i++) {
            final track = tracks[i];
            if (track is Map) {
              await _validateSongData(
                Map<String, dynamic>.from(track),
                '$context track $i',
                errors,
                warnings,
              );
            } else {
              warnings.add('Non-object track data in $context at index $i');
            }
          }
        } else {
          warnings.add('Tracks field in $context is not a list');
        }
      }
    } else {
      warnings.add('Missing tracks field in $context');
    }
  }

  /// Validate data consistency across the entire dataset
  void _validateDataConsistency(
    Map<String, dynamic> data,
    List<String> errors,
    List<String> warnings,
  ) {
    // Check for duplicate song IDs across different collections
    final songIds = <String>{};
    final duplicateIds = <String>{};

    void collectSongIds(dynamic value, String context) {
      if (value is Map) {
        final id = value['id'];
        if (id is String && id.isNotEmpty) {
          if (!songIds.add(id)) {
            duplicateIds.add(id);
          }
        }
        // Check nested songs
        if (value.containsKey('songs') && value['songs'] is List) {
          for (final song in value['songs']) {
            collectSongIds(song, '$context.songs');
          }
        }
        if (value.containsKey('tracks') && value['tracks'] is List) {
          for (final track in value['tracks']) {
            collectSongIds(track, '$context.tracks');
          }
        }
      } else if (value is List) {
        for (final item in value) {
          collectSongIds(item, context);
        }
      }
    }

    for (final entry in data.entries) {
      if (!entry.key.startsWith('_')) {
        collectSongIds(entry.value, entry.key);
      }
    }

    if (duplicateIds.isNotEmpty) {
      warnings.add(
        'Found ${duplicateIds.length} duplicate song IDs: ${duplicateIds.take(5).join(', ')}${duplicateIds.length > 5 ? '...' : ''}',
      );
    }
  }

  /// Check if a key should contain JSON
  bool _shouldBeJson(String key) {
    final keyLower = key.toLowerCase();
    return keyLower.contains('song') ||
        keyLower.contains('playlist') ||
        keyLower.contains('album') ||
        keyLower.contains('queue') ||
        keyLower.contains('liked');
  }

  /// Check if a key is song-related
  bool _isSongRelatedKey(String key) {
    final keyLower = key.toLowerCase();
    return keyLower.contains('song') ||
        keyLower.contains('track') ||
        keyLower.contains('liked');
  }

  /// Check if a key should contain a list of songs
  bool _isSongListKey(String key) {
    final keyLower = key.toLowerCase();
    return keyLower.contains('playlist') ||
        keyLower.contains('queue') ||
        keyLower.contains('liked') ||
        (keyLower.contains('album') &&
            !keyLower.contains('saved') &&
            keyLower != 'albums');
  }

  /// Check if a key should contain a list of albums
  bool _isAlbumListKey(String key) {
    final keyLower = key.toLowerCase();
    return (keyLower.contains('saved') && keyLower.contains('album')) ||
        (keyLower == 'albums');
  }

  /// Check if a key is optional
  bool _isOptionalKey(String key) {
    const optionalKeys = [
      'localFilePath',
      'plainLyrics',
      'syncedLyrics',
      'releaseDate',
    ];
    return optionalKeys.contains(key.toLowerCase());
  }

  /// Export selected data categories to a plist file
  Future<String?> exportSelectiveData(
    Set<DataCategory> categories, {
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call(
        'Initializing selective export',
        0.0,
        'Preparing export...',
      );

      final prefs = await SharedPreferences.getInstance();
      final allData = <String, dynamic>{};
      final keys = prefs.getKeys();

      // Define key patterns for each category
      final categoryPatterns = <DataCategory, List<String>>{
        DataCategory.settings: [
          // Common setting patterns (exclude data-specific keys)
          if (!categories.contains(DataCategory.playlists)) ...['playlist'],
          if (!categories.contains(DataCategory.likedSongs)) ...['liked'],
          if (!categories.contains(DataCategory.downloadHistory)) ...[
            'downloaded',
            'download',
          ],
          if (!categories.contains(DataCategory.queue)) ...[
            'queue',
            'currentQueue',
          ],
          if (!categories.contains(DataCategory.albums)) ...['album'],
          if (!categories.contains(DataCategory.listeningStats)) ...[
            'playCount',
            'stats',
          ],
        ].map((pattern) => pattern.toLowerCase()).toList(),
      };

      onProgress?.call(
        'Filtering data',
        0.1,
        'Filtering ${keys.length} preferences by category...',
      );

      for (final key in keys) {
        final keyLower = key.toLowerCase();
        bool shouldInclude = false;

        // Check if key belongs to selected categories
        // Always include settings (app preferences, configuration, etc.)
        bool isSettingsKey = true;
        for (final pattern in categoryPatterns[DataCategory.settings]!) {
          if (keyLower.contains(pattern)) {
            isSettingsKey = false;
            break;
          }
        }
        if (isSettingsKey) {
          shouldInclude = true;
        } else {
          // Check other selected categories
          for (final category in categories) {
            switch (category) {
              case DataCategory.settings:
                // Settings are already handled above
                break;
              case DataCategory.playlists:
                if (keyLower.contains('playlist') &&
                    !keyLower.contains('album')) {
                  shouldInclude = true;
                }
                break;
              case DataCategory.likedSongs:
                if (keyLower.contains('liked')) {
                  shouldInclude = true;
                }
                break;
              case DataCategory.downloadHistory:
                if ((keyLower.contains('download') ||
                        keyLower.contains('downloaded')) &&
                    !keyLower.contains('queue')) {
                  shouldInclude = true;
                }
                break;
              case DataCategory.queue:
                if (keyLower.contains('queue') ||
                    keyLower.contains('currentqueue')) {
                  shouldInclude = true;
                }
                break;
              case DataCategory.albums:
                if (keyLower.contains('album') &&
                    !keyLower.contains('playlist')) {
                  shouldInclude = true;
                }
                break;
              case DataCategory.listeningStats:
                if (keyLower.contains('playcount') ||
                    keyLower.contains('stats')) {
                  shouldInclude = true;
                }
                break;
            }
          }
          if (shouldInclude) break;
        }

        if (!shouldInclude) continue;

        final value = prefs.get(key);
        if (value != null) {
          // Sanitize song data to remove download states
          if (value is String) {
            if (_shouldSanitizeSongData(key)) {
              try {
                final jsonData = jsonDecode(value);
                if (jsonData is Map) {
                  allData[key] = _sanitizeSongData(
                    Map<String, dynamic>.from(jsonData),
                  );
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
                allData[key] = value;
              }
            } else {
              allData[key] = value;
            }
          } else if (value is List<String>) {
            if (_shouldSanitizeSongData(key)) {
              allData[key] = value.map((jsonStr) {
                try {
                  final jsonData = jsonDecode(jsonStr);
                  if (jsonData is Map) {
                    return jsonEncode(
                      _sanitizeSongData(Map<String, dynamic>.from(jsonData)),
                    );
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
            allData[key] = value;
          }
        }
      }

      // Add metadata
      allData['_exportVersion'] = '1.1';
      allData['_exportDate'] = DateTime.now().toIso8601String();
      // Always include settings in the exported categories
      final exportedCategories = {...categories, DataCategory.settings};
      allData['_exportCategories'] =
          exportedCategories.map((c) => c.name).toList();

      // Export using the unified export method
      final categoriesStr = categories.map((c) => c.name).join('_');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'LTunes_Selective_${categoriesStr}_$timestamp';
      final filePath = await exportData(
        allData,
        ExportFormat.plist,
        customFileName: fileName,
        onProgress: onProgress,
      );

      debugPrint('Selective data exported successfully to: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('Error in selective export: $e');
      onProgress?.call('Error', 0.0, 'Selective export failed: $e');
      return null;
    }
  }

  /// Import selected data categories from a plist or xml file
  Future<bool> importSelectiveData(
    Set<DataCategory> categories, {
    CurrentSongProvider? songProvider,
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call('Selecting file', 0.0, 'Waiting for file selection...');

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['plist', 'xml'],
      );

      if (result == null || result.files.single.path == null) {
        onProgress?.call('Cancelled', 0.0, 'File selection cancelled');
        return false;
      }

      onProgress?.call('Reading file', 0.05, 'Loading file content...');

      final filePath = result.files.single.path!;
      final file = File(filePath);

      if (!await file.exists()) {
        debugPrint('File does not exist: $filePath');
        onProgress?.call('Error', 0.0, 'File does not exist');
        return false;
      }

      final plistContent = await file.readAsString();
      onProgress?.call('Parsing data', 0.15, 'Parsing XML content...');

      final jsonData = _plistXmlToJson(plistContent);

      if (jsonData == null) {
        debugPrint('Failed to parse plist file');
        onProgress?.call('Error', 0.0, 'Failed to parse file format');
        return false;
      }

      // Validate imported data before filtering
      onProgress?.call('Validating data', 0.18, 'Validating data integrity...');
      final validationResult = await validateImportedData(jsonData);

      if (!validationResult.isValid) {
        debugPrint('Data validation failed: ${validationResult.errors}');
        onProgress?.call(
          'Error',
          0.0,
          'Data validation failed: ${validationResult.errors.first}',
        );
        return false;
      }

      if (validationResult.hasWarnings) {
        debugPrint('Data validation warnings: ${validationResult.warnings}');
        // Continue with import but log warnings
      }

      // Check exported categories
      final exportedCategories =
          (jsonData['_exportCategories'] as List<dynamic>?)
                  ?.map((c) => c.toString())
                  .toSet() ??
              {};

      // Filter data based on requested categories
      final filteredData = <String, dynamic>{};
      for (final entry in jsonData.entries) {
        final key = entry.key;
        if (key.startsWith('_')) continue; // Skip metadata

        final keyLower = key.toLowerCase();
        bool shouldInclude = false;

        for (final category in categories) {
          switch (category) {
            case DataCategory.settings:
              shouldInclude = true;
              // Exclude data-specific keys
              if (keyLower.contains('playlist') ||
                  keyLower.contains('liked') ||
                  keyLower.contains('download') ||
                  keyLower.contains('queue') ||
                  keyLower.contains('album') ||
                  keyLower.contains('playcount')) {
                shouldInclude = false;
              }
              break;
            case DataCategory.playlists:
              if (keyLower.contains('playlist') &&
                  !keyLower.contains('album')) {
                shouldInclude = true;
              }
              break;
            case DataCategory.likedSongs:
              if (keyLower.contains('liked')) {
                shouldInclude = true;
              }
              break;
            case DataCategory.downloadHistory:
              if ((keyLower.contains('download') ||
                      keyLower.contains('downloaded')) &&
                  !keyLower.contains('queue')) {
                shouldInclude = true;
              }
              break;
            case DataCategory.queue:
              if (keyLower.contains('queue') ||
                  keyLower.contains('currentqueue')) {
                shouldInclude = true;
              }
              break;
            case DataCategory.albums:
              if (keyLower.contains('album') &&
                  !keyLower.contains('playlist')) {
                shouldInclude = true;
              }
              break;
            case DataCategory.listeningStats:
              if (keyLower.contains('playcount') ||
                  keyLower.contains('stats')) {
                shouldInclude = true;
              }
              break;
          }
          if (shouldInclude) break;
        }

        if (shouldInclude) {
          filteredData[key] = entry.value;
        }
      }

      // Create automatic backup before importing
      onProgress?.call('Creating backup', 0.22, 'Backing up current data...');
      final backupPath = await _createAutomaticBackup();

      final prefs = await SharedPreferences.getInstance();
      final songsToRedownload = <Song>[];
      final totalEntries = filteredData.length;
      int processedEntries = 0;

      onProgress?.call(
        'Importing data',
        0.25,
        'Importing ${categories.length} categories...',
      );

      // Import filtered data
      for (final entry in filteredData.entries) {
        final key = entry.key;
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
          if (value.isNotEmpty && value.first is String) {
            final processedList = value.map((jsonStr) {
              try {
                final decoded = jsonDecode(jsonStr as String);
                if (decoded is Map) {
                  final decodedMap = Map<String, dynamic>.from(decoded);
                  _extractSongsForRedownload(decodedMap, songsToRedownload);
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
            final stringList = value.map((e) {
              if (e is Map) {
                final eMap = Map<String, dynamic>.from(e);
                _extractSongsForRedownload(eMap, songsToRedownload);
                final sanitized = _sanitizeForJson(eMap);
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
          _extractSongsForRedownload(valueMap, songsToRedownload);
          final sanitized = _sanitizeForJson(valueMap);
          if (sanitized is Map) {
            final sanitizedMap = Map<String, dynamic>.from(sanitized);
            _removeWasDownloadedFlags(sanitizedMap);
            await prefs.setString(key, jsonEncode(sanitizedMap));
          } else {
            await prefs.setString(key, jsonEncode(sanitized));
          }
        }

        processedEntries++;
        final progress = 0.25 + (processedEntries / totalEntries) * 0.6;
        onProgress?.call(
          'Importing data',
          progress,
          'Processed $processedEntries/$totalEntries items...',
        );
      }

      // Queue songs for redownload if provider is available
      if (songProvider != null && songsToRedownload.isNotEmpty) {
        onProgress?.call(
          'Queueing downloads',
          0.9,
          'Queueing ${songsToRedownload.length} songs for redownload...',
        );

        debugPrint('Queueing ${songsToRedownload.length} songs for redownload');
        for (int i = 0; i < songsToRedownload.length; i++) {
          final song = songsToRedownload[i];
          try {
            await songProvider.queueSongForDownload(song);
          } catch (e) {
            debugPrint('Error queueing song ${song.title} for download: $e');
          }

          final downloadProgress =
              0.9 + ((i + 1) / songsToRedownload.length) * 0.1;
          onProgress?.call(
            'Queueing downloads',
            downloadProgress,
            'Queued ${i + 1}/${songsToRedownload.length} songs...',
          );
        }
      }

      onProgress?.call(
        'Complete',
        1.0,
        'Selective import completed successfully',
      );

      debugPrint('Selective data imported successfully');
      return true;
    } catch (e) {
      debugPrint('Error in selective import: $e');
      onProgress?.call('Error', 0.0, 'Selective import failed: $e');
      return false;
    }
  }

  /// Check if a key should have song data sanitized
  bool _shouldSanitizeSongData(String key) {
    final keyLower = key.toLowerCase();
    return keyLower.contains('song') ||
        keyLower.contains('queue') ||
        keyLower.contains('playlist') ||
        keyLower.contains('album') ||
        keyLower.contains('liked');
  }

  /// Export all app data to a plist file (iOS/macOS) or xml file (Android)
  Future<String?> exportAllData({ProgressCallback? onProgress}) async {
    try {
      onProgress?.call('Initializing export', 0.0, 'Loading preferences...');

      final prefs = await SharedPreferences.getInstance();

      // Get all SharedPreferences keys and values
      final allData = <String, dynamic>{};
      final keys = prefs.getKeys();
      final totalKeys = keys.length;
      int processedKeys = 0;

      onProgress?.call(
        'Processing data',
        0.1,
        'Processing $totalKeys preferences...',
      );

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
                  allData[key] = _sanitizeSongData(
                    Map<String, dynamic>.from(jsonData),
                  );
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
                      _sanitizeSongData(Map<String, dynamic>.from(jsonData)),
                    );
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

        processedKeys++;
        final progress = 0.1 + (processedKeys / totalKeys) * 0.7; // 10% to 80%
        onProgress?.call(
          'Processing data',
          progress,
          'Processed $processedKeys/$totalKeys items...',
        );
      }

      // Add metadata
      allData['_exportVersion'] = '1.1'; // Updated version
      allData['_exportDate'] = DateTime.now().toIso8601String();

      // Export using the unified export method
      final filePath = await exportData(
        allData,
        ExportFormat.plist,
        onProgress: onProgress,
      );

      debugPrint('Data exported successfully to: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('Error exporting data: $e');
      onProgress?.call('Error', 0.0, 'Export failed: $e');
      return null;
    }
  }

  /// Import all app data from a plist or xml file (always replaces existing data)
  Future<bool> importAllData({
    CurrentSongProvider? songProvider,
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call('Selecting file', 0.0, 'Waiting for file selection...');

      // Pick file - accept plist, xml, and json files
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['plist', 'xml', 'json'],
      );

      if (result == null || result.files.single.path == null) {
        onProgress?.call('Cancelled', 0.0, 'File selection cancelled');
        return false;
      }

      final filePath = result.files.single.path!;

      // Parse the exported data (handles multiple formats)
      final jsonData = await parseExportedData(
        filePath,
        onProgress: (operation, progress, message) {
          // Adjust progress for the import workflow
          final adjustedProgress =
              progress * 0.15; // 0-15% of total import progress
          onProgress?.call(operation, adjustedProgress, message);
        },
      );

      if (jsonData == null) {
        debugPrint('Failed to parse plist file');
        onProgress?.call('Error', 0.0, 'Failed to parse file format');
        return false;
      }

      // Validate imported data
      onProgress?.call('Validating data', 0.18, 'Validating data integrity...');
      final validationResult = await validateImportedData(jsonData);

      if (!validationResult.isValid) {
        debugPrint('Data validation failed: ${validationResult.errors}');
        onProgress?.call(
          'Error',
          0.0,
          'Data validation failed: ${validationResult.errors.first}',
        );
        return false;
      }

      if (validationResult.hasWarnings) {
        debugPrint('Data validation warnings: ${validationResult.warnings}');
        // Continue with import but log warnings
      }

      // Check version compatibility
      final exportVersion = jsonData['_exportVersion'] as String? ?? '1.0';
      onProgress?.call(
        'Validating data',
        0.2,
        'Checking compatibility (v$exportVersion)...',
      );

      // Create automatic backup before importing
      onProgress?.call('Creating backup', 0.22, 'Backing up current data...');
      final backupPath = await _createAutomaticBackup();
      if (backupPath == null) {
        debugPrint('Warning: Failed to create backup before import');
        // Continue with import but log the warning
      } else {
        debugPrint('Backup created at: $backupPath');
      }

      // Import all SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final songsToRedownload = <Song>[];
      final totalEntries = jsonData.length;
      int processedEntries = 0;

      onProgress?.call(
        'Importing data',
        0.25,
        'Importing $totalEntries preferences...',
      );

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

        processedEntries++;
        final progress =
            0.25 + (processedEntries / totalEntries) * 0.6; // 25% to 85%
        onProgress?.call(
          'Importing data',
          progress,
          'Processed $processedEntries/$totalEntries items...',
        );
      }

      // Queue songs for redownload if provider is available
      if (songProvider != null && songsToRedownload.isNotEmpty) {
        onProgress?.call(
          'Queueing downloads',
          0.9,
          'Queueing ${songsToRedownload.length} songs for redownload...',
        );

        debugPrint('Queueing ${songsToRedownload.length} songs for redownload');
        for (int i = 0; i < songsToRedownload.length; i++) {
          final song = songsToRedownload[i];
          try {
            await songProvider.queueSongForDownload(song);
          } catch (e) {
            debugPrint('Error queueing song ${song.title} for download: $e');
          }

          final downloadProgress =
              0.9 + ((i + 1) / songsToRedownload.length) * 0.1; // 90% to 100%
          onProgress?.call(
            'Queueing downloads',
            downloadProgress,
            'Queued ${i + 1}/${songsToRedownload.length} songs...',
          );
        }
      }

      onProgress?.call('Complete', 1.0, 'Import completed successfully');

      debugPrint('Data imported successfully');
      return true;
    } catch (e) {
      debugPrint('Error importing data: $e');
      onProgress?.call('Error', 0.0, 'Import failed: $e');
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

  /// Get list of available automatic backups
  Future<List<Map<String, dynamic>>> getAvailableBackups() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${directory.path}/backups');

      if (!await backupDir.exists()) {
        return [];
      }

      final backupFiles = await backupDir.list().toList();
      final backups = <Map<String, dynamic>>[];

      for (final file in backupFiles) {
        if (file is File && file.path.endsWith('.plist')) {
          try {
            final content = await file.readAsString();
            final jsonData = _plistXmlToJson(content);

            if (jsonData != null) {
              final backupDate = jsonData['_backupDate'] as String?;
              final backupType = jsonData['_backupType'] as String? ?? 'manual';

              if (backupDate != null) {
                backups.add({
                  'path': file.path,
                  'date': DateTime.parse(backupDate),
                  'type': backupType,
                  'size': await file.length(),
                });
              }
            }
          } catch (e) {
            debugPrint('Error reading backup file ${file.path}: $e');
          }
        }
      }

      // Sort by date descending (newest first)
      backups.sort(
        (a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime),
      );

      return backups;
    } catch (e) {
      debugPrint('Error getting available backups: $e');
      return [];
    }
  }

  /// Restore from a backup file
  Future<bool> restoreFromBackup(
    String backupPath, {
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call('Reading backup', 0.0, 'Loading backup file...');

      final backupFile = File(backupPath);
      if (!await backupFile.exists()) {
        onProgress?.call('Error', 0.0, 'Backup file does not exist');
        return false;
      }

      final content = await backupFile.readAsString();
      onProgress?.call('Parsing backup', 0.2, 'Parsing backup data...');

      final jsonData = _plistXmlToJson(content);
      if (jsonData == null) {
        onProgress?.call('Error', 0.0, 'Failed to parse backup file');
        return false;
      }

      // Create a backup of current state before restoring
      onProgress?.call(
        'Creating safety backup',
        0.3,
        'Backing up current data...',
      );
      final safetyBackupPath = await _createAutomaticBackup();
      if (safetyBackupPath != null) {
        debugPrint('Safety backup created at: $safetyBackupPath');
      }

      // Restore SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final totalEntries = jsonData.length;
      int processedEntries = 0;

      onProgress?.call('Restoring data', 0.4, 'Restoring preferences...');

      // Clear all current data first
      await prefs.clear();

      // Skip metadata keys
      for (final entry in jsonData.entries) {
        final key = entry.key;
        if (key.startsWith('_') &&
            (key == '_backupVersion' ||
                key == '_backupDate' ||
                key == '_backupType')) {
          continue; // Skip backup metadata
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
          if (value.isNotEmpty && value.first is String) {
            final processedList = value.map((jsonStr) {
              try {
                final decoded = jsonDecode(jsonStr as String);
                if (decoded is Map) {
                  final decodedMap = Map<String, dynamic>.from(decoded);
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
            final stringList = value.map((e) {
              if (e is Map) {
                final eMap = Map<String, dynamic>.from(e);
                final sanitized = _sanitizeForJson(eMap);
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
          final sanitized = _sanitizeForJson(valueMap);
          if (sanitized is Map) {
            final sanitizedMap = Map<String, dynamic>.from(sanitized);
            _removeWasDownloadedFlags(sanitizedMap);
            await prefs.setString(key, jsonEncode(sanitizedMap));
          } else {
            await prefs.setString(key, jsonEncode(sanitized));
          }
        }

        processedEntries++;
        final progress = 0.4 + (processedEntries / totalEntries) * 0.6;
        onProgress?.call(
          'Restoring data',
          progress,
          'Restored $processedEntries/$totalEntries items...',
        );
      }

      onProgress?.call('Complete', 1.0, 'Backup restored successfully');

      debugPrint('Backup restored successfully from: $backupPath');
      return true;
    } catch (e) {
      debugPrint('Error restoring from backup: $e');
      onProgress?.call('Error', 0.0, 'Failed to restore backup: $e');
      return false;
    }
  }

  /// Extract songs that need to be redownloaded from nested structures
  void _extractSongsForRedownload(
    Map<String, dynamic> data,
    List<Song> songsToRedownload,
  ) {
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
            Map<String, dynamic>.from(songItem),
            songsToRedownload,
          );
        }
      }
    }

    if (data.containsKey('tracks') && data['tracks'] is List) {
      for (final trackItem in data['tracks'] as List) {
        if (trackItem is Map) {
          _extractSongsForRedownload(
            Map<String, dynamic>.from(trackItem),
            songsToRedownload,
          );
        }
      }
    }
  }

  /// Remove _wasDownloaded flags from nested structures
  void _removeWasDownloadedFlags(Map<String, dynamic> data) {
    data.remove('_wasDownloaded');

    if (data.containsKey('songs') && data['songs'] is List) {
      final songsList = data['songs'] as List;
      for (int i = 0; i < songsList.length; i++) {
        final songItem = songsList[i];
        if (songItem is Map) {
          songsList[i] = Map<String, dynamic>.from(songItem);
          _removeWasDownloadedFlags(songsList[i] as Map<String, dynamic>);
        }
      }
    }

    if (data.containsKey('tracks') && data['tracks'] is List) {
      final tracksList = data['tracks'] as List;
      for (int i = 0; i < tracksList.length; i++) {
        final trackItem = tracksList[i];
        if (trackItem is Map) {
          tracksList[i] = Map<String, dynamic>.from(trackItem);
          _removeWasDownloadedFlags(tracksList[i] as Map<String, dynamic>);
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

        // Fix extras field - preserve data but ensure proper types
        if (key == 'extras') {
          if (value == null ||
              value == '' ||
              (value is String && value.trim().isEmpty)) {
            sanitized[key] = null;
          } else if (value is Map) {
            sanitized[key] = _sanitizeExtras(Map<String, dynamic>.from(value));
          } else {
            // Preserve non-Map extras (will be handled by _sanitizeSongData)
            sanitized[key] = value;
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

  /// Sanitize extras data to remove sensitive or transient information
  Map<String, dynamic> _sanitizeExtras(Map<String, dynamic> extras) {
    final sanitized = Map<String, dynamic>.from(extras);

    // Remove any potentially sensitive fields from extras
    // Add any fields that should be excluded during export
    const sensitiveFields = <String>{};
    for (final field in sensitiveFields) {
      sanitized.remove(field);
    }

    // Recursively sanitize nested Maps
    for (final entry in sanitized.entries) {
      if (entry.value is Map) {
        sanitized[entry.key] = _sanitizeExtras(
          Map<String, dynamic>.from(entry.value),
        );
      }
    }

    return sanitized;
  }

  /// Safely extract boolean value from dynamic data
  bool _safeBoolValue(dynamic value) {
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    if (value is int) return value != 0;
    return false;
  }

  /// Safely extract integer value from dynamic data
  int? _safeIntValue(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.toInt();
    return null;
  }

  /// Create an automatic backup before importing data
  Future<String?> _createAutomaticBackup() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupDir = Directory('${directory.path}/backups');

      // Create backups directory if it doesn't exist
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      // Clean up old backups (keep only last 5)
      final backupFiles = await backupDir.list().toList();
      if (backupFiles.length >= 5) {
        backupFiles.sort(
          (a, b) => b.path.compareTo(a.path),
        ); // Sort by name descending (newest first)
        for (int i = 4; i < backupFiles.length; i++) {
          try {
            await backupFiles[i].delete(recursive: true);
          } catch (e) {
            debugPrint('Failed to delete old backup: $e');
          }
        }
      }

      final backupPath = '${backupDir.path}/LTunes_AutoBackup_$timestamp.plist';

      // Export current data to backup file
      final prefs = await SharedPreferences.getInstance();
      final allData = <String, dynamic>{};
      final keys = prefs.getKeys();

      for (final key in keys) {
        final value = prefs.get(key);
        if (value != null) {
          // Use same sanitization logic as regular export
          if (value is String) {
            if (key.contains('song') ||
                key.contains('queue') ||
                key.contains('playlist') ||
                key.contains('album') ||
                key.contains('liked')) {
              try {
                final jsonData = jsonDecode(value);
                if (jsonData is Map) {
                  allData[key] = _sanitizeSongData(
                    Map<String, dynamic>.from(jsonData),
                  );
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
                allData[key] = value;
              }
            } else {
              allData[key] = value;
            }
          } else if (value is List<String>) {
            if (key.contains('playlist') ||
                key.contains('queue') ||
                key.contains('album') ||
                key.contains('liked')) {
              allData[key] = value.map((jsonStr) {
                try {
                  final jsonData = jsonDecode(jsonStr);
                  if (jsonData is Map) {
                    return jsonEncode(
                      _sanitizeSongData(Map<String, dynamic>.from(jsonData)),
                    );
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
            allData[key] = value;
          }
        }
      }

      // Add backup metadata
      allData['_backupVersion'] = '1.1';
      allData['_backupDate'] = DateTime.now().toIso8601String();
      allData['_backupType'] = 'automatic_pre_import';

      final plistXml = _jsonToPlistXml(allData);
      final backupFile = File(backupPath);
      await backupFile.writeAsString(plistXml);

      return backupPath;
    } catch (e) {
      debugPrint('Error creating automatic backup: $e');
      return null;
    }
  }

  /// Sanitize song data by removing download states but tracking if it was downloaded
  Map<String, dynamic> _sanitizeSongData(Map<String, dynamic> data) {
    final sanitized = Map<String, dynamic>.from(data);

    // Track if song was downloaded before removing the flag
    final wasDownloaded = _safeBoolValue(sanitized['isDownloaded']);
    if (wasDownloaded) {
      sanitized['_wasDownloaded'] = true;
    }

    // Remove all download-related and transient fields
    sanitized['isDownloaded'] = false;
    sanitized['localFilePath'] = null;
    sanitized['isDownloading'] = false;
    sanitized['downloadProgress'] = 0.0;
    sanitized['plainLyrics'] = null;
    sanitized['syncedLyrics'] = null;
    sanitized['playCount'] = _safeIntValue(sanitized['playCount']) ?? 0;

    // Handle extras field - preserve data but sanitize nested content
    if (sanitized.containsKey('extras')) {
      final extras = sanitized['extras'];
      if (extras == null ||
          extras == '' ||
          (extras is String && extras.trim().isEmpty)) {
        sanitized['extras'] = null;
      } else if (extras is Map) {
        // Sanitize nested Map in extras
        sanitized['extras'] = _sanitizeExtras(
          Map<String, dynamic>.from(extras),
        );
      } else if (extras is String) {
        // Try to parse string extras as JSON, but preserve as string if not JSON
        try {
          final parsed = jsonDecode(extras);
          if (parsed is Map) {
            sanitized['extras'] = _sanitizeExtras(
              Map<String, dynamic>.from(parsed),
            );
          } else {
            // Not a JSON object, keep as string but trim
            sanitized['extras'] = extras.trim();
          }
        } catch (e) {
          // Not valid JSON, keep as trimmed string
          sanitized['extras'] = extras.trim();
        }
      } else {
        // For other types, convert to string representation
        sanitized['extras'] = extras.toString();
      }
    }

    // Handle nested song data in playlists/albums
    if (sanitized.containsKey('songs') && sanitized['songs'] is List) {
      sanitized['songs'] = (sanitized['songs'] as List).map((song) {
        if (song is Map) {
          return _sanitizeSongData(Map<String, dynamic>.from(song));
        } else if (song is String) {
          // Try to parse string as JSON song data
          try {
            final parsed = jsonDecode(song);
            if (parsed is Map) {
              return _sanitizeSongData(Map<String, dynamic>.from(parsed));
            }
          } catch (e) {
            // Keep as string if not valid JSON
          }
        }
        return song;
      }).toList();
    }

    if (sanitized.containsKey('tracks') && sanitized['tracks'] is List) {
      sanitized['tracks'] = (sanitized['tracks'] as List).map((track) {
        if (track is Map) {
          return _sanitizeSongData(Map<String, dynamic>.from(track));
        } else if (track is String) {
          // Try to parse string as JSON track data
          try {
            final parsed = jsonDecode(track);
            if (parsed is Map) {
              return _sanitizeSongData(Map<String, dynamic>.from(parsed));
            }
          } catch (e) {
            // Keep as string if not valid JSON
          }
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

  /// Export data in the specified format
  Future<String?> exportData(
    Map<String, dynamic> data,
    ExportFormat format, {
    String? customFileName,
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call(
        'Converting format',
        0.8,
        'Converting to ${format.displayName} format...',
      );

      String content;
      String fileName;
      String extension;

      switch (format) {
        case ExportFormat.plist:
          content = _jsonToPlistXml(data);
          extension = Platform.isAndroid ? 'xml' : 'plist';
          fileName = customFileName ??
              'LTunes_Export_${DateTime.now().millisecondsSinceEpoch}.$extension';
          break;
        case ExportFormat.json:
          content = JsonEncoder.withIndent('  ').convert(data);
          extension = 'json';
          fileName = customFileName ??
              'LTunes_Export_${DateTime.now().millisecondsSinceEpoch}.$extension';
          break;
      }

      onProgress?.call('Saving file', 0.9, 'Writing to disk...');

      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsString(content);

      onProgress?.call(
        'Complete',
        1.0,
        '${format.displayName} export completed successfully',
      );

      debugPrint('Data exported successfully to: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('Error exporting data in ${format.displayName} format: $e');
      onProgress?.call('Error', 0.0, '${format.displayName} export failed: $e');
      return null;
    }
  }

  /// Parse data from different formats
  Future<Map<String, dynamic>?> parseExportedData(
    String filePath, {
    ProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call('Reading file', 0.0, 'Loading exported file...');

      final file = File(filePath);
      if (!await file.exists()) {
        onProgress?.call('Error', 0.0, 'File does not exist');
        return null;
      }

      final content = await file.readAsString();
      onProgress?.call('Parsing data', 0.5, 'Parsing file content...');

      final extension = filePath.split('.').last.toLowerCase();

      Map<String, dynamic>? jsonData;
      if (extension == 'plist' || extension == 'xml') {
        jsonData = _plistXmlToJson(content);
      } else if (extension == 'json') {
        jsonData = jsonDecode(content) as Map<String, dynamic>;
      } else {
        onProgress?.call('Error', 0.0, 'Unsupported file format: $extension');
        return null;
      }

      onProgress?.call('Complete', 1.0, 'File parsed successfully');
      return jsonData;
    } catch (e) {
      debugPrint('Error parsing exported data: $e');
      onProgress?.call('Error', 0.0, 'Failed to parse file: $e');
      return null;
    }
  }

  /// Convert JSON data to plist XML format
  String _jsonToPlistXml(Map<String, dynamic> json) {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'plist',
      attributes: {'version': '1.0'},
      nest: () {
        builder.element(
          'dict',
          nest: () {
            _addDictEntries(builder, json);
          },
        );
      },
    );

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
      builder.element(
        'array',
        nest: () {
          for (final item in value) {
            _addValue(builder, item);
          }
        },
      );
    } else if (value is Map) {
      builder.element(
        'dict',
        nest: () {
          _addDictEntries(builder, Map<String, dynamic>.from(value));
        },
      );
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
