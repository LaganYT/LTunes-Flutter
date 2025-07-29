import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../widgets/full_screen_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';

class DesktopPlaybar extends StatefulWidget {
  const DesktopPlaybar({super.key});

  @override
  State<DesktopPlaybar> createState() => _DesktopPlaybarState();
}

class _DesktopPlaybarState extends State<DesktopPlaybar> {
  String? _previousSongId;
  Timer? _updateTimer;
  static const Duration _updateDelay = Duration(milliseconds: 100);
  CurrentSongProvider? _currentSongProvider;
  Future<String>? _localArtPathFuture;
  Song? _cachedCurrentSong;
  Future<String>? _cachedLocalArtFuture;
  ImageProvider? _currentArtProvider;
  String? _currentArtId;
  bool _artLoading = false;
  final Map<String, Future<String>> _localArtFutureCache = {};
  final Map<String, ImageProvider> _artProviderCache = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    final currentSong = _currentSongProvider?.currentSong;
    _previousSongId = currentSong?.id;
    _cachedCurrentSong = currentSong;
    if (currentSong != null) {
      _localArtPathFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
      if (!currentSong.albumArtUrl.startsWith('http')) {
        _cachedLocalArtFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
      }
      _updateArtProvider(currentSong);
    }
    
    _currentSongProvider?.addListener(_onSongChanged);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _currentSongProvider?.removeListener(_onSongChanged);
    super.dispose();
  }

  void _onSongChanged() {
    if (_updateTimer?.isActive ?? false) return;
    
    _updateTimer = Timer(_updateDelay, () {
      if (!mounted) return;
      
      final currentSong = _currentSongProvider?.currentSong;
      if (currentSong?.id != _previousSongId) {
        _previousSongId = currentSong?.id;
        _cachedCurrentSong = currentSong;
        
        if (currentSong != null) {
          _localArtPathFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
          if (!currentSong.albumArtUrl.startsWith('http')) {
            _cachedLocalArtFuture = _resolveLocalArtPath(currentSong.albumArtUrl);
          }
          _updateArtProvider(currentSong);
        }
        
        setState(() {});
      }
    });
  }

  Future<String> _resolveLocalArtPath(String artUrl) async {
    if (artUrl.isEmpty) return '';
    
    if (artUrl.startsWith('http')) {
      return artUrl;
    }
    
    if (_localArtFutureCache.containsKey(artUrl)) {
      return await _localArtFutureCache[artUrl]!;
    }
    
    final future = _resolveLocalArtPathInternal(artUrl);
    _localArtFutureCache[artUrl] = future;
    
    try {
      final result = await future;
      return result;
    } catch (e) {
      _localArtFutureCache.remove(artUrl);
      rethrow;
    }
  }

  Future<String> _resolveLocalArtPathInternal(String artUrl) async {
    if (artUrl.isEmpty) return '';
    
    if (artUrl.startsWith('http')) {
      return artUrl;
    }
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = p.join(directory.path, artUrl);
      final file = File(filePath);
      
      if (await file.exists()) {
        return filePath;
      }
    } catch (e) {
      debugPrint('Error resolving local art path: $e');
    }
    
    return '';
  }

  void _updateArtProvider(Song song) {
    if (song.albumArtUrl.isEmpty) {
      _currentArtProvider = null;
      _currentArtId = null;
      return;
    }
    
    if (_artProviderCache.containsKey(song.albumArtUrl)) {
      _currentArtProvider = _artProviderCache[song.albumArtUrl];
      _currentArtId = song.albumArtUrl;
      return;
    }
    
    _artLoading = true;
    setState(() {});
    
    _resolveLocalArtPath(song.albumArtUrl).then((path) {
      if (mounted && path.isNotEmpty) {
        ImageProvider provider;
        if (path.startsWith('http')) {
          provider = CachedNetworkImageProvider(path);
        } else {
          provider = FileImage(File(path));
        }
        
        _artProviderCache[song.albumArtUrl] = provider;
        _currentArtProvider = provider;
        _currentArtId = song.albumArtUrl;
        _artLoading = false;
        setState(() {});
      }
    }).catchError((e) {
      debugPrint('Error loading artwork: $e');
      _artLoading = false;
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final currentSong = currentSongProvider.currentSong;
    
    if (currentSong == null) {
      return const SizedBox.shrink();
    }

    final Song songForArt = _cachedCurrentSong ?? currentSong;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

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
            key: ValueKey<String>('desktop_playbar_art_${songForArt.id}'),
          ),
    );

    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outline.withOpacity(0.2),
            width: 1,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: IntrinsicHeight(
          child: Row(
          children: [
            // Left section - Album art and song info
            Expanded(
              flex: 1,
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (context, animation, secondaryAnimation) => const FullScreenPlayer(),
                          transitionDuration: const Duration(milliseconds: 350),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            const begin = Offset(0.0, 1.0);
                            const end = Offset.zero;
                            final curve = Curves.easeOutQuint;
                            final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                            final offsetAnimation = animation.drive(tween);
                            return SlideTransition(position: offsetAnimation, child: child);
                          },
                        ),
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: albumArtContent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          currentSong.title,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          currentSong.artist,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withOpacity(0.7),
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            // Center section - Playback controls and progress
            Expanded(
              flex: 2,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Playback controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: colorScheme.onSurface.withOpacity(0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          // TODO: Implement shuffle
                        },
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.skip_previous,
                          color: colorScheme.onSurface,
                          size: 24,
                        ),
                        onPressed: () => currentSongProvider.playPrevious(),
                      ),
                      const SizedBox(width: 8),
                                             Container(
                         decoration: BoxDecoration(
                           color: const Color(0xFFFF9800), // LTunes orange
                           shape: BoxShape.circle,
                         ),
                        child: IconButton(
                          icon: Icon(
                            currentSongProvider.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 28,
                          ),
                          onPressed: () {
                            if (currentSongProvider.isPlaying) {
                              currentSongProvider.pauseSong();
                            } else {
                              currentSongProvider.resumeSong();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.skip_next,
                          color: colorScheme.onSurface,
                          size: 24,
                        ),
                        onPressed: () => currentSongProvider.playNext(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.repeat,
                          color: colorScheme.onSurface.withOpacity(0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          // TODO: Implement repeat
                        },
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.fullscreen,
                          color: colorScheme.onSurface.withOpacity(0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          if (currentSongProvider.currentSong != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const FullScreenPlayer(),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Progress bar
                  Row(
                    children: [
                                             Text(
                         _formatDuration(currentSongProvider.currentPosition),
                         style: textTheme.bodySmall?.copyWith(
                           color: colorScheme.onSurface.withOpacity(0.7),
                           fontSize: 11,
                         ),
                       ),
                       Expanded(
                         child: SliderTheme(
                           data: SliderTheme.of(context).copyWith(
                             trackHeight: 3,
                             thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                             overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                             activeTrackColor: const Color(0xFFFF9800), // LTunes orange
                             inactiveTrackColor: colorScheme.onSurface.withOpacity(0.2),
                             thumbColor: const Color(0xFFFF9800), // LTunes orange
                           ),
                           child: Slider(
                             value: currentSongProvider.currentPosition.inMilliseconds.toDouble(),
                             max: (currentSongProvider.totalDuration ?? Duration.zero).inMilliseconds.toDouble(),
                             onChanged: (value) {
                               final newPosition = Duration(milliseconds: value.toInt());
                               currentSongProvider.audioHandler.seek(newPosition);
                             },
                           ),
                         ),
                       ),
                       Text(
                         _formatDuration(currentSongProvider.totalDuration ?? Duration.zero),
                         style: textTheme.bodySmall?.copyWith(
                           color: colorScheme.onSurface.withOpacity(0.7),
                           fontSize: 11,
                         ),
                       ),
                    ],
                  ),
                ],
              ),
            ),
            
                         // Right section - Placeholder for future volume control
             Expanded(
               flex: 1,
               child: Container(),
             ),
          ],
        ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
} 