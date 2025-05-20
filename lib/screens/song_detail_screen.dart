import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';

class SongDetailScreen extends StatefulWidget {
  final Song song;

  const SongDetailScreen({super.key, required this.song});

  @override
  _SongDetailScreenState createState() => _SongDetailScreenState();
}

class _SongDetailScreenState extends State<SongDetailScreen> {
  bool _isDownloading = false;
  double _downloadProgress = 0;
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final AudioPlayer audioPlayer = AudioPlayer();
  bool isPlaying = false;
  final bool _isLoadingAudio = false;

  @override
  void initState() {
    super.initState();
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
      });
    });
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _downloadSong() async {
    setState(() => _isDownloading = true);
    String? audioUrl;
    try {
      final apiService = ApiService();
      audioUrl = await apiService.fetchAudioUrl(widget.song.artist, widget.song.title);
      if (audioUrl == null) {
        _showErrorDialog('Failed to fetch audio URL.');
        setState(() => _isDownloading = false);
        return;
      }
      // print('Fetching audio URL from: $audioUrl');
    } catch (e) {
      _showErrorDialog('Error fetching audio URL: $e');
      setState(() => _isDownloading = false);
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/${widget.song.title}.mp3';
      final url = audioUrl;

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          if (mounted) {
            setState(() {
              _downloadProgress = bytes.length / (totalBytes ?? 1);
            });
          }
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          if (mounted) {
            setState(() {
              _isDownloading = false;
              widget.song.localFilePath = filePath;
              widget.song.isDownloaded = true;
            });
          }
          await _saveSongMetadata(widget.song);
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('Download complete!')),
          );
        },
        onError: (e) {
          if (mounted) {
            setState(() => _isDownloading = false);
          }
          _showErrorDialog('Download failed: $e');
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
      _showErrorDialog('Error downloading song: $e');
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('An Error Occurred'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('Okay'),
              onPressed: () {
                Navigator.of(context).pop();
                // Save state and exit the app
                // SystemNavigator.pop(); // Exit the app
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteSong() async {
    try {
      final file = File(widget.song.localFilePath!);
      await file.delete();
      setState(() {
        widget.song.isDownloaded = false;
        widget.song.localFilePath = null;
      });
      await _removeSongMetadata(widget.song);
      scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Song deleted!')),
      );
    } catch (e) {
      _showErrorDialog('Error deleting song: $e');
    }
  }

  Future<void> _saveSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = jsonEncode(song.toJson());
    await prefs.setString('song_${song.title}', songJson);
  }

  Future<void> _removeSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('song_${song.title}');
  }

  Future<void> _playSong() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.playSong(widget.song);
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Song Details'),
        ),
        body: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Artist: ${widget.song.artist}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Album: ${widget.song.album ?? 'N/A'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Release Date: ${widget.song.releaseDate ?? 'N/A'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      widget.song.albumArtUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.music_note,
                        size: 150,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_isDownloading) ...[
                    LinearProgressIndicator(value: _downloadProgress),
                    Text(
                      'Downloading... ${(_downloadProgress * 100).toStringAsFixed(2)}%',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ] else if (widget.song.isDownloaded) ...[
                    Text('Song downloaded!', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                    ElevatedButton(
                      onPressed: _deleteSong,
                      child: const Text('Delete Song'),
                    ),
                  ] else ...[
                    ElevatedButton(
                      onPressed: _downloadSong,
                      child: const Text('Download Song'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: _playSong,
                        child: _isLoadingAudio
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                            : Text(isPlaying ? 'Pause Song' : 'Play Song'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: const Text('Song Information'),
                            content: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Title: ${widget.song.title}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                                Text('Artist: ${widget.song.artist}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                                Text('Album: ${widget.song.album ?? 'N/A'}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                                Text('Release Date: ${widget.song.releaseDate ?? 'N/A'}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                              ],
                            ),
                            actions: <Widget>[
                              TextButton(
                                child: const Text('Close'),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                              ),
                              TextButton(
                                child: const Text('Add to Playlist'),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showAddToPlaylistDialog(context, widget.song);
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                    child: const Text('More Song Info'),
                  ),
                ],
              ),
            ),
            if (_isDownloading)
              Container(
                color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.7),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AddToPlaylistDialog(song: song);
      },
    );
  }
}

class AddToPlaylistDialog extends StatefulWidget {
  final Song song;

  const AddToPlaylistDialog({super.key, required this.song});

  @override
  _AddToPlaylistDialogState createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  List<Playlist> _playlists = [];

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJson = prefs.getStringList('playlists') ?? [];
    setState(() {
      _playlists = playlistJson.map((json) => Playlist.fromJson(jsonDecode(json))).toList();
    });
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistJson = _playlists.map((playlist) => jsonEncode(playlist.toJson())).toList();
    await prefs.setStringList('playlists', playlistJson);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add to Playlist'),
      content: _playlists.isEmpty
          ? Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No playlists available.'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _showCreatePlaylistDialog(context);
            },
            child: const Text('Create Playlist'),
          ),
        ],
      )
          : SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _playlists.length,
          itemBuilder: (BuildContext context, int index) {
            final playlist = _playlists[index];
            return ListTile(
              title: Text(playlist.name),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'Delete Playlist',
                onPressed: () async {
                  setState(() {
                    _playlists.removeAt(index);
                  });
                  await _savePlaylists();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted playlist "${playlist.name}"')),
                  );
                },
              ),
              onTap: () {
                // Prevent duplicates
                if (!playlist.songs.any((s) =>
                    s.title == widget.song.title &&
                        s.artist == widget.song.artist)) {
                  setState(() {
                    playlist.songs.add(widget.song);
                  });
                  _savePlaylists();
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added to ${playlist.name}')),
                  );
                } else {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Song already in playlist')),
                  );
                }
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          child: const Text('Cancel'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final TextEditingController playlistNameController = TextEditingController();
        return AlertDialog(
          title: const Text('Create Playlist'),
          content: TextField(
            controller: playlistNameController,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Create'),
              onPressed: () {
                final playlistName = playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  setState(() {
                    _playlists.add(Playlist(id: DateTime.now().toString(), name: playlistName, songs: []));
                  });
                  _savePlaylists();
                }
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
