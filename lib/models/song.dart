class Song {
  final String title;
  final String artist;
  final String albumArtUrl;
  final String? album;
  final String? releaseDate;
  final String? audioUrl;

  // Add these fields
  bool isDownloaded;
  String? localFilePath;

  Song({
    required this.title,
    required this.artist,
    required this.albumArtUrl,
    this.album,
    this.releaseDate,
    this.audioUrl,
    this.isDownloaded = false,
    this.localFilePath,
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
    final album = json['album'];
    final images = album != null && album['images'] != null && album['images'].isNotEmpty
        ? album['images']
        : [];
    final albumArtUrl = images.isNotEmpty ? images[0]['url'] : '';
    final artists = json['artists'] ?? [];
    final artistName = artists.isNotEmpty ? artists[0]['name'] : '';
    return Song(
      title: json['name'] ?? '',
      artist: artistName,
      albumArtUrl: albumArtUrl,
      album: album != null ? album['name'] : null,
      releaseDate: album != null ? album['release_date'] : null,
      audioUrl: null, //json['preview_url'], // Add this line
      // isDownloaded and localFilePath default to false/null
    );
  }
}
