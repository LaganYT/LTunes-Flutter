import 'dart:io';
import 'dart:convert'; // Required for jsonDecode
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Required for SharedPreferences
import '../models/song.dart';
import '../models/playlist.dart';
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import 'playlist_detail_screen.dart'; // Import for navigation

// Imports for file import functionality
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with SingleTickerProviderStateMixin { // Add SingleTickerProviderStateMixin
  List<Song> _songs = [];
  List<Playlist> _playlists = [];
  final AudioPlayer audioPlayer = AudioPlayer();
  String? _currentlyPlayingSongPath;
  bool isPlaying = false;
  final TextEditingController _playlistNameController = TextEditingController();
  final PlaylistManagerService _playlistManager = PlaylistManagerService();
  TabController? _tabController; // Declare TabController
  final Uuid _uuid = const Uuid(); // For generating unique IDs

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this); // Initialize TabController
    _loadDownloadedSongs();
    _loadPlaylists();
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
        // Consider updating based on CurrentSongProvider state if it's managing global playback
      });
    });
  }

  @override
  void dispose() {
    _tabController?.dispose(); // Dispose TabController
    audioPlayer.dispose();
    _playlistNameController.dispose();
    super.dispose();
  }

  Future<void> _loadDownloadedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final List<Song> loadedSongs = [];

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              final file = File(song.localFilePath!);
              if (await file.exists()) {
                loadedSongs.add(song);
              } else {
                // File doesn't exist, update metadata
                song.isDownloaded = false;
                song.localFilePath = null;
                await prefs.setString(key, jsonEncode(song.toJson()));
              }
            }
          } catch (e) {
            debugPrint('Error decoding song from SharedPreferences for key $key: $e');
            // Optionally remove corrupted data: await prefs.remove(key);
          }
        }
      }
    }
    setState(() {
      _songs = loadedSongs;
    });
  }

  Future<void> _loadPlaylists() async {
    await _playlistManager.loadPlaylists();
    setState(() {
      _playlists = _playlistManager.playlists;
    });
  }

  Future<void> _deletePlaylist(BuildContext context, Playlist playlist) async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete Playlist "${playlist.name}"?'),
          content: const Text('Are you sure you want to delete this playlist? This action cannot be undone.'),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: Text('Delete', style: TextStyle(color: Colors.red[700])),
              onPressed: () {
                _playlistManager.removePlaylist(playlist);
                _loadPlaylists(); // Refresh the list from the service
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Playlist "${playlist.name}" deleted.')),
                );
              },
            ),
          ],
        );
      },
    );
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
                  final newPlaylist = Playlist(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: playlistName,
                    songs: [],
                  );
                  _playlistManager.addPlaylist(newPlaylist);
                  // No need to call savePlaylists() here as addPlaylist now handles it.
                  _loadPlaylists(); // Refresh the list from the service
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

  // _addSongsToPlaylistDialog and _removeSongFromPlaylist methods remain,
  // though their primary use might shift to PlaylistDetailScreen.
  // For now, they are kept as they might be invoked from there or future features.
  // ignore: unused_element
  Future<void> _addSongsToPlaylistDialog(BuildContext context, Playlist playlist) async {
    if (_songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No downloaded songs available to add.')),
      );
      return;
    }

    // _songs is already List<Song>, so direct use or copy
    List<Song> availableSongs = List<Song>.from(_songs);

    // Filter out songs already in the playlist
    availableSongs.removeWhere((s) => playlist.songs.any((ps) => ps.id == s.id));

    if (availableSongs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('All downloaded songs are already in "${playlist.name}".')),
      );
      return;
    }
    
    final List<Song> selectedSongs = await showDialog<List<Song>>(
      context: context,
      builder: (BuildContext context) {
        final List<Song> tempSelectedSongs = [];
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text('Add to "${playlist.name}"'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableSongs.length,
                  itemBuilder: (context, index) {
                    final song = availableSongs[index];
                    final isSelected = tempSelectedSongs.contains(song);
                    return CheckboxListTile(
                      title: Text(song.title),
                      value: isSelected,
                      onChanged: (bool? value) {
                        setStateDialog(() {
                          if (value == true) {
                            tempSelectedSongs.add(song);
                          } else {
                            tempSelectedSongs.remove(song);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: const Text('Add Selected'),
                  onPressed: () {
                    Navigator.of(context).pop(tempSelectedSongs);
                  },
                ),
              ],
            );
          }
        );
      },
    ) ?? []; // Return empty list if dialog is dismissed

    if (selectedSongs.isNotEmpty) {
      for (var song in selectedSongs) {
        _playlistManager.addSongToPlaylist(playlist, song);
      }
      // No need to call savePlaylists() here as addSongToPlaylist now handles it.
      _loadPlaylists(); // Refresh the list
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedSongs.length} song(s) added to "${playlist.name}"')),
      );
    }
  }

  // ignore: unused_element
  Future<void> _removeSongFromPlaylist(Playlist playlist, Song song) async {
    _playlistManager.removeSongFromPlaylist(playlist, song);
    _loadPlaylists(); // Refresh the list
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed "${song.title}" from "${playlist.name}"')),
    );
  }

  Future<void> _deleteDownloadedSong(Song songToDelete) async {
    try {
      if (songToDelete.localFilePath != null && songToDelete.localFilePath!.isNotEmpty) {
        final file = File(songToDelete.localFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Update metadata in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final updatedSong = songToDelete.copyWith(isDownloaded: false, localFilePath: null);
      // Use the song's actual ID for the SharedPreferences key
      await prefs.setString('song_${songToDelete.id}', jsonEncode(updatedSong.toJson()));
      
      // Refresh UI by reloading the songs list
      await _loadDownloadedSongs(); 

      // If this song was playing via the local audioPlayer instance
      if (_currentlyPlayingSongPath == songToDelete.localFilePath) {
        audioPlayer.stop();
        setState(() {
          isPlaying = false;
          _currentlyPlayingSongPath = null;
        });
      }
      // Note: If CurrentSongProvider is managing playback, it should also be notified or handle this.

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "${songToDelete.title}"')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting song: $e')),
      );
    }
  }

  Future<void> _importSongs() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom, // Changed from FileType.audio
        allowedExtensions: ['mp3'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        final prefs = await SharedPreferences.getInstance();
        int importCount = 0;

        // Show a loading indicator
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Importing songs...')),
        );

        for (PlatformFile file in result.files) {
          if (file.path == null) continue;

          String originalPath = file.path!;
          String originalFileName = p.basename(originalPath);
          
          // Create a unique name for the copied file to avoid conflicts
          String uniquePrefix = _uuid.v4();
          String newFileName = '${uniquePrefix}_$originalFileName';
          String copiedFilePath = p.join(appDocDir.path, newFileName);

          try {
            // ignore: unused_local_variable
            File newFile = await File(originalPath).copy(copiedFilePath); // Keep this line if you still copy the file

            String songId = _uuid.v4(); // Generate a unique ID for the song
            
            Song newSong = Song(
              id: songId,
              title: p.basenameWithoutExtension(originalFileName), // Use filename as title
              artist: 'Unknown Artist', // Default artist
              album: null, // Default album to null or empty string
              albumArtUrl: '', // Album art from local files is more complex, leave empty for now
              audioUrl: '', // Not an online stream
              localFilePath: copiedFilePath,
              isDownloaded: true, // Mark as "downloaded" i.e., locally available
              releaseDate: null, // Default releaseDate to null or empty string
            );

            await prefs.setString('song_${newSong.id}', jsonEncode(newSong.toJson()));
            importCount++;
          } catch (e) {
            debugPrint('Error processing file $originalFileName: $e');
            // Optionally, delete partially copied file if error occurs during metadata/saving
            final tempFile = File(copiedFilePath);
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          }
        }

        await _loadDownloadedSongs(); // Refresh the list of downloaded songs

        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$importCount song(s) imported successfully.')),
        );
      } else {
        // User canceled the picker or no files selected
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No songs selected for import.')),
        );
      }
    } catch (e) {
      debugPrint('Error importing songs: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('An error occurred during import: $e')),
      );
    }
  }

  Widget _buildPlaylistsView() {
    if (_playlists.isEmpty) {
      return const Center(child: Text('No playlists yet. Create one using the "+" button!'));
    }
    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: ListTile(
            leading: Icon(Icons.playlist_play, color: Theme.of(context).colorScheme.primary),
            title: Text(playlist.name, style: Theme.of(context).textTheme.titleMedium),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[700]),
              tooltip: 'Delete Playlist',
              onPressed: () {
                _deletePlaylist(context, playlist);
              },
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PlaylistDetailScreen(playlist: playlist),
                ),
              ).then((_) {
                // Refresh playlists in case of changes in PlaylistDetailScreen, e.g., name change or song additions/removals.
                _loadPlaylists();
              });
            },
          ),
        );
      },
    );
  }

  Widget _buildDownloadedSongsView() {
    if (_songs.isEmpty) {
      return const Center(child: Text('No downloaded songs yet.'));
    }
    return ListView.builder(
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final songObj = _songs[index];
        return ListTile(
          key: Key(songObj.id),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4.0),
            child: songObj.albumArtUrl.isNotEmpty
                ? Image.network(
                    songObj.albumArtUrl,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.music_note, size: 40),
                  )
                : const Icon(Icons.music_note, size: 40),
          ),
          title: Text(songObj.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(songObj.artist.isNotEmpty ? songObj.artist : "Unknown Artist", maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'Delete Download',
                onPressed: () => _deleteDownloadedSong(songObj),
              ),
            ],
          ),
          onTap: () {
            Provider.of<CurrentSongProvider>(context, listen: false).playSong(songObj);
            Provider.of<CurrentSongProvider>(context, listen: false).setQueue(_songs, initialIndex: index);
          },
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
            icon: const Icon(Icons.file_upload_outlined), // Icon for importing
            tooltip: 'Import Songs',
            onPressed: _importSongs, // Call the import function
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Playlist',
            onPressed: () => _createPlaylist(context),
          ),
        ],
        bottom: TabBar( // Add TabBar
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.list), text: 'Playlists'),
            Tab(icon: Icon(Icons.download_done), text: 'Downloads'),
          ],
        ),
      ),
      body: TabBarView( // Add TabBarView
        controller: _tabController,
        children: [
          _buildPlaylistsView(), // First tab: Playlists
          _buildDownloadedSongsView(), // Second tab: Downloaded Songs
        ],
      ),
    );
  }
}