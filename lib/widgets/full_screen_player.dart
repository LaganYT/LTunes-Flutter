import 'dart:io'; // Required for File
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/playlist.dart'; // Import Playlist model
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import

class FullScreenPlayer extends StatelessWidget {
  const FullScreenPlayer({super.key});

  String _formatDuration(Duration? duration) {
    if (duration == null) return "0:00";
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  // Helper method to resolve local album art path
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
  }

  void _showQueueBottomSheet(BuildContext context, CurrentSongProvider provider) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final Song? currentSong = provider.currentSong;

    showModalBottomSheet(
      context: context,
      backgroundColor: colorScheme.surfaceContainerLowest,
      isScrollControlled: true, // Allows for taller bottom sheet
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5, // Start at 50% of screen height
          minChildSize: 0.3,   // Minimum 30%
          maxChildSize: 0.8,   // Maximum 80%
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Text(
                    'Up Next',
                    style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
                  ),
                ),
                Expanded(
                  child: provider.queue.isEmpty
                      ? Center(
                          child: Text(
                            'Queue is empty',
                            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: provider.queue.length,
                          itemBuilder: (context, index) {
                            final song = provider.queue[index];
                            bool isCurrentlyPlaying = song.id == currentSong?.id;
                            Widget leadingImage;
                            if (song.albumArtUrl.isNotEmpty) {
                              if (song.albumArtUrl.startsWith('http')) {
                                leadingImage = Image.network(
                                  song.albumArtUrl,
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 50, color: colorScheme.onSurfaceVariant),
                                );
                              } else {
                                leadingImage = FutureBuilder<String>(
                                  future: _resolveLocalArtPath(song.albumArtUrl), // Use helper
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                                      return Image.file(
                                        File(snapshot.data!),
                                        width: 50,
                                        height: 50,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 50, color: colorScheme.onSurfaceVariant),
                                      );
                                    }
                                    return Icon(Icons.music_note, size: 50, color: colorScheme.onSurfaceVariant);
                                  },
                                );
                              }
                            } else {
                              leadingImage = Icon(Icons.music_note, size: 50, color: colorScheme.onSurfaceVariant);
                            }

                            return ListTile(
                              tileColor: isCurrentlyPlaying ? colorScheme.primaryContainer.withOpacity(0.3) : null,
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: leadingImage,
                              ),
                              title: Text(
                                song.title.isNotEmpty ? song.title : 'Unknown Title',
                                style: textTheme.bodyLarge?.copyWith(color: colorScheme.onSurface),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                song.artist.isNotEmpty ? song.artist : 'Unknown Artist',
                                style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                provider.playSong(song);
                                // Navigator.pop(context); // Optionally close sheet on selection
                              },
                            );
                          },
                        ),
                ),
                if (provider.queue.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TextButton.icon(
                      icon: Icon(Icons.clear_all, color: colorScheme.error),
                      label: Text('Clear Queue', style: TextStyle(color: colorScheme.error)),
                      onPressed: () {
                        provider.clearQueue();
                        // Optionally pop the sheet after clearing
                        // Navigator.pop(context); 
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song songToAdd) async {
    final playlistManager = PlaylistManagerService();
    // Explicitly load playlists to ensure the list is up-to-date.
    await playlistManager.loadPlaylists(); 
    final List<Playlist> playlists = playlistManager.playlists;

    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No playlists available. Create one in the Library.')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      builder: (BuildContext ctx) {
        return Container(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  'Add "${songToAdd.title}" to playlist:',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final bool alreadyInPlaylist = playlist.songs.any((s) => s.id == songToAdd.id);
                    return ListTile(
                      title: Text(playlist.name),
                      trailing: alreadyInPlaylist ? const Icon(Icons.check, color: Colors.green) : null,
                      onTap: alreadyInPlaylist ? null : () {
                        playlistManager.addSongToPlaylist(playlist, songToAdd);
                        // savePlaylists() is called within addSongToPlaylist
                        Navigator.pop(ctx); // Close the bottom sheet
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Added "${songToAdd.title}" to "${playlist.name}"')),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoadingAudio = currentSongProvider.isLoadingAudio;

    // ThemeData for easier access
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return GestureDetector( // Wrap Scaffold with GestureDetector
      onVerticalDragEnd: (details) {
        // Check if the swipe is downwards and with sufficient velocity
        if (details.primaryVelocity != null && details.primaryVelocity! > 200) { // Threshold for swipe velocity
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent, // Make AppBar transparent
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.keyboard_arrow_down, color: colorScheme.onSurface, size: 30),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            currentSong?.album ?? 'Now Playing', // Display album name or default
            style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface),
            overflow: TextOverflow.ellipsis,
          ),
          centerTitle: true,
        ),
        body: currentSong != null
            ? LayoutBuilder( // Added LayoutBuilder
                builder: (context, constraints) {
                  return SingleChildScrollView( // Added SingleChildScrollView
                    child: ConstrainedBox( // Added ConstrainedBox
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight, // Ensure Column takes at least the viewport height
                      ),
                      child: Padding( // Existing Padding widget
                        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                        child: Column( // Existing Column
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          mainAxisSize: MainAxisSize.max, // Ensure Column tries to fill height
                          children: [
                            // Album Art and Song Info Section
                            Column(
                              children: [
                                const SizedBox(height: 20),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: currentSong.albumArtUrl.isNotEmpty
                                      ? (currentSong.albumArtUrl.startsWith('http')
                                          ? Image.network(
                                              currentSong.albumArtUrl,
                                              width: MediaQuery.of(context).size.width * 0.75,
                                              height: MediaQuery.of(context).size.width * 0.75,
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => Container(
                                                width: MediaQuery.of(context).size.width * 0.75,
                                                height: MediaQuery.of(context).size.width * 0.75,
                                                color: colorScheme.surfaceContainerHighest,
                                                child: Icon(Icons.music_note, size: 100, color: colorScheme.onSurfaceVariant),
                                              ),
                                            )
                                          : FutureBuilder<String>(
                                              future: _resolveLocalArtPath(currentSong.albumArtUrl), // Use helper
                                              builder: (context, snapshot) {
                                                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                                                  return Image.file(
                                                    File(snapshot.data!),
                                                    width: MediaQuery.of(context).size.width * 0.75,
                                                    height: MediaQuery.of(context).size.width * 0.75,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (context, error, stackTrace) => Container(
                                                      width: MediaQuery.of(context).size.width * 0.75,
                                                      height: MediaQuery.of(context).size.width * 0.75,
                                                      color: colorScheme.surfaceContainerHighest,
                                                      child: Icon(Icons.music_note, size: 100, color: colorScheme.onSurfaceVariant),
                                                    ),
                                                  );
                                                }
                                                return Container( // Placeholder while checking or if file doesn't exist
                                                  width: MediaQuery.of(context).size.width * 0.75,
                                                  height: MediaQuery.of(context).size.width * 0.75,
                                                  color: colorScheme.surfaceContainerHighest,
                                                  child: Icon(Icons.music_note, size: 100, color: colorScheme.onSurfaceVariant),
                                                );
                                              },
                                            ))
                                      : Container(
                                          width: MediaQuery.of(context).size.width * 0.75,
                                          height: MediaQuery.of(context).size.width * 0.75,
                                          color: colorScheme.surfaceContainerHighest,
                                          child: Icon(Icons.music_note, size: 100, color: colorScheme.onSurfaceVariant),
                                        ),
                                ),
                                const SizedBox(height: 30),
                                Text(
                                  currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                                  style: textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.onSurface,
                                  ),
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist',
                                  style: textTheme.titleMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ],
                            ),

                            // Progress Slider and Time
                            Column(
                              children: [
                                StreamBuilder<Duration>(
                                  stream: currentSongProvider.onPositionChanged,
                                  builder: (context, snapshot) {
                                    final position = snapshot.data ?? Duration.zero;
                                    final duration = currentSongProvider.totalDuration ?? Duration.zero;
                                    final isRadio = currentSong.id.startsWith('radio_');
                                    // For radio, use live current position as total duration
                                    final effectiveDuration = isRadio ? position : duration;

                                    return Column(
                                      children: [
                                        SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 3.0,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.0),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 15.0),
                                            activeTrackColor: colorScheme.primary,
                                            inactiveTrackColor: colorScheme.onSurface.withOpacity(0.2),
                                            thumbColor: colorScheme.primary,
                                            overlayColor: colorScheme.primary.withOpacity(0.2),
                                          ),
                                          child: Slider(
                                            value: (effectiveDuration.inMilliseconds > 0 && position.inMilliseconds <= effectiveDuration.inMilliseconds)
                                                ? position.inMilliseconds.toDouble()
                                                : 0.0,
                                            min: 0.0,
                                            max: effectiveDuration.inMilliseconds > 0 ? effectiveDuration.inMilliseconds.toDouble() : 1.0,
                                            onChanged: (value) {
                                              currentSongProvider.seek(Duration(milliseconds: value.round()));
                                            },
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(_formatDuration(position), style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                                              Text(isRadio ? 'Live' : _formatDuration(effectiveDuration), style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 10), // Spacing before controls
                                // Playback Controls
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.shuffle, color: currentSongProvider.isShuffling ? colorScheme.primary : colorScheme.onSurfaceVariant),
                                      iconSize: 28,
                                      onPressed: () {
                                        currentSongProvider.toggleShuffle();
                                      },
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.skip_previous, color: colorScheme.onSurface),
                                      iconSize: 40,
                                      onPressed: () {
                                        currentSongProvider.playPrevious();
                                      },
                                    ),
                                    IconButton(
                                      icon: isLoadingAudio
                                          ? SizedBox(
                                              width: 64,
                                              height: 64,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 3.0,
                                                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                                              ),
                                            )
                                          : Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: colorScheme.primary),
                                      iconSize: 72,
                                      onPressed: isLoadingAudio
                                          ? null
                                          : () {
                                              if (isPlaying) {
                                                currentSongProvider.pauseSong();
                                              } else {
                                                currentSongProvider.resumeSong(); // Assuming resumeSong handles playing if not already playing current
                                              }
                                            },
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.skip_next, color: colorScheme.onSurface),
                                      iconSize: 40,
                                      onPressed: () {
                                        currentSongProvider.playNext();
                                      },
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.repeat, color: currentSongProvider.isLooping ? colorScheme.primary : colorScheme.onSurfaceVariant),
                                      iconSize: 28,
                                      onPressed: () {
                                        currentSongProvider.toggleLoop();
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20), // Spacing after controls

                                // Action Buttons (Download, Add to Queue)
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    if (!currentSong.isDownloaded) // currentSong is non-null in this block
                                      IconButton(
                                        icon: Icon(Icons.download_outlined, color: colorScheme.onSurfaceVariant),
                                        tooltip: "Download",
                                        onPressed: () {
                                          currentSongProvider.downloadSongInBackground(currentSong);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('Download started')),
                                          );
                                        },
                                      ),
                                    IconButton(
                                      icon: Icon(Icons.playlist_add, color: colorScheme.onSurfaceVariant),
                                      tooltip: "Add to playlist",
                                      onPressed: () {
                                        _showAddToPlaylistDialog(context, currentSong);
                                      },
                                    ),
                                    IconButton( // New "View Queue" button
                                      icon: Icon(Icons.queue_music, color: colorScheme.onSurfaceVariant),
                                      tooltip: "View queue",
                                      onPressed: () {
                                        _showQueueBottomSheet(context, currentSongProvider);
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            
                            // Removed the old horizontal queue display here
                            // const SizedBox(height: 20), // Adjust or remove spacing as needed
                          ],
                        ),
                      )));
                },
              )
            : Center( // Fallback if no song is selected
                child: Text(
                  'No song selected',
                  style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
      ),
    );
  }
}