import 'dart:ui'; // Import for ImageFilter
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart'; // Ensure Song model is imported
import '../providers/current_song_provider.dart';
import 'dart:io'; // Required for File
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final PlaylistManagerService _playlistManager = PlaylistManagerService(); // For deleting playlist

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

  Future<void> _downloadAllSongs() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    if (widget.playlist.songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist is empty. Nothing to download.')),
      );
      return;
    }

    int songsToDownloadCount = 0;
    for (final song in widget.playlist.songs) {
      // Add all songs to the download queue in CurrentSongProvider
      if (!song.isDownloaded) {
        // Corrected line: Use queueSongForDownload
        currentSongProvider.queueSongForDownload(song);
        songsToDownloadCount++;
      }
    }

    if (songsToDownloadCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $songsToDownloadCount song(s) for download...')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All songs in this playlist are already downloaded.')),
      );
    }
  }

  Future<void> _showRemoveSongDialog(Song songToRemove, int originalIndexInPlaylist) async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    // Capture mounted state outside async gap if used across await
    final bool isCurrentlyMounted = mounted;

    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must tap button
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Remove Song'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Are you sure you want to remove "${songToRemove.title}" from this playlist?'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Remove'),
              onPressed: () {
                Song? currentlyPlayingSong = currentSongProvider.currentSong;
                bool wasPlayingRemovedSong = currentlyPlayingSong?.id == songToRemove.id;

                // This assumes widget.playlist.songs is a mutable list.
                // If Playlist class has a dedicated method like widget.playlist.removeSong(song), prefer that.
                widget.playlist.songs.remove(songToRemove);

                if (isCurrentlyMounted) {
                  setState(() {
                    // UI will rebuild to reflect the removed song
                  });
                }

                List<Song> updatedPlaylistSongs = List.from(widget.playlist.songs);

                if (wasPlayingRemovedSong) {
                  if (updatedPlaylistSongs.isEmpty) {
                    currentSongProvider.setQueue([], initialIndex: 0);
                    // Consider adding currentSongProvider.stop() or currentSongProvider.clearCurrentSong()
                    // if available and necessary to fully clear player state.
                  } else {
                    int newPlayIndex = originalIndexInPlaylist;
                    if (newPlayIndex >= updatedPlaylistSongs.length) {
                      newPlayIndex = 0; // Play first if last was removed or index is now out of bounds
                    }
                     if (newPlayIndex < 0) newPlayIndex = 0; // Safety check

                    currentSongProvider.setQueue(updatedPlaylistSongs, initialIndex: newPlayIndex);
                    currentSongProvider.playSong(updatedPlaylistSongs[newPlayIndex]);
                  }
                } else { // Removed song was not playing, or no song was playing
                  Song? songThatWasPlaying = currentlyPlayingSong;
                  int newIndexOfSongThatWasPlaying = -1;
                  if (songThatWasPlaying != null) {
                    newIndexOfSongThatWasPlaying = updatedPlaylistSongs.indexWhere((s) => s.id == songThatWasPlaying.id);
                  }

                  if (newIndexOfSongThatWasPlaying != -1) {
                    // Song that was playing is still in the list, update queue and its index.
                    // Playback should continue.
                    currentSongProvider.setQueue(updatedPlaylistSongs, initialIndex: newIndexOfSongThatWasPlaying);
                  } else {
                    // No song was playing, or the song that was playing is no longer in this updated list.
                    // Reset queue. Player might auto-play first if its logic dictates and queue not empty.
                    currentSongProvider.setQueue(updatedPlaylistSongs, initialIndex: 0);
                  }
                }
                Navigator.of(dialogContext).pop(); // Close the dialog
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDeletePlaylistDialog() async {
    // Capture mounted state and context outside async gap if used across await
    final bool isCurrentlyMounted = mounted;
    final BuildContext currentContext = context; // Capture context

    return showDialog<void>(
      context: currentContext,
      barrierDismissible: false, // User must tap button
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete Playlist'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Are you sure you want to delete the playlist "${widget.playlist.name}"? This action cannot be undone.'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(currentContext).colorScheme.error),
              child: const Text('Delete'),
              onPressed: () async {
                await _playlistManager.removePlaylist(widget.playlist);
                Navigator.of(dialogContext).pop(); // Close the dialog

                if (isCurrentlyMounted) {
                  // Navigate back to the previous screen (LibraryScreen)
                  Navigator.of(currentContext).pop();
                  ScaffoldMessenger.of(currentContext).showSnackBar(
                    SnackBar(content: Text('Playlist "${widget.playlist.name}" deleted.')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  // Helper to build individual art piece for grid/single display
  Widget _buildArtImage(String artUrl, double size, {BoxFit fit = BoxFit.cover}) {
    Widget placeholder = Container(
      width: size,
      height: size,
      color: Colors.grey[700], // Placeholder color
      child: Icon(Icons.music_note, size: size * 0.6, color: Colors.white70),
    );

    if (artUrl.startsWith('http')) {
      return Image.network(
        artUrl,
        width: size,
        height: size,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    } else {
      return FutureBuilder<String>(
        future: _resolveLocalArtPath(artUrl),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
            return Image.file(
              File(snapshot.data!),
              width: size,
              height: size,
              fit: fit,
              errorBuilder: (context, error, stackTrace) => placeholder,
            );
          }
          return placeholder; // Show placeholder while loading or if path is invalid
        },
      );
    }
  }

  Widget _buildProminentPlaylistArt(List<String> artUrls, double containerSize) {
    if (artUrls.isEmpty) {
      return Container(
        width: containerSize,
        height: containerSize,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.primary.withOpacity(0.7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Icon(Icons.music_note, color: Colors.white.withOpacity(0.7), size: containerSize * 0.5),
      );
    }

    if (artUrls.length < 4) {
      // Display first art as a single image
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: _buildArtImage(artUrls.first, containerSize),
      );
    } else {
      // Display a 2x2 grid of the first 4 album arts
      double imageSize = containerSize / 2;
      return SizedBox(
        width: containerSize,
        height: containerSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: artUrls.take(4).map((url) => _buildArtImage(url, imageSize)).toList(),
          ),
        ),
      );
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));

    if (duration.inHours > 0) {
      return "${duration.inHours} hr $twoDigitMinutes min";
    } else if (duration.inMinutes > 0) {
      return "$twoDigitMinutes min $twoDigitSeconds sec";
    } else {
      return "$twoDigitSeconds sec";
    }
  }

  String _calculateAndFormatPlaylistDuration() {
    if (widget.playlist.songs.isEmpty) {
      return "0 sec";
    }
    Duration totalDuration = Duration.zero;
    for (var song in widget.playlist.songs) {
      // Assuming song.duration is a Duration? object.
      // If song.duration is not available or is null, it won't be added.
      // This part needs the Song model to have a 'duration' field.
      // For now, we'll simulate it or handle null.
      // Example: if (song.duration != null) totalDuration += song.duration!;
      // As a placeholder if song.duration doesn't exist:
      // totalDuration += const Duration(minutes: 3, seconds: 30); // Placeholder
      
      // Assuming Song model has: Duration? duration;
      if (song.duration != null) {
        totalDuration += song.duration!;
      }
    }
    if (totalDuration == Duration.zero && widget.playlist.songs.isNotEmpty) {
        // This case means songs exist but none had a parsable duration,
        // or the duration field isn't populated in the Song model.
        return "N/A"; 
    }
    return _formatDuration(totalDuration);
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final bool hasSongs = widget.playlist.songs.isNotEmpty;

    List<String> uniqueAlbumArtUrls = widget.playlist.songs
        .map((song) => song.albumArtUrl)
        .where((artUrl) => artUrl.isNotEmpty)
        .toSet()
        .toList();

    Widget flexibleSpaceBackground;
    if (uniqueAlbumArtUrls.isNotEmpty) {
      // Use the first art for the blurred background
      if (uniqueAlbumArtUrls.first.startsWith('http')) {
        flexibleSpaceBackground = Image.network(
          uniqueAlbumArtUrls.first,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[850]),
        );
      } else {
        flexibleSpaceBackground = FutureBuilder<String>(
          future: _resolveLocalArtPath(uniqueAlbumArtUrls.first),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
              return Image.file(File(snapshot.data!), fit: BoxFit.cover);
            }
            return Container(color: Colors.grey[850]); // Placeholder
          },
        );
      }
    } else {
      flexibleSpaceBackground = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    const double prominentArtSize = 160.0; 
    final double systemTopPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 390.0, 
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Builder(
                builder: (context) {
                  final settings = context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
                  if (settings == null) return const SizedBox.shrink();

                  // Calculate how "collapsed" the bar is.
                  // currentExtent goes from maxExtent down to minExtent.
                  // We want the title to appear when currentExtent is very close to minExtent.
                  final double delta = settings.maxExtent - settings.minExtent;
                  // Threshold for when the title starts becoming visible.
                  // Let's say it starts appearing when 90% collapsed.
                  final double collapseThreshold = delta * 0.1; // 10% of the scroll range remains
                  
                  double opacity = 0.0;
                  if (delta > 0) { // Avoid division by zero
                    // When currentExtent is at minExtent, settings.currentExtent - settings.minExtent is 0.
                    // We want opacity to be 1.0 when fully collapsed (or very near it).
                    // And 0.0 when it's more expanded than our threshold.
                    if ((settings.currentExtent - settings.minExtent) < collapseThreshold) {
                        // Smoothly fade in as it approaches full collapse within the threshold
                        opacity = 1.0 - ((settings.currentExtent - settings.minExtent) / collapseThreshold);
                        opacity = opacity.clamp(0.0, 1.0); // Ensure opacity is between 0 and 1
                    }
                  } else if (settings.currentExtent == settings.minExtent) {
                    opacity = 1.0; // Fully collapsed
                  }


                  return Opacity(
                    opacity: opacity,
                    child: Text(
                      widget.playlist.name,
                      style: const TextStyle(
                        fontSize: 16.0, 
                        color: Colors.white, // Ensure text color is set for visibility
                        shadows: [ // Optional: add a slight shadow for better readability
                          Shadow(
                            blurRadius: 1.0,
                            color: Colors.black54,
                            offset: Offset(0.5, 0.5),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }
              ),
              centerTitle: true, 
              titlePadding: const EdgeInsets.only(bottom: 16.0, left: 48.0, right: 48.0), 
              background: Stack(
                fit: StackFit.expand,
                children: [
                  flexibleSpaceBackground,
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                    child: Container(
                      color: Colors.black.withOpacity(0.6),
                    ),
                  ),
                  // Use Padding to position the content column correctly
                  Padding(
                    padding: EdgeInsets.only(
                      top: systemTopPadding + kToolbarHeight + 10, // Space for status bar, app bar, and a small margin
                      left: 16.0,
                      right: 16.0,
                      bottom: 16.0, // Padding at the bottom of the content area
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start, // Align content to the start (top) of the padded area
                      mainAxisSize: MainAxisSize.min, 
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildProminentPlaylistArt(uniqueAlbumArtUrls, prominentArtSize),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    widget.playlist.name,
                                    style: const TextStyle(
                                      fontSize: 22, // Adjusted size
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      shadows: [Shadow(blurRadius: 3, color: Colors.black)],
                                    ),
                                    maxLines: 3, // Allow more lines for playlist name
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${widget.playlist.songs.length} songs',
                                    style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14, shadows: const [Shadow(blurRadius: 2, color: Colors.black87)]),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _calculateAndFormatPlaylistDuration(),
                                    style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13, shadows: const [Shadow(blurRadius: 1, color: Colors.black54)]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24), 
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: hasSongs ? () {
                                  currentSongProvider.setQueue(widget.playlist.songs, initialIndex: 0);
                                  currentSongProvider.playSong(widget.playlist.songs.first);
                                } : null,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play All'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.surface, // Brighter background
                                  foregroundColor: Theme.of(context).colorScheme.onSurface, // Contrasting text
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: hasSongs ? () {
                                  if (!currentSongProvider.isShuffling) currentSongProvider.toggleShuffle();
                                  currentSongProvider.setQueue(widget.playlist.songs, initialIndex: 0);
                                  currentSongProvider.playNext();
                                } : null,
                                icon: const Icon(Icons.shuffle),
                                label: const Text('Shuffle'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: BorderSide(color: Colors.white.withOpacity(0.7)),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (hasSongs)
                              Expanded(
                                child: TextButton.icon(
                                  onPressed: _downloadAllSongs,
                                  icon: Icon(Icons.download_for_offline_outlined, color: Colors.white.withOpacity(0.85)),
                                  label: Text(
                                    'Download', // Shorter label
                                    style: TextStyle(color: Colors.white.withOpacity(0.85)),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      side: BorderSide(color: Colors.white.withOpacity(0.4)),
                                    ),
                                  ),
                                ),
                              ),
                            if (hasSongs) const SizedBox(width: 12), 
                            Expanded(
                              child: TextButton.icon(
                                onPressed: _showDeletePlaylistDialog,
                                icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error.withOpacity(0.9)),
                                label: Text(
                                  'Delete', // Shorter label
                                  style: TextStyle(color: Theme.of(context).colorScheme.error.withOpacity(0.9)),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    side: BorderSide(color: Theme.of(context).colorScheme.error.withOpacity(0.5)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // No extra SizedBox here, bottom padding is handled by the outer Padding
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!hasSongs) 
            SliverFillRemaining( // Use SliverFillRemaining for empty state
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.music_off_outlined, size: 60, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                      'This playlist is empty.',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add some songs from your library.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = widget.playlist.songs[index]; // Use widget.playlist
                  Widget listItemLeading;
                  if (song.albumArtUrl.isNotEmpty) {
                    if (song.albumArtUrl.startsWith('http')) {
                      listItemLeading = Image.network(
                        song.albumArtUrl,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      );
                    } else {
                      listItemLeading = FutureBuilder<String>(
                        future: _resolveLocalArtPath(song.albumArtUrl), // Use helper
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                            return Image.file(
                              File(snapshot.data!),
                              width: 50,
                              height: 50,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            );
                          }
                          return Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant);
                        },
                      );
                    }
                  } else {
                    listItemLeading = Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant);
                  }

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: listItemLeading,
                    ),
                    title: Text(
                      song.title,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w500),
                       maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      song.artist.isNotEmpty ? song.artist : "Unknown Artist",
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                       maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                      tooltip: 'Remove from playlist',
                      onPressed: () {
                        _showRemoveSongDialog(song, index);
                      },
                    ),
                    onTap: () {
                      currentSongProvider.setQueue(widget.playlist.songs, initialIndex: index);
                      currentSongProvider.playSong(song);
                    },
                  );
                },
                childCount: widget.playlist.songs.length, // Use widget.playlist
              ),
            ),
        ],
      ),
    );
  }
}