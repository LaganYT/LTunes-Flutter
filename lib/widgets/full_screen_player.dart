import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';

class FullScreenPlayer extends StatelessWidget {
  const FullScreenPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_downward, color: Theme.of(context).colorScheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: currentSong != null
          ? Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: currentSong.albumArtUrl.isNotEmpty
                          ? Image.network(
                              currentSong.albumArtUrl,
                              width: MediaQuery.of(context).size.width * 0.8,
                              height: MediaQuery.of(context).size.width * 0.8,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 150, color: Theme.of(context).colorScheme.onSurface),
                            )
                          : Icon(Icons.music_note, size: 150, color: Theme.of(context).colorScheme.onSurface),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 24,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist',
                      style: TextStyle(
                        fontSize: 18,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: Icon(Icons.download, color: Theme.of(context).colorScheme.primary),
                          onPressed: () {
                            currentSongProvider.downloadSong(currentSong);
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.playlist_add, color: Theme.of(context).colorScheme.primary),
                          onPressed: () {
                            currentSongProvider.addToQueue(currentSong);
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.shuffle, color: currentSongProvider.isShuffling ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface),
                          onPressed: () {
                            currentSongProvider.toggleShuffle();
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.loop, color: currentSongProvider.isLooping ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface),
                          onPressed: () {
                            currentSongProvider.toggleLoop();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.skip_previous, size: 36, color: Theme.of(context).colorScheme.onSurface),
                          onPressed: () {
                            currentSongProvider.playPrevious();
                          },
                        ),
                        IconButton(
                          icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 64, color: Theme.of(context).colorScheme.primary),
                          onPressed: () {
                            if (isPlaying) {
                              currentSongProvider.pauseSong();
                            } else {
                              currentSongProvider.playSong(currentSong);
                            }
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.skip_next, size: 36, color: Theme.of(context).colorScheme.onSurface),
                          onPressed: () {
                            currentSongProvider.playNext();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      height: 100,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                      ),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: currentSongProvider.queue.length,
                        itemBuilder: (context, index) {
                          final song = currentSongProvider.queue[index];
                          return Dismissible(
                            key: Key(song.id),
                            direction: DismissDirection.startToEnd,
                            onDismissed: (direction) {
                              currentSongProvider.addToQueue(song);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('${song.title} added to queue')),
                              );
                            },
                            background: Container(
                              color: Theme.of(context).colorScheme.primary,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.only(left: 16),
                              child: Icon(Icons.queue, color: Theme.of(context).colorScheme.onPrimary),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: song.albumArtUrl.isNotEmpty
                                        ? Image.network(
                                            song.albumArtUrl,
                                            width: 60,
                                            height: 60,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 60, color: Theme.of(context).colorScheme.onSurface),
                                          )
                                        : Icon(Icons.music_note, size: 60, color: Theme.of(context).colorScheme.onSurface),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    song.title,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Center(
              child: Text(
                'No song selected',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  fontSize: 18,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
    );
  }
}
