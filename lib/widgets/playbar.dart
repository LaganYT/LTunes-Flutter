import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart'; // Ensure this is the correct path to CurrentSongProvider
import '../widgets/full_screen_player.dart';
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import


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

  // Helper method to resolve local album art path
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoadingAudio = currentSongProvider.isLoadingAudio;
    final bool isRadio = currentSongProvider.isCurrentlyPlayingRadio; // Get radio status

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
        // Assume it's a local file path (filename)
        leadingWidget = FutureBuilder<String>(
          future: _resolveLocalArtPath(currentSong.albumArtUrl),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
              return Image.file(
                File(snapshot.data!),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
              );
            }
            // Show placeholder while checking or if file doesn't exist/path is empty
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
          MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
        );
      },
      child: GestureDetector( // Added GestureDetector for horizontal swipes
        onHorizontalDragEnd: (details) {
          // Swipe gestures on playbar can also trigger next/previous
          if (details.primaryVelocity! > 0) {
            // Swiped right (previous)
            currentSongProvider.playPrevious();
          } else if (details.primaryVelocity! < 0) {
            // Swiped left (next)
            currentSongProvider.playNext();
          }
        },
        child: Material(
          elevation: 8.0,
          color: colorScheme.surfaceVariant.withOpacity(0.95),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (Widget child, Animation<double> animation) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOutQuart)
                  ),
                  child: child,
                ),
              );
            },
            child: Container(
              key: ValueKey<String>(currentSong.id), // Key to trigger animation
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              height: 64, // Standard height for a playbar
              child: Row(
                children: [
                  leadingWidget,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          currentSong.title,
                          style: textTheme.titleSmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        Text(
                          currentSong.artist.isNotEmpty ? currentSong.artist : (isRadio ? "Radio Stream" : "Unknown Artist"),
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  if (isLoadingAudio)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    )
                  else
                    IconButton(
                      icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
                      color: colorScheme.primary,
                      onPressed: () {
                        if (isPlaying) {
                          currentSongProvider.pauseSong();
                        } else {
                          currentSongProvider.resumeSong();
                        }
                      },
                    ),
                  if (!isRadio) // Show next button only if not radio
                    IconButton(
                      icon: Icon(Icons.skip_next_rounded, size: 32),
                      color: colorScheme.onSurfaceVariant,
                      onPressed: () => currentSongProvider.playNext(),
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