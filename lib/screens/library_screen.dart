import 'dart:io';
import 'dart:convert'; // Required for jsonDecode
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Required for SharedPreferences
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/album.dart'; // Import Album model
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart'; // Import AlbumManagerService
import 'playlist_detail_screen.dart'; // Import for navigation
import 'album_screen.dart'; // Import AlbumScreen for navigation
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart'; // Required for getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // Required for path manipulation
import 'package:uuid/uuid.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart'; // Import for metadata

// Enum definitions for sorting
enum PlaylistSortType { nameAsc, nameDesc, songCountAsc, songCountDesc }
enum AlbumSortType { titleAsc, titleDesc, artistAsc, artistDesc }
enum SongSortType { titleAsc, titleDesc, artistAsc, artistDesc }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with SingleTickerProviderStateMixin { // Add SingleTickerProviderStateMixin
  List<Song> _songs = [];
  List<Playlist> _playlists = [];
  List<Album> _savedAlbums = []; // New list for saved albums
  final AudioPlayer audioPlayer = AudioPlayer();
  // ignore: unused_field
  String? _currentlyPlayingSongPath;
  bool isPlaying = false;
  final TextEditingController _playlistNameController = TextEditingController();
  final PlaylistManagerService _playlistManager = PlaylistManagerService();
  final AlbumManagerService _albumManager = AlbumManagerService(); // Instance of AlbumManagerService
  TabController? _tabController; // Declare TabController
  final Uuid _uuid = const Uuid(); // For generating unique IDs

  late CurrentSongProvider _currentSongProvider; // To listen for song updates

  // Search functionality
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Sort state variables
  PlaylistSortType _playlistSortType = PlaylistSortType.nameAsc;
  AlbumSortType _albumSortType = AlbumSortType.titleAsc;
  SongSortType _songSortType = SongSortType.titleAsc;

  // SharedPreferences keys for sorting
  static const String _playlistSortPrefKey = 'playlistSortType_v2';
  static const String _albumSortPrefKey = 'albumSortType_v2';
  static const String _songSortPrefKey = 'songSortType_v2';


  // cache local‐art lookup futures by filename
  // ignore: unused_field
  final Map<String, Future<String>> _localArtPathCache = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this); // Changed length to 3
    _tabController?.addListener(() {
      if (!mounted) return;
      if (_searchController.text.isNotEmpty) {
        _searchController.clear(); // Clears search query, _onSearchChanged handles state
      }
      // Update hint text and potentially sort options based on tab
      setState(() {}); 
    });

    _searchController.addListener(_onSearchChanged);
    
    _loadSortPreferences().then((_) {
      // Initial loads after sort preferences are loaded
      _loadDataAndApplySort();
    });
    

    // Listen to PlaylistManagerService
    // This listener will call _loadPlaylists when playlist data changes.
    _playlistManager.addListener(_onPlaylistChanged);
    _albumManager.addListener(_onSavedAlbumsChanged); // Listen to AlbumManagerService
    
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
        // Consider updating based on CurrentSongProvider state if it's managing global playback
      });
    });
  }

  void _loadDataAndApplySort() {
    _loadDownloadedSongs(); // This will eventually call _applySortAndRefresh via its completion or listener
    _loadPlaylists();       // This will eventually call _applySortAndRefresh
    _loadSavedAlbums();     // This will eventually call _applySortAndRefresh
  }

  Future<void> _loadSortPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _playlistSortType = _enumFromString(prefs.getString(_playlistSortPrefKey), PlaylistSortType.values, PlaylistSortType.nameAsc);
      _albumSortType = _enumFromString(prefs.getString(_albumSortPrefKey), AlbumSortType.values, AlbumSortType.titleAsc);
      _songSortType = _enumFromString(prefs.getString(_songSortPrefKey), SongSortType.values, SongSortType.titleAsc);
    });
  }

  Future<void> _saveSortPreference(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  T _enumFromString<T>(String? value, List<T> enumValues, T defaultValue) {
    if (value == null) return defaultValue;
    return enumValues.firstWhere((e) => e.toString().split('.').last == value, orElse: () => defaultValue);
  }

  void _applySortAndRefresh() {
    if (!mounted) return;

    // Apply sorting based on current tab and sort type
    if (_tabController?.index == 0) { // Playlists
      _sortPlaylists();
    } else if (_tabController?.index == 1) { // Albums
      _sortAlbums();
    } else if (_tabController?.index == 2) { // Downloads
      _sortSongs();
    }
    setState(() {});
  }

  void _sortPlaylists() {
    _playlists.sort((a, b) {
      switch (_playlistSortType) {
        case PlaylistSortType.nameAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case PlaylistSortType.nameDesc:
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case PlaylistSortType.songCountAsc:
          return a.songs.length.compareTo(b.songs.length);
        case PlaylistSortType.songCountDesc:
          return b.songs.length.compareTo(a.songs.length);
      }
    });
  }

  void _sortAlbums() {
    _savedAlbums.sort((a, b) {
      switch (_albumSortType) {
        case AlbumSortType.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case AlbumSortType.titleDesc:
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case AlbumSortType.artistAsc:
          return a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase());
        case AlbumSortType.artistDesc:
          return b.artistName.toLowerCase().compareTo(a.artistName.toLowerCase());
      }
    });
  }

  void _sortSongs() {
    _songs.sort((a, b) {
      switch (_songSortType) {
        case SongSortType.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case SongSortType.titleDesc:
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case SongSortType.artistAsc:
          return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case SongSortType.artistDesc:
          return b.artist.toLowerCase().compareTo(a.artist.toLowerCase());
      }
    });
  }


  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      // No need to call _applySortAndRefresh here, filtering happens in build methods
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
      _loadPlaylists(); // This will call _applySortAndRefresh after loading
    }
  }

  void _onSavedAlbumsChanged() { // New listener method
    if (mounted) {
      _loadSavedAlbums(); // This will call _applySortAndRefresh after loading
    }
  }

  void _onSongDataChanged() {
    // CurrentSongProvider notified changes (e.g., download finished, metadata updated)
    // Reload downloaded songs list
    if (mounted) {
      _loadDownloadedSongs(); // This will call _applySortAndRefresh after loading
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
    _albumManager.removeListener(_onSavedAlbumsChanged); // Remove listener
    _currentSongProvider.removeListener(_onSongDataChanged); // Remove listener
    super.dispose();
  }

  Future<void> _loadDownloadedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final List<Song> loadedSongs = [];
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once
    const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager

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
              // Correct path for checking existence, including the subdirectory
              final fullPath = p.join(appDocDir.path, downloadsSubDir, fileName);
              
              if (await File(fullPath).exists()) {
                if (song.localFilePath != fileName) { // Was a full path, now migrated to just filename
                  song = song.copyWith(localFilePath: fileName);
                  songMap['localFilePath'] = fileName; // Update map for saving
                  metadataUpdated = true;
                }
              } else { // File doesn't exist in the expected subdirectory
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

            // Migration and validation for albumArtUrl (if local and stored in root app docs)
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
              // in the correct subdirectory
              final checkFile = File(p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
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
      _applySortAndRefresh(); // Apply sort after songs are loaded
    }
  }

  Future<void> _loadPlaylists() async {
    if (mounted) {
      setState(() {
        _playlists = List.from(_playlistManager.playlists); // Create a mutable copy
      });
      _applySortAndRefresh(); // Apply sort after playlists are loaded
    }
  }
  
  Future<void> _loadSavedAlbums() async { // New method to load saved albums
    if (mounted) {
      setState(() {
        _savedAlbums = List.from(_albumManager.savedAlbums); // Create a mutable copy
      });
      _applySortAndRefresh(); // Apply sort after albums are loaded
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
      // Stop playback if this song is currently playing from local file
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final audioHandler = currentSongProvider.audioHandler; // Use public getter
      final currentMediaItem = audioHandler.mediaItem.value;

      // ignore: unused_local_variable
      bool wasPlayingThisDeletedSong = false;
      if (currentMediaItem != null &&
          currentMediaItem.extras?['songId'] == songToDelete.id &&
          (currentMediaItem.extras?['isLocal'] as bool? ?? false)) {
        wasPlayingThisDeletedSong = true;
      }

      if (songToDelete.localFilePath != null && songToDelete.localFilePath!.isNotEmpty) {
        final appDocDir = await getApplicationDocumentsDirectory();
        const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager
        // Correct path for deletion, including the subdirectory
        final fullPath = p.join(appDocDir.path, downloadsSubDir, songToDelete.localFilePath!);
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('Deleted file: $fullPath');
        } else {
          debugPrint('File not found for deletion: $fullPath');
        }
      }

      // Update metadata
      final updatedSong = songToDelete.copyWith(isDownloaded: false, localFilePath: null);
      
      // Persist updated metadata
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('song_${updatedSong.id}', jsonEncode(updatedSong.toJson()));

      // Notify CurrentSongProvider and PlaylistManagerService
      currentSongProvider.updateSongDetails(updatedSong); // This updates provider's state, queue, and current song if necessary
      PlaylistManagerService().updateSongInPlaylists(updatedSong);
      
      // If the deleted song was playing, the audio_handler's queue update (via updateSongDetails)
      // should handle transitioning playback or stopping.
      // If it was playing locally, updateSongDetails will replace the MediaItem with one
      // that's not local, and if it can't be streamed, playback might stop or skip.
      // If it was the only song, playback will stop.

      // The _loadDownloadedSongs will be called by the listener _onSongDataChanged
      // due to currentSongProvider.updateSongDetails.

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${updatedSong.title}"')),
        );
      }
    } catch (e) {
      debugPrint('Error deleting song: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting song: $e')),
        );
      }
    }
  }

  Future<void> _importSongs() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom, // Changed from FileType.audio
        allowedExtensions: ['mp3', 'wav', 'm4a', 'mp4', 'flac', 'opus'], // Added new extensions
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory for downloads
        final Directory fullDownloadsDir = Directory(p.join(appDocDir.path, downloadsSubDir));
        if (!await fullDownloadsDir.exists()) {
          await fullDownloadsDir.create(recursive: true); // Ensure the subdirectory exists
        }
        
        final prefs = await SharedPreferences.getInstance();
        int importCount = 0;

        // Show a loading indicator
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Importing songs...')),
        );

        for (PlatformFile file in result.files) {
          if (file.path == null) continue;

          String originalPath = file.path!;
          String originalFileName = p.basename(originalPath).toLowerCase();
          
          // Create a unique name for the copied file to avoid conflicts
          // Use the original extension from originalFileName for the new file name
          String baseNameWithoutExt = p.basenameWithoutExtension(originalFileName);
          String originalExtension = p.extension(originalFileName); // e.g. .mp3
          String newFileName = '${_uuid.v4()}_$baseNameWithoutExt$originalExtension';

          // Corrected path: Copy to the 'ltunes_downloads' subdirectory
          String copiedFilePath = p.join(fullDownloadsDir.path, newFileName); 

          try {
            // Copy the file to the app's documents directory (specifically, the downloads subdirectory)
            File copiedFile = await File(originalPath).copy(copiedFilePath); // Ensure file is copied

            // Extract metadata
            AudioMetadata? metadata;
            // Check if the file is an M4A, MP4 file by its original extension
            List<String> skipMetadataExtensions = ['.m4a', '.mp4'];
            bool skipMetadata = skipMetadataExtensions.any((ext) => originalFileName.endsWith(ext));

            if (!skipMetadata) {
              try {
                // getImage: true to attempt to load album art
                metadata = await readMetadata(copiedFile, getImage: true); 
              } catch (e) {
                debugPrint('Error reading metadata for $originalFileName: $e');
                // Proceed with default values if metadata reading fails
              }
            } else {
              debugPrint('Skipping metadata reading for $originalFileName');
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
                // Album art is saved in the root of appDocDir, not the downloadsSubDir
                String fullAlbumArtPath = p.join(appDocDir.path, albumArtFileName); 
                
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
                                // The listener _onSongDataChanged should handle updates if songs are managed via CurrentSongProvider.
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
            _loadDownloadedSongs(); // This will also trigger sorting
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
    List<Playlist> filteredPlaylists = _playlists;
    if (_searchQuery.isNotEmpty) {
      filteredPlaylists = _playlists
          .where((playlist) =>
              playlist.name.toLowerCase().contains(_searchQuery))
          .toList();
    }

    return Column( // Wrap content in a Column
      children: [
        Expanded( // Make ListView take remaining space
          child: filteredPlaylists.isEmpty
              ? Center(child: Text(_searchQuery.isNotEmpty ? 'No playlists found matching "$_searchQuery".' : 'No playlists yet. Create one using the button below!')) // Updated text
              : ListView.builder(
                  itemCount: filteredPlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = filteredPlaylists[index];
                    
                    // Logic to determine leading widget based on album art
                    List<String> uniqueAlbumArtUrls = playlist.songs
                        .map((song) => song.albumArtUrl)
                        .where((artUrl) => artUrl.isNotEmpty)
                        .toSet() // Get unique URLs
                        .toList();

                    Widget leadingWidget;
                    const double leadingSize = 56.0;

                    if (uniqueAlbumArtUrls.isEmpty) {
                      leadingWidget = Icon(Icons.playlist_play, size: leadingSize, color: Theme.of(context).colorScheme.primary);
                    } else if (uniqueAlbumArtUrls.length < 4) {
                      leadingWidget = _buildPlaylistArtWidget(uniqueAlbumArtUrls.first, leadingSize);
                    } else {
                      // Display a 2x2 grid of the first 4 album arts
                      List<Widget> gridImages = uniqueAlbumArtUrls
                          .take(4)
                          .map((artUrl) => _buildPlaylistArtWidget(artUrl, leadingSize / 2)) // Each image is half the size
                          .toList();
                      
                      leadingWidget = SizedBox(
                        width: leadingSize,
                        height: leadingSize,
                        child: GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(), // Disable scrolling within the grid
                          mainAxisSpacing: 1, // Optional spacing
                          crossAxisSpacing: 1, // Optional spacing
                          padding: EdgeInsets.zero,
                          children: gridImages,
                        ),
                      );
                    }

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4.0), // Match album art clip
                          child: leadingWidget,
                        ),
                        title: Text(playlist.name, style: Theme.of(context).textTheme.titleMedium),
                        subtitle: Text('${playlist.songs.length} songs', style: Theme.of(context).textTheme.bodySmall),
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
                            // Listener _onPlaylistChanged handles refresh
                          });
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSavedAlbumsView() { // New method for "Albums" tab
    List<Album> filteredAlbums = _savedAlbums;
    if (_searchQuery.isNotEmpty) {
      filteredAlbums = _savedAlbums
          .where((album) =>
              album.title.toLowerCase().contains(_searchQuery) ||
              album.artistName.toLowerCase().contains(_searchQuery))
          .toList();
    }

    if (filteredAlbums.isEmpty) {
      return Center(child: Text(_searchQuery.isNotEmpty ? 'No albums found matching "$_searchQuery".' : 'No saved albums yet. Find albums in Search and save them!'));
    }

    return ListView.builder(
      itemCount: filteredAlbums.length,
      itemBuilder: (context, index) {
        final album = filteredAlbums[index];
        Widget leadingImage;
        if (album.fullAlbumArtUrl.isNotEmpty) {
          leadingImage = Image.network(
            album.fullAlbumArtUrl,
            width: 56, height: 56, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.album, size: 40),
          );
        } else {
          leadingImage = const Icon(Icons.album, size: 40);
        }

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4.0),
              child: leadingImage,
            ),
            title: Text(album.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(album.artistName, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton( // "Unsave" button
              icon: Icon(Icons.bookmark_remove_outlined, color: Theme.of(context).colorScheme.error),
              tooltip: 'Unsave Album',
              onPressed: () async {
                await _albumManager.removeSavedAlbum(album.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('"${album.title}" unsaved.')),
                );
                // Listener _onSavedAlbumsChanged handles refresh
              },
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlbumScreen(album: album),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildDownloadedSongsView() {
    // Do not listen here, we'll scope rebuilds to each item
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    // _songs list is already sorted by _sortSongs() via _applySortAndRefresh()
    final List<Song> completedSortedSongs = List.from(_songs);

    List<Song> allSongsToShow = [];
    final Set<String> addedSongIds = {};

    // Add active downloads first (these are not filtered by search as they are ongoing tasks)
    for (final song in currentSongProvider.activeDownloadTasks.values) {
      allSongsToShow.add(song);
      addedSongIds.add(song.id);
    }

    // Filter completed songs if search query is present
    List<Song> songsToConsider = completedSortedSongs;
    if (_searchQuery.isNotEmpty) {
      songsToConsider = completedSortedSongs.where((song) {
        return song.title.toLowerCase().contains(_searchQuery) ||
               (song.artist.toLowerCase().contains(_searchQuery));
      }).toList();
    }
    
    // Add filtered/completed downloads, avoiding duplicates
    // These are already sorted by user preference via _sortSongs -> _applySortAndRefresh
    for (final song in songsToConsider) {
      if (!addedSongIds.contains(song.id)) {
        allSongsToShow.add(song);
        // addedSongIds.add(song.id); // Not strictly needed here as we iterate unique songs
      }
    }

    // Active downloads are already at the top. The 'songsToConsider' part is already sorted.
    // No additional sorting needed here unless active downloads also need sorting,
    // but they are typically displayed by order of initiation or fixed at the top.
    // The previous sort logic for allSongsToShow is now handled by _sortSongs for the _songs list.

    if (allSongsToShow.isEmpty) {
      return Center(child: Text(_searchQuery.isNotEmpty ? 'No songs found matching "$_searchQuery".' : 'No downloaded songs yet.'));
    }

    return ListView.builder(
      itemCount: allSongsToShow.length,
      itemBuilder: (context, index) {
        final songObj = allSongsToShow[index];
        // ...existing code to build leadingWidget...

        return Consumer<CurrentSongProvider>(
          builder: (context, provider, _) {
            final active = provider.activeDownloadTasks;
            final prog  = provider.downloadProgress;
            final double? progress = prog[songObj.id];
            final bool isDownloading = active.containsKey(songObj.id) && progress != null;

            if (isDownloading) {
              return ListTile(
                key: Key("downloading_${songObj.id}"),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4.0),
                  child: const Icon(Icons.music_note),
                ),
                title: Text(songObj.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(songObj.artist.isNotEmpty ? songObj.artist : "Unknown Artist",
                         maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 2),
                    Text('Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                         style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.cancel_outlined, color: Colors.orange),
                  tooltip: 'Cancel Download',
                  onPressed: () {
                    Provider.of<CurrentSongProvider>(context, listen: false)
                        .cancelDownload(songObj.id);
                  },
                ),
                onTap: null,
              );
            } else {
              return ListTile(
                key: Key(songObj.id),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4.0),
                  child: songObj.albumArtUrl.isNotEmpty
                    ? (songObj.albumArtUrl.startsWith('http')
                        ? Image.network(
                            songObj.albumArtUrl,
                            width: 40, height: 40, fit: BoxFit.cover, // Reduced size
                            errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40), // Reduced size
                          )
                        : FutureBuilder<String>(
                            future: (() async {
                              final dir = await getApplicationDocumentsDirectory();
                              // Ensure albumArtUrl is just a filename if local
                              String artFileName = songObj.albumArtUrl;
                              if (artFileName.contains(Platform.pathSeparator)) {
                                artFileName = p.basename(artFileName);
                              }
                              final fullPath = p.join(dir.path, artFileName);
                              if (await File(fullPath).exists()) return fullPath;
                              return '';
                            })(),
                            builder: (context, snap) {
                              if (snap.connectionState == ConnectionState.done
                                  && snap.hasData && snap.data!.isNotEmpty) {
                                return Image.file(
                                  File(snap.data!),
                                  width: 40, height: 40, fit: BoxFit.cover, // Reduced size
                                  errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40), // Reduced size
                                );
                              }
                              return const Icon(Icons.music_note, size: 40); // Reduced size
                            },
                          ))
                    : const Icon(Icons.music_note, size: 40), // Reduced size
                ),
                title: Text(songObj.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(songObj.artist.isNotEmpty ? songObj.artist : "Unknown Artist", maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  tooltip: 'Delete Download',
                  onPressed: () => _deleteDownloadedSong(songObj),
                ),
                onTap: () {
                  // When tapping a completed song, play it and set the queue to all *completed* songs.
                  // Filter 'allSongsToShow' to only include non-downloading songs for the playback queue.
                  final playableSongs = allSongsToShow.where((s) => !active.containsKey(s.id)).toList();
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
      },
    );
  }

  // Helper widget to build album art for playlists (handles local and network)
  Widget _buildPlaylistArtWidget(String artUrl, double size) {
    Widget placeholder = Icon(Icons.music_note, size: size * 0.7, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5));
    
    return SizedBox(
      width: size,
      height: size,
      child: artUrl.startsWith('http')
          ? Image.network(
              artUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => placeholder,
            )
          : FutureBuilder<String>(
              future: _getResolvedLocalPath(artUrl), // Use existing helper
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                  return Image.file(
                    File(snapshot.data!),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder,
                  );
                }
                // Show placeholder while loading or if path is invalid/empty
                return placeholder;
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String hintText = 'Search...';
    IconData sortIcon = Icons.sort; // Default, can be more specific
    List<PopupMenuEntry<dynamic>> sortMenuItems = [];

    int currentTabIndex = _tabController?.index ?? 0;

    if (currentTabIndex == 0) { // Playlists
      hintText = 'Search Playlists...';
      sortIcon = Icons.sort_by_alpha; // Example, adjust as needed
      sortMenuItems = PlaylistSortType.values.map((sortType) {
        String text = '';
        switch (sortType) {
          case PlaylistSortType.nameAsc: text = 'Name (A-Z)'; break;
          case PlaylistSortType.nameDesc: text = 'Name (Z-A)'; break;
          case PlaylistSortType.songCountAsc: text = 'Song Count (Fewest)'; break;
          case PlaylistSortType.songCountDesc: text = 'Song Count (Most)'; break;
        }
        return PopupMenuItem(
          value: sortType,
          child: Row(
            children: [
              if (_playlistSortType == sortType) ...[
                const Icon(Icons.check, size: 20.0),
                const SizedBox(width: 8.0),
              ] else ...[
                const SizedBox(width: 28.0), // Placeholder for icon (20.0) + padding (8.0)
              ],
              Text(text),
            ],
          ),
        );
      }).toList();
    } else if (currentTabIndex == 1) { // Albums
      hintText = 'Search Saved Albums...';
      sortIcon = Icons.sort_by_alpha; // Example
      sortMenuItems = AlbumSortType.values.map((sortType) {
        String text = '';
        switch (sortType) {
          case AlbumSortType.titleAsc: text = 'Title (A-Z)'; break;
          case AlbumSortType.titleDesc: text = 'Title (Z-A)'; break;
          case AlbumSortType.artistAsc: text = 'Artist (A-Z)'; break;
          case AlbumSortType.artistDesc: text = 'Artist (Z-A)'; break;
        }
        return PopupMenuItem(
          value: sortType,
          child: Row(
            children: [
              if (_albumSortType == sortType) ...[
                const Icon(Icons.check, size: 20.0),
                const SizedBox(width: 8.0),
              ] else ...[
                const SizedBox(width: 28.0), // Placeholder for icon (20.0) + padding (8.0)
              ],
              Text(text),
            ],
          ),
        );
      }).toList();
    } else if (currentTabIndex == 2) { // Downloads
      hintText = 'Search Downloads...';
      sortIcon = Icons.sort_by_alpha; // Example
      sortMenuItems = SongSortType.values.map((sortType) {
        String text = '';
        switch (sortType) {
          case SongSortType.titleAsc: text = 'Title (A-Z)'; break;
          case SongSortType.titleDesc: text = 'Title (Z-A)'; break;
          case SongSortType.artistAsc: text = 'Artist (A-Z)'; break;
          case SongSortType.artistDesc: text = 'Artist (Z-A)'; break;
        }
        return PopupMenuItem(
          value: sortType,
          child: Row(
            children: [
              if (_songSortType == sortType) ...[
                const Icon(Icons.check, size: 20.0),
                const SizedBox(width: 8.0),
              ] else ...[
                const SizedBox(width: 28.0), // Placeholder for icon (20.0) + padding (8.0)
              ],
              Text(text),
            ],
          ),
        );
      }).toList();
    }


    List<Widget> appBarActions = [];
    // "Create Playlist" button is now a FAB, so it's removed from here.
    // The "Import Songs" button is also moved to a FAB.
    // appBarActions.add(
    //   IconButton(
    //     icon: const Icon(Icons.file_upload_outlined), // Icon for importing
    //     tooltip: 'Import Songs',
    //     onPressed: _importSongs, // Call the import function
    //   ),
    // );


    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        centerTitle: true, // Center the title
        actions: appBarActions, // Use the dynamically built list of actions
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight + 56), // Adjusted height for search bar + tabs
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: hintText, // Updated hintText
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
                    PopupMenuButton(
                      icon: Icon(sortIcon),
                      tooltip: "Sort",
                      onSelected: (selectedValue) {
                        if (currentTabIndex == 0 && selectedValue is PlaylistSortType) {
                          setState(() => _playlistSortType = selectedValue);
                          _saveSortPreference(_playlistSortPrefKey, selectedValue.toString().split('.').last);
                        } else if (currentTabIndex == 1 && selectedValue is AlbumSortType) {
                          setState(() => _albumSortType = selectedValue);
                           _saveSortPreference(_albumSortPrefKey, selectedValue.toString().split('.').last);
                        } else if (currentTabIndex == 2 && selectedValue is SongSortType) {
                          setState(() => _songSortType = selectedValue);
                           _saveSortPreference(_songSortPrefKey, selectedValue.toString().split('.').last);
                        }
                        _applySortAndRefresh();
                      },
                      itemBuilder: (BuildContext context) => sortMenuItems,
                    ),
                  ],
                ),
              ),
              TabBar( // Add TabBar
                controller: _tabController,
                tabs: const [
                  Tab(icon: Icon(Icons.list), text: 'Playlists'),
                  Tab(icon: Icon(Icons.album), text: 'Albums'), // New "Albums" tab
                  Tab(icon: Icon(Icons.download_done), text: 'Downloads'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPlaylistsView(),
          _buildSavedAlbumsView(), // View for "Albums" tab
          _buildDownloadedSongsView(),
        ],
      ),
      floatingActionButton: AnimatedOpacity(
        opacity: (currentTabIndex == 0 || currentTabIndex == 2) ? 1.0 : 0.0, // Visible on Playlists or Downloads tab
        duration: const Duration(milliseconds: 200),
        child: currentTabIndex == 0
            ? FloatingActionButton(
                onPressed: () => _createPlaylist(context),
                tooltip: 'Create New Playlist',
                child: const Icon(Icons.add),
              )
            : currentTabIndex == 2
                ? FloatingActionButton(
                    onPressed: _importSongs,
                    tooltip: 'Import Songs',
                    child: const Icon(Icons.file_upload_outlined),
                  )
                : null, // Render nothing if not on Playlists or Downloads tab
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  // Helper to resolve a local filename (stored in song.albumArtUrl or song.localFilePath) to a full path
  // ignore: unused_element
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