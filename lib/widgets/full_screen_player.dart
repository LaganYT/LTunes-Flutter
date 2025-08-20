import 'dart:convert'; // For jsonEncode
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart'; // Ensure CurrentSongProvider is imported
import '../models/song.dart'; // Ensure Song model is imported
import '../models/lyrics_data.dart'; // Import LyricsData
import 'package:path_provider/path_provider.dart'; // For getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // For path joining
import 'dart:io'; // For File operations
import 'dart:async'; // For StreamSubscription and Timer
import 'package:shared_preferences/shared_preferences.dart'; // For SharedPreferences
import 'package:palette_generator/palette_generator.dart'; // Added for color extraction
import 'package:wakelock_plus/wakelock_plus.dart'; // <-- Add this import
import '../services/api_service.dart'; 
import '../screens/song_detail_screen.dart'; // For AddToPlaylistDialog
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart'; // Import for synced lyrics
import 'dart:math' as math; // Added for min/max in lyrics scroll
import 'package:cached_network_image/cached_network_image.dart'; // Added for CachedNetworkImageProvider
import 'playbar.dart'; // Import Playbar to access its state
import '../screens/audio_effects_screen.dart'; // Import AudioEffectsScreen
import '../services/sleep_timer_service.dart'; // Import SleepTimerService
import '../screens/album_screen.dart'; // Import AlbumScreen
import '../screens/artist_screen.dart'; // Import ArtistScreen
import '../services/animation_service.dart'; // Import AnimationService

// Helper class for parsed lyric lines
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});
}

class _QueueBottomSheetContent extends StatefulWidget {
  @override
  State<_QueueBottomSheetContent> createState() => _QueueBottomSheetContentState();
}

class _QueueBottomSheetContentState extends State<_QueueBottomSheetContent> {
  static const double itemHeight = 72.0;
  final Map<String, String> _artPathCache = {};
  bool _loading = true;
  final ScrollController _scrollController = ScrollController();
  String? _lastSongId; // Track last song ID for scroll logic
  bool _hasAutoScrolled = false; // Only scroll on first open

  @override
  void initState() {
    super.initState();
    _precacheArtPaths();
  }

  Future<void> _precacheArtPaths() async {
    final provider = Provider.of<CurrentSongProvider>(context, listen: false);
    final queue = List<Song>.from(provider.queue);
    for (final song in queue) {
      if (song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
        final path = await _resolveLocalArtPath(song.albumArtUrl);
        _artPathCache[song.id] = path;
      } else {
        _artPathCache[song.id] = '';
      }
    }
    if (mounted) setState(() { _loading = false; });
  }

  bool _isIndexVisible(int index) {
    if (!_scrollController.hasClients) return false;
    final double minVisible = _scrollController.offset;
    final double maxVisible = _scrollController.offset + (_scrollController.position.viewportDimension);
    final double itemTop = index * itemHeight;
    final double itemBottom = itemTop + itemHeight;
    return itemBottom > minVisible && itemTop < maxVisible;
  }

  void _maybeScrollToCurrentSong(List<Song> queue, Song? currentSong) {
    if (_hasAutoScrolled) return;
    final currentIndex = queue.indexWhere((s) => s.id == currentSong?.id);
    if (currentIndex != -1 && _scrollController.hasClients) {
      final offset = (currentIndex * itemHeight) - 100.0;
      _scrollController.animateTo(
        offset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
      _hasAutoScrolled = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CurrentSongProvider>(
      builder: (context, currentSongProvider, _) {
        final queue = List<Song>.from(currentSongProvider.queue);
        final currentSong = currentSongProvider.currentSong;
        final currentIndex = queue.indexWhere((s) => s.id == currentSong?.id);
        if (_artPathCache.length != queue.length && !_loading) {
          _loading = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _precacheArtPaths();
          });
        }
        if (_loading) {
          return const Center(child: CircularProgressIndicator());
        }
        final ColorScheme colorScheme = Theme.of(context).colorScheme;
        final TextTheme textTheme = Theme.of(context).textTheme;
        // Only scroll to current song the first time the sheet is opened
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _maybeScrollToCurrentSong(queue, currentSong);
        });
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (_, controller) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 8.0, 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Up Next',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (queue.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              currentSongProvider.clearQueue();
                              if (mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Queue cleared')),
                                );
                              }
                            },
                            child: Text(
                              'Clear Queue',
                              style: TextStyle(color: Theme.of(context).colorScheme.primary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (queue.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Queue is empty.',
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ReorderableListView.builder(
                        key: ValueKey(queue.map((s) => s.id).join(',')), // Force rebuild when queue order changes
                        buildDefaultDragHandles: false,
                        scrollController: _scrollController,
                        itemCount: queue.length,
                        itemBuilder: (BuildContext context, int index) {
                          final song = queue[index];
                          final bool isCurrentlyPlaying = song.id == currentSong?.id;
                          final String artPath = _artPathCache[song.id] ?? '';
                          Widget imageWidget;
                          if (song.albumArtUrl.startsWith('http')) {
                            imageWidget = Image.network(
                              song.albumArtUrl, width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                            );
                          } else if (artPath.isNotEmpty) {
                            imageWidget = Image.file(
                              File(artPath), width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                            );
                          } else {
                            imageWidget = const Icon(Icons.music_note, size: 40);
                          }
                          return SizedBox(
                            key: ValueKey(song.id),
                            height: itemHeight,
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: imageWidget,
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isCurrentlyPlaying ? FontWeight.bold : FontWeight.normal,
                                  color: isCurrentlyPlaying ? colorScheme.primary : colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                song.artist.isNotEmpty ? song.artist : "Unknown Artist",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isCurrentlyPlaying)
                                    AnimatedEqualizerIcon(isPlaying: currentSongProvider.isPlaying, color: colorScheme.primary),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 8.0),
                                      child: Icon(Icons.drag_handle, color: colorScheme.onSurface.withValues(alpha: 0.5)),
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () async {
                                final isPlaying = currentSongProvider.isPlaying;
                                await currentSongProvider.playWithContext(queue, song, playImmediately: isPlaying);
                                if (mounted) setState(() {}); // Update queue UI immediately
                                // Do not close the queue after selecting a song
                                // if (mounted) Navigator.pop(context);
                              },
                            ),
                          );
                        },
                        onReorder: (int oldIndex, int newIndex) async {
                          if (newIndex > oldIndex) newIndex -= 1;
                          await currentSongProvider.reorderQueue(oldIndex, newIndex);
                          // Remove manual setState - let the provider's notifyListeners() handle UI updates
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// Add this widget above _QueueBottomSheetContentState
class AnimatedEqualizerIcon extends StatefulWidget {
  final bool isPlaying;
  final Color color;
  const AnimatedEqualizerIcon({super.key, required this.isPlaying, required this.color});

  @override
  State<AnimatedEqualizerIcon> createState() => _AnimatedEqualizerIconState();
}

class _AnimatedEqualizerIconState extends State<AnimatedEqualizerIcon> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  static const int barCount = 3;
  static const double baseHeight = 10;
  static const double amplitude = 10;
  static const double minHeight = 8;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _updateAnimation();
  }

  void _updateAnimation() {
    final animationService = AnimationService.instance;
    if (widget.isPlaying && animationService.isAnimationEnabled(AnimationType.equalizerAnimations)) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedEqualizerIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _barHeight(int i, double t) {
    // t goes from 0 to 1, map to 0 to 2pi
    final double phase = i * 1.2; // phase offset for each bar
    final double wave = math.sin(2 * math.pi * t + phase);
    return minHeight + baseHeight + amplitude * wave;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 28,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(barCount, (i) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Container(
                  width: 4,
                  height: _barHeight(i, t),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

// Move this to the top level so it can be used by both classes
Future<String> _resolveLocalArtPath(String? fileName) async {
  if (fileName == null || fileName.isEmpty || fileName.startsWith('http')) {
    return '';
  }
  try {
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
  } catch (e) {
    debugPrint("Error resolving local art path: $e");
  }
  return '';
}

class FullScreenPlayer extends StatefulWidget {
  // Removed song parameter as Provider will supply the current song
  const FullScreenPlayer({super.key});

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer> with TickerProviderStateMixin {
  double _slideOffsetX = 0.0; // To control slide direction, 0.0 means no slide (fade in art)
  String? _previousSongId;
  double _verticalDragAccumulator = 0.0; // For swipe down to close gesture

  late AnimationController _textFadeController;
  late Animation<double> _textFadeAnimation;

  late AnimationController _albumArtSlideController;
  late Animation<Offset> _albumArtSlideAnimation;
  
  // New animation controllers for enhanced opening animation
  late AnimationController _scaleController;
  late AnimationController _slideController;
  late AnimationController _backgroundController;
  late AnimationController _rotationController;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _backgroundAnimation;
  late Animation<double> _rotationAnimation;

  late CurrentSongProvider _currentSongProvider;
  late ApiService _apiService;
  final SleepTimerService _sleepTimerService = SleepTimerService();

  Color _dominantColor = Colors.transparent;

  // Lyrics State
  bool _showLyrics = false;
  List<LyricLine> _parsedLyrics = [];
  int _currentLyricIndex = -1;
  bool _areLyricsSynced = false; 
  bool _lyricsLoading = false;
  bool _lyricsFetchedForCurrentSong = false;

  final ItemScrollController _lyricsScrollController = ItemScrollController();
  final ItemPositionsListener _lyricsPositionsListener = ItemPositionsListener.create();

  bool _isLiked = false;
  Future<String>? _localArtPathFuture;

  // New state for seek bar
  double? _sliderValue;
  bool _isSeeking = false;

  ImageProvider? _currentArtProvider;
  String? _currentArtId;
  bool _artLoading = false;

  // 1. Add a palette cache at the top of _FullScreenPlayerState
  final Map<String, Color> _paletteCache = {}; // Palette cache by song ID
  // 3. Throttle for lyrics index update
  final int _lastLyricUpdate = 0;
  int _artTransitionId = 0; // Unique id for each album art transition

  // Lyrics animation controllers
  late AnimationController _lyricTransitionController;
  late AnimationController _lyricHighlightController;
  late Animation<double> _lyricTransitionAnimation;
  late Animation<double> _lyricHighlightAnimation;
  
  // Track previous lyric index for smooth transitions
  int _previousLyricIndex = -1;
  final Map<int, AnimationController> _lyricLineControllers = {};
  
  // Debounce timer for lyrics toggle button to prevent spam
  Timer? _lyricsToggleDebounceTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // Prevent sleep when player is open
    _apiService = ApiService();

    _textFadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _textFadeAnimation = CurvedAnimation(
      parent: _textFadeController,
      curve: Curves.easeOut,
    );

    _albumArtSlideController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );

    // Initialize with a default slide animation (e.g., no slide initially)
    _albumArtSlideAnimation = Tween<Offset>(
      begin: Offset.zero, // Initial song won't slide with _slideOffsetX = 0.0
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _albumArtSlideController,
      curve: Curves.easeInOut,
    ));

    // Initialize new animation controllers for enhanced opening animation
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 700),
      vsync: this,
    );

    _backgroundController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _rotationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    // Enhanced opening animations
    _scaleAnimation = Tween<double>(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOutBack,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutQuart,
    ));

    _backgroundAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _backgroundController,
      curve: Curves.easeOut,
    ));

    _rotationAnimation = Tween<double>(
      begin: -0.05,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _rotationController,
      curve: Curves.easeOutCubic,
    ));

    // Initialize lyrics animation controllers
    _lyricTransitionController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _lyricTransitionAnimation = CurvedAnimation(
      parent: _lyricTransitionController,
      curve: Curves.easeInOut,
    );

    _lyricHighlightController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _lyricHighlightAnimation = CurvedAnimation(
      parent: _lyricHighlightController,
      curve: Curves.easeOut,
    );

    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    _previousSongId = _currentSongProvider.currentSong?.id;
    
    // Initialize sleep timer service
    if (!_sleepTimerService.isInitialized) {
      _sleepTimerService.initialize(_currentSongProvider);
    }
    _sleepTimerService.setCallbacks(
      onTimerUpdate: () {
        if (mounted) setState(() {});
      },
      onTimerExpired: () {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sleep timer expired. Playback stopped.')),
          );
        }
      },
    );

    if (_currentSongProvider.currentSong != null) {
      _localArtPathFuture = _resolveLocalArtPath(_currentSongProvider.currentSong!.albumArtUrl);
    }

    // Initial lyrics state reset (lyrics will be loaded on demand or if _showLyrics is true)
    _resetLyricsState();

    if (_currentSongProvider.currentSong != null) {
      // Enhanced initial appearance with staggered animations
      _startOpeningAnimation();
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updatePalette(_currentSongProvider.currentSong);
      }
    });

    _currentSongProvider.addListener(_onSongChanged);
    _loadLikeState(); // load initial like state
    
    final song = _currentSongProvider.currentSong;
    if (song != null) {
      // Try to use playbar's artwork immediately if available
      final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
      final playbarArtId = PlaybarState.getCurrentArtworkId();
      
      if (playbarArtProvider != null && playbarArtId == song.id && !PlaybarState.isArtworkLoading()) {
        _currentArtProvider = playbarArtProvider;
        _currentArtId = song.id;
        _artLoading = false;
      } else {
        _updateArtProvider(song);
      }
    }

  }

  Future<void> _updateArtProvider(Song song) async {
    if (mounted) setState(() { _artLoading = true; });
    
    // Try to get the artwork from the playbar first
    final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
    final playbarArtId = PlaybarState.getCurrentArtworkId();
    
    // If the playbar has the same artwork loaded, use it
    if (playbarArtProvider != null && playbarArtId == song.id) {
      _currentArtProvider = playbarArtProvider;
      _currentArtId = song.id;
      if (mounted) setState(() { _artLoading = false; });
      return;
    }
    
    // Otherwise, load the artwork as before
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


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    _currentSongProvider.addListener(_onSongChanged);
    final song = _currentSongProvider.currentSong;
    if (song != null) {
      // Try to use playbar's artwork immediately if available
      final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
      final playbarArtId = PlaybarState.getCurrentArtworkId();
      
      if (playbarArtProvider != null && playbarArtId == song.id && !PlaybarState.isArtworkLoading()) {
        _currentArtProvider = playbarArtProvider;
        _currentArtId = song.id;
        _artLoading = false;
      } else {
        _updateArtProvider(song);
      }
    }
  }

  void _resetLyricsState() {
    if (mounted) {
      setState(() {
        _parsedLyrics = [];
        _currentLyricIndex = -1;
        _previousLyricIndex = -1; // Reset previous index
        _areLyricsSynced = false;
        _lyricsFetchedForCurrentSong = false;
        _lyricsLoading = false;
        // _showLyrics remains as is, or reset if desired:
        // _showLyrics = false; 
      });
      
      // Reset animation controllers
      _lyricTransitionController.reset();
      _lyricHighlightController.reset();
      
      // Dispose and clear individual lyric line controllers
      for (final controller in _lyricLineControllers.values) {
        controller.dispose();
      }
      _lyricLineControllers.clear();
    }
  }

  // Enhanced opening animation method
  void _startOpeningAnimation() {
    final animationService = AnimationService.instance;
    
    if (!animationService.isAnimationEnabled(AnimationType.songChangeAnimations)) {
      // Skip animations if disabled
      _backgroundController.value = 1.0;
      _scaleController.value = 1.0;
      _slideController.value = 1.0;
      _rotationController.value = 1.0;
      _textFadeController.value = 1.0;
      return;
    }
    
    // Start all animations simultaneously for a more cohesive feel
    _backgroundController.forward();
    _scaleController.forward();
    _slideController.forward();
    _rotationController.forward();
    
    // Stagger the text fade animation with longer delay for smoother feel
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _textFadeController.forward();
      }
    });
  }

  // Enhanced song change animation method
  void _startSongChangeAnimation(double slideOffsetX) {
    final animationService = AnimationService.instance;
    
    if (!animationService.isAnimationEnabled(AnimationType.songChangeAnimations)) {
      // Skip animations if disabled
      _backgroundController.value = 1.0;
      _scaleController.value = 1.0;
      _slideController.value = 1.0;
      _rotationController.value = 1.0;
      _textFadeController.value = 1.0;
      return;
    }
    
    // Reset and start background animation immediately
    _backgroundController.reset();
    _backgroundController.forward();
    
    // Reset and start scale animation
    _scaleController.reset();
    _scaleController.forward();
    
    // Reset and start slide animation with horizontal direction
    _slideController.reset();
    _slideAnimation = Tween<Offset>(
      begin: Offset(slideOffsetX, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutQuart,
    ));
    _slideController.forward();
    
    // Reset and start rotation animation
    _rotationController.reset();
    _rotationController.forward();
    
    // Reset and start text fade animation with longer delay for smoother feel
    _textFadeController.reset();
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _textFadeController.forward();
      }
    });
  }

  // 2. Batch setState in _onSongChanged and other methods
  void _onSongChanged() async {
    if (!mounted) return;

    final newSong = _currentSongProvider.currentSong;
    final newSongId = newSong?.id;

    // Only update if the song ID actually changed
    if (newSongId != _previousSongId) {
      double effectiveSlideOffsetX = _slideOffsetX;
      if (_previousSongId == null && newSongId != null) {
        effectiveSlideOffsetX = 0.3;
      } else if (_slideOffsetX == 0.0 && newSongId != null) {
        effectiveSlideOffsetX = 0.3;
      }

      if (newSong != null) {
        _localArtPathFuture = _resolveLocalArtPath(newSong.albumArtUrl);
        
        // Try to use playbar's artwork immediately if available
        final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
        final playbarArtId = PlaybarState.getCurrentArtworkId();
        
        if (playbarArtProvider != null && playbarArtId == newSong.id && !PlaybarState.isArtworkLoading()) {
          _currentArtProvider = playbarArtProvider;
          _currentArtId = newSong.id;
          _artLoading = false;
        } else {
          // Preload the new art provider and only then animate
          await _updateArtProvider(newSong);
        }
      }

      // Use enhanced animations for song changes
      _startSongChangeAnimation(effectiveSlideOffsetX);

      if (mounted) _updatePalette(newSong);
      _resetLyricsState();

      final provider = Provider.of<CurrentSongProvider>(context, listen: false);
      final currentSong = provider.currentSong;
      if (currentSong != null && currentSong.isDownloaded) {
        provider.updateMissingMetadata(currentSong);
      }

      if (_showLyrics && newSong != null) {
        _loadAndProcessLyrics(newSong);
      }

      if (_lyricsScrollController.isAttached) {
        _lyricsScrollController.jumpTo(index: 0);
      }

      if (mounted) {
        setState(() {
          _previousSongId = newSongId;
          _slideOffsetX = 0.0;
          _artTransitionId++; // Increment transition id for each song change
        });
      }
      _loadLikeState();
    }
  }

  // New method to fetch and save lyrics for a downloaded song
  // ignore: unused_element
  Future<void> _fetchAndSaveLyricsForSong(Song song) async {
    // Early exit if song is no longer current or widget is unmounted.
    if (!mounted || _currentSongProvider.currentSong?.id != song.id) {
      return;
    }

    debugPrint("Auto-fetching lyrics for downloaded song: ${song.title}");
    try {
      LyricsData? lyricsData = await _apiService.fetchLyrics(song.artist, song.title);

      // Check again if still mounted, song is current, and lyrics were actually found.
      if (mounted &&
          _currentSongProvider.currentSong?.id == song.id &&
          lyricsData != null &&
          (lyricsData.syncedLyrics?.isNotEmpty == true || lyricsData.plainLyrics?.isNotEmpty == true)) {
        
        // Assumes CurrentSongProvider.updateSongLyrics updates the song, persists, and notifies.
        await _currentSongProvider.updateSongLyrics(song.id, lyricsData);
        debugPrint("Lyrics auto-downloaded and saved for ${song.title}");

        // If lyrics view is active for this song, refresh it.
        // The provider's notification should ideally handle updating the song instance.
        // Calling _loadAndProcessLyrics ensures the view updates with new local lyrics.
        if (_showLyrics) {
          final potentiallyUpdatedSong = _currentSongProvider.currentSong;
          if (potentiallyUpdatedSong != null && potentiallyUpdatedSong.id == song.id) {
             _loadAndProcessLyrics(potentiallyUpdatedSong);
          }
        }
      } else if (lyricsData == null || (lyricsData.syncedLyrics?.isEmpty ?? true) && (lyricsData.plainLyrics?.isEmpty ?? true)) {
        debugPrint("No lyrics found (auto-fetch) for ${song.title}");
      }
    } catch (e) {
      debugPrint("Error auto-fetching lyrics for ${song.title}: $e");
    }
  }

  Future<void> _loadAndProcessLyrics(Song currentSong) async {
    if (!mounted) return;
    setState(() {
      _lyricsLoading = true;
      _parsedLyrics = []; 
      _currentLyricIndex = -1;
      _areLyricsSynced = false;
      // _lyricsFetchedForCurrentSong is reset in _resetLyricsState.
      // It will be set to true in the finally block or if local lyrics are found.
    });

    // Check for local lyrics first
    // currentSong should be the latest instance from the provider if a rebuild occurred.
    if ((currentSong.syncedLyrics != null && currentSong.syncedLyrics!.isNotEmpty) ||
        (currentSong.plainLyrics != null && currentSong.plainLyrics!.isNotEmpty)) {
      debugPrint("Using local lyrics for ${currentSong.title}");
      final localLyricsData = LyricsData(
        plainLyrics: currentSong.plainLyrics,
        syncedLyrics: currentSong.syncedLyrics,
      );
      _processLyricsForSongData(localLyricsData);
      if (mounted) {
        setState(() {
          _lyricsLoading = false;
          _lyricsFetchedForCurrentSong = true;
        });
      }
      return;
    }

    // If no local lyrics, fetch from API
    debugPrint("Fetching lyrics from API for ${currentSong.title}");
    LyricsData? lyricsData;
    try {
      lyricsData = await _apiService.fetchLyrics(currentSong.artist, currentSong.title);
      
      // If lyrics were fetched from API, are not empty, and the song is downloaded, save them.
      if (lyricsData != null &&
          (lyricsData.syncedLyrics?.isNotEmpty == true || lyricsData.plainLyrics?.isNotEmpty == true) &&
          currentSong.isDownloaded) {
        
        debugPrint("Lyrics fetched via API for downloaded song ${currentSong.title}. Saving them.");
        // Assumes CurrentSongProvider.updateSongLyrics updates the song, persists, and notifies.
        await _currentSongProvider.updateSongLyrics(currentSong.id, lyricsData);
      }
      
      _processLyricsForSongData(lyricsData);
    } catch (e) {
      debugPrint("Error loading lyrics in FullScreenPlayer: $e");
      _processLyricsForSongData(null); // Process with null to clear lyrics and show "not available"
    } finally {
      if (mounted) {
        setState(() {
          _lyricsLoading = false;
          _lyricsFetchedForCurrentSong = true; 
        });
      }
    }
  }

  void _processLyricsForSongData(LyricsData? lyricsData) {
    List<LyricLine> tempParsedLyrics = [];
    bool tempAreLyricsSynced = false;

    if (lyricsData?.syncedLyrics != null && lyricsData!.syncedLyrics!.isNotEmpty) {
      tempParsedLyrics = _parseSyncedLyrics(lyricsData.syncedLyrics!);
      if (tempParsedLyrics.isNotEmpty) {
        tempAreLyricsSynced = true;
      }
    }

    if (!tempAreLyricsSynced && lyricsData?.plainLyrics != null && lyricsData!.plainLyrics!.isNotEmpty) {
      tempParsedLyrics = _parsePlainLyrics(lyricsData.plainLyrics!);
    }

    if (mounted) {
      setState(() {
        _parsedLyrics = tempParsedLyrics;
        _areLyricsSynced = tempAreLyricsSynced;
        // Clamp _currentLyricIndex to -1 or valid range
        if (_currentLyricIndex >= _parsedLyrics.length) {
          _currentLyricIndex = _parsedLyrics.isEmpty ? -1 : _parsedLyrics.length - 1;
        }
        if (_currentLyricIndex < -1) _currentLyricIndex = -1;
      });
      
      // Trigger entrance animation for new lyrics
      if (tempParsedLyrics.isNotEmpty) {
        _triggerLyricsEntranceAnimation();
      }
    }
  }


  // void _processLyricsForSong(Song? song) { // Replaced by _loadAndProcessLyrics & _processLyricsForSongData
  //   List<LyricLine> tempParsedLyrics = [];
  //   bool tempAreLyricsSynced = false;

  //   if (song?.syncedLyrics != null && song!.syncedLyrics!.isNotEmpty) {
  //     tempParsedLyrics = _parseSyncedLyrics(song.syncedLyrics!);
  //     if (tempParsedLyrics.isNotEmpty) {
  //       tempAreLyricsSynced = true;
  //     }
  //   }

  //   // If synced lyrics parsing failed or synced lyrics were not available, try plain lyrics
  //   if (!tempAreLyricsSynced && song?.plainLyrics != null && song!.plainLyrics!.isNotEmpty) {
  //     tempParsedLyrics = _parsePlainLyrics(song.plainLyrics!);
  //     // tempAreLyricsSynced remains false for plain lyrics
  //   }

  //   if (mounted) {
  //     setState(() {
  //       _parsedLyrics = tempParsedLyrics;
  //       _currentLyricIndex = -1; // Reset for new lyrics
  //       _areLyricsSynced = tempAreLyricsSynced;
  //       if (_parsedLyrics.isEmpty) {
  //         _showLyrics = false; // Automatically hide lyrics view if no lyrics are available
  //       }
  //     });
  //   }
  // }

  List<LyricLine> _parseSyncedLyrics(String lrcContent) {
    final List<LyricLine> lines = [];
    final RegExp lrcLineRegex = RegExp(r"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)");
    final List<String> lrcLines = lrcContent.split('\n');

    for (String line in lrcLines) {
      final matches = lrcLineRegex.firstMatch(line);
      if (matches != null) {
        final minutes = int.parse(matches.group(1)!);
        final seconds = int.parse(matches.group(2)!);
        final milliseconds = int.parse(matches.group(3)!);
        final text = matches.group(4)!.trim();
        if (text.isNotEmpty) {
          lines.add(LyricLine(
            timestamp: Duration(minutes: minutes, seconds: seconds, milliseconds: milliseconds),
            text: text,
          ));
        }
      }
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  List<LyricLine> _parsePlainLyrics(String plainContent) {
    final List<LyricLine> lines = [];
    final List<String> plainLines = plainContent.split('\n');
    for (String text in plainLines) {
      if (text.trim().isNotEmpty) {
        lines.add(LyricLine(timestamp: Duration.zero, text: text.trim()));
      }
    }
    return lines;
  }

  // 8. Debounce album art/palette updates: add a debounce for _updatePalette
  Timer? _paletteDebounce;
  Future<void> _updatePalette(Song? song) async {
    if (song == null) {
      // Set a default color when no song is available
      if (mounted) {
        setState(() {
          _dominantColor = Theme.of(context).colorScheme.surface;
        });
      }
      return;
    }
    
    if (song.albumArtUrl.isEmpty) {
      // Set a default color when no album art is available
      if (mounted) {
        setState(() {
          _dominantColor = Theme.of(context).colorScheme.primaryContainer;
        });
      }
      return;
    }
    if (_paletteCache.containsKey(song.id)) {
      setState(() {
        _dominantColor = _paletteCache[song.id]!;
      });
      return;
    }
    _paletteDebounce?.cancel();
    _paletteDebounce = Timer(const Duration(milliseconds: 150), () async {
      ImageProvider provider;
      if (song.albumArtUrl.startsWith('http')) {
        provider = NetworkImage(song.albumArtUrl);
      } else {
        final path = await _resolveLocalArtPath(song.albumArtUrl);
        if (path.isEmpty) return;
        provider = FileImage(File(path));
      }
      try {
        final palette = await PaletteGenerator.fromImageProvider(provider);
        final baseColor = palette.dominantColor?.color ?? Theme.of(context).colorScheme.surface;
        final hsl = HSLColor.fromColor(baseColor);
        final Brightness currentBrightness = Theme.of(context).brightness;
        final bool isDarkMode = currentBrightness == Brightness.dark;
        
        // Make the color more vibrant and noticeable
        final adjustedColor = hsl
            .withSaturation((hsl.saturation * 1.2).clamp(0.0, 1.0)) // Increase saturation
            .withLightness(isDarkMode ? 0.15 : 0.85) // Slightly more contrast
            .toColor();
            
        _paletteCache[song.id] = adjustedColor;
        if (mounted) setState(() { _dominantColor = adjustedColor; });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Allow sleep when player is closed
    _currentSongProvider.removeListener(_onSongChanged);
    
    // Clear sleep timer callbacks
    _sleepTimerService.clearCallbacks();

    _textFadeController.dispose();
    _albumArtSlideController.dispose();
    _scaleController.dispose();
    _slideController.dispose();
    _backgroundController.dispose();
    _rotationController.dispose();
    
    // Dispose lyrics animation controllers
    _lyricTransitionController.dispose();
    _lyricHighlightController.dispose();
    
    // Dispose individual lyric line controllers
    for (final controller in _lyricLineControllers.values) {
      controller.dispose();
    }
    _lyricLineControllers.clear();
    
    // Cancel palette debounce timer if active
    _paletteDebounce?.cancel();
    
    // Cancel lyrics toggle debounce timer if active
    _lyricsToggleDebounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _downloadCurrentSong(Song song) async {
    // Use the CurrentSongProvider to handle the download
    if (mounted && context.mounted) {
      Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);

      // Show a snackbar indicating the download has started
      // You might want to check if the song is already downloading via provider state
      // to avoid redundant messages, but downloadSongInBackground itself has checks.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download started for "${song.title}"...')),
      );
    }
  }

  // ignore: unused_element
  Future<void> _saveSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('song_${song.id}', jsonEncode(song.toJson()));
  }

  Future<String> _resolveLocalArtPath(String? fileName) async {
    if (fileName == null || fileName.isEmpty || fileName.startsWith('http')) {
      return '';
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        return fullPath;
      }
    } catch (e) {
      debugPrint("Error resolving local art path for full screen player: $e");
    }
    return '';
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '0:00';
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _showQueueBottomSheet(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final queue = currentSongProvider.queue;
    final currentSong = currentSongProvider.currentSong;
    final int currentIndex = queue.indexWhere((s) => s.id == currentSong?.id);
    const double itemHeight = 72.0; // Estimated height for a two-line ListTile

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, // Make sheet background transparent
      builder: (BuildContext bc) {
        // Use the reorderable queue UI
        return _QueueBottomSheetContent();
      },
    );
  }

  // Added method to show "Add to Playlist" dialog
  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        // Assuming AddToPlaylistDialog is accessible and correctly defined
        // in song_detail_screen.dart or a shared widgets file.
        return AddToPlaylistDialog(song: song);
      },
    );
  }

  // ignore: unused_element
  void _updateCurrentLyricIndex(Duration currentPosition) {
    if (!_areLyricsSynced || _parsedLyrics.isEmpty) { 
      if (_currentLyricIndex != -1 && _areLyricsSynced) { // Reset if they were synced but now aren't or are empty
         if (mounted) {
            setState(() {
              _currentLyricIndex = -1;
            });
         }
      }
      return;
    }

    int newIndex = -1;
    for (int i = 0; i < _parsedLyrics.length; i++) {
      if (currentPosition >= _parsedLyrics[i].timestamp) {
        if (i + 1 < _parsedLyrics.length) {
          if (currentPosition < _parsedLyrics[i + 1].timestamp) {
            newIndex = i;
            break;
          }
        } else {
          // Last lyric line
          newIndex = i;
          break;
        }
      }
    }

    if (newIndex != _currentLyricIndex) {
      // Store previous index for animation transitions
      _previousLyricIndex = _currentLyricIndex;
      
      setState(() {
        _currentLyricIndex = newIndex;
      });
      
      // Trigger lyric transition animations
      if (newIndex != -1) {
        _triggerLyricTransitionAnimation(newIndex);
      }
      
      if (newIndex != -1 && _lyricsScrollController.isAttached) {
        // Do not auto-scroll for the first 3 lines
        if (newIndex >= 3) {
          _lyricsScrollController.scrollTo(
            index: newIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: 0.5,
          );
        }
      }
    }
  }

  // Trigger entrance animation when lyrics are first loaded
  void _triggerLyricsEntranceAnimation() {
    final animationService = AnimationService.instance;
    
    if (!animationService.isAnimationEnabled(AnimationType.lyricsAnimations)) {
      // Skip animations if disabled
      _lyricTransitionController.value = 1.0;
      _lyricHighlightController.value = 1.0;
      return;
    }
    
    // Reset animation controllers
    _lyricTransitionController.reset();
    _lyricHighlightController.reset();
    
    // Start a subtle entrance animation
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _lyricTransitionController.forward();
      }
    });
  }

  // Trigger animations when lyric index changes
  void _triggerLyricTransitionAnimation(int newIndex) {
    final animationService = AnimationService.instance;
    
    if (!animationService.isAnimationEnabled(AnimationType.lyricsAnimations)) {
      // Skip animations if disabled
      _lyricTransitionController.value = 1.0;
      _lyricHighlightController.value = 1.0;
      if (_lyricLineControllers.containsKey(newIndex)) {
        _lyricLineControllers[newIndex]!.value = 1.0;
      }
      return;
    }
    
    // Reset and start the main transition animation
    _lyricTransitionController.reset();
    _lyricTransitionController.forward();
    
    // Reset and start the highlight animation
    _lyricHighlightController.reset();
    _lyricHighlightController.forward();
    
    // Create or update individual lyric line controllers
    if (!_lyricLineControllers.containsKey(newIndex)) {
      _lyricLineControllers[newIndex] = AnimationController(
        duration: const Duration(milliseconds: 500),
        vsync: this,
      );
    }
    
    // Start the individual line animation
    _lyricLineControllers[newIndex]!.reset();
    _lyricLineControllers[newIndex]!.forward();
  }

  // Add missing seek bar handlers
  void _onSeekStart() {
    setState(() => _isSeeking = true);
  }
  void _onSeekChange(double value) {
    setState(() => _sliderValue = value);
  }
  Future<void> _onSeekEnd(double value) async {
    setState(() {
      _isSeeking = false;
      _sliderValue = null;
    });
    await _currentSongProvider.seek(Duration(milliseconds: value.round()));
  }

  Future<void> _loadLikeState() async {
    final prefs = await SharedPreferences.getInstance();
    final liked = prefs.getStringList('liked_songs') ?? [];
    final id = _currentSongProvider.currentSong?.id;
    setState(() {
      _isLiked = id != null && liked.any((s) {
        try {
          return Song.fromJson(jsonDecode(s) as Map<String, dynamic>).id == id;
        } catch (_) {
          return false;
        }
      });
    });
  }

  Future<void> _toggleLike() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('liked_songs') ?? [];
    final song = _currentSongProvider.currentSong!;
    final jsonStr = jsonEncode(song.toJson());
    if (_isLiked) {
      // unlike: just remove from liked list
      list.removeWhere((s) {
        try {
          return Song.fromJson(jsonDecode(s) as Map<String, dynamic>).id == song.id;
        } catch (_) {
          return false;
        }
      });
    } else {
      // like: add and queue if auto-download enabled
      list.add(jsonStr);
      final bool autoDL = prefs.getBool('autoDownloadLikedSongs') ?? false;
      if (autoDL && mounted && context.mounted) {
        Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);
      }
    }
    await prefs.setStringList('liked_songs', list);
    setState(() => _isLiked = !_isLiked);
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = _currentSongProvider; // Use cached provider
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoading = currentSongProvider.isLoadingAudio;
    final bool isRadio = currentSongProvider.isCurrentlyPlayingRadio;
    final LoopMode loopMode = currentSongProvider.loopMode;

    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    // Fallback UI if no song is loaded
    if (currentSong == null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Close Player',
          ),
        ),
        body: const Center(child: Text('No song selected.')),
      );
    }

    final albumArtWidget = _buildAlbumArtWidget(currentSong, isRadio);

    // Determine if lyrics should be shown (only if available and toggle is on)
    // final bool canShowLyrics = _parsedLyrics.isNotEmpty && _showLyrics; // Old logic

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Close Player',
        ),
        title: isRadio 
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Playing From Radio', style: TextStyle(fontSize: 12)),
                  if (currentSongProvider.stationName != null)
                    Text(currentSongProvider.stationName!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              )
            : null,
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More Options',
            onSelected: (value) {
              switch (value) {
                case 'view_album':
                  if (currentSong.album?.isNotEmpty == true) {
                    _viewAlbum(context, currentSong);
                  }
                  break;
                case 'view_artist':
                  if (currentSong.artist.isNotEmpty) {
                    _viewArtist(context, currentSong);
                  }
                  break;
                case 'audio_effects':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const AudioEffectsScreen(),
                    ),
                  );
                  break;
                case 'sleep_timer':
                  _showSleepTimerDialog(context);
                  break;
                case 'cancel_sleep_timer':
                  _sleepTimerService.cancelTimer();
                  break;
              }
            },
            itemBuilder: (BuildContext context) => [
              if (currentSong.album?.isNotEmpty == true)
                const PopupMenuItem<String>(
                  value: 'view_album',
                  child: Row(
                    children: [
                      Icon(Icons.album),
                      SizedBox(width: 8),
                      Text('View Album'),
                    ],
                  ),
                ),
              if (currentSong.artist.isNotEmpty)
                const PopupMenuItem<String>(
                  value: 'view_artist',
                  child: Row(
                    children: [
                      Icon(Icons.person),
                      SizedBox(width: 8),
                      Text('View Artist'),
                    ],
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'audio_effects',
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq),
                    SizedBox(width: 8),
                    Text('Audio Effects'),
                  ],
                ),
              ),
              if (_sleepTimerService.sleepTimerEndTime == null)
                const PopupMenuItem<String>(
                  value: 'sleep_timer',
                  child: Row(
                    children: [
                      Icon(Icons.timer),
                      SizedBox(width: 8),
                      Text('Sleep Timer'),
                    ],
                  ),
                )
              else
                PopupMenuItem<String>(
                  value: 'cancel_sleep_timer',
                  child: Row(
                    children: [
                      const Icon(Icons.timer_off),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Cancel Sleep Timer'),
                            Text(
                              'Ends at ${_sleepTimerService.getEndTimeString()}',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: GestureDetector( 
        onVerticalDragUpdate: (details) {
          // Accumulate drag distance when dragging downwards
          if (details.delta.dy > 0) {
            _verticalDragAccumulator += details.delta.dy;
          } else if (details.delta.dy < 0) {
            // If dragging back upwards, reduce accumulator, but not below zero
            _verticalDragAccumulator = (_verticalDragAccumulator + details.delta.dy).clamp(0.0, double.infinity);
          }
        },
        onVerticalDragEnd: (details) {
          final double screenHeight = MediaQuery.of(context).size.height;
          // Threshold for closing: drag > 20% of screen height with sufficient velocity
          if (_verticalDragAccumulator > screenHeight * 0.2 && (details.primaryVelocity ?? 0) > 250) {
            Navigator.of(context).pop();
          }
          _verticalDragAccumulator = 0.0; // Reset accumulator
        },
        // Setting behavior to opaque to ensure it participates in hit testing across its area
        // and doesn't let touches pass through to widgets below if it's layered.
                behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _backgroundController,
          builder: (context, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _dominantColor.withValues(alpha: _backgroundAnimation.value * 0.9),
                    _dominantColor.withValues(alpha: _backgroundAnimation.value * 0.5),
                    _dominantColor.withValues(alpha: _backgroundAnimation.value * 0.3),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0) + EdgeInsets.only(top: MediaQuery.of(context).padding.top + 16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    // Album Art Section OR Lyrics Section with Fade Transition
                    Expanded(
                      flex: 7,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: _showLyrics
                            ? (_lyricsLoading
                                ? const Center(
                                    key: ValueKey('lyrics_loading'),
                                    child: CircularProgressIndicator(),
                                  )
                                : (_parsedLyrics.isNotEmpty
                                    ? _buildLyricsView(context)
                                    : Center(
                                        key: ValueKey('lyrics_empty'),
                                        child: Text(
                                          _lyricsFetchedForCurrentSong ? "No lyrics available." : "Loading lyrics...",
                                          style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.7)),
                                          textAlign: TextAlign.center,
                                        ),
                                      )
                                  )
                              )
                            : GestureDetector(
                                key: const ValueKey('album_art'),
                                onHorizontalDragEnd: (details) {
                                  if (details.primaryVelocity == null) return; // Should not happen

                                  // Swipe Left (finger moves from right to left) -> Next Song
                                  if (details.primaryVelocity! < -200) { // Negative velocity for left swipe
                                    _slideOffsetX = 1.0; // New art slides in from right
                                    currentSongProvider.playNext();
                                  }
                                  // Swipe Right (finger moves from left to right) -> Previous Song
                                  else if (details.primaryVelocity! > 200) { // Positive velocity for right swipe
                                    _slideOffsetX = -1.0; // New art slides in from left
                                    currentSongProvider.playPrevious();
                                  }
                                },
                                // Ensure this GestureDetector also claims the gesture space over the album art.
                                behavior: HitTestBehavior.opaque,
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: AnimatedBuilder(
                                      animation: Listenable.merge([_scaleController, _slideController, _rotationController]),
                                      builder: (context, child) {
                                        return Transform.scale(
                                          scale: _scaleAnimation.value,
                                          child: Transform.rotate(
                                            angle: _rotationAnimation.value,
                                            child: SlideTransition(
                                              position: _slideAnimation,
                                              child: Hero(
                                                tag: 'current-song-art-$_artTransitionId',
                                                child: Material(
                                                  elevation: 12.0,
                                                  borderRadius: BorderRadius.circular(16.0),
                                                  shadowColor: Colors.black.withValues(alpha: 0.5),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(16.0),
                                                    child: albumArtWidget,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),

                    // Song Info Section
                    Expanded(
                      flex: 2,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          FadeTransition(
                            opacity: _textFadeAnimation,
                            child: Text(
                              currentSong.title,
                              key: ValueKey<String>('title_${currentSong.id}'),
                              style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FadeTransition(
                            opacity: _textFadeAnimation,
                            child: Text(
                              isRadio ? (currentSong.artist.isNotEmpty ? currentSong.artist : "Live Radio") : (currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist'),
                              key: ValueKey<String>('artist_${currentSong.id}'),
                              style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.7)),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Action Icons Row (shown at bottom)
                    if (!isRadio)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Download button
                            if (currentSong.isDownloaded)
                              IconButton(
                                icon: const Icon(Icons.check_circle_outline_rounded),
                                tooltip: 'Downloaded',
                                onPressed: null, // Disabled as it's already downloaded
                                iconSize: 26.0,
                                color: colorScheme.secondary,
                              )
                            else
                              IconButton(
                                icon: const Icon(Icons.download_rounded),
                                onPressed: () => _downloadCurrentSong(currentSong),
                                tooltip: 'Download Song',
                                iconSize: 26.0,
                                color: colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            // Add to Playlist
                            IconButton(
                              icon: const Icon(Icons.playlist_add_rounded),
                              onPressed: () => _showAddToPlaylistDialog(context, currentSong),
                              tooltip: 'Add to Playlist',
                              iconSize: 26.0,
                              color: colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            // Like button
                            IconButton(
                              icon: Icon(_isLiked ? Icons.favorite : Icons.favorite_border),
                              onPressed: _toggleLike,
                              tooltip: _isLiked ? 'Unlike' : 'Like',
                              iconSize: 26.0,
                              color: _isLiked ? colorScheme.secondary : colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            // Lyrics toggle
                            IconButton(
                              icon: Icon(_showLyrics ? Icons.music_note_rounded : Icons.lyrics_outlined),
                              onPressed: () {
                                // Debounce to prevent spam
                                if (_lyricsToggleDebounceTimer?.isActive == true) {
                                  return;
                                }
                                
                                final song = _currentSongProvider.currentSong;
                                if (song == null) return;
                                
                                bool newShowLyricsState = !_showLyrics;
                                if (newShowLyricsState && !_lyricsFetchedForCurrentSong) {
                                  _loadAndProcessLyrics(song);
                                }
                                
                                setState(() {
                                  _showLyrics = newShowLyricsState;
                                });
                                
                                // Set debounce timer to prevent rapid toggling
                                _lyricsToggleDebounceTimer = Timer(const Duration(milliseconds: 300), () {
                                  _lyricsToggleDebounceTimer = null;
                                });
                              },
                              iconSize: 26.0,
                              tooltip: _showLyrics ? 'Hide Lyrics' : 'Show Lyrics',
                              color: colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            // Queue
                            IconButton(
                              icon: const Icon(Icons.playlist_play_rounded),
                              onPressed: () => _showQueueBottomSheet(context),
                              tooltip: 'Show Queue',
                              iconSize: 26.0,
                              color: colorScheme.onSurface.withValues(alpha: 0.7),
                            ),

                          ],
                        ),
                      ),

                    // Seek Bar Section
                    _buildSeekBar(currentSongProvider, isRadio, textTheme),
                    const SizedBox(height: 16),

                    // Controls Section
                    Row(
                      mainAxisAlignment: isRadio
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.spaceBetween,
                      children: [
                        if (!isRadio)
                          Consumer<CurrentSongProvider>(
                            builder: (context, provider, _) => IconButton(
                              icon: Icon(
                                provider.isShuffling ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                                color: provider.isShuffling ? colorScheme.secondary : colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                              iconSize: 26,
                              onPressed: () => provider.toggleShuffle(),
                              tooltip: provider.isShuffling ? 'Shuffle On' : 'Shuffle Off',
                            ),
                          ),
                        if (!isRadio)
                          IconButton(
                           icon: const Icon(Icons.skip_previous_rounded),
                           iconSize: 42,
                           color: colorScheme.onSurface,
                           onPressed: () {
                             _slideOffsetX = -1.0;
                             currentSongProvider.playPrevious();
                           },
                           tooltip: 'Previous Song',
                         ),
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorScheme.secondary,
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.secondary.withValues(alpha: 0.4),
                                blurRadius: 10,
                                spreadRadius: 2,
                              )
                            ]
                          ),
                          child: Consumer<CurrentSongProvider>(
                            builder: (context, provider, _) {
                              final isLoading = provider.isLoadingAudio;
                              final isPlaying = provider.isPlaying;
                              return IconButton(
                                icon: isLoading
                                    ? SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 2.5, color: colorScheme.onSecondary))
                                    : Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                iconSize: 48,
                                color: colorScheme.onSecondary,
                                onPressed: isLoading ? null : () {
                                  if (isPlaying) {
                                    provider.pauseSong();
                                  } else {
                                    provider.resumeSong();
                                  }
                                },
                                tooltip: isPlaying ? 'Pause' : 'Play',
                              );
                            },
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                           icon: const Icon(Icons.skip_next_rounded),
                           iconSize: 42,
                           color: colorScheme.onSurface,
                           onPressed: () {
                             _slideOffsetX = 1.0;
                             currentSongProvider.playNext();
                           },
                           tooltip: 'Next Song',
                         ),
                        if (!isRadio)
                          Consumer<CurrentSongProvider>(
                            builder: (context, provider, _) => IconButton(
                              icon: Icon(
                                provider.loopMode == LoopMode.none
                                    ? Icons.repeat_rounded
                                    : provider.loopMode == LoopMode.queue
                                        ? Icons.repeat_on_rounded
                                        : Icons.repeat_one_on_rounded,
                                color: provider.loopMode != LoopMode.none
                                    ? colorScheme.secondary
                                    : colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                              iconSize: 26,
                              onPressed: () => provider.toggleLoop(),
                              tooltip: provider.loopMode == LoopMode.none
                                  ? 'Repeat Off'
                                  : provider.loopMode == LoopMode.queue
                                      ? 'Repeat Queue'
                                      : 'Repeat Song',
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: MediaQuery.of(context).padding.bottom + 16), // For bottom padding
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLyricsView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false); // Get provider instance

    // This specific check for _parsedLyrics.isEmpty is now handled in the main build method's conditional display.
    // If _buildLyricsView is called, it means _parsedLyrics is not empty (or loading is finished).
    // However, keeping a fallback here is safe.
    if (_parsedLyrics.isEmpty) {
      return Center(
        child: Text(
          "No lyrics available.", 
          style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.7)),
        ),
      );
    }

    const int bottomPaddingLines = 3;
    return ScrollablePositionedList.builder(
      itemCount: _parsedLyrics.length + bottomPaddingLines,
      itemScrollController: _lyricsScrollController,
      itemPositionsListener: _lyricsPositionsListener,
      itemBuilder: (context, index) {
        if (index >= _parsedLyrics.length) {
          // Add empty lines at the bottom for centering the last lyric
          return const SizedBox(height: 44.0); // Match lyric line height
        }
        if (index < 0 || index >= _parsedLyrics.length) {
          return const SizedBox.shrink();
        }
        final line = _parsedLyrics[index];
        final bool isCurrent = _areLyricsSynced && index == _currentLyricIndex; // Highlight only if synced
        final bool wasCurrent = _areLyricsSynced && index == _previousLyricIndex; // Was previously current
        
        return GestureDetector(
          onTap: () {
            if (_areLyricsSynced && currentSongProvider.currentSong != null && !currentSongProvider.isCurrentlyPlayingRadio) {
              currentSongProvider.seek(line.timestamp);
            }
          },
          child: AnimatedBuilder(
            animation: _lyricTransitionController,
            builder: (context, child) {
              return AnimatedBuilder(
                animation: _lyricHighlightController,
                builder: (context, child) {
                  // Get individual line animation if it exists
                  final lineController = _lyricLineControllers[index];
                  final lineAnimation = lineController != null 
                      ? CurvedAnimation(
                          parent: lineController,
                          curve: Curves.easeOutBack,
                        )
                      : null;
                  
                  return AnimatedBuilder(
                    animation: lineAnimation ?? const AlwaysStoppedAnimation(1.0),
                    builder: (context, child) {
                      // Calculate animation values
                      double scale = 1.0;
                      double opacity = 1.0;
                      Color textColor = colorScheme.onSurface.withValues(alpha: 0.6);
                      FontWeight fontWeight = FontWeight.normal;
                      double fontSize = 20.0;
                      
                      if (isCurrent) {
                        // Current line animations
                        scale = 1.0 + (0.1 * _lyricHighlightAnimation.value);
                        opacity = 0.6 + (0.4 * _lyricHighlightAnimation.value);
                        textColor = Color.lerp(
                          colorScheme.onSurface.withValues(alpha: 0.6),
                          colorScheme.secondary,
                          _lyricHighlightAnimation.value,
                        )!;
                        fontWeight = FontWeight.bold;
                        fontSize = 20.0 + (2.0 * _lyricHighlightAnimation.value);
                      } else if (wasCurrent) {
                        // Previously current line - fade out effect
                        opacity = 1.0 - (0.3 * _lyricTransitionAnimation.value);
                        textColor = Color.lerp(
                          colorScheme.secondary,
                          colorScheme.onSurface.withValues(alpha: 0.6),
                          _lyricTransitionAnimation.value,
                        )!;
                        fontWeight = FontWeight.normal;
                        fontSize = 22.0 - (2.0 * _lyricTransitionAnimation.value);
                      }
                      
                      // Apply line-specific animation
                      if (lineAnimation != null) {
                        scale *= (0.95 + (0.05 * lineAnimation.value));
                      }
                      
                      return Transform.scale(
                        scale: scale,
                        child: Opacity(
                          opacity: opacity,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                            child: Text(
                              line.text,
                              textAlign: TextAlign.center,
                              style: textTheme.titleLarge?.copyWith(
                                color: textColor,
                                fontWeight: fontWeight,
                                fontSize: fontSize,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildAlbumArtWidget(Song currentSong, bool isRadio) {
    // Check if we can get artwork from playbar immediately
    final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
    final playbarArtId = PlaybarState.getCurrentArtworkId();
    
    // If playbar has the same artwork and it's not loading, use it immediately
    if (playbarArtProvider != null && playbarArtId == currentSong.id && !PlaybarState.isArtworkLoading()) {
      return Image(
        key: ValueKey('art_${playbarArtId}_$_artTransitionId'),
        image: playbarArtProvider,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => _placeholderArt(context, isRadio),
      );
    }
    
    // Otherwise, use the local artwork provider
    return _currentArtProvider != null
      ? Image(
          key: ValueKey('art_${_currentArtId}_$_artTransitionId'),
          image: _currentArtProvider!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _placeholderArt(context, isRadio),
        )
      : _placeholderArt(context, isRadio);
  }

  Widget _placeholderArt(BuildContext context, bool isRadio) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.7),
            Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          isRadio ? Icons.radio_rounded : Icons.music_note_rounded,
          size: 100,
          color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
        ),
      ),
    );
  }

    void _showPlaybackSpeedDialog(BuildContext context) async {
    // Disable on iOS
    if (Platform.isIOS) return;
    
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final colorScheme = Theme.of(context).colorScheme;
    
    // Load custom speed presets
    final prefs = await SharedPreferences.getInstance();
    final customSpeedPresetsJson = prefs.getStringList('customSpeedPresets') ?? [];
    final customSpeedPresets = customSpeedPresetsJson
        .map((e) => double.tryParse(e) ?? 1.0)
        .where((e) => e >= 0.25 && e <= 3.0)
        .toList();
    
    if (!mounted) return;
    
    // Combine built-in and custom presets, then sort them
    final allSpeeds = <double>[
      0.8, // Daycore
      1.0, // Normal
      1.2, // Nightcore
      ...customSpeedPresets,
    ];
    allSpeeds.sort();
    
    // Create a map to store labels for built-in speeds
    final speedLabels = <double, String>{
      0.8: '0.8x (Daycore)',
      1.0: '1.0x (Normal)',
      1.2: '1.2x (Nightcore)',
    };
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Playback Speed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 16.0),
                child: Text(
                  'Speed changes affect pitch naturally',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              ...allSpeeds.map((speed) {
                final label = speedLabels[speed] ?? '${speed.toStringAsFixed(2)}x';
                return _buildSpeedOption(context, speed, label, currentSongProvider, colorScheme);
              }),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSpeedOption(BuildContext context, double speed, String label, CurrentSongProvider provider, ColorScheme colorScheme) {
    final isSelected = provider.playbackSpeed == speed;
    
    return ListTile(
      title: Text(
        label,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? colorScheme.primary : colorScheme.onSurface,
        ),
      ),
      trailing: isSelected ? Icon(Icons.check, color: colorScheme.primary) : null,
      onTap: () {
        provider.setPlaybackSpeed(speed);
        Navigator.of(context).pop();
      },
    );
  }

  ImageProvider getArtworkProvider(String artUrl) {
    if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
    if (artUrl.startsWith('http')) {
      return CachedNetworkImageProvider(artUrl);
    } else {
      return FileImage(File(artUrl));
    }
  }

  // 4. Extracted seek bar widget
  Widget _buildSeekBar(CurrentSongProvider currentSongProvider, bool isRadio, TextTheme textTheme) {
    return SeekBar(
      currentSongProvider: currentSongProvider,
      isRadio: isRadio,
      areLyricsSynced: _areLyricsSynced,
      updateCurrentLyricIndex: _updateCurrentLyricIndex,
      isSeeking: _isSeeking,
      sliderValue: _sliderValue,
      onSeekStart: _onSeekStart,
      onSeekChange: _onSeekChange,
      onSeekEnd: _onSeekEnd,
      formatDuration: _formatDuration,
      textTheme: textTheme,
    );
  }

  Future<void> _viewAlbum(BuildContext context, Song song) async {
    if (song.album == null || song.album!.isEmpty || song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album information is not available for this song.')),
      );
      return;
    }

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
    );

    try {
      final albumDetails = await _apiService.getAlbum(song.album!, song.artist);

      if (mounted) {
        Navigator.of(context).pop(); // Remove loading dialog
        if (albumDetails != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AlbumScreen(album: albumDetails),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find details for album: "${song.album}".')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Remove loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching album details: $e')),
        );
      }
      debugPrint('Error fetching album details: $e');
    }
  }

  Future<void> _viewArtist(BuildContext context, Song song) async {
    if (song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Artist information is not available for this song.')),
      );
      return;
    }

    try {
      // Use artistId if available, otherwise use artist name
      final artistQuery = song.artistId.isNotEmpty 
          ? song.artistId 
          : song.artist;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ArtistScreen(
            artistId: artistQuery,
            artistName: song.artist,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading artist details: $e')),
        );
      }
      debugPrint('Error loading artist details: $e');
    }
  }

  void _showSleepTimerDialog(BuildContext context) {
    final List<int> presetMinutes = [15, 30, 60];
    int? selectedMinutes = _sleepTimerService.sleepTimerMinutes;
    final TextEditingController customController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Set Sleep Timer'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...presetMinutes.map((m) => RadioListTile<int>(
                        title: Text('$m minutes'),
                        value: m,
                        groupValue: selectedMinutes,
                        onChanged: (val) {
                          setState(() {
                            selectedMinutes = val;
                            customController.clear();
                          });
                        },
                      )),
                  RadioListTile<int>(
                    title: Row(
                      children: [
                        const Text('Custom: '),
                        SizedBox(
                          width: 60,
                          child: TextField(
                            controller: customController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: 'min'),
                            onChanged: (val) {
                              final parsed = int.tryParse(val);
                              setState(() {
                                selectedMinutes = parsed;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    value: selectedMinutes != null && !presetMinutes.contains(selectedMinutes!) ? selectedMinutes! : -1,
                    groupValue: selectedMinutes != null && !presetMinutes.contains(selectedMinutes!) ? selectedMinutes! : -1,
                    onChanged: (_) {},
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: (selectedMinutes != null && selectedMinutes! > 0)
                      ? () {
                          _sleepTimerService.startTimer(selectedMinutes!);
                          Navigator.of(context).pop();
                        }
                      : null,
                  child: const Text('Start'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// 4. Add SeekBar widget at the end of the file
class SeekBar extends StatelessWidget {
  final CurrentSongProvider currentSongProvider;
  final bool isRadio;
  final bool areLyricsSynced;
  final void Function(Duration) updateCurrentLyricIndex;
  final bool isSeeking;
  final double? sliderValue;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekChange;
  final ValueChanged<double> onSeekEnd;
  final String Function(Duration?) formatDuration;
  final TextTheme textTheme;
  const SeekBar({
    super.key,
    required this.currentSongProvider,
    required this.isRadio,
    required this.areLyricsSynced,
    required this.updateCurrentLyricIndex,
    required this.isSeeking,
    required this.sliderValue,
    required this.onSeekStart,
    required this.onSeekChange,
    required this.onSeekEnd,
    required this.formatDuration,
    required this.textTheme,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        StreamBuilder<Duration>(
          stream: currentSongProvider.positionStream, // Ensure this is a stable stream
          builder: (context, snapshot) {
            var position = snapshot.data ?? Duration.zero;
            if (position == Duration.zero && currentSongProvider.currentPosition != Duration.zero) {
              position = currentSongProvider.currentPosition;
            }
            if (isRadio) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 32.0),
                child: Text("LIVE", style: TextStyle(fontWeight: FontWeight.bold)),
              );
            }
            final duration = currentSongProvider.totalDuration ?? Duration.zero;
            // Only update lyrics index if not seeking
            if (areLyricsSynced && !isSeeking) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                updateCurrentLyricIndex(position);
              });
            }
            final double maxValue = duration.inMilliseconds.toDouble() > 0
                ? duration.inMilliseconds.toDouble()
                : 1.0;
            final double clampedValue = position.inMilliseconds
                .toDouble()
                .clamp(0.0, maxValue);
            final double sliderVal = isSeeking ? (sliderValue ?? clampedValue) : clampedValue;
            return Column(
              children: [
                Slider(
                  value: sliderVal,
                  max: maxValue,
                  min: 0.0,
                  onChangeStart: (_) => onSeekStart(),
                  onChanged: onSeekChange,
                  onChangeEnd: onSeekEnd,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(formatDuration(Duration(milliseconds: sliderVal.round())), style: textTheme.bodySmall),
                      Text(formatDuration(duration), style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}