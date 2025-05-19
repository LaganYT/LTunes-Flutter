import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import '../providers/current_song_provider.dart';

class PlaylistDetailScreen extends StatelessWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 250.0,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                playlist.name,
                style: const TextStyle(color: Colors.white),
              ),
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.purple, Colors.deepPurple],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.music_note, size: 80, color: Colors.white),
                      const SizedBox(height: 16),
                      Text(
                        playlist.name,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${playlist.songs.length} songs',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          // Play all songs in the playlist
                          if (playlist.songs.isNotEmpty) {
                            Provider.of<CurrentSongProvider>(context, listen: false)
                                .playSong(playlist.songs.first);
                          }
                        },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () async {
                          // Download all songs in the playlist
                          await PlaylistManagerService().downloadAllSongsInPlaylist(playlist);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Download initiated for all songs.')),
                          );
                        },
                        icon: const Icon(Icons.download),
                        label: const Text('Download All'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = playlist.songs[index];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      song.albumArtUrl,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  title: Text(
                    song.title,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  ),
                  subtitle: Text(
                    song.artist,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                  ),
                  onTap: () {
                    // Play the selected song
                    Provider.of<CurrentSongProvider>(context, listen: false).playSong(song);
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
