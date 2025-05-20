import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart'; // Ensure this is the correct path to CurrentSongProvider
import '../widgets/full_screen_player.dart';


class Playbar extends StatefulWidget {
  static _PlaybarState of(BuildContext context) =>
      context.findAncestorStateOfType<_PlaybarState>()!;

  const Playbar({super.key});

  @override
  _PlaybarState createState() => _PlaybarState();
}

class _PlaybarState extends State<Playbar> {
  @override
  void initState() {
    super.initState();
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.addListener(() {
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;

    return GestureDetector(
      onTap: () {
        if (currentSong != null) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        padding: const EdgeInsets.all(8.0),
        child: currentSong != null
            ? Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: currentSong.albumArtUrl.isNotEmpty
                        ? Image.network(
                            currentSong.albumArtUrl,
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurface),
                          )
                        : Icon(Icons.music_note, size: 50, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 36, color: Theme.of(context).colorScheme.primary),
                    onPressed: () {
                      if (isPlaying) {
                        currentSongProvider.pauseSong();
                      } else {
                        currentSongProvider.playSong(currentSong);
                      }
                    },
                  ),
                ],
              )
            : const Padding(
                padding: EdgeInsets.all(8.0),
                child: Card(
                  color: Color(0xFFF5F5F5),
                  elevation: 0,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.music_note, size: 32, color: Colors.grey),
                        SizedBox(width: 12),
                        Text(
                          'No song selected',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

}
