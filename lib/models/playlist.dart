import 'song.dart';

class Playlist {
  final String id;
  String name;
  List<Song> songs;

  Playlist({required this.id, required this.name, required this.songs});

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] ?? 'Unnamed Playlist',
      songs: (json['songs'] as List? ?? []).map((songJson) => Song.fromJson(songJson)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songs': songs.map((song) => song.toJson()).toList(),
  };
  
  Playlist copyWith({
    String? id,
    String? name,
    List<Song>? songs,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      songs: songs ?? this.songs,
    );
  }

  // Optionally: a method for renaming a playlist
  void rename(String newName) {
    name = newName;
  }
}
