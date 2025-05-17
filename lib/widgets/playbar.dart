import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';

class Playbar extends StatelessWidget {
  const Playbar({super.key});

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final currentSong = currentSongProvider.currentSong;
    return Container(
      decoration: const BoxDecoration(color: Colors.grey),
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          if (currentSong != null) ...[
            Image.network(
              currentSong.albumArtUrl,
              width: 40,
              height: 40,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                currentSong.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(
                currentSongProvider.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              onPressed: () {
                if (currentSongProvider.isPlaying) {
                  currentSongProvider.pauseSong();
                } else {
                  currentSongProvider.resumeSong();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: () {
                currentSongProvider.stopSong();
              },
            ),
          ] else
            const Text('No song selected'),
        ],
      ),
    );
  }
}
