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

  late CurrentSongProvider _currentSongProvider; // To listen for song updates

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this); // Initialize TabController
    
    // Initial loads
    _loadDownloadedSongs();
    _loadPlaylists();

    // Listen to PlaylistManagerService
    // This listener will call _loadPlaylists when playlist data changes.
    _playlistManager.addListener(_onPlaylistChanged);
    
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
        // Consider updating based on CurrentSongProvider state if it's managing global playback
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Setup listener for CurrentSongProvider here as context is available.
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    // This listener will call _loadDownloadedSongs when song data changes (e.g., download status).
    _currentSongProvider.addListener(_onSongDataChanged);
  }

  void _onPlaylistChanged() {
    // PlaylistManagerService notified changes, reload playlists
    if (mounted) {
      _loadPlaylists();
    }
  }

  void _onSongDataChanged() {
    // CurrentSongProvider notified changes (e.g., download finished, metadata updated)
    // Reload downloaded songs list
    if (mounted) {
      _loadDownloadedSongs();
    }
  }

  @override
  void dispose() {
    _tabController?.dispose(); // Dispose TabController
    audioPlayer.dispose();
    _playlistNameController.dispose();
    _playlistManager.removeListener(_onPlaylistChanged);
    _currentSongProvider.removeListener(_onSongDataChanged); // Remove listener
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
    if (mounted) {
      setState(() {
        _songs = loadedSongs;
      });
    }
  }

  Future<void> _loadPlaylists() async {
    // No need to call _playlistManager.loadPlaylists() if it loads itself initially
    // and notifies. We just get the current state.
    // However, if PlaylistManagerService's loadPlaylists itself is what triggers
    // the initial load and notify, then it's fine.
    // For robustness, ensure it's loaded if this is the first time.
    // await _playlistManager.loadPlaylists(); // This might cause a loop if loadPlaylists also notifies.
                                         // Let's assume PlaylistManagerService handles its own loading.
    if (mounted) {
      setState(() {
        _playlists = _playlistManager.playlists;
      });
    }
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
              onPressed: () async { // Make async
                await _playlistManager.removePlaylist(playlist); // await the operation
                // _loadPlaylists(); // No longer needed here, listener will handle it.
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
              onPressed: () async { // Make async
                final playlistName = _playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  final newPlaylist = Playlist(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: playlistName,
                    songs: [],
                  );
                  await _playlistManager.addPlaylist(newPlaylist); // await the operation
                  // _loadPlaylists(); // No longer needed here, listener will handle it.
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
        await _playlistManager.addSongToPlaylist(playlist, song); // await
      }
      // _loadPlaylists(); // No longer needed here, listener will handle it.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedSongs.length} song(s) added to "${playlist.name}"')),
      );
    }
  }

  // ignore: unused_element
  Future<void> _removeSongFromPlaylist(Playlist playlist, Song song) async {
    await _playlistManager.removeSongFromPlaylist(playlist, song); // await
    // _loadPlaylists(); // No longer needed here, listener will handle it.
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
      // await _loadDownloadedSongs(); // No longer needed here, listener will handle it.

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
            // Copy the file to the app's documents directory
            await File(originalPath).copy(copiedFilePath); // Ensure file is copied

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

        // await _loadDownloadedSongs(); // This will be triggered by _onSongDataChanged if CurrentSongProvider notifies appropriately
                                // For direct import, if CurrentSongProvider isn't involved in notifying about these new files,
                                // calling _loadDownloadedSongs() directly or ensuring a notification path is valid.
                                // The existing listener _onSongDataChanged should handle updates if songs are managed via CurrentSongProvider.
                                // If import directly modifies SharedPreferences, then _loadDownloadedSongs() is the correct refresh.
                                // The listener _onSongDataChanged should ideally be triggered if these new songs are "globally" announced.
                                // For now, assuming the provider pattern will eventually lead to a notification.
                                // If not, a direct call to _loadDownloadedSongs() here after the loop would be needed.
                                // However, the current structure relies on listeners.

        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$importCount song(s) imported successfully.')),
        );
        // Manually trigger a reload if the provider pattern doesn't cover this specific import case for notifications.
        // This ensures the UI updates immediately after import.
        if (importCount > 0) {
            _loadDownloadedSongs();
        }
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
    // Use a Consumer for PlaylistManagerService if you prefer that pattern,
    // or rely on the listener calling setState via _loadPlaylists.
    // For this example, we're using the listener pattern established in initState.
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
                // Refresh playlists in case of changes in PlaylistDetailScreen,
                // e.g., name change or song additions/removals.
                // Listener should ideally handle this if PlaylistDetailScreen uses PlaylistManagerService.
                // _loadPlaylists(); // This might be redundant if listener works correctly.
              });
            },
          ),
        );
      },
    );
  }

  Widget _buildDownloadedSongsView() {
    // Similar to _buildPlaylistsView, this relies on the listener for CurrentSongProvider.
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