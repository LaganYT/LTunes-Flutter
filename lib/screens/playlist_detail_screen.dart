import 'dart:ui'; // Import for ImageFilter
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart'; // Ensure Song model is imported
import '../providers/current_song_provider.dart';
import 'dart:io'; // Required for File

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
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

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    // Use widget.playlist to access the playlist data
    final bool hasSongs = widget.playlist.songs.isNotEmpty;
    final String? firstSongArtUrl = hasSongs ? widget.playlist.songs.first.albumArtUrl : null;

    Widget appBarBackground;
    if (firstSongArtUrl != null && firstSongArtUrl.isNotEmpty) {
      if (firstSongArtUrl.startsWith('http')) {
        appBarBackground = Image.network(
          firstSongArtUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800]),
        );
      } else {
        appBarBackground = FutureBuilder<bool>(
          future: File(firstSongArtUrl).exists(),
          builder: (context, snapshot) {
            if (snapshot.data == true) {
              return Image.file(
                File(firstSongArtUrl),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800]),
              );
            }
            return Container(color: Colors.grey[800]); // Placeholder
          },
        );
      }
    } else {
      appBarBackground = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.primaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }


    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300.0, // Increased height
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  appBarBackground,
                  if (firstSongArtUrl != null && firstSongArtUrl.isNotEmpty) // Apply blur only if image exists
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                      child: Container(
                        color: Colors.black.withOpacity(0.3), // Darken the image slightly for text readability
                      ),
                    ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40), // Adjust for appbar title
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            widget.playlist.name, // Use widget.playlist
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: [Shadow(blurRadius: 2, color: Colors.black87)],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.playlist.songs.length} songs', // Use widget.playlist
                          style: TextStyle(color: Colors.white.withOpacity(0.9), shadows: const [Shadow(blurRadius: 1, color: Colors.black54)]),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: hasSongs ? () { // hasSongs is updated by setState
                                currentSongProvider.setQueue(widget.playlist.songs, initialIndex: 0);
                                currentSongProvider.playSong(widget.playlist.songs.first);
                              } : null,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Play All'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.secondary,
                                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                               onPressed: hasSongs ? () { // hasSongs is updated by setState
                                currentSongProvider.toggleShuffle(); // Ensure shuffle is on
                                if (!currentSongProvider.isShuffling) currentSongProvider.toggleShuffle(); // if it was off, turn it on
                                currentSongProvider.setQueue(widget.playlist.songs, initialIndex: 0); // Set queue
                                currentSongProvider.playNext(); // playNext will pick a shuffled song if shuffle is on
                              } : null,
                              icon: const Icon(Icons.shuffle),
                              label: const Text('Shuffle'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(color: Colors.white.withOpacity(0.8)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // Download All button can be added here if desired
                      ],
                    ),
                  ),
                ],
              ),
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
                      listItemLeading = FutureBuilder<bool>(
                        future: File(song.albumArtUrl).exists(),
                        builder: (context, snapshot) {
                          if (snapshot.data == true) {
                            return Image.file(
                              File(song.albumArtUrl),
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
