import 'song.dart';

class Album {
  final String id;
  final String title;
  final String artistName;
  final String albumArtPictureId;
  final String releaseDate;
  List<Song> tracks;
  final String? upc;
  final int? durationSeconds; // Total album duration in seconds
  final int? trackCount;
  bool isSaved; // New field
  int playCount; // New field for play count

  Album({
    required this.id,
    required this.title,
    required this.artistName,
    required this.albumArtPictureId,
    required this.releaseDate,
    required this.tracks,
    this.upc,
    this.durationSeconds,
    this.trackCount,
    this.isSaved = false, // Default to false
    this.playCount = 0, // Default to 0
  });

  String get fullAlbumArtUrl => albumArtPictureId.isNotEmpty
      ? 'https://e-cdns-images.dzcdn.net/images/cover/$albumArtPictureId/1000x1000-000000-80-0-0.jpg'
      : '';

  factory Album.fromJson(Map<String, dynamic> json) {
    // Handle different API response structures
    Map<String, dynamic> albumData;
    
    // Check if this is a search API response (direct album data)
    if (json.containsKey('ALB_ID') && json.containsKey('ALB_TITLE')) {
      albumData = json;
    } else if (json.containsKey('info')) {
      // Handle legacy structure with 'info' wrapper
      albumData = json['info'] as Map<String, dynamic>? ?? {};
    } else {
      // Handle other structures
      albumData = json;
    }

    final albumId = albumData['ALB_ID']?.toString() ?? json['id']?.toString() ?? '';
    final albumTitle = albumData['ALB_TITLE']?.toString() ?? json['title']?.toString() ?? 'Unknown Album';
    final albumArtPicId = albumData['ALB_PICTURE']?.toString() ?? json['albumArtPictureId']?.toString() ?? '';
    final albumReleaseDate = albumData['PHYSICAL_RELEASE_DATE']?.toString() ?? 
                            albumData['ORIGINAL_RELEASE_DATE']?.toString() ?? 
                            json['releaseDate']?.toString() ?? '';
    
    String artistName = albumData['ART_NAME']?.toString() ?? json['artistName']?.toString() ?? '';
    if (artistName.isEmpty) {
      final artistsList = albumData['ARTISTS'] as List<dynamic>?;
      if (artistsList != null && artistsList.isNotEmpty) {
        final firstArtistMap = artistsList.first as Map<String, dynamic>?;
        artistName = firstArtistMap?['ART_NAME']?.toString() ?? 'Unknown Artist';
      } else {
        artistName = 'Unknown Artist';
      }
    }

    List<Song> songs;
    final rawTracksField = json['tracks']; // This could be List<map> (our save), Map (Deezer API {'data': [...]}), or null

    // Determine if this JSON is from our local save (isSaved: true) vs. an external API or old format.
    if (json['isSaved'] as bool? ?? false) {
      // Locally saved album: tracks are already in Song.toJson() format.
      final List<dynamic> tracksList = (rawTracksField is List) ? rawTracksField : [];
      songs = tracksList
          .map((trackJson) => Song.fromJson(trackJson as Map<String, dynamic>))
          .toList();
    } else {
      // API data or old format (isSaved is false or not present).
      List<dynamic> trackListForParsing;
      bool useSongFromJsonForApiOrOldFormat = false;

      if (rawTracksField is List && rawTracksField.isNotEmpty &&
          rawTracksField.first is Map &&
          (rawTracksField.first as Map).containsKey('id') && 
          (rawTracksField.first as Map).containsKey('title')) {
        // Tracks list looks like our Song.toJson() output (e.g., old save without 'isSaved' flag).
        trackListForParsing = rawTracksField;
        useSongFromJsonForApiOrOldFormat = true;
      } else if (rawTracksField is Map && rawTracksField.containsKey('data') && rawTracksField['data'] is List) {
        // Deezer-like API structure: json['tracks']['data'] is the list of raw track JSONs.
        trackListForParsing = rawTracksField['data'] as List<dynamic>;
      } else if (rawTracksField is List) {
        // Generic list of tracks, assume API format for Song.fromAlbumTrackJson.
        trackListForParsing = rawTracksField;
      } else {
        // No recognizable track structure.
        trackListForParsing = [];
      }

      if (useSongFromJsonForApiOrOldFormat) {
        songs = trackListForParsing
            .map((trackJson) => Song.fromJson(trackJson as Map<String, dynamic>))
            .toList();
      } else {
        // Use Song.fromAlbumTrackJson for API-specific track formats.
        songs = trackListForParsing.map((trackJson) {
          return Song.fromAlbumTrackJson(
            trackJson as Map<String, dynamic>,
            albumTitle,
            albumArtPicId,
            albumReleaseDate,
            artistName
          );
        }).toList();
      }
    }

    return Album(
      id: albumId,
      title: albumTitle,
      artistName: artistName,
      albumArtPictureId: albumArtPicId,
      releaseDate: albumReleaseDate,
      tracks: songs,
      upc: albumData['UPC']?.toString() ?? json['upc']?.toString(),
      durationSeconds: int.tryParse(albumData['DURATION']?.toString() ?? json['durationSeconds']?.toString() ?? ''),
      trackCount: int.tryParse(albumData['NUMBER_TRACK']?.toString() ?? json['trackCount']?.toString() ?? ''),
      isSaved: json['isSaved'] as bool? ?? false, // Load isSaved
      playCount: json['playCount'] as int? ?? 0, // Load playCount
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artistName': artistName,
        'albumArtPictureId': albumArtPictureId,
        'releaseDate': releaseDate,
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'upc': upc,
        'durationSeconds': durationSeconds,
        'trackCount': trackCount,
        'isSaved': isSaved, // Save isSaved
        'playCount': playCount, // Save playCount
      };

  Album copyWith({
    String? id,
    String? title,
    String? artistName,
    String? albumArtPictureId,
    String? releaseDate,
    List<Song>? tracks,
    String? upc,
    int? durationSeconds,
    int? trackCount,
    bool? isSaved,
    int? playCount, // New field
  }) {
    return Album(
      id: id ?? this.id,
      title: title ?? this.title,
      artistName: artistName ?? this.artistName,
      albumArtPictureId: albumArtPictureId ?? this.albumArtPictureId,
      releaseDate: releaseDate ?? this.releaseDate,
      tracks: tracks ?? this.tracks,
      upc: upc ?? this.upc,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      trackCount: trackCount ?? this.trackCount,
      isSaved: isSaved ?? this.isSaved,
      playCount: playCount ?? this.playCount, // New field
    );
  }
}
