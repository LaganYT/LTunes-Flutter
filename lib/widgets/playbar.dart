import 'dart:io';
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

    if (currentSong == null) {
      return const SizedBox.shrink(); // Don't show playbar if no song is loaded
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    Widget leadingWidget;
    if (currentSong.albumArtUrl.isNotEmpty) {
      if (currentSong.albumArtUrl.startsWith('http')) {
        leadingWidget = Image.network(
          currentSong.albumArtUrl,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
        );
      } else {
        // Assume it's a local file path
        File artFile = File(currentSong.albumArtUrl);
        leadingWidget = FutureBuilder<bool>(
          future: artFile.exists(),
          builder: (context, snapshot) {
            if (snapshot.data == true) {
              return Image.file(
                artFile,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
              );
            }
            // Show placeholder while checking or if file doesn't exist
            return Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant);
          },
        );
      }
    } else {
      leadingWidget = Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant);
    }

    return GestureDetector(
      onTap: () {
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
      },
      child: Material(
        color: theme.cardColor, // Changed from colorScheme.surfaceContainerHighest
        elevation: 4.0, // Reduced from 8.0
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
          height: 64.0, // Fixed height for the playbar
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4.0),
                child: leadingWidget,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                      style: textTheme.titleSmall?.copyWith(color: colorScheme.onSurface),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    Text(
                      currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist',
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isLoadingAudio)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.0, color: colorScheme.primary),
                )
              else
                IconButton(
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: colorScheme.onSurface),
                  iconSize: 32.0,
                  onPressed: () {
                    if (isPlaying) {
                      currentSongProvider.pauseSong();
                    } else {
                      currentSongProvider.resumeSong();
                    }
                  },
                ),
              IconButton(
                icon: Icon(Icons.skip_next, color: colorScheme.onSurface.withOpacity(0.7)),
                iconSize: 28.0,
                onPressed: () {
                  currentSongProvider.playNext();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

}
