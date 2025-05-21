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

      // Handle album field based on its type.
      String albumName;
      String? releaseDate;
      String albumArtUrl = '';
      final albumField = json['album'];
      if (albumField is Map) {
        final images = albumField['images'] ?? [];
        if (images is List && images.isNotEmpty) {
          albumArtUrl = images[0]['url'] ?? '';
        }
        albumName = albumField['name'] ?? '';
        releaseDate = albumField['release_date'];
      } else if (albumField is String) {
        albumName = albumField;
      } else {
        albumName = '';
      }
      final artists = json['artists'] ?? [];
      final artistName = artists is List && artists.isNotEmpty ? artists[0]['name'] ?? '' : '';
      return Song(
        title: title,
        id: id, // Use the parsed or generated ID
        artist: artistName,
        albumArtUrl: albumArtUrl,
        album: albumName.isNotEmpty ? albumName : null,
        releaseDate: releaseDate,
        audioUrl: json['audioUrl'] ?? '',
        isDownloaded: json['isDownloaded'] ?? false,
        localFilePath: json['localFilePath'] as String?, // Allow null
      );
    } catch (e) {
      throw FormatException('Invalid song JSON format: $e');
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
