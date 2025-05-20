import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';

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
    final playlistManager = PlaylistManager();
    await playlistManager.loadPlaylists();
    setState(() {
      _playlists = playlistManager.playlists;
    });
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
                    _playlists.add(Playlist(id: DateTime.now().toString(), name: playlistName, songs: []));
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

  Future<void> _deleteDownloadedSong(FileSystemEntity songFile) async {
    try {
      final file = File(songFile.path);
      if (await file.exists()) {
        await file.delete();
      }
      setState(() {
        _songs.remove(songFile);
        if (_currentlyPlayingSongPath == songFile.path) {
          isPlaying = false;
          _currentlyPlayingSongPath = null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${songFile.path.split('/').last}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting song: $e')),
      );
    }
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              tooltip: 'Delete Download',
                              onPressed: () => _deleteDownloadedSong(song),
                            ),
                          ],
                        ),
                        onTap: () {
                          final songObj = Song(
                            title: songName,
                            id: DateTime.now().toString(),
                            artist: 'Unknown Artist',
                            albumArtUrl: '',
                            localFilePath: song.path,
                            isDownloaded: true,
                          );
                          Provider.of<CurrentSongProvider>(context, listen: false).playSong(songObj);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
