class Song {
  final String title;
  final String id; 
  final String artist;
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

  // Add a getter for isRadio
  bool get isRadio => extras?['isRadio'] as bool? ?? false;

  Song({
    required this.title,
    required this.id,
    required this.artist,
    required this.albumArtUrl,
    this.album,
    this.releaseDate,
    this.audioUrl = '', // Default to empty string
    this.isDownloaded = false,
    this.localFilePath,
    this.extras, // Added extras to constructor
    this.duration, // Ensure duration is part of the constructor
  });

  Song copyWith({
    String? title,
    String? id, // Allow copying ID if necessary, though typically fixed
    String? artist,
    String? albumArtUrl,
    String? album,
    String? releaseDate,
    String? audioUrl,
    bool? isDownloaded,
    String? localFilePath, // Ensure this can be null
    Map<String, dynamic>? extras, // Added extras to copyWith
    Duration? duration, // Added duration to copyWith
    
  }) {
    return Song(
      title: title ?? this.title,
      id: id ?? this.id, // Keep original ID unless explicitly overridden
      artist: artist ?? this.artist,
      albumArtUrl: albumArtUrl ?? this.albumArtUrl, // Handled by consumers
      album: album ?? this.album,
      releaseDate: releaseDate ?? this.releaseDate,
      audioUrl: audioUrl ?? this.audioUrl,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      localFilePath: localFilePath, // Consumers ensure this is a filename
      extras: extras ?? this.extras, // Added extras logic
      duration: duration ?? this.duration, // Added duration logic
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
      String albumArtUrlFromJson = _asString(json['albumArtUrl']); // Raw value
      String audioUrl = _asString(json['audioUrl']);
      
      String? albumName;
      String? releaseDate = _asNullableString(json['releaseDate']);

      // Parse duration_ms
      final int? durationMs = json['duration_ms'] as int?;
      final Duration? parsedDuration = durationMs != null ? Duration(milliseconds: durationMs) : null;

      if (artist.isEmpty && json.containsKey('artists')) {
        final artistsList = json['artists'] as List?;
        if (artistsList != null && artistsList.isNotEmpty) {
          final firstArtistMap = artistsList.first as Map?;
          artist = _asString(firstArtistMap?['name']);
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

      return Song(
        title: title,
        id: id,
        artist: artist,
        albumArtUrl: albumArtUrlFromJson, // Store as is; migration/usage logic handles interpretation
        album: albumName, // albumName is already String?
        releaseDate: releaseDate, // releaseDate is already String?
        audioUrl: audioUrl,
        isDownloaded: json['isDownloaded'] as bool? ?? false, // Assuming isDownloaded is boolean
        localFilePath: _asNullableString(json['localFilePath']), // Store as is; migration/usage logic handles interpretation
        extras: json['extras'] as Map<String, dynamic>?, // Added extras parsing
        duration: parsedDuration, // Assign parsed duration
      );
    } catch (e) {
      // For debugging purposes, it can be helpful to print the problematic JSON.
      // print('Error parsing song from JSON: $json. Error: $e'); 
      throw FormatException('Invalid song JSON format: $e. Source JSON: $json');
    }
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'id': id, // Ensure ID is saved
        'artist': artist,
        'albumArtUrl': albumArtUrl, // Will save filename if correctly set by app logic
        'album': album,
        'releaseDate': releaseDate,
        'audioUrl': audioUrl,
        'isDownloaded': isDownloaded,
        'localFilePath': localFilePath, // Will save filename if correctly set by app logic
        'extras': extras, // Added extras to JSON
        'duration_ms': duration?.inMilliseconds, // Serialize duration to milliseconds
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
