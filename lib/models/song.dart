class Song {
  final String title;
  final String id; 
  final String artist;
  final String albumArtUrl;
  final String? album;
  final String? releaseDate;
  final String audioUrl; // Ensure non-nullable, default to empty

  // Add these fields
  bool isDownloaded;
  String? localFilePath;

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
  }) {
    return Song(
      title: title ?? this.title,
      id: id ?? this.id, // Keep original ID unless explicitly overridden
      artist: artist ?? this.artist,
      albumArtUrl: albumArtUrl ?? this.albumArtUrl,
      album: album ?? this.album,
      releaseDate: releaseDate ?? this.releaseDate,
      audioUrl: audioUrl ?? this.audioUrl,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      localFilePath: localFilePath ?? this.localFilePath,
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
      String albumArtUrl = _asString(json['albumArtUrl']);
      String audioUrl = _asString(json['audioUrl']);
      
      String? albumName;
      String? releaseDate = _asNullableString(json['releaseDate']);

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
        if (albumArtUrl.isEmpty && albumField.containsKey('images')) {
          final images = albumField['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final firstImageMap = images.first as Map?;
            albumArtUrl = _asString(firstImageMap?['url']);
          }
        }
      } else { // albumField is not a Map (could be String, null, or other type to convert)
        albumName = _asNullableString(albumField);
      }

      return Song(
        title: title,
        id: id,
        artist: artist,
        albumArtUrl: albumArtUrl,
        album: albumName, // albumName is already String?
        releaseDate: releaseDate, // releaseDate is already String?
        audioUrl: audioUrl,
        isDownloaded: json['isDownloaded'] as bool? ?? false, // Assuming isDownloaded is boolean
        localFilePath: _asNullableString(json['localFilePath']),
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
        'albumArtUrl': albumArtUrl,
        'album': album,
        'releaseDate': releaseDate,
        'audioUrl': audioUrl,
        'isDownloaded': isDownloaded,
        'localFilePath': localFilePath,
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
