import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:io';
import '../models/song.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart'; // Use PlaylistManagerService
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:path/path.dart' as p; // Import path package

class SongDetailScreen extends StatefulWidget {
  final Song song;

  const SongDetailScreen({super.key, required this.song});

  @override
  _SongDetailScreenState createState() => _SongDetailScreenState();
}

class _SongDetailScreenState extends State<SongDetailScreen> {
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  // @override // initState and dispose are fine
  // void initState() {
  //   super.initState();
  // }

  // @override
  // void dispose() {
  //   super.dispose();
  // }

  void _downloadSong() {
    // No longer async, just triggers the provider's background download
    Provider.of<CurrentSongProvider>(context, listen: false).downloadSongInBackground(widget.song);
    // Optionally, show a snackbar that download has started
    // scaffoldMessengerKey.currentState?.showSnackBar(
    //   SnackBar(content: Text('Starting download for ${widget.song.title}...')),
    // );
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
      if (widget.song.localFilePath != null && widget.song.localFilePath!.isNotEmpty) {
        // localFilePath is now just a filename
        final directory = await getApplicationDocumentsDirectory();
        final fullPath = p.join(directory.path, widget.song.localFilePath!);
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      
      Song updatedSong;
      if (mounted) {
        setState(() {
          widget.song.isDownloaded = false;
          widget.song.localFilePath = null;
        });
        updatedSong = widget.song.copyWith(isDownloaded: false, localFilePath: null);
      } else {
        // If not mounted, create a copy from the original widget.song state before modification attempt
        updatedSong = widget.song.copyWith(isDownloaded: false, localFilePath: null);
      }
      
      await _saveSongMetadata(updatedSong); // Save the updated state (isDownloaded: false, localFilePath: null)

      // Notify PlaylistManagerService
      PlaylistManagerService().updateSongInPlaylists(updatedSong);

      // Notify CurrentSongProvider
      // Ensure context is available and mounted if this is in an async gap without a mounted check
      // However, _deleteSong is usually called from a button press, so context should be valid.
      // Adding a mounted check for safety if it could be called otherwise.
      if (mounted) {
         Provider.of<CurrentSongProvider>(context, listen: false).updateSongDetails(updatedSong);
      }


      scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Song deleted!')),
      );
    } catch (e) {
      _showErrorDialog('Error deleting song: $e');
    }
  }

  Future<void> _saveSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    // Ensure all relevant fields are in toJson() and saved
    final songData = jsonEncode(song.toJson()); 
    await prefs.setString('song_${song.id}', songData); // Use song.id for unique key
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context); // Listen to changes
    final bool isCurrentSongInProvider = currentSongProvider.currentSong?.id == widget.song.id;
    final bool isPlayingThisSong = isCurrentSongInProvider && currentSongProvider.isPlaying;
    final bool isLoadingThisSong = isCurrentSongInProvider && currentSongProvider.isLoadingAudio;

    final Song songForDisplay; // Use a different variable for clarity
    if (isCurrentSongInProvider && currentSongProvider.currentSong != null) {
      songForDisplay = currentSongProvider.currentSong!;
    } else {
      songForDisplay = widget.song;
    }
    
    // Determine the song instance whose download status should be displayed.
    // Prioritize the one from CurrentSongProvider if it's the same song.
    final Song songForDownloadStatus;
    if (isCurrentSongInProvider && currentSongProvider.currentSong != null) {
      songForDownloadStatus = currentSongProvider.currentSong!;
    } else {
      songForDownloadStatus = widget.song;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return ScaffoldMessenger(
      key: scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.song.album ?? 'Song Details'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(height: MediaQuery.of(context).size.height * 0.05),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: widget.song.albumArtUrl.isNotEmpty
                    ? (widget.song.albumArtUrl.startsWith('http')
                        ? Image.network(
                            widget.song.albumArtUrl,
                            width: MediaQuery.of(context).size.width * 0.7,
                            height: MediaQuery.of(context).size.width * 0.7,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              width: MediaQuery.of(context).size.width * 0.7,
                              height: MediaQuery.of(context).size.width * 0.7,
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(
                                Icons.music_note,
                                size: 100,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : FutureBuilder<String>( // Changed to FutureBuilder<String> to resolve full path
                            future: _getLocalImagePath(widget.song.albumArtUrl), // Helper to get full path
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                                return Image.file(
                                  File(snapshot.data!), // Use resolved full path
                                  width: MediaQuery.of(context).size.width * 0.7,
                                  height: MediaQuery.of(context).size.width * 0.7,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => Container(
                                    width: MediaQuery.of(context).size.width * 0.7,
                                    height: MediaQuery.of(context).size.width * 0.7,
                                    decoration: BoxDecoration(
                                      color: colorScheme.surfaceVariant,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Icon(
                                      Icons.music_note,
                                      size: 100,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                );
                              }
                              return Container( // Placeholder
                                width: MediaQuery.of(context).size.width * 0.7,
                                height: MediaQuery.of(context).size.width * 0.7,
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceVariant,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  Icons.music_note,
                                  size: 100,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              );
                            },
                          ))
                    : Container(
                        width: MediaQuery.of(context).size.width * 0.7,
                        height: MediaQuery.of(context).size.width * 0.7,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.music_note,
                          size: 100,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(height: 24),
              Text(
                songForDisplay.title, // Use songForDisplay
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                songForDisplay.artist.isNotEmpty ? songForDisplay.artist : 'Unknown Artist', // Use songForDisplay
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (songForDisplay.album != null && songForDisplay.album!.isNotEmpty) ...[ // Use songForDisplay
                const SizedBox(height: 4),
                Text(
                  '${songForDisplay.album!} ${songForDisplay.releaseDate != null && songForDisplay.releaseDate!.isNotEmpty ? "(${songForDisplay.releaseDate!})" : ""}', // Use songForDisplay
                  style: textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant.withOpacity(0.8),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 32),
              
              // Play/Pause Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: isLoadingThisSong
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimary),
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(isPlayingThisSong ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28),
                  label: Text(isPlayingThisSong ? 'Pause' : 'Play', style: textTheme.labelLarge?.copyWith(color: colorScheme.onPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: isLoadingThisSong
                      ? null
                      : () {
                          if (isPlayingThisSong) {
                            currentSongProvider.pauseSong();
                          } else {
                            if (isCurrentSongInProvider) {
                              currentSongProvider.resumeSong();
                            } else {
                              currentSongProvider.playSong(widget.song);
                            }
                          }
                        },
                ),
              ),
              const SizedBox(height: 16),

              // Download/Delete Button
              // Check if the specific song is being downloaded by the provider
              if (currentSongProvider.isDownloadingSong && currentSongProvider.downloadProgress.containsKey(songForDownloadStatus.id)) ...[
                LinearProgressIndicator(
                  value: currentSongProvider.downloadProgress[songForDownloadStatus.id],
                  color: colorScheme.secondary
                ),
                const SizedBox(height: 4),
                Text(
                  'Downloading... ${((currentSongProvider.downloadProgress[songForDownloadStatus.id] ?? 0.0) * 100).toStringAsFixed(0)}%',
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ] else if (songForDownloadStatus.isDownloaded && songForDownloadStatus.localFilePath != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    icon: Icon(Icons.delete_outline_rounded, color: colorScheme.onErrorContainer),
                    label: Text('Delete Download', style: textTheme.labelLarge?.copyWith(color: colorScheme.onErrorContainer)),
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer,
                      foregroundColor: colorScheme.onErrorContainer,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _deleteSong,
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.download_rounded),
                    label: Text('Download Song', style: textTheme.labelLarge),
                     style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _downloadSong,
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // Action Row: Add to Playlist & More Info
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: Icon(Icons.playlist_add_rounded, color: colorScheme.secondary),
                    label: Text('Add to Playlist', style: TextStyle(color: colorScheme.secondary)),
                    onPressed: () => _showAddToPlaylistDialog(context, widget.song),
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.queue_music, color: colorScheme.secondary),
                    label: Text('Add to Queue', style: TextStyle(color: colorScheme.secondary)),
                    onPressed: () {
                      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                      currentSongProvider.addToQueue(widget.song);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${widget.song.title} added to queue')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _getLocalImagePath(String imageFileName) async {
    if (imageFileName.isEmpty || imageFileName.startsWith('http')) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, imageFileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
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
  final PlaylistManagerService _playlistManagerService = PlaylistManagerService(); // Use singleton

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    // No need to load manually if PlaylistManagerService handles it internally and provides getter
    // await _playlistManagerService.loadPlaylists(); // Ensure it's loaded if not already
    setState(() {
      _playlists = _playlistManagerService.playlists;
    });
  }

  Future<void> _savePlaylists() async {
    // PlaylistManagerService handles saving
    await _playlistManagerService.savePlaylists();
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
                  final playlistToDelete = _playlists[index];
                  _playlistManagerService.removePlaylist(playlistToDelete);
                  await _savePlaylists(); // Save changes
                  setState(() { // Refresh local list
                    _playlists = _playlistManagerService.playlists;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted playlist "${playlistToDelete.name}"')),
                  );
                },
              ),
              onTap: () {
                final playlist = _playlists[index];
                // Prevent duplicates using song.id
                if (!playlist.songs.any((s) => s.id == widget.song.id)) {
                  _playlistManagerService.addSongToPlaylist(playlist, widget.song);
                  _savePlaylists(); // Save changes
                  // No need to setState for playlist.songs directly if _playlistManagerService handles it
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
                  final newPlaylist = Playlist(id: DateTime.now().millisecondsSinceEpoch.toString(), name: playlistName, songs: []);
                  _playlistManagerService.addPlaylist(newPlaylist);
                  _savePlaylists(); // Save the new playlist
                  setState(() { // Refresh local list
                     _playlists = _playlistManagerService.playlists;
                  });
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
