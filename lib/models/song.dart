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

  factory Song.fromJson(Map<String, dynamic> json) {
    try {
      // Ensure the title field is correctly parsed
      final title = json['title'] ?? json['name'] ?? 'Unknown Title';
      final id = json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(); // Ensure ID is present

      // Prioritize direct fields (as saved by toJson)
      String artist = json['artist'] as String? ?? '';
      String albumArtUrl = json['albumArtUrl'] as String? ?? '';
      String audioUrl = json['audioUrl'] as String? ?? '';
      
      // Initialize albumName to null. It will be populated by the albumField logic.
      String? albumName; 
      // releaseDate can be directly in json or within the album map.
      String? releaseDate = json['releaseDate'] as String?;

      // Fallback for artist if not directly available (e.g., from fresh API response)
      if (artist.isEmpty && json.containsKey('artists')) {
        final artistsList = json['artists'] as List?;
        if (artistsList != null && artistsList.isNotEmpty) {
          final firstArtistMap = artistsList.first as Map?;
          artist = firstArtistMap?['name'] as String? ?? '';
        }
      }

      // Fallback for album info and albumArtUrl if not directly available or album is an object
      final albumField = json['album'];
      if (albumField is Map) {
        // If albumField is a map, get 'name' from it for albumName.
        albumName = albumField['name'] as String?; 
        // Prioritize release_date from album map if available and not null.
        // If albumField['release_date'] is null, the existing value of releaseDate (from json['releaseDate']) is kept.
        releaseDate = albumField['release_date'] as String? ?? releaseDate; 
        if (albumArtUrl.isEmpty && albumField.containsKey('images')) {
          final images = albumField['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final firstImageMap = images.first as Map?;
            albumArtUrl = firstImageMap?['url'] as String? ?? '';
          }
        }
      } else if (albumField is String) {
        // If albumField is a string, use it directly as albumName.
        albumName = albumField;
      }
      // If albumField is null or not a Map/String, albumName remains null.


      return Song(
        title: title,
        id: id, // Use the parsed or generated ID
        artist: artist,
        albumArtUrl: albumArtUrl,
        album: albumName?.isNotEmpty == true ? albumName : null,
        releaseDate: releaseDate,
        audioUrl: audioUrl, // Defaulted to '' if json['audioUrl'] is null
        isDownloaded: json['isDownloaded'] ?? false,
        localFilePath: json['localFilePath'] as String?, // Allow null
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
