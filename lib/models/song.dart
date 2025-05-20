class Song {
  final String title;
  final String id; 
  final String artist;
  final String albumArtUrl;
  final String? album;
  final String? releaseDate;
  final String audioUrl; // changed from String? to String

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
    this.audioUrl = '', // default to empty string
    this.isDownloaded = false,
    required this.localFilePath,
  });

  Song copyWith({
    String? title,
    String? artist,
    String? albumArtUrl,
    String? album,
    String? releaseDate,
    String? audioUrl,
    bool? isDownloaded,
    String? localFilePath,
  }) {
    return Song(
      title: title ?? this.title,
      id: id, // ID should not be changed
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
        title: json['title'] ?? '',
        id: json['id'] ?? '',
        artist: artistName,
        albumArtUrl: albumArtUrl,
        album: albumName.isNotEmpty ? albumName : null,
        releaseDate: releaseDate,
        audioUrl: json['audioUrl'] ?? '',
        isDownloaded: json['isDownloaded'] ?? false,
        localFilePath: json['localFilePath'] ?? '',
      );
    } catch (e) {
      throw FormatException('Invalid song JSON format: $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'id': id,
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
