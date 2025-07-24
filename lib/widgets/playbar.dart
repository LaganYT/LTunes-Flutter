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
  String? _previousSongId;
  
  // Performance: Debounced state updates
  Timer? _updateTimer;
  static const Duration _updateDelay = Duration(milliseconds: 100);

  CurrentSongProvider? _currentSongProvider;
  // ignore: unused_field
  Future<String>? _localArtPathFuture;
  
  // Cache the current song to prevent unnecessary rebuilds
  Song? _cachedCurrentSong;
  
  // Cache the Future for the current song's local art path
  Future<String>? _cachedLocalArtFuture;

  // Artwork caching for smooth transitions
  ImageProvider? _currentArtProvider;
  String? _currentArtId;
  bool _artLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    // Initialize current song and listener
    final currentSong = _currentSongProvider?.currentSong;
    _previousSongId = currentSong?.id;
    _cachedCurrentSong = currentSong; // Initialize cached song
    if (currentSong != null) {
      _localArtPathFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
      // Initialize cached Future for local art
      if (!currentSong.albumArtUrl.startsWith('http')) {
        _cachedLocalArtFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
      }
      _updateArtProvider(currentSong);
    }
    
    // Add listener for song changes
    _currentSongProvider?.addListener(_onSongChanged);
  }

  @override
  void initState() {
    super.initState();

  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _currentSongProvider?.removeListener(_onSongChanged);
    super.dispose();
  }

  // Performance: Debounced song change handler
  void _onSongChanged() {
    _updateTimer?.cancel();
    _updateTimer = Timer(_updateDelay, () async {
      if (!mounted) return;

      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final newSong = currentSongProvider.currentSong;
      final newSongId = newSong?.id;
      
      // Only update if the song ID actually changed
      if (newSongId != _previousSongId) {
        _previousSongId = newSongId;
        _cachedCurrentSong = newSong; // Cache the new song
        _cachedLocalArtFuture = null; // Reset cached Future for local art
        if (newSong != null) {
          _localArtPathFuture = _resolveLocalArtPath(newSong.albumArtUrl);
          // Create a stable Future for local art that won't change during the song's lifetime
          if (!newSong.albumArtUrl.startsWith('http')) {
            _cachedLocalArtFuture = _resolveLocalArtPath(newSong.albumArtUrl);
          } else {
            _cachedLocalArtFuture = null;
          }
          _updateArtProvider(newSong);
        }
        // Only call setState if the widget is still mounted and we have a song change
        if (mounted) {
          setState(() {});
        }
      }
    });
  }

  Future<void> _updateArtProvider(Song song) async {
    setState(() { _artLoading = true; });
    if (song.albumArtUrl.startsWith('http')) {
      _currentArtProvider = CachedNetworkImageProvider(song.albumArtUrl);
    } else {
      final path = await _resolveLocalArtPath(song.albumArtUrl);
      if (path.isNotEmpty) {
        _currentArtProvider = FileImage(File(path));
      } else {
        _currentArtProvider = null;
      }
    }
    _currentArtId = song.id;
    if (mounted) setState(() { _artLoading = false; });
  }

  void playUrl(String url) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.playUrl(url);
  }

  Future<String> _resolveLocalArtPath(String? fileName) async {
    if (fileName == null || fileName.isEmpty || fileName.startsWith('http')) {
      return '';
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        debugPrint('Found local album art: $fullPath');
        return fullPath;
      } else {
        debugPrint('Local album art not found: $fullPath');
      }
    } catch (e) {
      debugPrint("Error resolving local art path for playbar: $e");
    }
    return '';
  }

  ImageProvider getArtworkProvider(String artUrl) {
    if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
    if (artUrl.startsWith('http')) {
      return CachedNetworkImageProvider(artUrl);
    } else {
      return FileImage(File(artUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use listen: false to prevent rebuilds on every state change
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final Song? currentSong = currentSongProvider.currentSong;
    
    if (currentSong == null) {
      return const SizedBox.shrink(); // Don't show playbar if no song is loaded
    }

    // Use cached song for album art to prevent flashing, but current song for other UI
    final Song? songForArt = _cachedCurrentSong ?? currentSong;
    
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    // Performance: Optimized album art widget using FutureBuilder
    Widget albumArtContent = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _currentArtProvider != null
        ? Image(
            key: ValueKey(_currentArtId),
            image: _currentArtProvider!,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant);
            },
          )
        : Icon(
            Icons.album,
            size: 48,
            color: colorScheme.onSurfaceVariant,
            key: ValueKey<String>('playbar_art_${songForArt?.id ?? "none"}'),
          ),
    );

    Widget leadingWidget = SizedBox( // Remove Hero wrapper, just use SizedBox
      width: 48,
      height: 48,
      child: ClipRRect( // Optional: for rounded corners if desired, matching FullScreenPlayer
        borderRadius: BorderRadius.circular(6.0),
        child: albumArtContent,
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
              key: ValueKey<String>('playbar_container_${songForArt?.id}'), // Key to trigger animation only on song change
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
                  // Separate widget for controls that can listen to state changes
                  _PlaybarControls(
                    currentSong: currentSong,
                    colorScheme: colorScheme,
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

// Separate widget for controls that can listen to state changes without affecting album art
class _PlaybarControls extends StatelessWidget {
  final Song currentSong;
  final ColorScheme colorScheme;

  const _PlaybarControls({
    required this.currentSong,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<CurrentSongProvider>(
      builder: (context, currentSongProvider, child) {
        final bool isPlaying = currentSongProvider.isPlaying;
        final bool isLoadingAudio = currentSongProvider.isLoadingAudio;

        return Row(
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
        );
      },
    );
  }
}