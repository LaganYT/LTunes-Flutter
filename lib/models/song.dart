import '../services/version_service.dart';

class Song {
  final String title;
  final String id;
  final List<String> artists;
  final List<String> artistIds;
  final String
      albumArtUrl; // Can be network URL or local filename (relative to docs dir)
  final String? album;
  final String? releaseDate;
  final String audioUrl; // Ensure non-nullable, default to empty
  final Duration? duration;

  // Backward compatibility getters
  String get artist => artists.isNotEmpty ? artists.first : '';
  String get artistId => artistIds.isNotEmpty ? artistIds.first : '';

  // Add these fields
  bool isDownloaded;
  String?
      localFilePath; // Stores filename only (relative to docs dir) if downloaded
  bool get isLocal => !albumArtUrl.startsWith('http');
  final Map<String, dynamic>? extras; // Added extras field
  final bool isImported; // New field for imported songs
  int playCount; // New field for play count
  final bool isCustomMetadata; // New field for custom metadata

  // Add a getter for isRadio
  bool get isRadio => extras?['isRadio'] as bool? ?? false;

  // Fields for download state
  bool isDownloading;
  double downloadProgress;

  // Lyrics fields
  String? plainLyrics;
  String? syncedLyrics;

  Song({
    required this.title,
    required this.id,
    List<String>? artists,
    List<String>? artistIds,
    String? artist, // Backward compatibility
    String? artistId, // Backward compatibility
    required this.albumArtUrl,
    this.album,
    this.releaseDate,
    this.audioUrl = '', // Default to empty string
    this.isDownloaded = false,
    this.localFilePath,
    this.extras, // Added extras to constructor
    this.duration, // Ensure duration is part of the constructor
    this.isDownloading = false, // Default value
    this.downloadProgress = 0.0, // Default value
    this.isImported = false, // Default to false
    this.plainLyrics,
    this.syncedLyrics,
    this.playCount = 0, // Default to 0
    this.isCustomMetadata = false, // Default to false
  })  : artists =
            artists ?? (artist != null && artist.isNotEmpty ? [artist] : []),
        artistIds = artistIds ??
            (artistId != null && artistId.isNotEmpty ? [artistId] : []);

  Song copyWith({
    String? title,
    String? id, // Allow copying ID if necessary, though typically fixed
    List<String>? artists,
    List<String>? artistIds,
    String? albumArtUrl,
    String? album,
    String? releaseDate,
    String? audioUrl,
    bool? isDownloaded,
    String? localFilePath, // <— parameter stays nullable
    Map<String, dynamic>? extras, // Added extras to copyWith
    Duration? duration, // Added duration to copyWith
    bool? isDownloading,
    double? downloadProgress,
    bool? isImported, // Added isImported
    String? plainLyrics,
    String? syncedLyrics,
    int? playCount, // New field
    bool? isCustomMetadata, // Add to copyWith
  }) {
    return Song(
      title: title ?? this.title,
      id: id ?? this.id, // Keep original ID unless explicitly overridden
      artists: artists ?? this.artists,
      artistIds: artistIds ?? this.artistIds,
      albumArtUrl: albumArtUrl ?? this.albumArtUrl, // Handled by consumers
      album: album ?? this.album,
      releaseDate: releaseDate ?? this.releaseDate,
      audioUrl: audioUrl ?? this.audioUrl,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      localFilePath:
          localFilePath ?? this.localFilePath, // <— preserve existing path
      extras: extras ?? this.extras, // Added extras logic
      duration: duration ?? this.duration, // Added duration logic
      isDownloading: isDownloading ?? this.isDownloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      isImported: isImported ?? this.isImported, // Added isImported logic
      plainLyrics: plainLyrics ?? this.plainLyrics,
      syncedLyrics: syncedLyrics ?? this.syncedLyrics,
      playCount: playCount ?? this.playCount, // New field
      isCustomMetadata:
          isCustomMetadata ?? this.isCustomMetadata, // Add to copyWith logic
    );
  }

  // Helper function to safely convert a dynamic value to String, or return a default.
  static String _asString(dynamic value, [String defaultValue = '']) {
    if (value is String) return value;
    if (value != null) return value.toString();
    return defaultValue;
  }

  // Helper function to safely convert a dynamic value to String?, or return null.
  // Treats empty strings as valid strings, not null.
  static String? _asNullableString(dynamic value) {
    if (value is String) return value;
    if (value != null) return value.toString();
    return null;
  }

  /// Universal factory constructor that handles both API v2 and original API formats
  factory Song.fromJson(Map<String, dynamic> json) {
    try {
      // Use helpers for safer parsing - handle both API v2 and original API field names
      String title = _asString(
          json['title'] ?? json['name'] ?? json['SNG_TITLE'], 'Unknown Title');

      // Append version to title if VERSION field exists (Deezer API format)
      final version = _asNullableString(json['VERSION']);
      if (version != null && version.isNotEmpty) {
        title = '$title $version';
      }
      final id = _asString(json['id'] ?? json['SNG_ID'],
          DateTime.now().millisecondsSinceEpoch.toString());

      List<String> artists = [];
      List<String> artistIds = [];

      // Parse single artist for backward compatibility
      String singleArtist = _asString(json['artist'] ?? json['ART_NAME']);
      String singleArtistId = _asString(json['artistId'] ?? json['ART_ID']);

      // Handle artists array if present (support both API v2 and Deezer formats)
      final artistsList = json['artists'] ?? json['ARTISTS'] as List?;
      if (artistsList != null && artistsList.isNotEmpty) {
        for (final artistMap in artistsList) {
          if (artistMap is Map) {
            // Support both API v2 format (name/id) and Deezer format (ART_NAME/ART_ID)
            final artistName =
                _asString(artistMap['name'] ?? artistMap['ART_NAME']);
            final artistId = _asString(artistMap['id'] ?? artistMap['ART_ID']);
            if (artistName.isNotEmpty) {
              artists.add(artistName);
              artistIds.add(artistId);
            }
          }
        }
      }

      // If no artists array, use single artist fields
      if (artists.isEmpty) {
        if (singleArtist.isNotEmpty) {
          artists.add(singleArtist);
          artistIds.add(singleArtistId);
        }
      }
      String albumArtUrlFromJson = _asString(json['albumArtUrl']); // Raw value
      String audioUrl = _asString(json['audioUrl']);

      String? albumName;
      String? releaseDate = _asNullableString(
          json['releaseDate'] ?? json['PHYSICAL_RELEASE_DATE']);

      // Parse duration robustly - handle both generic and Deezer API formats
      dynamic durationMsValue = json['duration_ms'];
      dynamic durationSecondsValue = json['DURATION'];

      int? durationMsAsInt;
      if (durationMsValue is int) {
        durationMsAsInt = durationMsValue;
      } else if (durationMsValue is String) {
        durationMsAsInt = int.tryParse(durationMsValue);
      }

      // If no duration_ms, try to parse DURATION (in seconds) from Deezer API
      if (durationMsAsInt == null && durationSecondsValue != null) {
        int? durationSeconds;
        if (durationSecondsValue is int) {
          durationSeconds = durationSecondsValue;
        } else if (durationSecondsValue is String) {
          durationSeconds = int.tryParse(durationSecondsValue);
        }
        if (durationSeconds != null) {
          durationMsAsInt =
              durationSeconds * 1000; // Convert seconds to milliseconds
        }
      }

      // If durationMsValue is null or not int/String, durationMsAsInt remains null.
      final Duration? parsedDuration = durationMsAsInt != null
          ? Duration(milliseconds: durationMsAsInt)
          : null;

      // isDownloading and downloadProgress are typically transient state,
      // so they are not usually part of fromJson.
      // If they were persisted, you'd parse them here.
      // For now, they will default to false and 0.0 respectively via the constructor.

      // Handle album parsing for both generic and Deezer API formats
      final albumField = json['album'];
      if (albumField is Map) {
        albumName = _asNullableString(albumField['name']);
        releaseDate =
            _asNullableString(albumField['release_date']) ?? releaseDate;
        if (albumArtUrlFromJson.isEmpty && albumField.containsKey('images')) {
          final images = albumField['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final firstImageMap = images.first as Map?;
            albumArtUrlFromJson = _asString(firstImageMap?['url']);
          }
        }
      } else {
        // albumField is not a Map (could be String, null, or other type to convert)
        albumName = _asNullableString(albumField) ??
            _asNullableString(json['ALB_TITLE']);
      }

      // Handle Deezer API album art URL
      if (albumArtUrlFromJson.isEmpty && json['ALB_PICTURE'] != null) {
        final albumPictureId = json['ALB_PICTURE'].toString();
        if (albumPictureId.isNotEmpty) {
          albumArtUrlFromJson =
              'https://e-cdns-images.dzcdn.net/images/cover/$albumPictureId/500x500-000000-80-0-0.jpg';
        }
      }

      final bool isImported =
          json['isImported'] as bool? ?? false; // Parse isImported
      final String? plainLyrics = _asNullableString(json['plainLyrics']);
      final String? syncedLyrics = _asNullableString(json['syncedLyrics']);
      final int playCount = json['playCount'] as int? ?? 0; // Parse playCount
      final bool isCustomMetadata =
          json['isCustomMetadata'] as bool? ?? false; // Parse isCustomMetadata

      return Song(
        title: title,
        id: id,
        artists: artists,
        artistIds: artistIds,
        albumArtUrl:
            albumArtUrlFromJson, // Store as is; migration/usage logic handles interpretation
        album: albumName, // albumName is already String?
        releaseDate: releaseDate, // releaseDate is already String?
        audioUrl: audioUrl,
        isDownloaded: json['isDownloaded'] as bool? ??
            false, // Assuming isDownloaded is boolean
        localFilePath: _asNullableString(json[
            'localFilePath']), // Store as is; migration/usage logic handles interpretation
        extras: json['extras'] as Map<String, dynamic>?, // Added extras parsing
        duration: parsedDuration, // Assign parsed duration
        isImported: isImported, // Assign parsed isImported
        plainLyrics: plainLyrics,
        syncedLyrics: syncedLyrics,
        playCount: playCount, // Assign playCount
        isCustomMetadata: isCustomMetadata, // Assign parsed isCustomMetadata
        // isDownloading and downloadProgress will use default constructor values
      );
    } catch (e) {
      // For debugging purposes, it can be helpful to print the problematic JSON.
      // print('Error parsing song from JSON: $json. Error: $e');
      throw FormatException('Invalid song JSON format: $e. Source JSON: $json');
    }
  }

  /// Factory constructor specifically for API v2 format
  factory Song.fromApiV2Json(Map<String, dynamic> json) {
    return Song.fromJson(
        json); // API v2 uses the same format as the universal parser
  }

  /// Factory constructor specifically for original API (fallback) format
  /// This matches the old Song.fromJson behavior exactly
  factory Song.fromOriginalApiJson(Map<String, dynamic> json) {
    try {
      // Use the exact same logic as the old fromJson method
      final title = _asString(json['title'] ?? json['name'], 'Unknown Title');
      final id = _asString(
          json['id'], DateTime.now().millisecondsSinceEpoch.toString());

      List<String> artists = [];
      List<String> artistIds = [];

      // Parse single artist for backward compatibility
      String singleArtist = _asString(json['artist']);
      String singleArtistId = _asString(json['artistId']);

      // Handle artists array (same as old method)
      if (json.containsKey('artists')) {
        final artistsList = json['artists'] as List?;
        if (artistsList != null && artistsList.isNotEmpty) {
          for (final artistMap in artistsList) {
            if (artistMap is Map) {
              final artistName = _asString(artistMap['name']);
              final artistId = _asString(artistMap['id']);
              if (artistName.isNotEmpty) {
                artists.add(artistName);
                artistIds.add(artistId);
              }
            }
          }
        }
      }

      // If no artists array, use single artist fields
      if (artists.isEmpty) {
        if (singleArtist.isNotEmpty) {
          artists.add(singleArtist);
          artistIds.add(singleArtistId);
        }
      }
      String albumArtUrlFromJson = _asString(json['albumArtUrl']); // Raw value
      String audioUrl = _asString(json['audioUrl']);

      String? albumName;
      String? releaseDate = _asNullableString(json['releaseDate']);

      // Parse duration_ms robustly (same as old method)
      dynamic durationMsValue = json['duration_ms'];
      int? durationMsAsInt;
      if (durationMsValue is int) {
        durationMsAsInt = durationMsValue;
      } else if (durationMsValue is String) {
        durationMsAsInt = int.tryParse(durationMsValue);
      }
      // If durationMsValue is null or not int/String, durationMsAsInt remains null.
      final Duration? parsedDuration = durationMsAsInt != null
          ? Duration(milliseconds: durationMsAsInt)
          : null;

      // Handle album field (same as old method)
      final albumField = json['album'];
      if (albumField is Map) {
        albumName = _asNullableString(albumField['name']);
        releaseDate =
            _asNullableString(albumField['release_date']) ?? releaseDate;
        if (albumArtUrlFromJson.isEmpty && albumField.containsKey('images')) {
          final images = albumField['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final firstImageMap = images.first as Map?;
            albumArtUrlFromJson = _asString(firstImageMap?['url']);
          }
        }
      } else {
        // albumField is not a Map (could be String, null, or other type to convert)
        albumName = _asNullableString(albumField);
      }

      final bool isImported =
          json['isImported'] as bool? ?? false; // Parse isImported
      final String? plainLyrics = _asNullableString(json['plainLyrics']);
      final String? syncedLyrics = _asNullableString(json['syncedLyrics']);
      final int playCount = json['playCount'] as int? ?? 0; // Parse playCount
      final bool isCustomMetadata =
          json['isCustomMetadata'] as bool? ?? false; // Parse isCustomMetadata

      return Song(
        title: title,
        id: id,
        artists: artists,
        artistIds: artistIds,
        albumArtUrl:
            albumArtUrlFromJson, // Store as is; migration/usage logic handles interpretation
        album: albumName, // albumName is already String?
        releaseDate: releaseDate, // releaseDate is already String?
        audioUrl: audioUrl,
        isDownloaded: json['isDownloaded'] as bool? ??
            false, // Assuming isDownloaded is boolean
        localFilePath: _asNullableString(json[
            'localFilePath']), // Store as is; migration/usage logic handles interpretation
        extras: json['extras'] as Map<String, dynamic>?, // Added extras parsing
        duration: parsedDuration, // Assign parsed duration
        isImported: isImported, // Assign parsed isImported
        plainLyrics: plainLyrics,
        syncedLyrics: syncedLyrics,
        playCount: playCount, // Assign playCount
        isCustomMetadata: isCustomMetadata, // Assign parsed isCustomMetadata
        // isDownloading and downloadProgress will use default constructor values
      );
    } catch (e) {
      // For debugging purposes, it can be helpful to print the problematic JSON.
      // print('Error parsing song from JSON: $json. Error: $e');
      throw FormatException('Invalid song JSON format: $e. Source JSON: $json');
    }
  }

  factory Song.fromAlbumTrackJson(
      Map<String, dynamic> trackJson,
      String albumTitle,
      String albumArtPictureId,
      String albumReleaseDate,
      String albumArtistName) {
    final String songId = trackJson['SNG_ID']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    String title = trackJson['SNG_TITLE']?.toString() ?? 'Unknown Track';

    // Append version to title if VERSION field exists (Deezer API format)
    final version = trackJson['VERSION']?.toString();
    if (version != null && version.isNotEmpty) {
      title = '$title $version';
    }
    final String artist = trackJson['ART_NAME']?.toString() ?? albumArtistName;
    final String artistId =
        trackJson['ART_ID']?.toString() ?? ''; // Parse ART_ID for artistId

    final String durationStr = trackJson['DURATION']?.toString() ?? '0';
    final int seconds = int.tryParse(durationStr) ?? 0;
    final Duration duration = Duration(seconds: seconds);

    final String diskNumberStr = trackJson['DISK_NUMBER']?.toString() ?? '1';
    final String trackNumberStr = trackJson['TRACK_NUMBER']?.toString() ?? '0';

    final Map<String, dynamic> extras = {
      'diskNumber': int.tryParse(diskNumberStr) ?? 1,
      'trackNumber': int.tryParse(trackNumberStr) ?? 0,
      'SNG_ID': songId,
    };

    final String albumArtUrl = albumArtPictureId.isNotEmpty
        ? 'https://e-cdns-images.dzcdn.net/images/cover/$albumArtPictureId/500x500-000000-80-0-0.jpg'
        : '';

    return Song(
      id: songId,
      title: title,
      artists: [artist],
      artistIds: [artistId],
      album: albumTitle,
      albumArtUrl: albumArtUrl,
      releaseDate: albumReleaseDate,
      audioUrl: '', // To be fetched later
      isDownloaded: false,
      localFilePath: null,
      duration: duration,
      extras: extras,
      isImported: false, // API songs are not imported by default
      isCustomMetadata: false, // API songs are not custom metadata by default
      // plainLyrics and syncedLyrics will be null by default
      // isDownloading and downloadProgress will use default constructor values
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'id': id, // Ensure ID is saved
        'artist': artist, // Backward compatibility - first artist
        'artistId': artistId, // Backward compatibility - first artist ID
        'artists': artists, // New field for multiple artists
        'artistIds': artistIds, // New field for multiple artist IDs
        'albumArtUrl':
            albumArtUrl, // Will save filename if correctly set by app logic
        'album': album,
        'releaseDate': releaseDate,
        'audioUrl': audioUrl,
        'isDownloaded': isDownloaded,
        'localFilePath':
            localFilePath, // Will save filename if correctly set by app logic
        'extras': extras, // Added extras to JSON
        'duration_ms':
            duration?.inMilliseconds, // Serialize duration to milliseconds
        'isImported': isImported, // Serialize isImported
        'plainLyrics': plainLyrics,
        'syncedLyrics': syncedLyrics,
        'playCount': playCount, // Serialize playCount
        'isCustomMetadata': isCustomMetadata, // Serialize isCustomMetadata
        // isDownloading and downloadProgress are typically transient state
        // and not included in toJson. If you need to persist them, add them here.
      };

  // New getter to safely provide a valid audio URL
  String get effectiveAudioUrl {
    // Return audioUrl if not empty, otherwise try localFilePath if downloaded and non-empty.
    if (audioUrl.isNotEmpty) return audioUrl;
    if (isDownloaded && (localFilePath ?? '').isNotEmpty) return localFilePath!;
    return '';
  }

  // New method to fetch the song URL
  Future<String> fetchUrl() async {
    // Simulate fetching the URL (replace with actual API call if needed)
    return audioUrl.isNotEmpty ? audioUrl : '';
  }

  // Version-aware title methods

  /// Get the display title with properly formatted version information
  String get displayTitle => VersionService.getDisplayTitle(title);

  /// Get the base title without version information
  String get baseTitle => VersionService.getBaseTitle(title);

  /// Get all versions from the title
  List<String> get versions => VersionService.getVersions(title);

  /// Check if this is an acoustic version
  bool get isAcoustic => VersionService.hasAcousticVersion(title);

  /// Check if this is a live version
  bool get isLive => VersionService.hasLiveVersion(title);

  /// Get formatted version tags for display
  String get versionTags {
    final versionList = versions;
    if (versionList.isEmpty) return '';
    return versionList.map((v) => '($v)').join(' ');
  }

  /// Create search-optimized queries for this song
  List<String> get searchQueries =>
      VersionService.createAlternativeSearchQueries(artist, title);

  /// Primary search query for this song
  String get primarySearchQuery =>
      VersionService.createSearchQuery(artist, title);
}
