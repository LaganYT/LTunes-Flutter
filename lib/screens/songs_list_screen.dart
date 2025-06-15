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

class SongsScreen extends StatefulWidget {
  final String? artistFilter;
  const SongsScreen({super.key, this.artistFilter});
  @override
  _SongsScreenState createState() => _SongsScreenState();
  
}

class _SongsScreenState extends State<SongsScreen> {
  List<Song> _songs = [];
  final _playlistManager = PlaylistManagerService();
  final Uuid _uuid = const Uuid(); // For generating unique IDs
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('song_'));
    final temp = <Song>[];
    for (var k in keys) {
      final js = prefs.getString(k);
      if (js != null) {
        final s = Song.fromJson(jsonDecode(js));
        if (widget.artistFilter == null || s.artist == widget.artistFilter) {
          temp.add(s);
        }
      }
    }
    setState(() => _songs = temp);
  }


  Future<void> _deleteSong(Song s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${s.title}"?'),
        content: const Text('This will remove the downloaded file if present.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    // remove local file if exists
    if (s.localFilePath != null) {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path, 'ltunes_downloads', s.localFilePath!));
      if (await f.exists()) await f.delete();
    }
    // update prefs & provider
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${s.id}', jsonEncode(s.copyWith(isDownloaded: false, localFilePath: null).toJson()));
    Provider.of<CurrentSongProvider>(context, listen: false).updateSongDetails(s);

    // also remove from any playlists that contain it
    await _playlistManager.removeSongFromAllPlaylists(s);

    setState(() => _songs.removeWhere((song) => song.id == s.id));
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
              title: metadata?.title ?? p.basenameWithoutExtension(originalFileName),
              artist: metadata?.artist ?? 'Unknown Artist',
              album: metadata?.album,
              albumArtUrl: albumArtFileName, // Store just the filename
              audioUrl: copiedFilePath, // Store full path for initial playback before metadata save
              isDownloaded: true, // Mark as downloaded
              localFilePath: newFileName, // Store just the filename for persistence
              duration: metadata?.duration,
              isImported: true, // Mark as imported
            );

            // Persist song metadata
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.artistFilter == null ? 'Songs' : widget.artistFilter!),
      ),
      body: _songs.isEmpty
          ? const Center(child: Text('No songs found.'))
          : ListView.builder(
              itemCount: _songs.length,
              itemBuilder: (c, i) {
                final s = _songs[i];
                return ListTile(
                  leading: s.albumArtUrl.isNotEmpty
                      ? (s.albumArtUrl.startsWith('http')
                          ? Image.network(s.albumArtUrl, width: 40, height: 40, fit: BoxFit.cover)
                          : FutureBuilder<String>(
                              future: () async {
                                final dir = await getApplicationDocumentsDirectory();
                                final fname = p.basename(s.albumArtUrl);
                                final path = p.join(dir.path, fname);
                                return await File(path).exists() ? path : '';
                              }(),
                              builder: (_, snap) {
                                if (snap.connectionState == ConnectionState.done && snap.hasData && snap.data!.isNotEmpty) {
                                  return Image.file(File(snap.data!), width: 40, height: 40, fit: BoxFit.cover);
                                }
                                return const Icon(Icons.album, size: 40);
                              },
                            ))
                      : const Icon(Icons.album, size: 40),
                  title: Text(s.title),
                  subtitle: Text(s.artist),
                  onTap: () {
                    final prov = Provider.of<CurrentSongProvider>(context, listen: false);
                    prov.playSong(s);
                    prov.setQueue(_songs, initialIndex: i);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteSong(s),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _importSongs,
        tooltip: 'Import Songs',
        child: const Icon(Icons.file_upload_outlined),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
