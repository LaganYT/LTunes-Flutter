import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart'; // Import for metadata
import 'package:uuid/uuid.dart'; // Import for UUID generation
import 'package:file_picker/file_picker.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import '../services/auto_fetch_service.dart';
import '../services/liked_songs_service.dart';
import '../widgets/playbar.dart';
import 'song_detail_screen.dart';
import '../services/album_manager_service.dart'; // Import for AlbumManagerService
import 'package:flutter_slidable/flutter_slidable.dart';

class SongsScreen extends StatefulWidget {
  final String? artistFilter;
  const SongsScreen({super.key, this.artistFilter});
  @override
  SongsScreenState createState() => SongsScreenState();
}

class SongsScreenState extends State<SongsScreen> {
  List<Song> _songs = [];
  final _playlistManager = PlaylistManagerService();
  final Uuid _uuid = const Uuid(); // For generating unique IDs

  // Pagination support
  final ScrollController _scrollController = ScrollController();
  static const int _pageSize = 50;
  bool _isLoading = false;
  bool _hasMoreSongs = true;
  int _currentPage = 0;
  List<Song> _allSongs = []; // Keep all songs in memory for filtering
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _refreshSongs(); // Changed from _load()
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshSongs() async {
    // Renamed from _loadDownloadedSongs and modified
    final prefs = await SharedPreferences.getInstance();
    final Set<String> keys = prefs.getKeys();
    final List<Song> allValidSongs =
        []; // Temporary list for all valid downloaded songs
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once
    const String downloadsSubDir =
        'ltunes_downloads'; // Subdirectory used by DownloadManager

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final String? songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap =
                jsonDecode(songJson) as Map<String, dynamic>;
            Song song = Song.fromJson(songMap);
            bool metadataUpdated = false;

            // Migration and validation for localFilePath
            if (song.isDownloaded &&
                song.localFilePath != null &&
                song.localFilePath!.isNotEmpty) {
              String fileName = song.localFilePath!;
              if (song.localFilePath!.contains(Platform.pathSeparator)) {
                // It's a full path, needs migration
                fileName = p.basename(song.localFilePath!);
              }
              // Correct path for checking existence, including the subdirectory
              final fullPath =
                  p.join(appDocDir.path, downloadsSubDir, fileName);

              if (await File(fullPath).exists()) {
                if (song.localFilePath != fileName) {
                  // Was a full path, now migrated to just filename
                  song = song.copyWith(localFilePath: fileName);
                  songMap['localFilePath'] = fileName; // Update map for saving
                  metadataUpdated = true;
                }
              } else {
                // File doesn't exist in the expected subdirectory
                song = song.copyWith(isDownloaded: false, localFilePath: null);
                songMap['isDownloaded'] = false;
                songMap['localFilePath'] = null;
                metadataUpdated = true;
              }
            } else if (song.isDownloaded) {
              // Marked downloaded but path is null/empty
              song = song.copyWith(isDownloaded: false, localFilePath: null);
              songMap['isDownloaded'] = false;
              songMap['localFilePath'] = null;
              metadataUpdated = true;
            }

            // Migration and validation for albumArtUrl (if local and stored in root app docs)
            if (song.albumArtUrl.isNotEmpty &&
                !song.albumArtUrl.startsWith('http')) {
              String artFileName = song.albumArtUrl;
              if (song.albumArtUrl.contains(Platform.pathSeparator)) {
                // Full path, needs migration
                artFileName = p.basename(song.albumArtUrl);
              }
              final fullArtPath = p.join(appDocDir.path, artFileName);

              if (await File(fullArtPath).exists()) {
                if (song.albumArtUrl != artFileName) {
                  song = song.copyWith(albumArtUrl: artFileName);
                  songMap['albumArtUrl'] = artFileName;
                  metadataUpdated = true;
                }
              } else {
                // Local album art file missing
                // Optionally clear it or use a placeholder indicator.
                // For now, we keep the potentially broken filename if it was already a filename.
                // If it was a full path and file is missing, it effectively becomes "broken".
                // Consider if song = song.copyWith(albumArtUrl: ''); is desired here.
              }
            }

            if (metadataUpdated) {
              await prefs.setString(key, jsonEncode(songMap));
            }

            // Add to list if downloaded and file exists
            if (song.isDownloaded &&
                song.localFilePath != null &&
                song.localFilePath!.isNotEmpty) {
              // Re-check after potential modifications if file truly exists with the (potentially migrated) filename
              // in the correct subdirectory
              final checkFile = File(
                  p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
              if (await checkFile.exists()) {
                allValidSongs
                    .add(song); // Add to the temporary list of all valid songs
              }
            }
          } catch (e) {
            debugPrint(
                'Error decoding song from SharedPreferences for key $key: $e');
            // Optionally remove corrupted data: await prefs.remove(key);
          }
        }
      }
    }

    // Apply artist filter if present
    List<Song> songsToDisplay = allValidSongs;
    if (widget.artistFilter != null) {
      songsToDisplay =
          allValidSongs.where((s) => s.artist == widget.artistFilter).toList();
    }

    // Sort songs alphabetically by title
    songsToDisplay
        .sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    if (mounted) {
      setState(() {
        _allSongs = songsToDisplay;
        _currentPage = 0;
        _hasMoreSongs = true;
        _songs = _loadNextPage();
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _hasMoreSongs) {
      _loadMoreSongs();
    }
  }

  List<Song> _loadNextPage() {
    final startIndex = _currentPage * _pageSize;
    final endIndex = startIndex + _pageSize;
    final nextPageSongs = _allSongs.sublist(
      startIndex,
      endIndex > _allSongs.length ? _allSongs.length : endIndex,
    );

    if (endIndex >= _allSongs.length) {
      _hasMoreSongs = false;
    }

    _currentPage++;
    return nextPageSongs;
  }

  Future<void> _loadMoreSongs() async {
    if (_isLoading || !_hasMoreSongs) return;

    setState(() {
      _isLoading = true;
    });

    // Simulate async operation for smooth UX
    await Future.delayed(const Duration(milliseconds: 100));

    if (mounted) {
      final nextPageSongs = _loadNextPage();
      setState(() {
        _songs.addAll(nextPageSongs);
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteSong(Song s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${s.title}"?'),
        content: const Text(
            'This will remove the downloaded audio file and associated album art if present.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;

    // Notify CurrentSongProvider to remove the song from its active state (queue, current song)
    // This should happen before file deletion and SharedPreferences.remove
    // so that CurrentSongProvider saves its state *without* the song.
    if (context.mounted) {
      await Provider.of<CurrentSongProvider>(context, listen: false)
          .processSongLibraryRemoval(s.id);
    }

    // Remove song from any playlists. This should modify playlist data.
    await _playlistManager.removeSongFromAllPlaylists(s);

    // Remove from liked songs if it's a local song (since it won't be available after deletion)
    await LikedSongsService().removeLocalSongFromLiked(s);

    final dir =
        await getApplicationDocumentsDirectory(); // Get app documents directory once

    // 1. Delete the local audio file
    if (s.localFilePath != null && s.localFilePath!.isNotEmpty) {
      final audioFile =
          File(p.join(dir.path, 'ltunes_downloads', s.localFilePath!));
      try {
        if (await audioFile.exists()) {
          await audioFile.delete();
          debugPrint('Deleted audio file: ${audioFile.path}');
        }
      } catch (e) {
        debugPrint('Error deleting audio file ${audioFile.path}: $e');
      }
    }

    // 2. Delete the local album art file
    if (s.albumArtUrl.isNotEmpty && !s.albumArtUrl.startsWith('http')) {
      // Check if any other song uses this cover
      bool coverIsUsedElsewhere = _songs.any(
          (other) => other.id != s.id && other.albumArtUrl == s.albumArtUrl);
      if (!coverIsUsedElsewhere) {
        final albumArtFile = File(p.join(dir.path, s.albumArtUrl));
        try {
          if (await albumArtFile.exists()) {
            await albumArtFile.delete();
            debugPrint('Deleted album art file:  [33m${albumArtFile.path} [0m');
          }
        } catch (e) {
          debugPrint('Error deleting album art file ${albumArtFile.path}: $e');
        }
      } else {
        debugPrint('Album art file not deleted: still used by other songs.');
      }
    }

    // 3. Remove the song metadata from SharedPreferences - this should be the final action for this key.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('song_${s.id}');
    debugPrint('Removed song_${s.id} from SharedPreferences (final step)');

    // Update album download status
    final updatedSong = s.copyWith(isDownloaded: false, localFilePath: null);
    await AlbumManagerService().updateSongInAlbums(updatedSong);

    // Update UI
    setState(() => _songs.removeWhere((song) => song.id == s.id));
  }

  Future<void> _importSongs() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom, // Changed from FileType.audio
        allowedExtensions: [
          'mp3',
          'wav',
          'm4a',
          'mp4',
          'flac',
          'opus'
        ], // Added new extensions
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        const String downloadsSubDir =
            'ltunes_downloads'; // Subdirectory for downloads
        final Directory fullDownloadsDir =
            Directory(p.join(appDocDir.path, downloadsSubDir));
        if (!await fullDownloadsDir.exists()) {
          await fullDownloadsDir.create(
              recursive: true); // Ensure the subdirectory exists
        }

        final prefs = await SharedPreferences.getInstance();
        int importCount = 0;

        // Show a loading indicator
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Importing songs...')),
          );
        }

        for (PlatformFile file in result.files) {
          if (file.path == null) continue;

          String originalPath = file.path!;
          String originalFileName = p.basename(originalPath).toLowerCase();
          debugPrint('Processing file: $originalFileName');

          // Create a unique name for the copied file to avoid conflicts
          // Use the original extension from originalFileName for the new file name
          String baseNameWithoutExt =
              p.basenameWithoutExtension(originalFileName);
          String originalExtension = p.extension(originalFileName); // e.g. .mp3
          String newFileName =
              '${_uuid.v4()}_$baseNameWithoutExt$originalExtension';

          // Corrected path: Copy to the 'ltunes_downloads' subdirectory
          String copiedFilePath = p.join(fullDownloadsDir.path, newFileName);

          try {
            // Copy the file to the app's documents directory (specifically, the downloads subdirectory)
            File copiedFile = await File(originalPath)
                .copy(copiedFilePath); // Ensure file is copied

            // Extract metadata
            AudioMetadata? metadata;
            // Try to extract metadata for all formats, including M4A and MP4
            try {
              // getImage: true to attempt to load album art
              metadata = readMetadata(copiedFile, getImage: true);
            } catch (e) {
              debugPrint('Error reading metadata for $originalFileName: $e');
              // Proceed with default values if metadata reading fails
            }

            String songId = _uuid.v4(); // Generate a unique ID for the song
            String albumArtFileName = ''; // Will store just the filename

            if (metadata?.pictures.isNotEmpty ?? false) {
              debugPrint(
                  'Found ${metadata!.pictures.length} picture(s) in metadata for $originalFileName');
              final picture = (metadata.pictures.isNotEmpty)
                  ? metadata.pictures.first
                  : null;
              if (picture != null &&
                  picture.bytes.isNotEmpty &&
                  picture.bytes.length > 100) {
                // Ensure minimum size for valid image
                debugPrint(
                    'Picture mimetype: ${picture.mimetype}, size: ${picture.bytes.length} bytes');
                // Determine file extension from mime type or default to .jpg
                String extension = '.jpg'; // Default extension
                if (picture.mimetype.isNotEmpty) {
                  if (picture.mimetype.endsWith('png')) {
                    extension = '.png';
                  } else if (picture.mimetype.endsWith('jpeg') ||
                      picture.mimetype.endsWith('jpg')) {
                    extension = '.jpg';
                  } else if (picture.mimetype.endsWith('webp')) {
                    extension = '.webp';
                  } else if (picture.mimetype.endsWith('gif')) {
                    extension = '.gif';
                  }
                }
                // Add more formats as needed

                albumArtFileName =
                    'albumart_$songId$extension'; // Just the filename
                // Album art is saved in the root of appDocDir, not the downloadsSubDir
                String fullAlbumArtPath =
                    p.join(appDocDir.path, albumArtFileName);

                try {
                  final albumArtFile = File(fullAlbumArtPath);
                  await albumArtFile.writeAsBytes(picture.bytes);
                  debugPrint(
                      'Successfully saved album art: $fullAlbumArtPath (${picture.bytes.length} bytes)');

                  // Verify the file was created and has content
                  if (await albumArtFile.exists() &&
                      await albumArtFile.length() > 0) {
                    debugPrint(
                        'Album art file verified: ${await albumArtFile.length()} bytes');
                  } else {
                    debugPrint(
                        'Warning: Album art file may not have been created properly');
                    albumArtFileName = ''; // Clear if file creation failed
                  }
                  // albumArtPath = fullAlbumArtFullPath; // No, store filename
                } catch (e) {
                  debugPrint(
                      'Error saving album art for $originalFileName: $e');
                  albumArtFileName = ''; // Clear if saving failed
                }
              }
            } else {
              debugPrint('No pictures found in metadata for $originalFileName');
            }

            Song newSong = Song(
              id: songId,
              title: metadata?.title ??
                  p.basenameWithoutExtension(originalFileName),
              artist: metadata?.artist ?? 'Unknown Artist',
              album: metadata?.album,
              albumArtUrl: albumArtFileName, // Store just the filename
              audioUrl:
                  copiedFilePath, // Store full path for initial playback before metadata save
              isDownloaded: true, // Mark as downloaded
              localFilePath:
                  newFileName, // Store just the filename for persistence
              duration: metadata?.duration,
              isImported: true, // Mark as imported
            );

            // Persist song metadata
            await prefs.setString(
                'song_${newSong.id}', jsonEncode(newSong.toJson()));

            // Auto-fetch metadata if enabled
            final autoFetchService = AutoFetchService();
            await autoFetchService.autoFetchMetadataForNewImport(newSong);

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

        if (context.mounted) {
          ScaffoldMessenger.of(context).removeCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('$importCount song(s) imported successfully.')),
          );
        }
        // Manually trigger a reload if the provider pattern doesn't cover this specific import case for notifications.
        // This ensures the UI updates immediately after import.
        if (importCount > 0) {
          await _refreshSongs(); // Updated to call _refreshSongs
        }
      } else {
        // User canceled the picker or no files selected
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No songs selected for import.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error importing songs: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An error occurred during import: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.artistFilter == null ? 'Songs' : widget.artistFilter!),
        actions: [
          if (widget.artistFilter == null)
            IconButton(
              onPressed: _importSongs,
              tooltip: 'Import Songs',
              icon: const Icon(Icons.file_upload_outlined),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48.0),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search songs...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24.0),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                hintStyle: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7)),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              onChanged: (query) {
                setState(() {
                  if (query.isEmpty) {
                    // Reset to show all songs with pagination
                    _currentPage = 0;
                    _hasMoreSongs = true;
                    _songs = _loadNextPage();
                  } else {
                    // Filter from all songs and show results immediately (no pagination for search)
                    final filteredSongs = _allSongs
                        .where((song) => song.title
                            .toLowerCase()
                            .contains(query.toLowerCase()))
                        .toList();
                    _songs = filteredSongs;
                    _hasMoreSongs = false; // Disable pagination during search
                  }
                });
              },
            ),
          ),
        ),
      ),
      body: _songs.isEmpty
          ? const Center(child: Text('No songs found.'))
          : ListView.builder(
              controller: _scrollController,
              padding:
                  const EdgeInsets.only(bottom: 80), // Add padding for playbar
              itemCount: _songs.length + (_isLoading ? 1 : 0),
              itemBuilder: (c, i) {
                // Show loading indicator at the bottom
                if (i == _songs.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final s = _songs[i];
                return Slidable(
                  key: Key(s.id),
                  endActionPane: ActionPane(
                    motion: const DrawerMotion(),
                    extentRatio: 0.32, // enough for two square buttons
                    children: [
                      SlidableAction(
                        onPressed: (context) {
                          final currentSongProvider =
                              Provider.of<CurrentSongProvider>(context,
                                  listen: false);
                          currentSongProvider.addToQueue(s);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('${s.title} added to queue')),
                          );
                        },
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimary,
                        icon: Icons.playlist_add,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      SlidableAction(
                        onPressed: (context) {
                          showDialog(
                            context: context,
                            builder: (BuildContext dialogContext) {
                              return AddToPlaylistDialog(song: s);
                            },
                          );
                        },
                        backgroundColor:
                            Theme.of(context).colorScheme.secondary,
                        foregroundColor:
                            Theme.of(context).colorScheme.onSecondary,
                        icon: Icons.library_add,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ],
                  ),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8.0),
                      child: s.albumArtUrl.isNotEmpty
                          ? (s.albumArtUrl.startsWith('http')
                              ? Image.network(
                                  s.albumArtUrl,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(Icons.album, size: 40);
                                  },
                                )
                              : FutureBuilder<String>(
                                  future: () async {
                                    final dir =
                                        await getApplicationDocumentsDirectory();
                                    final fname = p.basename(s.albumArtUrl);
                                    final path = p.join(dir.path, fname);
                                    return await File(path).exists()
                                        ? path
                                        : '';
                                  }(),
                                  builder: (_, snap) {
                                    if (snap.connectionState ==
                                            ConnectionState.done &&
                                        snap.hasData &&
                                        snap.data!.isNotEmpty) {
                                      return Image.file(
                                        File(snap.data!),
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                          return const Icon(Icons.album,
                                              size: 40);
                                        },
                                      );
                                    }
                                    return const Icon(Icons.album, size: 40);
                                  },
                                ))
                          : const Icon(Icons.album, size: 40),
                    ),
                    title: Text(s.title),
                    subtitle: Text(s.artist),
                    onTap: () async {
                      final prov = Provider.of<CurrentSongProvider>(context,
                          listen: false);
                      final song = _songs[i];
                      // If the song is downloaded, has a network album art URL, and is missing local art, try to download it
                      bool needsArtDownload = song.isDownloaded &&
                          song.albumArtUrl.isNotEmpty &&
                          song.albumArtUrl.startsWith('http');
                      bool isOnline = true;
                      try {
                        final result =
                            await InternetAddress.lookup('example.com');
                        isOnline = result.isNotEmpty &&
                            result[0].rawAddress.isNotEmpty;
                      } catch (_) {
                        isOnline = false;
                      }
                      if (needsArtDownload && isOnline) {
                        await prov.updateMissingMetadata(song);
                      }
                      await prov.smartPlayWithContext(_songs, song);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _deleteSong(s),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 32.0),
        child: const Hero(
          tag: 'global-playbar-hero',
          child: Playbar(),
        ),
      ),
    );
  }
}
