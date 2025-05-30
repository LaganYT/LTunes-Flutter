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
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart'; // Required for getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // Required for path manipulation
import 'package:uuid/uuid.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart'; // Import for metadata

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

  // Search functionality
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this); // Initialize TabController
    _tabController?.addListener(() {
      // Clear search when tab changes
      if (_searchController.text.isNotEmpty) {
        _searchController.clear();
      }
      // The _onSearchChanged will be called by the controller's listener
    });

    _searchController.addListener(_onSearchChanged);
    
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

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
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
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
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
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap = jsonDecode(songJson) as Map<String, dynamic>;
            Song song = Song.fromJson(songMap);
            bool metadataUpdated = false;

            // Migration and validation for localFilePath
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              String fileName = song.localFilePath!;
              if (song.localFilePath!.contains(Platform.pathSeparator)) { // It's a full path, needs migration
                fileName = p.basename(song.localFilePath!);
              }
              final fullPath = p.join(appDocDir.path, fileName);
              
              if (await File(fullPath).exists()) {
                if (song.localFilePath != fileName) { // Was a full path, now migrated
                  song = song.copyWith(localFilePath: fileName);
                  songMap['localFilePath'] = fileName; // Update map for saving
                  metadataUpdated = true;
                }
              } else { // File doesn't exist
                song = song.copyWith(isDownloaded: false, localFilePath: null);
                songMap['isDownloaded'] = false;
                songMap['localFilePath'] = null;
                metadataUpdated = true;
              }
            } else if (song.isDownloaded) { // Marked downloaded but path is null/empty
                song = song.copyWith(isDownloaded: false, localFilePath: null);
                songMap['isDownloaded'] = false;
                songMap['localFilePath'] = null;
                metadataUpdated = true;
            }

            // Migration and validation for albumArtUrl (if local)
            if (song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
                String artFileName = song.albumArtUrl;
                if (song.albumArtUrl.contains(Platform.pathSeparator)) { // Full path, needs migration
                    artFileName = p.basename(song.albumArtUrl);
                }
                final fullArtPath = p.join(appDocDir.path, artFileName);

                if (await File(fullArtPath).exists()) {
                    if (song.albumArtUrl != artFileName) {
                        song = song.copyWith(albumArtUrl: artFileName);
                        songMap['albumArtUrl'] = artFileName;
                        metadataUpdated = true;
                    }
                } else { // Local album art file missing
                    // Optionally clear it or use a placeholder indicator.
                    // For now, we keep the potentially broken filename if it was already a filename.
                    // If it was a full path and file is missing, it effectively becomes "broken".
                    // Consider if song = song.copyWith(albumArtUrl: ''); is desired here.
                }
            }
            
            if (metadataUpdated) {
              await prefs.setString(key, jsonEncode(songMap));
            }

            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              // Re-check after potential modifications if file truly exists with the (potentially migrated) filename
              final checkFile = File(p.join(appDocDir.path, song.localFilePath!));
              if (await checkFile.exists()){
                  loadedSongs.add(song);
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
        // localFilePath is a filename
        final appDocDir = await getApplicationDocumentsDirectory();
        final fullPath = p.join(appDocDir.path, songToDelete.localFilePath!);
        final file = File(fullPath);
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
          // String uniquePrefix = _uuid.v4(); // Not needed if newFileName is used directly
          String newFileName = '${_uuid.v4()}_$originalFileName'; // This is just the filename
          String copiedFilePath = p.join(appDocDir.path, newFileName); // Full path for copy destination

          try {
            // Copy the file to the app's documents directory
            File copiedFile = await File(originalPath).copy(copiedFilePath); // Ensure file is copied

            // Extract metadata
            AudioMetadata? metadata;
            try {
              // getImage: true to attempt to load album art
              metadata = await readMetadata(copiedFile, getImage: true); 
            } catch (e) {
              debugPrint('Error reading metadata for $originalFileName: $e');
              // Proceed with default values if metadata reading fails
            }

            String songId = _uuid.v4(); // Generate a unique ID for the song
            String albumArtFileName = ''; // Will store just the filename

            if (metadata?.pictures.isNotEmpty ?? false) {
              final picture = (metadata?.pictures.isNotEmpty ?? false) ? metadata!.pictures.first : null;
              if (picture != null && picture.bytes.isNotEmpty) { // Replace 'imageData' with 'bytes'
                // Determine file extension from mime type or default to .jpg
                String extension = '.jpg'; // Default extension
                if (picture.mimetype.endsWith('png')) {
                  extension = '.png';
                } else if (picture.mimetype.endsWith('jpeg') || picture.mimetype.endsWith('jpg')) {
                  extension = '.jpg';
                }
                // Add more formats as needed
                
                albumArtFileName = 'albumart_${songId}$extension'; // Just the filename
                String fullAlbumArtPath = p.join(appDocDir.path, albumArtFileName); // Full path for writing
                
                try {
                  await File(fullAlbumArtPath).writeAsBytes(picture.bytes);
                  // albumArtPath = fullAlbumArtFullPath; // No, store filename
                } catch (e) {
                  debugPrint('Error saving album art for $originalFileName: $e');
                  albumArtFileName = ''; // Clear if saving failed
                }
              }
            }
            
            Song newSong = Song(
              id: songId,
              title: metadata?.title ?? p.basenameWithoutExtension(originalFileName), // Use metadata title or filename
              artist: metadata?.artist ?? 'Unknown Artist', // Use metadata artist or default
              album: metadata?.album, // Use metadata album or null
              albumArtUrl: albumArtFileName, // Store filename for local album art
              audioUrl: '', // Not an online stream
              localFilePath: newFileName, // Store filename of the copied audio file
              isDownloaded: true, // Mark as "downloaded" i.e., locally available
              releaseDate: null, // Default releaseDate to null or empty string
                                 // metadata.year could be used if available and parsed
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
    List<Playlist> filteredPlaylists = _playlists;
    if (_searchQuery.isNotEmpty) {
      filteredPlaylists = _playlists
          .where((playlist) =>
              playlist.name.toLowerCase().contains(_searchQuery))
          .toList();
    }

    if (filteredPlaylists.isEmpty) {
      return Center(child: Text(_searchQuery.isNotEmpty ? 'No playlists found matching "$_searchQuery".' : 'No playlists yet. Create one using the "+" button!'));
    }
    return ListView.builder(
      itemCount: filteredPlaylists.length,
      itemBuilder: (context, index) {
        final playlist = filteredPlaylists[index];
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
    // Access CurrentSongProvider to get active downloads and progress
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final activeTasks = currentSongProvider.activeDownloadTasks; // Map<String, Song>
    final progressMap = currentSongProvider.downloadProgress; // Map<String, double>
    final List<Song> completedSongs = List.from(_songs); // Use a copy of _songs

    List<Song> allSongsToShow = [];
    final Set<String> addedSongIds = {};

    // Add active downloads first (these are not filtered by search as they are ongoing tasks)
    for (final song in activeTasks.values) {
      allSongsToShow.add(song);
      addedSongIds.add(song.id);
    }

    // Filter completed songs if search query is present
    List<Song> songsToConsider = completedSongs;
    if (_searchQuery.isNotEmpty) {
      songsToConsider = completedSongs.where((song) {
        return song.title.toLowerCase().contains(_searchQuery) ||
               (song.artist.toLowerCase().contains(_searchQuery));
      }).toList();
    }
    
    // Add filtered/completed downloads, avoiding duplicates
    for (final song in songsToConsider) {
      if (!addedSongIds.contains(song.id)) {
        allSongsToShow.add(song);
        addedSongIds.add(song.id);
      }
    }

    // Sort songs by title (optional, but good for consistency)
    // Only sort if not primarily showing active downloads at the top, or sort sections separately
    // For simplicity, let's sort the whole list after combining.
    // Active downloads might jump around if their title isn't first alphabetically.
    // A more sophisticated sort would keep active downloads at the top, then sort completed ones.
    // Current sort:
    allSongsToShow.sort((a, b) {
      // Prioritize active downloads at the top
      bool aIsDownloading = activeTasks.containsKey(a.id);
      bool bIsDownloading = activeTasks.containsKey(b.id);
      if (aIsDownloading && !bIsDownloading) return -1;
      if (!aIsDownloading && bIsDownloading) return 1;
      // Then sort by title
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });


    if (allSongsToShow.isEmpty) {
      return Center(child: Text(_searchQuery.isNotEmpty ? 'No songs found matching "$_searchQuery".' : 'No downloaded songs yet.'));
    }

    return ListView.builder(
      itemCount: allSongsToShow.length,
      itemBuilder: (context, index) {
        final songObj = allSongsToShow[index];
        final double? progress = progressMap[songObj.id];
        final bool isDownloading = activeTasks.containsKey(songObj.id) && progress != null;

        Widget leadingWidget;
        if (songObj.albumArtUrl.isNotEmpty) {
          if (songObj.albumArtUrl.startsWith('http')) {
            leadingWidget = Image.network(
              songObj.albumArtUrl,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.music_note, size: 40),
            );
          } else {
            // Assume it's a local file (filename)
            leadingWidget = FutureBuilder<String>(
              future: _getResolvedLocalPath(songObj.albumArtUrl), // Resolve filename to full path
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                  return Image.file(
                    File(snapshot.data!), // Use resolved full path
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.music_note, size: 40),
                  );
                }
                return const Icon(Icons.music_note, size: 40); // Fallback if file doesn't exist or still loading
              }
            );
          }
        } else {
          leadingWidget = const Icon(Icons.music_note, size: 40);
        }

        if (isDownloading) {
          return ListTile(
            key: Key("downloading_${songObj.id}"),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4.0),
              child: leadingWidget,
            ),
            title: Text(songObj.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(songObj.artist.isNotEmpty ? songObj.artist : "Unknown Artist", maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.grey[300],
                ),
                const SizedBox(height: 2),
                Text(
                  'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.cancel_outlined, color: Colors.orange),
              tooltip: 'Cancel Download (Not Implemented)',
              onPressed: () {
                // TODO: Implement cancel download functionality in CurrentSongProvider
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cancel download not yet implemented.')),
                );
              },
            ),
            onTap: null, // Or navigate to a detail page that also shows progress
          );
        } else {
          // Completed download
          return ListTile(
            key: Key(songObj.id),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4.0),
              child: leadingWidget,
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
              // When tapping a completed song, play it and set the queue to all *completed* songs.
              // Filter 'allSongsToShow' to only include non-downloading songs for the playback queue.
              final playableSongs = allSongsToShow.where((s) => !activeTasks.containsKey(s.id)).toList();
              int playableIndex = playableSongs.indexWhere((s) => s.id == songObj.id);
              if (playableIndex != -1) {
                 Provider.of<CurrentSongProvider>(context, listen: false).playSong(songObj);
                 Provider.of<CurrentSongProvider>(context, listen: false).setQueue(playableSongs, initialIndex: playableIndex);
              }
            },
          );
        }
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight + 56), // Adjusted height for search bar + tabs
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: _tabController?.index == 0 ? 'Search Playlists...' : 'Search Downloads...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              // _onSearchChanged will be called by listener
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24.0),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[850]
                        : Colors.grey[200],
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  ),
                ),
              ),
              TabBar( // Add TabBar
                controller: _tabController,
                tabs: const [
                  Tab(icon: Icon(Icons.list), text: 'Playlists'),
                  Tab(icon: Icon(Icons.download_done), text: 'Downloads'),
                ],
              ),
            ],
          ),
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

  // Helper to resolve a local filename (stored in song.albumArtUrl or song.localFilePath) to a full path
  Future<String> _getResolvedLocalPath(String? fileName) async {
    if (fileName == null || fileName.isEmpty) return '';
    // If it's already an absolute path or URL (e.g. http), return as is (though local files should be filenames)
    if (fileName.startsWith('http') || fileName.contains(Platform.pathSeparator)) {
        // This case should ideally not happen for local files if migration is correct
        // but as a fallback, check existence if it looks like an absolute path
        if (!fileName.startsWith('http') && await File(fileName).exists()) return fileName;
        if (fileName.startsWith('http')) return fileName; // It's a URL
        return ''; // Absolute path but file doesn't exist
    }
    // It's a filename, resolve it
    final appDocDir = await getApplicationDocumentsDirectory();
    final fullPath = p.join(appDocDir.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return ''; // File not found with filename
  }
}