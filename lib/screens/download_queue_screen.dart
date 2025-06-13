import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import '../models/song.dart'; // For Song model

class DownloadQueueScreen extends StatelessWidget {
  const DownloadQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download Queue'),
      ),
      body: Consumer<CurrentSongProvider>(
        builder: (context, provider, child) {
          final activeTasks = provider.activeDownloadTasks;
          final downloadProgress = provider.downloadProgress;

          if (activeTasks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'No active downloads.',
                  style: TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          // Convert map to list for ListView.builder
          final List<Song> downloadingSongs = activeTasks.values.toList();

          return ListView.builder(
            itemCount: downloadingSongs.length,
            itemBuilder: (context, index) {
              final song = downloadingSongs[index];
              final double? progress = downloadProgress[song.id];

              Widget leadingWidget;
              if (song.albumArtUrl.isNotEmpty) {
                if (song.albumArtUrl.startsWith('http')) {
                  leadingWidget = Image.network(
                    song.albumArtUrl,
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                  );
                } else {
                  // Placeholder for local album art if logic is added later
                  // For now, using a generic icon if not an HTTP URL
                  leadingWidget = const Icon(Icons.music_note, size: 40);
                }
              } else {
                leadingWidget = const Icon(Icons.music_note, size: 40);
              }

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4.0),
                    child: leadingWidget,
                  ),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.artist.isNotEmpty ? song.artist : "Unknown Artist",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      if (progress != null) ...[
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.grey[300],
                          valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ] else ...[
                        Text(
                          'Pending...',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'Cancel Download',
                    color: Colors.orangeAccent,
                    onPressed: () {
                      provider.cancelDownload(song.id);
                      // Optional: Show a SnackBar
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Cancelled download for "${song.title}".')),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
