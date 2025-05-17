import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<FileSystemEntity> _songs = [];
  List<Playlist> _playlists = [];
  final AudioPlayer audioPlayer = AudioPlayer();
  String? _currentlyPlayingSongPath;
  bool isPlaying = false;
  final TextEditingController _playlistNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadDownloadedSongs();
    _loadPlaylists();
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
      });
    });
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    _playlistNameController.dispose();
    super.dispose();
  }

  Future<void> _loadDownloadedSongs() async {
    final directory = await getApplicationDocumentsDirectory();
    final songsDir = Directory(directory.path);
    List<FileSystemEntity> files = songsDir.listSync();

    setState(() {
      _songs = files.where((file) => file is File && file.path.endsWith('.mp3')).toList();
    });
  }

  Future<void> _loadPlaylists() async {
    // TODO: Load playlists from local storage
    setState(() {
      _playlists = [
        Playlist(name: 'My Playlist', songs: []),
        Playlist(name: 'Workout', songs: []),
      ];
    });
  }

  Future<void> _playSong(String filePath) async {
    try {
      if (_currentlyPlayingSongPath == filePath) {
        if (isPlaying) {
          await audioPlayer.pause();
        } else {
          await audioPlayer.resume();
        }
      } else {
        await audioPlayer.play(DeviceFileSource(filePath));
      }

      setState(() {
        isPlaying = !isPlaying;
        _currentlyPlayingSongPath = filePath;
      });
    } catch (e) {
      print('Error playing song: $e');
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
      });
    }
  }

  Future<void> _createPlaylist(BuildContext context) async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create New Playlist'),
          content: TextField(
            controller: _playlistNameController,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
            TextButton(
              child: const Text('Create'),
              onPressed: () {
                final playlistName = _playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  setState(() {
                    _playlists.add(Playlist(name: playlistName, songs: []));
                  });
                  // TODO: Save playlist to local storage
                }
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _createPlaylist(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _playlists.length,
              itemBuilder: (context, index) {
                final playlist = _playlists[index];
                return ExpansionTile(
                  title: Text(playlist.name),
                  children: [
                    if (playlist.songs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('No songs in this playlist yet.'),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: playlist.songs.length,
                        itemBuilder: (context, songIndex) {
                          final song = playlist.songs[songIndex];
                          return ListTile(
                            title: Text(song.title),
                            // Add more song details here
                          );
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: ElevatedButton(
                        onPressed: () {
                          // TODO: Implement adding songs to playlist
                        },
                        child: const Text('Add Songs'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text('Downloaded Songs'),
          ),
          Expanded(
            child: _songs.isEmpty
                ? const Center(child: Text('No downloaded songs yet.'))
                : ListView.builder(
                    itemCount: _songs.length,
                    itemBuilder: (context, index) {
                      final song = _songs[index];
                      final songName = song.path.split('/').last;
                      return ListTile(
                        title: Text(songName),
                        trailing: IconButton(
                          icon: Icon(
                            _currentlyPlayingSongPath == song.path && isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                          onPressed: () => _playSong(song.path),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class Playlist {
  String name;
  List<Song> songs;

  Playlist({required this.name, required this.songs});
}
