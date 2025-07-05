import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart'; // Ensure this is the correct path to CurrentSongProvider
import '../widgets/full_screen_player.dart';
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';

class Playbar extends StatefulWidget {
  static _PlaybarState of(BuildContext context) =>
      context.findAncestorStateOfType<_PlaybarState>()!;

  const Playbar({super.key});

  @override
  _PlaybarState createState() => _PlaybarState();
}

class _PlaybarState extends State<Playbar> {
  // Performance: Cache for local art paths
  final Map<String, String> _localArtPathCache = {};
  String? _previousSongId;
  
  // Performance: Debounced state updates
  Timer? _updateTimer;
  static const Duration _updateDelay = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    // Cache initial art path
    final currentSong = currentSongProvider.currentSong;
    _previousSongId = currentSong?.id;
    if (currentSong != null) {
      _cacheLocalArtPath(currentSong.albumArtUrl);
    }
    
    // Performance: Optimized listener with debouncing
    currentSongProvider.addListener(_onSongChanged);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.removeListener(_onSongChanged);
    super.dispose();
  }

  // Performance: Debounced song change handler
  void _onSongChanged() {
    _updateTimer?.cancel();
    _updateTimer = Timer(_updateDelay, () {
      if (!mounted) return;
      
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final newSong = currentSongProvider.currentSong;
      if (newSong?.id != _previousSongId) {
        _previousSongId = newSong?.id;
        if (newSong != null) {
          _cacheLocalArtPath(newSong.albumArtUrl);
        }
        setState(() {});
      }
    });
  }

  void playUrl(String url) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.playUrl(url);
  }

  // Performance: Cached local art path resolution
  Future<void> _cacheLocalArtPath(String fileName) async {
    if (fileName.isEmpty || fileName.startsWith('http')) return;
    
    if (_localArtPathCache.containsKey(fileName)) return;
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        _localArtPathCache[fileName] = fullPath;
      }
    } catch (e) {
      debugPrint('Error caching local art path: $e');
    }
  }

  // Performance: Get cached local art path
  String? _getCachedLocalArtPath(String fileName) {
    return _localArtPathCache[fileName];
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoadingAudio = currentSongProvider.isLoadingAudio;
    final bool isRadio = currentSongProvider.isCurrentlyPlayingRadio;

    if (currentSong == null) {
      return const SizedBox.shrink(); // Don't show playbar if no song is loaded
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    // Performance: Optimized album art widget
    Widget albumArtContent;
    if (currentSong.albumArtUrl.isNotEmpty) {
      if (currentSong.albumArtUrl.startsWith('http')) {
        albumArtContent = CachedNetworkImage(
          imageUrl: currentSong.albumArtUrl,
          fit: BoxFit.cover,
          width: 50,
          height: 50,
          memCacheWidth: 100,
          memCacheHeight: 100,
          placeholder: (context, url) => const Icon(Icons.album, size: 40),
          errorWidget: (context, url, error) => Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
        );
      } else {
        // Performance: Use cached local path
        final cachedPath = _getCachedLocalArtPath(currentSong.albumArtUrl);
        if (cachedPath != null) {
          albumArtContent = Image.file(
            File(cachedPath),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
          );
        } else {
          albumArtContent = const Icon(Icons.music_note, size: 48);
        }
      }
    } else {
      albumArtContent = Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant);
    }

    Widget leadingWidget = Hero(
      tag: 'current-song-art', // ensure tag matches full screen player
      child: SizedBox( // Ensure consistent size for the Hero child content
        width: 48,
        height: 48,
        child: ClipRRect( // Optional: for rounded corners if desired, matching FullScreenPlayer
          borderRadius: BorderRadius.circular(6.0),
          child: albumArtContent,
        ),
      ),
    );

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) => const FullScreenPlayer(),
            transitionDuration: const Duration(milliseconds: 350),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              const begin = Offset(0.0, 1.0); // Slide from bottom
              const end = Offset.zero; // Slide to center
              final curve = Curves.easeOutQuint; // Smoother curve

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
      child: GestureDetector( // Added GestureDetector for horizontal swipes
        onHorizontalDragEnd: isRadio
            ? null
            : (details) {
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          clipBehavior: Clip.antiAlias,
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
                        const SizedBox(height: 2),
                        Text(
                          currentSong.artist,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withOpacity(0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Performance: Optimized control buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLoadingAudio)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: colorScheme.onSurface,
                          ),
                                                     onPressed: () {
                             if (isPlaying) {
                               currentSongProvider.pauseSong();
                             } else {
                               currentSongProvider.resumeSong();
                             }
                           },
                          iconSize: 28,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                        ),
                    ],
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