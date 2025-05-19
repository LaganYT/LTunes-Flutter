import 'package:flutter/material.dart';
import '../models/song.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';

class FullScreenPlayer extends StatelessWidget {
  final Song song;

  const FullScreenPlayer({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final bool isPlaying = currentSongProvider.isPlaying;

    return Scaffold(
      appBar: AppBar(
        title: Text(song.title),
        backgroundColor: Colors.black,
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: song.albumArtUrl.isNotEmpty
                  ? Image.network(
                      song.albumArtUrl,
                      width: 300,
                      height: 300,
                      fit: BoxFit.cover,
                    )
                  : Icon(Icons.music_note, size: 300, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            song.title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          Text(
            song.artist,
            style: const TextStyle(fontSize: 18, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, size: 48),
                onPressed: () {
                  currentSongProvider.playPrevious();
                },
              ),
              IconButton(
                icon: Icon(
                  isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  size: 64,
                ),
                onPressed: () {
                  if (isPlaying) {
                    currentSongProvider.pauseSong();
                  } else {
                    currentSongProvider.playSong(song);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 48),
                onPressed: () {
                  currentSongProvider.playNext();
                },
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
