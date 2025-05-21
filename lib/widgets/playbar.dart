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

  void playUrl(String url) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.playUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoadingAudio = currentSongProvider.isLoadingAudio;

    return GestureDetector(
      onTap: () {
        if (currentSong != null) {
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => const FullScreenPlayer(),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                const begin = Offset(0.0, 1.0);
                const end = Offset.zero;
                const curve = Curves.ease;

                final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                final offsetAnimation = animation.drive(tween);

                return SlideTransition(
                  position: offsetAnimation,
                  child: child,
                );
              },
            ),
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
                    child: (currentSong.albumArtUrl.isNotEmpty)
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
                          (currentSong.title.isNotEmpty) ? currentSong.title : 'Unknown Title',
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
                    icon: isLoadingAudio
                        ? SizedBox(
                            width: 24, // Standard icon button size constraint
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.0,
                              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                            ),
                          )
                        : Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 36, color: Theme.of(context).colorScheme.primary),
                    onPressed: isLoadingAudio
                        ? null // Disable button while loading
                        : () {
                            if (isPlaying) {
                              currentSongProvider.pauseSong();
                            } else {
                              // If it's the same song and paused, resume it. Otherwise, play.
                              if (currentSongProvider.currentSong == currentSong) {
                                currentSongProvider.resumeSong();
                              } else {
                                currentSongProvider.playSong(currentSong);
                              }
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
                          'No song selected', // This will show if no song was saved
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
