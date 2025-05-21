import 'dart:ui'; // Import for ImageFilter
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../providers/current_song_provider.dart';

class PlaylistDetailScreen extends StatelessWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final bool hasSongs = playlist.songs.isNotEmpty;
    final String? firstSongArtUrl = hasSongs ? playlist.songs.first.albumArtUrl : null;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300.0, // Increased height
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                playlist.name,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2, color: Colors.black54)]),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (firstSongArtUrl != null && firstSongArtUrl.isNotEmpty)
                    Image.network(
                      firstSongArtUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800]),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.primaryContainer],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
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
                        Icon(Icons.playlist_play, size: 70, color: Colors.white.withOpacity(0.8)),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            playlist.name,
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
                          '${playlist.songs.length} songs',
                          style: TextStyle(color: Colors.white.withOpacity(0.9), shadows: const [Shadow(blurRadius: 1, color: Colors.black54)]),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: hasSongs ? () {
                                currentSongProvider.setQueue(playlist.songs, initialIndex: 0);
                                currentSongProvider.playSong(playlist.songs.first);
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
                               onPressed: hasSongs ? () {
                                currentSongProvider.toggleShuffle(); // Ensure shuffle is on
                                if (!currentSongProvider.isShuffling) currentSongProvider.toggleShuffle(); // if it was off, turn it on
                                currentSongProvider.setQueue(playlist.songs, initialIndex: 0); // Set queue
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
                  final song = playlist.songs[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: song.albumArtUrl.isNotEmpty
                          ? Image.network(
                              song.albumArtUrl,
                              width: 50,
                              height: 50,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            )
                          : Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    onTap: () {
                      currentSongProvider.setQueue(playlist.songs, initialIndex: index);
                      currentSongProvider.playSong(song);
                    },
                  );
                },
                childCount: playlist.songs.length,
              ),
            ),
        ],
      ),
    );
  }
}
