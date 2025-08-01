class Song {
  final String title;
  final String id; 
  final String artist;
  final String artistId;
  final String albumArtUrl; // Can be network URL or local filename (relative to docs dir)
  final String? album;
  final String? releaseDate;
  final String audioUrl; // Ensure non-nullable, default to empty
  final Duration? duration;

  // Add these fields
  bool isDownloaded;
  String? localFilePath; // Stores filename only (relative to docs dir) if downloaded
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
    required this.artist,
    this.artistId = '', // Default to empty string if not provided
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
  });

  Song copyWith({
    String? title,
    String? id, // Allow copying ID if necessary, though typically fixed
    String? artist,
    String? artistId, // Added artistId
    String? albumArtUrl,
    String? album,
    String? releaseDate,
    String? audioUrl,
    bool? isDownloaded,
    String? localFilePath,           // <— parameter stays nullable
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
      artist: artist ?? this.artist,
      artistId: artistId ?? this.artistId, // Updated to use provided or existing artistId
      albumArtUrl: albumArtUrl ?? this.albumArtUrl, // Handled by consumers
      album: album ?? this.album,
      releaseDate: releaseDate ?? this.releaseDate,
      audioUrl: audioUrl ?? this.audioUrl,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      localFilePath: localFilePath ?? this.localFilePath,  // <— preserve existing path
      extras: extras ?? this.extras, // Added extras logic
      duration: duration ?? this.duration, // Added duration logic
      isDownloading: isDownloading ?? this.isDownloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      isImported: isImported ?? this.isImported, // Added isImported logic
      plainLyrics: plainLyrics ?? this.plainLyrics,
      syncedLyrics: syncedLyrics ?? this.syncedLyrics,
      playCount: playCount ?? this.playCount, // New field
      isCustomMetadata: isCustomMetadata ?? this.isCustomMetadata, // Add to copyWith logic
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

  factory Song.fromJson(Map<String, dynamic> json) {
    try {
      // Use helpers for safer parsing
      final title = _asString(json['title'] ?? json['name'], 'Unknown Title');
      final id = _asString(json['id'], DateTime.now().millisecondsSinceEpoch.toString());

      String artist = _asString(json['artist']);
      String artistIdFromJson = _asString(json['artistId']); // Parse artistId
      String albumArtUrlFromJson = _asString(json['albumArtUrl']); // Raw value
      String audioUrl = _asString(json['audioUrl']);
      
      String? albumName;
      String? releaseDate = _asNullableString(json['releaseDate']);

      // Parse duration_ms robustly
      dynamic durationMsValue = json['duration_ms'];
      int? durationMsAsInt;
      if (durationMsValue is int) {
        durationMsAsInt = durationMsValue;
      } else if (durationMsValue is String) {
        durationMsAsInt = int.tryParse(durationMsValue);
      }
      // If durationMsValue is null or not int/String, durationMsAsInt remains null.
      final Duration? parsedDuration = durationMsAsInt != null ? Duration(milliseconds: durationMsAsInt) : null;

      // isDownloading and downloadProgress are typically transient state,
      // so they are not usually part of fromJson.
      // If they were persisted, you'd parse them here.
      // For now, they will default to false and 0.0 respectively via the constructor.

      if (artist.isEmpty && json.containsKey('artists')) {
        final artistsList = json['artists'] as List?;
        if (artistsList != null && artistsList.isNotEmpty) {
          final firstArtistMap = artistsList.first as Map?;
          artist = _asString(firstArtistMap?['name']);
          // Attempt to get artistId from the same structure if not already found
          if (artistIdFromJson.isEmpty) {
            artistIdFromJson = _asString(firstArtistMap?['id']);
          }
        }
      }

      final albumField = json['album'];
      if (albumField is Map) {
        albumName = _asNullableString(albumField['name']);
        releaseDate = _asNullableString(albumField['release_date']) ?? releaseDate;
        if (albumArtUrlFromJson.isEmpty && albumField.containsKey('images')) {
          final images = albumField['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final firstImageMap = images.first as Map?;
            albumArtUrlFromJson = _asString(firstImageMap?['url']);
          }
        }
      } else { // albumField is not a Map (could be String, null, or other type to convert)
        albumName = _asNullableString(albumField);
      }

      final bool isImported = json['isImported'] as bool? ?? false; // Parse isImported
      final String? plainLyrics = _asNullableString(json['plainLyrics']);
      final String? syncedLyrics = _asNullableString(json['syncedLyrics']);
      final int playCount = json['playCount'] as int? ?? 0; // Parse playCount
      final bool isCustomMetadata = json['isCustomMetadata'] as bool? ?? false; // Parse isCustomMetadata

      return Song(
        title: title,
        id: id,
        artist: artist,
        artistId: artistIdFromJson, // Assign parsed artistId
        albumArtUrl: albumArtUrlFromJson, // Store as is; migration/usage logic handles interpretation
        album: albumName, // albumName is already String?
        releaseDate: releaseDate, // releaseDate is already String?
        audioUrl: audioUrl,
        isDownloaded: json['isDownloaded'] as bool? ?? false, // Assuming isDownloaded is boolean
        localFilePath: _asNullableString(json['localFilePath']), // Store as is; migration/usage logic handles interpretation
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
    String albumArtistName
  ) {
    final String songId = trackJson['SNG_ID']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    final String title = trackJson['SNG_TITLE']?.toString() ?? 'Unknown Track';
    final String artist = trackJson['ART_NAME']?.toString() ?? albumArtistName;
    final String artistId = trackJson['ART_ID']?.toString() ?? ''; // Parse ART_ID for artistId

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
      artist: artist,
      artistId: artistId, // Assign parsed artistId
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
        'artist': artist,
        'artistId': artistId, // Serialize artistId
        'albumArtUrl': albumArtUrl, // Will save filename if correctly set by app logic
        'album': album,
        'releaseDate': releaseDate,
        'audioUrl': audioUrl,
        'isDownloaded': isDownloaded,
        'localFilePath': localFilePath, // Will save filename if correctly set by app logic
        'extras': extras, // Added extras to JSON
        'duration_ms': duration?.inMilliseconds, // Serialize duration to milliseconds
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
}
