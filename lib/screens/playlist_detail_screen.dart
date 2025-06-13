import 'dart:ui'; // Import for ImageFilter
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart'; // Ensure Song model is imported
import '../providers/current_song_provider.dart';
import 'dart:io'; // Required for File
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {

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

    const double prominentArtSize = 200.0; // Size for the main artwork display

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 400.0, // Adjusted height
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  flexibleSpaceBackground,
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0), // Increased blur
                    child: Container(
                      color: Colors.black.withOpacity(0.6), // Darker overlay
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: kToolbarHeight - 20), // Space for system status bar & appbar title area
                          _buildProminentPlaylistArt(uniqueAlbumArtUrls, prominentArtSize),
                          const SizedBox(height: 16),
                          Text(
                            widget.playlist.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24, // Slightly larger
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: [Shadow(blurRadius: 3, color: Colors.black)],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${widget.playlist.songs.length} songs',
                            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14, shadows: const [Shadow(blurRadius: 2, color: Colors.black87)]),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton.icon(
                                onPressed: hasSongs ? () {
                                  currentSongProvider.setQueue(widget.playlist.songs, initialIndex: 0);
                                  currentSongProvider.playSong(widget.playlist.songs.first);
                                } : null,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play All'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.secondary,
                                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
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
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (hasSongs) ...[
                            const SizedBox(height: 12),
                            TextButton.icon(
                              onPressed: _downloadAllSongs,
                              icon: Icon(Icons.download_for_offline_outlined, color: Colors.white.withOpacity(0.85)),
                              label: Text(
                                'Download Playlist',
                                style: TextStyle(color: Colors.white.withOpacity(0.85)),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(color: Colors.white.withOpacity(0.4)),
                                ),
                              ),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              // Title is not explicitly set here to allow the centered content to be the focus.
              // If a title is needed when collapsed, it can be added to SliverAppBar.
              // title: Text(widget.playlist.name, style: TextStyle(color: Colors.white)), // Example if title needed
              // centerTitle: true, // If title is used
            ),
          ),
          if (!hasSongs) // hasSongs is updated by setState
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