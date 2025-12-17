import 'dart:convert'; // For jsonEncode
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart'; // For AudioServiceRepeatMode
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
import '../services/liked_songs_service.dart';
import '../services/lyrics_service.dart';
import '../screens/song_detail_screen.dart'; // For AddToPlaylistDialog
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart'; // Import for synced lyrics
import 'dart:math' as math; // Added for min/max in lyrics scroll
import 'package:cached_network_image/cached_network_image.dart'; // Added for CachedNetworkImageProvider
import 'playbar.dart'; // Import Playbar to access its state
import '../services/sleep_timer_service.dart'; // Import SleepTimerService
import '../screens/album_screen.dart'; // Import AlbumScreen
import '../screens/artist_screen.dart'; // Import ArtistScreen
import '../services/animation_service.dart'; // Import AnimationService
import '../models/album.dart'; // Import Album model
import '../services/album_manager_service.dart'; // Import AlbumManagerService
import '../services/artwork_service.dart'; // Import centralized artwork service
import '../services/haptic_service.dart'; // Import HapticService
import 'package:url_launcher/url_launcher.dart'; // Import url_launcher

// Helper class for parsed lyric lines
class LyricLine {
  final Duration timestamp;
  final String text;
  final LyricLineType type;

  LyricLine({
    required this.timestamp,
    required this.text,
    this.type = LyricLineType.normal,
  });
}

enum LyricLineType {
  normal,
  loadingDots,
}

class _QueueBottomSheetContent extends StatefulWidget {
  @override
  State<_QueueBottomSheetContent> createState() =>
      _QueueBottomSheetContentState();
}

class _QueueBottomSheetContentState extends State<_QueueBottomSheetContent> {
  static const double itemHeight = 72.0;
  final Map<String, String> _artPathCache = {};
  bool _loading = false; // Start with loading false to show queue immediately
  final ScrollController _scrollController = ScrollController();
  String? _lastSongId; // Track last song ID for scroll logic
  bool _hasAutoScrolled = false; // Only scroll on first open
  bool _isReordering = false; // Prevent auto-scroll during reordering

  @override
  void initState() {
    super.initState();
    _precacheArtPaths();
  }

  Future<void> _precacheArtPaths() async {
    final provider = Provider.of<CurrentSongProvider>(context, listen: false);
    final queue = List<Song>.from(provider.queue);

    // Initialize cache with empty paths first to avoid loading state
    for (final song in queue) {
      if (!_artPathCache.containsKey(song.id)) {
        _artPathCache[song.id] = '';
      }
    }

    // Set loading to false immediately so queue can be displayed
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }

    // Now cache art paths asynchronously in the background
    for (final song in queue) {
      if (song.albumArtUrl.isNotEmpty &&
          !song.albumArtUrl.startsWith('http') &&
          mounted) {
        try {
          final path = await _resolveLocalArtPath(song.albumArtUrl);
          if (mounted) {
            setState(() {
              _artPathCache[song.id] = path;
            });
          }
        } catch (e) {
          debugPrint('Error resolving art path for ${song.title}: $e');
        }
      }
    }
  }

  bool _isIndexVisible(int index) {
    if (!_scrollController.hasClients) return false;
    final double minVisible = _scrollController.offset;
    final double maxVisible = _scrollController.offset +
        (_scrollController.position.viewportDimension);
    final double itemTop = index * itemHeight;
    final double itemBottom = itemTop + itemHeight;
    return itemBottom > minVisible && itemTop < maxVisible;
  }

  void _maybeScrollToCurrentSong(List<Song> queue, Song? currentSong) {
    if (_hasAutoScrolled || _isReordering) return;
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
        // Only trigger background caching if queue changed significantly and we're not already loading
        if (_artPathCache.length < queue.length * 0.8 &&
            !_loading &&
            queue.length > 10) {
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
                color: colorScheme.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Handle bar
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    decoration: BoxDecoration(
                      color: colorScheme.onSurface.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(20.0, 8.0, 16.0, 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Up Next',
                          style: textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                              ) ??
                              TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 20.0,
                                color: colorScheme.onSurface,
                              ),
                        ),
                        if (queue.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              currentSongProvider.clearQueue();
                              if (mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: const Text('Queue cleared'),
                                    backgroundColor: colorScheme.inverseSurface,
                                  ),
                                );
                              }
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.primary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                            ),
                            child: const Text(
                              'Clear Queue',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (queue.isEmpty)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.queue_music,
                              size: 64,
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Your queue is empty',
                              style: textTheme.titleMedium?.copyWith(
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.7),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Songs you play next will appear here',
                              style: textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        scrollController: _scrollController,
                        itemCount: queue.length,
                        itemBuilder: (BuildContext context, int index) {
                          final song = queue[index];
                          final bool isCurrentlyPlaying =
                              song.id == currentSong?.id;
                          final String artPath = _artPathCache[song.id] ?? '';
                          Widget imageWidget;
                          if (song.albumArtUrl.startsWith('http')) {
                            imageWidget = Image.network(
                              song.albumArtUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color:
                                    colorScheme.surface.withValues(alpha: 0.3),
                                child: Icon(
                                  Icons.music_note,
                                  size: 24,
                                  color: colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            );
                          } else if (artPath.isNotEmpty) {
                            imageWidget = Image.file(
                              File(artPath),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color:
                                    colorScheme.surface.withValues(alpha: 0.3),
                                child: Icon(
                                  Icons.music_note,
                                  size: 24,
                                  color: colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            );
                          } else {
                            imageWidget = Container(
                              color: colorScheme.surface.withValues(alpha: 0.3),
                              child: Icon(
                                Icons.music_note,
                                size: 24,
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.6),
                              ),
                            );
                          }
                          return Container(
                            key: ValueKey(song.id),
                            height: itemHeight,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16.0),
                            child: InkWell(
                              onTap: () async {
                                final isPlaying = currentSongProvider.isPlaying;
                                await currentSongProvider.smartPlayWithContext(
                                    queue, song,
                                    playImmediately: isPlaying);
                                if (mounted) {
                                  setState(
                                      () {}); // Update queue UI immediately
                                }
                                // Do not close the queue after selecting a song
                                // if (mounted) Navigator.pop(context);
                              },
                              child: Row(
                                children: [
                                  // Album art
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: imageWidget,
                                    ),
                                  ),
                                  const SizedBox(width: 12),

                                  // Song info
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                song.baseTitle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: isCurrentlyPlaying
                                                      ? FontWeight.w600
                                                      : FontWeight.w500,
                                                  fontSize: 14,
                                                  color: isCurrentlyPlaying
                                                      ? colorScheme.primary
                                                      : colorScheme.onSurface,
                                                ),
                                              ),
                                            ),
                                            if (song
                                                .versionTags.isNotEmpty) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                song.versionTags,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isCurrentlyPlaying
                                                      ? colorScheme.primary
                                                          .withValues(
                                                              alpha: 0.8)
                                                      : colorScheme.onSurface
                                                          .withValues(
                                                              alpha: 0.6),
                                                  fontStyle: FontStyle.italic,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          song.artists.isNotEmpty
                                              ? song.artists.join(', ')
                                              : "Unknown Artist",
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isCurrentlyPlaying
                                                ? colorScheme.primary
                                                    .withValues(alpha: 0.9)
                                                : colorScheme.onSurface
                                                    .withValues(alpha: 0.7),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Trailing icons
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isCurrentlyPlaying) ...[
                                        AnimatedEqualizerIcon(
                                          isPlaying:
                                              currentSongProvider.isPlaying,
                                          color: colorScheme.primary,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: Icon(
                                          Icons.drag_handle,
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.5),
                                          size: 20,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                        onReorder: (int oldIndex, int newIndex) async {
                          if (newIndex > oldIndex) newIndex -= 1;

                          // Prevent auto-scrolling during reordering
                          setState(() {
                            _isReordering = true;
                          });

                          // Store current scroll position before reordering
                          final currentScrollOffset =
                              _scrollController.hasClients
                                  ? _scrollController.offset
                                  : 0.0;

                          await currentSongProvider.reorderQueue(
                              oldIndex, newIndex);

                          // Restore scroll position and allow auto-scrolling again
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              if (_scrollController.hasClients) {
                                _scrollController.jumpTo(currentScrollOffset);
                              }
                              setState(() {
                                _isReordering = false;
                              });
                            }
                          });
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
  const AnimatedEqualizerIcon(
      {super.key, required this.isPlaying, required this.color});

  @override
  State<AnimatedEqualizerIcon> createState() => _AnimatedEqualizerIconState();
}

class _AnimatedEqualizerIconState extends State<AnimatedEqualizerIcon>
    with SingleTickerProviderStateMixin {
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
    if (widget.isPlaying &&
        animationService
            .isAnimationEnabled(AnimationType.equalizerAnimations)) {
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
  // Use centralized artwork service for consistent path resolution
  return await artworkService.resolveLocalArtPath(fileName);
}

class FullScreenPlayer extends StatefulWidget {
  // Removed song parameter as Provider will supply the current song
  const FullScreenPlayer({super.key});

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer>
    with TickerProviderStateMixin {
  double _slideOffsetX =
      0.0; // To control slide direction, 0.0 means no slide (fade in art)
  String? _previousSongId;
  bool _previousIsPlaying =
      false; // Track previous playing state for dots animation
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
  bool _lyricsChanging = false; // Track when lyrics are being reset/changed
  String?
      _lastLyricsType; // Track the last lyrics type (synced/plain) to detect changes

  final ItemScrollController _lyricsScrollController = ItemScrollController();
  final ItemPositionsListener _lyricsPositionsListener =
      ItemPositionsListener.create();
  bool _isLyricsWidgetAttached =
      false; // Track if ScrollablePositionedList is properly attached
  final bool _lyricsWidgetError =
      false; // Track if there was an error with the lyrics widget

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

  // Lyrics animation controllers
  late AnimationController _lyricTransitionController;
  late AnimationController _lyricHighlightController;
  late Animation<double> _lyricTransitionAnimation;
  late Animation<double> _lyricHighlightAnimation;

  // Loading dots animation controllers - one for each loading dots line
  final Map<int, AnimationController> _loadingDotsControllers = {};
  final Map<int, Animation<double>> _loadingDotsAnimations = {};

  // Track previous lyric index for smooth transitions
  int _previousLyricIndex = -1;
  final Map<int, AnimationController> _lyricLineControllers = {};

  // Debounce timer for lyrics toggle button to prevent spam
  Timer? _lyricsToggleDebounceTimer;

  // Timer to update sleep timer countdown every minute
  Timer? _sleepTimerCountdownUpdater;

  // Store reference to lyrics positions listener for proper cleanup
  VoidCallback? _lyricsPositionsListenerCallback;

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

    // Loading dots controllers will be created on-demand for each loading dots line

    _currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    _previousSongId = _currentSongProvider.currentSong?.id;

    // Initialize sleep timer service
    if (!_sleepTimerService.isInitialized) {
      _sleepTimerService.initialize(_currentSongProvider);
    }
    _sleepTimerService.setCallbacks(
      onTimerUpdate: () {
        if (mounted) {
          setState(() {});
          // Start or stop countdown updater based on timer state
          if (_sleepTimerService.isTimerActive) {
            _startSleepTimerCountdownUpdater();
          } else {
            _stopSleepTimerCountdownUpdater();
          }
        }
      },
      onTimerExpired: () {
        _stopSleepTimerCountdownUpdater();
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Sleep timer expired. Playback stopped.')),
          );
        }
      },
    );

    if (_currentSongProvider.currentSong != null) {
      _localArtPathFuture =
          _resolveLocalArtPath(_currentSongProvider.currentSong!.albumArtUrl);
    }

    // Initial lyrics state reset (lyrics will be loaded on demand or if _showLyrics is true)
    _resetLyricsState();

    if (_currentSongProvider.currentSong != null) {
      // Start opening animation immediately for smooth transition
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startOpeningAnimation();
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updatePalette(_currentSongProvider.currentSong);
      }
    });

    _currentSongProvider.addListener(_onSongChanged);

    // Add listener for lyrics scroll positions to track when lyrics are close to top
    _lyricsPositionsListenerCallback = () {
      // This listener will be called whenever the scroll position changes
      // We don't need to do anything here, but having the listener active
      // ensures that itemPositions.value is updated and available for our checks
    };
    _lyricsPositionsListener.itemPositions
        .addListener(_lyricsPositionsListenerCallback!);

    final song = _currentSongProvider.currentSong;
    if (song != null) {
      // Try to use playbar's artwork immediately if available
      final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
      final playbarArtId = PlaybarState.getCurrentArtworkId();

      if (playbarArtProvider != null &&
          playbarArtId == song.id &&
          !PlaybarState.isArtworkLoading()) {
        _currentArtProvider = playbarArtProvider;
        _currentArtId = song.id;
        _artLoading = false;
      } else {
        // Set loading state and update artwork asynchronously
        _artLoading = true;
        _updateArtProvider(song);
      }
    }
  }

  void _updateArtProvider(Song song) {
    // Try to get the artwork from the playbar first
    final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
    final playbarArtId = PlaybarState.getCurrentArtworkId();

    // If the playbar has the same artwork loaded, use it
    if (playbarArtProvider != null && playbarArtId == song.id) {
      _currentArtProvider = playbarArtProvider;
      _currentArtId = song.id;
      if (mounted) {
        setState(() {
          _artLoading = false;
        });
      }
      return;
    }

    // Otherwise, load the artwork asynchronously using centralized service
    _loadArtworkAsync(song);
  }

  Future<void> _loadArtworkAsync(Song song) async {
    try {
      _currentArtProvider =
          await artworkService.getArtworkProvider(song.albumArtUrl);
      _currentArtId = song.id;
    } catch (e) {
      debugPrint('Error loading artwork: $e');
      _currentArtProvider = null;
    }

    if (mounted) {
      setState(() {
        _artLoading = false;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    _currentSongProvider.addListener(_onSongChanged);

    // Initialize playing state tracking
    _previousIsPlaying = _currentSongProvider.isPlaying;
    final song = _currentSongProvider.currentSong;
    if (song != null) {
      // Try to use playbar's artwork immediately if available
      final playbarArtProvider = PlaybarState.getCurrentArtworkProvider();
      final playbarArtId = PlaybarState.getCurrentArtworkId();

      if (playbarArtProvider != null &&
          playbarArtId == song.id &&
          !PlaybarState.isArtworkLoading()) {
        _currentArtProvider = playbarArtProvider;
        _currentArtId = song.id;
        _artLoading = false;
      } else {
        // Set loading state and update artwork asynchronously
        _artLoading = true;
        _updateArtProvider(song);
      }
    }
  }

  void _resetLyricsState() {
    if (mounted) {
      setState(() {
        _lyricsChanging = true; // Mark that lyrics are being changed
        _isLyricsWidgetAttached = false; // Reset attachment state
        _parsedLyrics = [];
        _currentLyricIndex = -1;
        _previousLyricIndex = -1; // Reset previous index
        _areLyricsSynced = false;
        _lyricsFetchedForCurrentSong = false;
        _lyricsLoading = false;
        _lastLyricsType = null; // Reset lyrics type tracking
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

      // Clear loading dots controllers to prevent state conflicts
      for (final controller in _loadingDotsControllers.values) {
        controller.stop();
        controller.reset();
      }
      _loadingDotsControllers.clear();
      _loadingDotsAnimations.clear();

      // Reset the changing flag after a longer delay to ensure UI has fully transitioned
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) {
          setState(() {
            _lyricsChanging = false;
          });
        }
      });
    }
  }

  // Helper method to safely check if scroll operations are possible
  bool _canPerformScrollOperation() {
    return mounted &&
        !_lyricsChanging &&
        !_lyricsLoading && // Don't scroll during loading state
        _isLyricsWidgetAttached &&
        _lyricsScrollController.isAttached &&
        _parsedLyrics.isNotEmpty &&
        _showLyrics && // Only scroll when lyrics view is actually shown
        _currentSongProvider.currentSong !=
            null && // Ensure we have a current song
        _lastLyricsType !=
            null; // Ensure lyrics type is set (prevents operations during type transitions)
  }

  // Safe wrapper for all scroll operations
  void _safeScrollOperation(VoidCallback operation, String operationName) {
    if (!_canPerformScrollOperation()) {
      debugPrint(
          "Cannot perform scroll operation '$operationName': widget not ready");
      return;
    }

    // Additional check: ensure we're actually showing the scrollable lyrics view
    if (_lyricsLoading || _parsedLyrics.isEmpty) {
      debugPrint(
          "Skipping scroll operation '$operationName': not showing scrollable lyrics");
      return;
    }

    // Add a small delay to ensure the widget is fully stable before performing scroll operations
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted || _lyricsChanging || _lyricsLoading) {
        debugPrint(
            "Skipping delayed scroll operation '$operationName': widget not stable");
        return;
      }

      try {
        operation();
      } catch (e) {
        debugPrint("Error during scroll operation '$operationName': $e");
        // For critical errors like _scrollableListState == null, mark widget as not attached
        if (e.toString().contains('_scrollableListState') ||
            e.toString().contains('null') ||
            e.toString().contains('Failed assertion')) {
          _isLyricsWidgetAttached = false;
          debugPrint(
              "Marking lyrics widget as not attached due to state error: $e");

          // Reset to stable state after error
          if (mounted) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (mounted) {
                setState(() {
                  _lyricsChanging = true;
                });
                Future.delayed(const Duration(milliseconds: 50), () {
                  if (mounted) {
                    setState(() {
                      _lyricsChanging = false;
                    });
                  }
                });
              }
            });
          }
        }
      }
    });
  }

  void _resetScrollPosition() {
    // Wait for lyrics state to stabilize before resetting scroll position
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_canPerformScrollOperation() &&
          _currentSongProvider.currentSong?.id == _previousSongId &&
          !_lyricsChanging &&
          !_lyricsLoading) {
        _safeScrollOperation(() {
          _lyricsScrollController.jumpTo(index: 0);
        }, "reset scroll position");
      }
    });
  }

  // Enhanced opening animation method
  void _startOpeningAnimation() {
    final animationService = AnimationService.instance;

    if (!animationService
        .isAnimationEnabled(AnimationType.songChangeAnimations)) {
      // Skip animations if disabled
      _backgroundController.value = 1.0;
      _scaleController.value = 1.0;
      _slideController.value = 1.0;
      _rotationController.value = 1.0;
      _textFadeController.value = 1.0;
      return;
    }

    // Start all animations immediately for smooth opening
    _backgroundController.forward();
    _scaleController.forward();
    _slideController.forward();
    _rotationController.forward();

    // Stagger the text fade animation with shorter delay for smoother feel
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        _textFadeController.forward();
      }
    });
  }

  // Start countdown timer updater when sleep timer is active
  void _startSleepTimerCountdownUpdater() {
    _stopSleepTimerCountdownUpdater(); // Cancel any existing timer
    if (_sleepTimerService.isTimerActive) {
      _sleepTimerCountdownUpdater = Timer.periodic(
        const Duration(
            seconds: 30), // Update every 30 seconds for smooth countdown
        (_) {
          if (mounted && _sleepTimerService.isTimerActive) {
            setState(() {});
          } else {
            _stopSleepTimerCountdownUpdater();
          }
        },
      );
    }
  }

  // Stop countdown timer updater
  void _stopSleepTimerCountdownUpdater() {
    _sleepTimerCountdownUpdater?.cancel();
    _sleepTimerCountdownUpdater = null;
  }

  // Enhanced song change animation method
  void _startSongChangeAnimation(double slideOffsetX) {
    final animationService = AnimationService.instance;

    if (!animationService
        .isAnimationEnabled(AnimationType.songChangeAnimations)) {
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

    // Reset and start text fade animation with shorter delay for smoother feel
    _textFadeController.reset();
    Future.delayed(const Duration(milliseconds: 100), () {
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
      // Immediately mark lyrics as changing to prevent scroll operations during transition
      if (mounted) {
        setState(() {
          _lyricsChanging = true;
          _isLyricsWidgetAttached = false;
          _lastLyricsType = null; // Reset lyrics type to force complete rebuild
        });
      }
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

        if (playbarArtProvider != null &&
            playbarArtId == newSong.id &&
            !PlaybarState.isArtworkLoading()) {
          _currentArtProvider = playbarArtProvider;
          _currentArtId = newSong.id;
          _artLoading = false;
        } else {
          // Start animation immediately without waiting for artwork
          _artLoading = true;
          // Update artwork asynchronously after animation starts
          _updateArtProvider(newSong);
        }
      }

      // Start animation immediately for smooth transition
      _startSongChangeAnimation(effectiveSlideOffsetX);

      if (mounted) _updatePalette(newSong);

      // Add a small delay before resetting lyrics state to ensure UI stability
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) {
          _resetLyricsState();
        }
      });

      final provider = Provider.of<CurrentSongProvider>(context, listen: false);
      final currentSong = provider.currentSong;
      if (currentSong != null) {
        // Check download status for all songs, not just those marked as downloaded
        // This ensures the UI reflects the actual download state without triggering downloads
        provider.checkDownloadStatus(currentSong);

        // Also update missing metadata for downloaded songs
        // Use provider's download state to determine if song is actually downloaded
        final downloadProgress = provider.downloadProgress[currentSong.id];
        final isActuallyDownloaded =
            downloadProgress == 1.0 || currentSong.isDownloaded;
        if (isActuallyDownloaded) {
          provider.updateMissingMetadata(currentSong);
        }
      }

      if (_showLyrics && newSong != null) {
        // Add a small delay to prevent rapid loading during fast song changes
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && _currentSongProvider.currentSong?.id == newSong.id) {
            _loadAndProcessLyrics(newSong);
          }
        });
      }

      // Safely reset scroll position after lyrics state is stable
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && _currentSongProvider.currentSong?.id == newSong?.id) {
          _resetScrollPosition();
        }
      });

      if (mounted) {
        setState(() {
          _previousSongId = newSongId;
          _slideOffsetX = 0.0;
        });
      }
    }

    // Check if playing state changed and update dots animation accordingly
    final currentIsPlaying = _currentSongProvider.isPlaying;
    if (currentIsPlaying != _previousIsPlaying) {
      _updateLoadingDotsAnimationState();
      _previousIsPlaying = currentIsPlaying;

      // Additional check: if song just started playing and position is at/near beginning,
      // ensure loading dots animation starts immediately
      if (currentIsPlaying && !_previousIsPlaying) {
        final currentPosition = _currentSongProvider.currentPosition;
        if ((currentPosition.inMilliseconds <=
                500) && // Within first 500ms or null
            _parsedLyrics.isNotEmpty &&
            _parsedLyrics[0].type == LyricLineType.loadingDots) {
          _startLoadingDotsAnimation(0);
        }
      }
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
      final lyricsService = LyricsService();
      LyricsData? lyricsData =
          await lyricsService.fetchLyricsIfNeeded(song, _currentSongProvider);

      // Check again if still mounted, song is current, and lyrics were actually found.
      if (mounted &&
          _currentSongProvider.currentSong?.id == song.id &&
          lyricsData != null &&
          (lyricsData.syncedLyrics?.isNotEmpty == true ||
              lyricsData.plainLyrics?.isNotEmpty == true)) {
        debugPrint("Lyrics auto-downloaded and saved for ${song.title}");

        // If lyrics view is active for this song, refresh it.
        // The provider's notification should ideally handle updating the song instance.
        // Calling _loadAndProcessLyrics ensures the view updates with new local lyrics.
        if (_showLyrics) {
          final potentiallyUpdatedSong = _currentSongProvider.currentSong;
          if (potentiallyUpdatedSong != null &&
              potentiallyUpdatedSong.id == song.id) {
            _loadAndProcessLyrics(potentiallyUpdatedSong);
          }
        }
      } else if (lyricsData == null ||
          (lyricsData.syncedLyrics?.isEmpty ?? true) &&
              (lyricsData.plainLyrics?.isEmpty ?? true)) {
        debugPrint("No lyrics found (auto-fetch) for ${song.title}");
      }
    } catch (e) {
      debugPrint("Error auto-fetching lyrics for ${song.title}: $e");
    }
  }

  Future<void> _loadAndProcessLyrics(Song currentSong) async {
    if (!mounted) return;

    // Store the song ID to validate this is still the current song after async operations
    final String songIdForLyrics = currentSong.id;

    setState(() {
      _lyricsLoading = true;
      _isLyricsWidgetAttached =
          false; // Reset attachment state during lyrics loading
      _parsedLyrics = [];
      _currentLyricIndex = -1;
      _areLyricsSynced = false;
      // _lyricsFetchedForCurrentSong is reset in _resetLyricsState.
      // It will be set to true in the finally block or if local lyrics are found.
    });

    // Use the new lyrics service for smart fetching
    debugPrint("Loading lyrics for ${currentSong.title}");
    final lyricsService = LyricsService();
    LyricsData? lyricsData;

    try {
      lyricsData = await lyricsService.fetchLyricsIfNeeded(
          currentSong, _currentSongProvider);

      // Validate that this song is still the current song before processing lyrics
      if (mounted && _currentSongProvider.currentSong?.id == songIdForLyrics) {
        _processLyricsForSongData(lyricsData, songIdForLyrics);
      } else {
        debugPrint(
            "Song changed during lyrics fetch for ${currentSong.title}, skipping lyrics processing");
      }
    } catch (e) {
      debugPrint("Error loading lyrics in FullScreenPlayer: $e");
      // Only process error state if this is still the current song
      if (mounted && _currentSongProvider.currentSong?.id == songIdForLyrics) {
        _processLyricsForSongData(null,
            songIdForLyrics); // Process with null to clear lyrics and show "not available"
      }
    } finally {
      if (mounted && _currentSongProvider.currentSong?.id == songIdForLyrics) {
        setState(() {
          _lyricsLoading = false;
          _lyricsFetchedForCurrentSong = true;
        });

        // If lyrics are being shown and we have a current lyric index, scroll to it
        if (_showLyrics && _currentLyricIndex >= 0) {
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted &&
                _currentSongProvider.currentSong?.id == songIdForLyrics) {
              _scrollToCurrentLyricIfNeeded();
            }
          });
        }
      }
    }
  }

  void _processLyricsForSongData(
      LyricsData? lyricsData, String songIdForLyrics) {
    // Validate that this is still the current song before processing
    if (!mounted || _currentSongProvider.currentSong?.id != songIdForLyrics) {
      debugPrint(
          "Song changed during lyrics processing, skipping for song ID: $songIdForLyrics");
      return;
    }

    List<LyricLine> tempParsedLyrics = [];
    bool tempAreLyricsSynced = false;

    if (lyricsData?.syncedLyrics != null &&
        lyricsData!.syncedLyrics!.isNotEmpty) {
      tempParsedLyrics = _parseSyncedLyrics(lyricsData.syncedLyrics!);
      if (tempParsedLyrics.isNotEmpty) {
        tempAreLyricsSynced = true;
      }
    }

    if (!tempAreLyricsSynced &&
        lyricsData?.plainLyrics != null &&
        lyricsData!.plainLyrics!.isNotEmpty) {
      tempParsedLyrics = _parsePlainLyrics(lyricsData.plainLyrics!);
    }

    // Detect if lyrics type has changed (synced vs plain)
    final String newLyricsType = tempAreLyricsSynced ? 'synced' : 'plain';
    final bool lyricsTypeChanged =
        _lastLyricsType != null && _lastLyricsType != newLyricsType;

    // Double-check that the song is still current before updating state
    if (mounted && _currentSongProvider.currentSong?.id == songIdForLyrics) {
      setState(() {
        _lyricsChanging = true; // Mark lyrics as changing during update
        _isLyricsWidgetAttached =
            false; // Reset attachment state when sync state changes
        _parsedLyrics = tempParsedLyrics;
        _areLyricsSynced = tempAreLyricsSynced;
        _lastLyricsType = newLyricsType; // Update lyrics type tracking
        // Clamp _currentLyricIndex to -1 or valid range
        if (_currentLyricIndex >= _parsedLyrics.length) {
          _currentLyricIndex =
              _parsedLyrics.isEmpty ? -1 : _parsedLyrics.length - 1;
        }
        if (_currentLyricIndex < -1) _currentLyricIndex = -1;
      });

      // If lyrics type changed, force a longer delay to ensure complete widget rebuild
      final int delayMs = lyricsTypeChanged ? 150 : 75;

      // Reset the changing flag after the UI has updated
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted &&
            _currentSongProvider.currentSong?.id == songIdForLyrics) {
          setState(() {
            _lyricsChanging = false;
          });

          // Allow attachment to be detected after lyrics are processed
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted &&
                _currentSongProvider.currentSong?.id == songIdForLyrics &&
                _parsedLyrics.isNotEmpty) {
              // Don't force attachment here, let the PostFrameCallback handle it
              debugPrint("Lyrics processed and ready for attachment detection");
            }
          });
        }
      });

      // Trigger entrance animation for new lyrics
      if (tempParsedLyrics.isNotEmpty) {
        _triggerLyricsEntranceAnimation();

        // If lyrics are being shown, scroll to current lyric after a short delay
        if (_showLyrics) {
          Future.delayed(const Duration(milliseconds: 350), () {
            if (mounted &&
                _currentSongProvider.currentSong?.id == songIdForLyrics) {
              _scrollToCurrentLyricIfNeeded();
            }
          });
        }
      }
    }
  }

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

        // Check if this is a blank timestamp (timestamp with no text or just whitespace)
        if (text.isEmpty) {
          // This is a blank timestamp - add loading dots
          lines.add(LyricLine(
            timestamp: Duration(
                minutes: minutes, seconds: seconds, milliseconds: milliseconds),
            text: "...",
            type: LyricLineType.loadingDots,
          ));
        } else {
          // This is a normal lyric line
          lines.add(LyricLine(
            timestamp: Duration(
                minutes: minutes, seconds: seconds, milliseconds: milliseconds),
            text: text,
          ));
        }
      }
    }
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Add loading dots at the beginning if there's a gap before the first lyric
    return _addBeginningLoadingDots(lines);
  }

  List<LyricLine> _addBeginningLoadingDots(List<LyricLine> originalLines) {
    if (originalLines.isEmpty) return originalLines;

    final List<LyricLine> linesWithBeginningDots = [];

    // Check if the first lyric starts after 00:00:00
    final firstLine = originalLines.first;
    if (firstLine.timestamp > Duration.zero) {
      // Only add loading dots if the first lyric doesn't appear within the first 1.5 seconds
      if (firstLine.timestamp.inMilliseconds > 1500) {
        // Add loading dots at 00:00:00
        linesWithBeginningDots.add(LyricLine(
          timestamp: Duration.zero,
          text: "...",
          type: LyricLineType.loadingDots,
        ));
      } else {}
    }

    // Add all original lines
    linesWithBeginningDots.addAll(originalLines);

    // Sort to ensure proper chronological order
    linesWithBeginningDots.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return linesWithBeginningDots;
  }

  Widget _buildLoadingDots(Color textColor, double fontSize, int lineIndex) {
    // Get the animation controller for this specific line
    final controller = _loadingDotsControllers[lineIndex];
    final animation = _loadingDotsAnimations[lineIndex];

    // Ensure animation controller exists for this line if it doesn't
    if (controller == null || animation == null) {
      _loadingDotsControllers[lineIndex] = AnimationController(
        duration: const Duration(milliseconds: 1500),
        vsync: this,
      );
      _loadingDotsAnimations[lineIndex] = CurvedAnimation(
        parent: _loadingDotsControllers[lineIndex]!,
        curve: Curves.easeInOut,
      );

      // Start animation if this is the current line and song is playing
      final currentSongProvider =
          Provider.of<CurrentSongProvider>(context, listen: false);
      if (currentSongProvider.isPlaying && _currentLyricIndex == lineIndex) {
        // Calculate duration for this animation
        if (lineIndex >= 0 && lineIndex < _parsedLyrics.length) {
          final currentLine = _parsedLyrics[lineIndex];
          Duration timeUntilNext =
              const Duration(milliseconds: 1500); // Default

          // Special handling for first loading dots (at 00:00:00)
          if (lineIndex == 0 &&
              currentLine.type == LyricLineType.loadingDots &&
              currentLine.timestamp == Duration.zero) {
            // Find the first actual lyric (not loading dots)
            for (int i = 1; i < _parsedLyrics.length; i++) {
              if (_parsedLyrics[i].type != LyricLineType.loadingDots) {
                timeUntilNext = _parsedLyrics[i].timestamp;

                break;
              }
            }
          } else if (lineIndex < _parsedLyrics.length - 1) {
            final nextLine = _parsedLyrics[lineIndex + 1];
            timeUntilNext = nextLine.timestamp - currentLine.timestamp;
          } else {
            final songDuration =
                currentSongProvider.totalDuration ?? Duration.zero;
            if (songDuration > currentLine.timestamp) {
              timeUntilNext = songDuration - currentLine.timestamp;
            }
          }

          final animationDuration =
              Duration(milliseconds: timeUntilNext.inMilliseconds);
          _loadingDotsControllers[lineIndex]!.duration = animationDuration;
          _loadingDotsControllers[lineIndex]!.repeat();
        }
      }

      // Use the newly created controllers
      final newController = _loadingDotsControllers[lineIndex]!;
      final newAnimation = _loadingDotsAnimations[lineIndex]!;

      // Use the newly created controllers with proper animation
      return AnimatedBuilder(
        animation: newAnimation,
        builder: (context, child) {
          final animationValue = newAnimation.value;

          // Calculate which dots should be visible based on animation progress
          final dot1Opacity =
              _calculateDotOpacity(animationValue, 0.0, 1.0 / 3.0);
          final dot2Opacity =
              _calculateDotOpacity(animationValue, 1.0 / 3.0, 2.0 / 3.0);
          final dot3Opacity =
              _calculateDotOpacity(animationValue, 2.0 / 3.0, 1.0);

          final dot1Scale = _calculateDotScale(animationValue, 0.0, 1.0 / 3.0);
          final dot2Scale =
              _calculateDotScale(animationValue, 1.0 / 3.0, 2.0 / 3.0);
          final dot3Scale = _calculateDotScale(animationValue, 2.0 / 3.0, 1.0);

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDot(textColor, fontSize, dot1Opacity, dot1Scale, 0),
              const SizedBox(width: 4),
              _buildDot(textColor, fontSize, dot2Opacity, dot2Scale, 1),
              const SizedBox(width: 4),
              _buildDot(textColor, fontSize, dot3Opacity, dot3Scale, 2),
            ],
          );
        },
      );
    }

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final animationValue = animation.value;

        // Calculate which dots should be visible based on animation progress
        // Each dot gets exactly 1/3 of the total animation time
        final dot1Opacity =
            _calculateDotOpacity(animationValue, 0.0, 1.0 / 3.0);
        final dot2Opacity =
            _calculateDotOpacity(animationValue, 1.0 / 3.0, 2.0 / 3.0);
        final dot3Opacity =
            _calculateDotOpacity(animationValue, 2.0 / 3.0, 1.0);

        final dot1Scale = _calculateDotScale(animationValue, 0.0, 1.0 / 3.0);
        final dot2Scale =
            _calculateDotScale(animationValue, 1.0 / 3.0, 2.0 / 3.0);
        final dot3Scale = _calculateDotScale(animationValue, 2.0 / 3.0, 1.0);

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildDot(textColor, fontSize, dot1Opacity, dot1Scale, 0),
            const SizedBox(width: 4),
            _buildDot(textColor, fontSize, dot2Opacity, dot2Scale, 1),
            const SizedBox(width: 4),
            _buildDot(textColor, fontSize, dot3Opacity, dot3Scale, 2),
          ],
        );
      },
    );
  }

  double _calculateDotOpacity(double animationValue, double start, double end) {
    // Create a smooth transition for each dot
    if (animationValue < start) return 0.3; // Start at 30% opacity

    // Calculate progress within this dot's time window
    final progress = (animationValue - start) / (end - start);

    // Once a dot is activated, keep it filled in (don't fade out)
    if (animationValue >= end) return 1.0;

    // Use a smooth curve: start at 0.3, peak at 1.0, then stay at 1.0
    if (progress < 0.5) {
      // Fade in: 0.3 to 1.0
      return 0.3 + (0.7 * (progress * 2)); // Linear fade from 0.3 to 1.0
    } else {
      // Stay at 1.0 once filled
      return 1.0;
    }
  }

  double _calculateDotScale(double animationValue, double start, double end) {
    // Create a growing effect for each dot
    if (animationValue < start) return 0.5; // Start at 50% size

    // Calculate progress within this dot's time window
    final progress = (animationValue - start) / (end - start);

    // Once a dot is activated, keep it at full size
    if (animationValue >= end) return 1.25;

    // Use a smooth curve: start at 0.5, peak at 1.25, then stay at 1.25
    if (progress < 0.5) {
      // Grow: 0.5 to 1.25
      return 0.5 + (0.75 * (progress * 2)); // Linear grow from 0.5 to 1.25
    } else {
      // Stay at 1.25 once fully grown
      return 1.25;
    }
  }

  Widget _buildDot(Color textColor, double fontSize, double opacity,
      double scale, int dotIndex) {
    return AnimatedOpacity(
      opacity: opacity,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Transform.scale(
        scale: scale,
        child: Text(
          "•",
          style: TextStyle(
            color: textColor,
            fontSize: fontSize * 1.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  void _startLoadingDotsAnimation(int lineIndex) {
    // Check if the song is currently playing
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    if (!currentSongProvider.isPlaying) {
      // Don't start animation if song is not playing

      return;
    }

    // Check if this is the first line and if it's a regular lyric (not loading dots)
    // that appears within the first 1.5 seconds
    if (lineIndex == 0 && _parsedLyrics.isNotEmpty) {
      final firstLine = _parsedLyrics[0];
      if (firstLine.type != LyricLineType.loadingDots &&
          firstLine.timestamp.inMilliseconds <= 1500) {
        // Skip animation if first lyric (not loading dots) appears within 1.5 seconds

        return;
      }
    }

    // Animation controller should now be created in _buildLoadingDots
    // This method just configures and starts existing controllers
    if (!_loadingDotsControllers.containsKey(lineIndex)) {
      return;
    }

    final controller = _loadingDotsControllers[lineIndex]!;
    if (!controller.isAnimating) {
      // Calculate the duration based on the time from blank timestamp to next lyric or song end
      if (lineIndex >= 0 && lineIndex < _parsedLyrics.length) {
        final currentLine = _parsedLyrics[lineIndex];

        // Find the duration until the next lyric line or song end
        Duration timeUntilNext = const Duration(milliseconds: 1500); // Default

        // Special handling for first loading dots (at 00:00:00)
        if (lineIndex == 0 &&
            currentLine.type == LyricLineType.loadingDots &&
            currentLine.timestamp == Duration.zero) {
          // Find the first actual lyric (not loading dots)
          for (int i = 1; i < _parsedLyrics.length; i++) {
            if (_parsedLyrics[i].type != LyricLineType.loadingDots) {
              timeUntilNext = _parsedLyrics[i].timestamp;

              break;
            }
          }
        } else if (lineIndex < _parsedLyrics.length - 1) {
          final nextLine = _parsedLyrics[lineIndex + 1];
          timeUntilNext = nextLine.timestamp - currentLine.timestamp;
        } else {
          // This is the last lyric line - calculate duration to song end
          final songDuration =
              currentSongProvider.totalDuration ?? Duration.zero;
          if (songDuration > currentLine.timestamp) {
            timeUntilNext = songDuration - currentLine.timestamp;
          }
        }

        // Set animation duration to the full time until next lyric or song end
        final animationDuration = Duration(
          milliseconds: timeUntilNext.inMilliseconds,
        );

        controller.duration = animationDuration;
      }

      controller.repeat();
    }
  }

  void _stopLoadingDotsAnimation(int lineIndex) {
    final controller = _loadingDotsControllers[lineIndex];
    if (controller != null && controller.isAnimating) {
      controller.stop();
      controller.reset();
    }
  }

  void _pauseLoadingDotsAnimation(int lineIndex) {
    final controller = _loadingDotsControllers[lineIndex];
    if (controller != null && controller.isAnimating) {
      controller.stop();
    }
  }

  void _resumeLoadingDotsAnimation(int lineIndex) {
    final controller = _loadingDotsControllers[lineIndex];
    if (controller != null && !controller.isAnimating) {
      controller.repeat();
    }
  }

  void _updateLoadingDotsAnimationState() {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);

    // Check if we have a current loading dots line
    if (_currentLyricIndex != -1 &&
        _currentLyricIndex < _parsedLyrics.length &&
        _parsedLyrics[_currentLyricIndex].type == LyricLineType.loadingDots) {
      if (currentSongProvider.isPlaying) {
        // Resume animation if song is playing
        _resumeLoadingDotsAnimation(_currentLyricIndex);
      } else {
        // Pause animation if song is paused
        _pauseLoadingDotsAnimation(_currentLyricIndex);
      }
    } else if (currentSongProvider.isPlaying &&
        _parsedLyrics.isNotEmpty &&
        _parsedLyrics[0].type == LyricLineType.loadingDots &&
        (_currentLyricIndex == -1 || _currentLyricIndex == 0)) {
      // Special case: Song just started playing and first line is loading dots
      // but _currentLyricIndex might not be set yet or is at the first position

      _startLoadingDotsAnimation(0);
    }
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
        final baseColor = palette.dominantColor?.color ??
            Theme.of(context).colorScheme.surface;
        final hsl = HSLColor.fromColor(baseColor);
        final Brightness currentBrightness = Theme.of(context).brightness;
        final bool isDarkMode = currentBrightness == Brightness.dark;

        // Make the color more vibrant and noticeable
        final adjustedColor = hsl
            .withSaturation(
                (hsl.saturation * 1.2).clamp(0.0, 1.0)) // Increase saturation
            .withLightness(isDarkMode ? 0.15 : 0.85) // Slightly more contrast
            .toColor();

        _paletteCache[song.id] = adjustedColor;
        if (mounted) {
          setState(() {
            _dominantColor = adjustedColor;
          });
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    // Mark lyrics widget as not attached during disposal
    _isLyricsWidgetAttached = false;

    WakelockPlus.disable(); // Allow sleep when player is closed
    _currentSongProvider.removeListener(_onSongChanged);

    // Remove lyrics positions listener
    if (_lyricsPositionsListenerCallback != null) {
      _lyricsPositionsListener.itemPositions
          .removeListener(_lyricsPositionsListenerCallback!);
    }

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

    // Dispose loading dots controllers
    for (final controller in _loadingDotsControllers.values) {
      controller.dispose();
    }
    _loadingDotsControllers.clear();
    _loadingDotsAnimations.clear();

    // Dispose individual lyric line controllers
    for (final controller in _lyricLineControllers.values) {
      controller.dispose();
    }
    _lyricLineControllers.clear();

    // Cancel palette debounce timer if active
    _paletteDebounce?.cancel();

    // Cancel lyrics toggle debounce timer if active
    _lyricsToggleDebounceTimer?.cancel();

    // Cancel sleep timer countdown updater
    _stopSleepTimerCountdownUpdater();

    super.dispose();
  }

  Future<void> _downloadCurrentSong(Song song) async {
    // Use the CurrentSongProvider to handle the download
    if (mounted && context.mounted) {
      final provider = Provider.of<CurrentSongProvider>(context, listen: false);

      // Check if the song is already downloaded or downloading
      final downloadProgress = provider.downloadProgress[song.id];
      final isDownloading = provider.activeDownloadTasks.containsKey(song.id);
      final isDownloaded = downloadProgress == 1.0 || song.isDownloaded;

      if (isDownloaded) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${song.title}" is already downloaded')),
        );
        return;
      }

      if (isDownloading) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${song.title}" is already downloading...')),
        );
        return;
      }

      provider.queueSongForDownload(song);

      // Show a snackbar indicating the download has started
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
    // Use centralized artwork service for consistent path resolution
    return await artworkService.resolveLocalArtPath(fileName);
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
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
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

  // ignore: unused_element
  void _updateCurrentLyricIndex(Duration currentPosition) {
    if (!_areLyricsSynced || _parsedLyrics.isEmpty) {
      if (_currentLyricIndex != -1 && _areLyricsSynced) {
        // Reset if they were synced but now aren't or are empty
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

      // Handle loading dots animation
      if (newIndex != -1 &&
          newIndex < _parsedLyrics.length &&
          _parsedLyrics[newIndex].type == LyricLineType.loadingDots) {
        _startLoadingDotsAnimation(newIndex);
      } else {
        // Stop animation for the previous loading dots line if it exists
        if (_previousLyricIndex != -1 &&
            _previousLyricIndex < _parsedLyrics.length &&
            _parsedLyrics[_previousLyricIndex].type ==
                LyricLineType.loadingDots) {
          _stopLoadingDotsAnimation(_previousLyricIndex);
        }
      }

      // Trigger lyric transition animations
      if (newIndex != -1) {
        _triggerLyricTransitionAnimation(newIndex);
      }

      if (newIndex != -1 && !_isCurrentLyricCloseToTop()) {
        _safeScrollOperation(() {
          _lyricsScrollController.scrollTo(
            index: newIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: 0.5,
          );
        }, "auto-scroll to lyric $newIndex");
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

  // Helper method to check if current lyric is close to the top
  bool _isCurrentLyricCloseToTop() {
    if (!_lyricsScrollController.isAttached || _currentLyricIndex < 0) {
      return false;
    }

    // Get the current scroll position and viewport dimensions
    final positions = _lyricsPositionsListener.itemPositions.value;
    if (positions.isEmpty) return false;

    // Find the current lyric position
    final currentPosition = positions.firstWhere(
      (position) => position.index == _currentLyricIndex,
      orElse: () =>
          ItemPosition(index: -1, itemLeadingEdge: 0.0, itemTrailingEdge: 0.0),
    );

    if (currentPosition.index == -1) return false;

    // Check if the current lyric is within the top 20% of the viewport
    // This means we don't want to auto-scroll when the lyric is already near the top
    return currentPosition.itemLeadingEdge < 0.5;
  }

  // Helper method to scroll to current lyric if conditions are met
  void _scrollToCurrentLyricIfNeeded() {
    if (_showLyrics &&
        _currentLyricIndex >= 0 &&
        !_isCurrentLyricCloseToTop()) {
      _safeScrollOperation(() {
        _lyricsScrollController.scrollTo(
          index: _currentLyricIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }, "scroll to current lyric");
    }
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

  Future<void> _toggleLike() async {
    await HapticService().lightImpact();
    final song = _currentSongProvider.currentSong!;
    final likedSongsService =
        Provider.of<LikedSongsService>(context, listen: false);
    final wasLiked = await likedSongsService.toggleLike(song);

    // If song was just liked (not unliked), check for auto-download
    if (!wasLiked) {
      final prefs = await SharedPreferences.getInstance();
      final bool autoDL = prefs.getBool('autoDownloadLikedSongs') ?? false;
      if (autoDL && mounted && context.mounted) {
        Provider.of<CurrentSongProvider>(context, listen: false)
            .queueSongForDownload(song);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = _currentSongProvider; // Use cached provider
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoading = currentSongProvider.isLoadingAudio;
    final bool isRadio = currentSongProvider.isCurrentlyPlayingRadio;
    final AudioServiceRepeatMode repeatMode = currentSongProvider.repeatMode;

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
                  const Text('Playing From Radio',
                      style: TextStyle(fontSize: 12)),
                  if (currentSongProvider.stationName != null)
                    Text(currentSongProvider.stationName!,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              )
            : null,
        centerTitle: true,
        actions: [
          // Sleep timer countdown display when active
          if (_sleepTimerService.isTimerActive)
            Container(
              margin: const EdgeInsets.only(right: 8.0),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(16.0),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.3),
                  width: 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer,
                    size: 16.0,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4.0),
                  Text(
                    _sleepTimerService.getRemainingTimeString(),
                    style: TextStyle(
                      fontSize: 12.0,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  InkWell(
                    onTap: () => _sleepTimerService.cancelTimer(),
                    borderRadius: BorderRadius.circular(12.0),
                    child: Padding(
                      padding: const EdgeInsets.all(2.0),
                      child: Icon(
                        Icons.close,
                        size: 14.0,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
              // Sleep timer is now handled in the app bar, but keep a quick access option
              if (_sleepTimerService.sleepTimerEndTime == null)
                PopupMenuItem<String>(
                  value: 'sleep_timer',
                  child: Row(
                    children: [
                      Icon(Icons.timer,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      const Text('Set Sleep Timer'),
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
            _verticalDragAccumulator =
                (_verticalDragAccumulator + details.delta.dy)
                    .clamp(0.0, double.infinity);
          }
        },
        onVerticalDragEnd: (details) {
          final double screenHeight = MediaQuery.of(context).size.height;
          // Threshold for closing: drag > 20% of screen height with sufficient velocity
          if (_verticalDragAccumulator > screenHeight * 0.2 &&
              (details.primaryVelocity ?? 0) > 250) {
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
                    _dominantColor.withValues(
                        alpha:
                            (_backgroundAnimation.value.clamp(0.0, 1.0)) * 0.9),
                    _dominantColor.withValues(
                        alpha:
                            (_backgroundAnimation.value.clamp(0.0, 1.0)) * 0.5),
                    _dominantColor.withValues(
                        alpha:
                            (_backgroundAnimation.value.clamp(0.0, 1.0)) * 0.3),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0) +
                    EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    // Album Art Section OR Lyrics Section with Fade Transition
                    Expanded(
                      flex: 7,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: _showLyrics
                            ? (_lyricsLoading || _lyricsChanging
                                ? const Center(
                                    key: ValueKey('lyrics_loading'),
                                    child: CircularProgressIndicator(),
                                  )
                                : (_parsedLyrics.isNotEmpty
                                    ? _buildLyricsView(context)
                                    : Center(
                                        key: ValueKey('lyrics_empty'),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              _lyricsFetchedForCurrentSong
                                                  ? "No lyrics available."
                                                  : "Loading lyrics...",
                                              style: textTheme.titleMedium
                                                      ?.copyWith(
                                                          color: colorScheme
                                                              .onSurface
                                                              .withValues(
                                                                  alpha:
                                                                      0.7)) ??
                                                  TextStyle(
                                                      color: colorScheme
                                                          .onSurface
                                                          .withValues(
                                                              alpha: 0.7),
                                                      fontSize: 16.0),
                                              textAlign: TextAlign.center,
                                            ),
                                            if (_lyricsFetchedForCurrentSong) ...[
                                              const SizedBox(height: 8),
                                              Text(
                                                'Want to add lyrics to our database?',
                                                style: textTheme.bodyMedium
                                                        ?.copyWith(
                                                      color: colorScheme
                                                          .onSurface
                                                          .withValues(
                                                              alpha: 0.7),
                                                    ) ??
                                                    TextStyle(
                                                      color: colorScheme
                                                          .onSurface
                                                          .withValues(
                                                              alpha: 0.7),
                                                      fontSize: 14.0,
                                                    ),
                                                textAlign: TextAlign.center,
                                              ),
                                              const SizedBox(height: 4),
                                              GestureDetector(
                                                onTap: () async {
                                                  const url =
                                                      'https://lrclibplusplus.vercel.app/publish';
                                                  try {
                                                    await launchUrl(
                                                        Uri.parse(url));
                                                  } catch (e) {
                                                    debugPrint(
                                                        'Error launching URL: $e');
                                                  }
                                                },
                                                child: Text(
                                                  'Click here',
                                                  style: textTheme.bodyMedium
                                                          ?.copyWith(
                                                        color:
                                                            colorScheme.primary,
                                                        decoration:
                                                            TextDecoration
                                                                .underline,
                                                      ) ??
                                                      TextStyle(
                                                        color:
                                                            colorScheme.primary,
                                                        decoration:
                                                            TextDecoration
                                                                .underline,
                                                        fontSize: 14.0,
                                                      ),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      )))
                            : GestureDetector(
                                key: const ValueKey('album_art'),
                                onHorizontalDragEnd: (details) {
                                  if (details.primaryVelocity == null) {
                                    return; // Should not happen
                                  }

                                  // Swipe Left (finger moves from right to left) -> Next Song
                                  if (details.primaryVelocity! < -200) {
                                    // Negative velocity for left swipe
                                    _slideOffsetX =
                                        1.0; // New art slides in from right
                                    currentSongProvider.playNext();
                                  }
                                  // Swipe Right (finger moves from left to right) -> Previous Song
                                  else if (details.primaryVelocity! > 200) {
                                    // Positive velocity for right swipe
                                    _slideOffsetX =
                                        -1.0; // New art slides in from left
                                    currentSongProvider.playPrevious();
                                  }
                                },
                                // Ensure this GestureDetector also claims the gesture space over the album art.
                                behavior: HitTestBehavior.opaque,
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: AnimatedBuilder(
                                      animation: Listenable.merge([
                                        _scaleController,
                                        _slideController,
                                        _rotationController
                                      ]),
                                      builder: (context, child) {
                                        return Transform.scale(
                                          scale: _scaleAnimation.value,
                                          child: Transform.rotate(
                                            angle: _rotationAnimation.value,
                                            child: SlideTransition(
                                              position: _slideAnimation,
                                              child: Hero(
                                                tag:
                                                    'current-song-art-${currentSong.id}',
                                                child: Material(
                                                  elevation: 12.0,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          16.0),
                                                  shadowColor: Colors.black
                                                      .withValues(alpha: 0.5),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16.0),
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
                              style: textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface) ??
                                  TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                      fontSize: 24.0),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FadeTransition(
                            opacity: _textFadeAnimation,
                            child: Builder(
                              builder: (context) {
                                final displayText = isRadio
                                    ? (currentSong.artists.isNotEmpty
                                        ? currentSong.artists.join(', ')
                                        : "Live Radio")
                                    : (currentSong.artists.isNotEmpty
                                        ? currentSong.artists.join(', ')
                                        : 'Unknown Artist');
                                return Text(
                                  displayText,
                                  key: ValueKey<String>(
                                      'artist_${currentSong.id}'),
                                  style: textTheme.titleMedium?.copyWith(
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.7)) ??
                                      TextStyle(
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.7),
                                          fontSize: 16.0),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
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
                            Consumer<CurrentSongProvider>(
                              builder: (context, provider, _) {
                                final downloadProgress =
                                    provider.downloadProgress[currentSong.id];
                                final isDownloading = provider
                                    .activeDownloadTasks
                                    .containsKey(currentSong.id);
                                final isDownloaded = downloadProgress == 1.0 ||
                                    currentSong.isDownloaded;

                                if (isDownloaded) {
                                  return IconButton(
                                    icon: const Icon(
                                        Icons.check_circle_outline_rounded),
                                    tooltip: 'Downloaded',
                                    onPressed:
                                        null, // Disabled as it's already downloaded
                                    iconSize: 26.0,
                                    color: colorScheme.secondary,
                                  );
                                } else if (isDownloading) {
                                  return IconButton(
                                    icon: SizedBox(
                                      width: 26.0,
                                      height: 26.0,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.0,
                                        value: downloadProgress,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    onPressed:
                                        null, // Disabled while downloading
                                    tooltip: 'Downloading...',
                                    iconSize: 26.0,
                                  );
                                } else {
                                  return IconButton(
                                    icon: const Icon(Icons.download_rounded),
                                    onPressed: () =>
                                        _downloadCurrentSong(currentSong),
                                    tooltip: 'Download Song',
                                    iconSize: 26.0,
                                    color: colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                                  );
                                }
                              },
                            ),
                            // Add to Playlist
                            IconButton(
                              icon: const Icon(Icons.playlist_add_rounded),
                              onPressed: () => showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return AddToPlaylistDialog(
                                    song: currentSong,
                                  );
                                },
                              ),
                              tooltip: 'Add to Playlist',
                              iconSize: 26.0,
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            // Like button
                            Consumer<LikedSongsService>(
                              builder: (context, likedSongsService, child) {
                                final isLiked =
                                    likedSongsService.isLiked(currentSong.id);
                                return IconButton(
                                  icon: Icon(isLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border),
                                  onPressed: _toggleLike,
                                  tooltip: isLiked ? 'Unlike' : 'Like',
                                  iconSize: 26.0,
                                  color: isLiked
                                      ? colorScheme.secondary
                                      : colorScheme.onSurface
                                          .withValues(alpha: 0.7),
                                );
                              },
                            ),
                            // Lyrics toggle
                            IconButton(
                              icon: Icon(_showLyrics
                                  ? Icons.music_note_rounded
                                  : Icons.lyrics_outlined),
                              onPressed: () async {
                                // Debounce to prevent spam
                                if (_lyricsToggleDebounceTimer?.isActive ==
                                    true) {
                                  return;
                                }
                                await HapticService().lightImpact();

                                final song = _currentSongProvider.currentSong;
                                if (song == null) return;

                                bool newShowLyricsState = !_showLyrics;
                                if (newShowLyricsState &&
                                    !_lyricsFetchedForCurrentSong) {
                                  _loadAndProcessLyrics(song);
                                }

                                setState(() {
                                  _showLyrics = newShowLyricsState;
                                });

                                // If showing lyrics, scroll to current lyric after a short delay
                                if (newShowLyricsState &&
                                    _currentLyricIndex >= 0) {
                                  Future.delayed(
                                      const Duration(milliseconds: 100), () {
                                    if (mounted) {
                                      _scrollToCurrentLyricIfNeeded();
                                    }
                                  });
                                }

                                // Set debounce timer to prevent rapid toggling
                                _lyricsToggleDebounceTimer = Timer(
                                    const Duration(milliseconds: 300), () {
                                  _lyricsToggleDebounceTimer = null;
                                });
                              },
                              iconSize: 26.0,
                              tooltip:
                                  _showLyrics ? 'Hide Lyrics' : 'Show Lyrics',
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            // Queue
                            IconButton(
                              icon: const Icon(Icons.playlist_play_rounded),
                              onPressed: () => _showQueueBottomSheet(context),
                              tooltip: 'Show Queue',
                              iconSize: 26.0,
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.7),
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
                                provider.isShuffling
                                    ? Icons.shuffle
                                    : Icons.shuffle_outlined,
                                color: provider.isShuffling
                                    ? colorScheme.primary
                                    : colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                              ),
                              iconSize: 26,
                              onPressed: () => provider.toggleShuffle(),
                              tooltip: provider.isShuffling
                                  ? 'Shuffle On'
                                  : 'Shuffle Off',
                            ),
                          ),
                        if (!isRadio)
                          IconButton(
                            icon: const Icon(Icons.skip_previous_rounded),
                            iconSize: 42,
                            color: colorScheme.onSurface,
                            onPressed: () async {
                              await HapticService().lightImpact();
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
                                  color: colorScheme.secondary
                                      .withValues(alpha: 0.4),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                )
                              ]),
                          child: Consumer<CurrentSongProvider>(
                            builder: (context, provider, _) {
                              final isLoading = provider.isLoadingAudio;
                              final isPlaying = provider.isPlaying;
                              return IconButton(
                                icon: isLoading
                                    ? SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: colorScheme.onSecondary))
                                    : Icon(isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded),
                                iconSize: 48,
                                color: colorScheme.onSecondary,
                                onPressed: isLoading
                                    ? null
                                    : () async {
                                        await HapticService().mediumImpact();
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
                            onPressed: () async {
                              await HapticService().lightImpact();
                              _slideOffsetX = 1.0;
                              currentSongProvider.playNext();
                            },
                            tooltip: 'Next Song',
                          ),
                        if (!isRadio)
                          Consumer<CurrentSongProvider>(
                            builder: (context, provider, _) => IconButton(
                              icon: Icon(
                                provider.repeatMode ==
                                        AudioServiceRepeatMode.none
                                    ? Icons.repeat
                                    : provider.repeatMode ==
                                            AudioServiceRepeatMode.all
                                        ? Icons.repeat_outlined
                                        : Icons.repeat_one,
                                color: provider.repeatMode !=
                                        AudioServiceRepeatMode.none
                                    ? colorScheme.primary
                                    : colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                              ),
                              iconSize: 26,
                              onPressed: () => provider.toggleLoop(),
                              tooltip: provider.repeatMode ==
                                      AudioServiceRepeatMode.none
                                  ? 'Repeat Off'
                                  : provider.repeatMode ==
                                          AudioServiceRepeatMode.all
                                      ? 'Repeat Queue'
                                      : 'Repeat Song',
                            ),
                          ),
                      ],
                    ),
                    SizedBox(
                        height: MediaQuery.of(context).padding.bottom +
                            16), // For bottom padding
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
    final currentSongProvider = Provider.of<CurrentSongProvider>(context,
        listen: false); // Get provider instance

    // Prevent building the ScrollablePositionedList during unstable states
    if (_lyricsChanging || _lyricsLoading || _parsedLyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_lyricsLoading)
              const CircularProgressIndicator()
            else
              Text(
                "No lyrics available.",
                style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.7)) ??
                    TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.7),
                        fontSize: 16.0),
                textAlign: TextAlign.center,
              ),
            if (!_lyricsLoading) ...[
              const SizedBox(height: 8),
              Text(
                'Want to add lyrics to our database?',
                style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ) ??
                    TextStyle(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      fontSize: 14.0,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () async {
                  const url = 'https://lrclibplusplus.vercel.app/publish';
                  try {
                    await launchUrl(Uri.parse(url));
                  } catch (e) {
                    debugPrint('Error launching URL: $e');
                  }
                },
                child: Text(
                  'Click here',
                  style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ) ??
                      TextStyle(
                        color: colorScheme.primary,
                        decoration: TextDecoration.underline,
                        fontSize: 14.0,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      );
    }

    const int bottomPaddingLines = 3;

    // Mark the widget as attached after the next frame, but only if we have lyrics
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_isLyricsWidgetAttached &&
          _parsedLyrics.isNotEmpty &&
          !_lyricsLoading &&
          !_lyricsChanging &&
          _currentSongProvider.currentSong != null &&
          _lastLyricsType != null) {
        // Add a small delay to ensure the widget is fully stable before marking as attached
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted &&
              !_isLyricsWidgetAttached &&
              _parsedLyrics.isNotEmpty &&
              !_lyricsLoading &&
              !_lyricsChanging &&
              _currentSongProvider.currentSong != null &&
              _lastLyricsType != null) {
            setState(() {
              _isLyricsWidgetAttached = true;
            });
            debugPrint("Lyrics widget marked as attached");
          }
        });
      }
    });

    // Only build ScrollablePositionedList when widget is fully stable
    if (!_isLyricsWidgetAttached || _lyricsChanging || _lyricsLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return ScrollablePositionedList.builder(
      key: ValueKey(
          'lyrics_${_currentSongProvider.currentSong?.id ?? "no_song"}_${_areLyricsSynced ? "synced" : "plain"}'),
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
        final bool isCurrent = _areLyricsSynced &&
            index == _currentLyricIndex; // Highlight only if synced
        final bool wasCurrent = _areLyricsSynced &&
            index == _previousLyricIndex; // Was previously current

        return GestureDetector(
          onTap: () {
            if (_areLyricsSynced &&
                currentSongProvider.currentSong != null &&
                !currentSongProvider.isCurrentlyPlayingRadio) {
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
                    animation:
                        lineAnimation ?? const AlwaysStoppedAnimation(1.0),
                    builder: (context, child) {
                      // Calculate animation values
                      double opacity = 1.0;
                      Color textColor =
                          colorScheme.onSurface.withValues(alpha: 0.6);
                      FontWeight fontWeight = FontWeight.normal;
                      double fontSize = 20.0;

                      if (isCurrent) {
                        // Current line animations
                        opacity = 0.7 +
                            (0.3 *
                                (_lyricHighlightAnimation.value
                                    .clamp(0.0, 1.0)));
                        textColor = Color.lerp(
                          colorScheme.onSurface.withValues(alpha: 0.7),
                          colorScheme.primary,
                          _lyricHighlightAnimation.value,
                        )!;
                        fontWeight = FontWeight.bold;
                        fontSize = 20.0; // Fixed font size for synced lyrics
                      } else if (wasCurrent &&
                          _lyricTransitionAnimation.value < 1.0) {
                        // Previously current line - fade out effect (only during animation)
                        opacity = 1.0 -
                            (0.2 *
                                (_lyricTransitionAnimation.value
                                    .clamp(0.0, 1.0)));
                        textColor = Color.lerp(
                          colorScheme.primary,
                          colorScheme.onSurface.withValues(alpha: 0.4),
                          _lyricTransitionAnimation.value,
                        )!;
                        fontWeight = FontWeight.normal;
                        fontSize = 20.0; // Fixed font size for synced lyrics
                      } else if (_areLyricsSynced &&
                          _currentLyricIndex >= 0 &&
                          index < _currentLyricIndex) {
                        // All previous lyrics - decreased opacity and lighter color
                        opacity = 0.6;
                        textColor =
                            colorScheme.onSurface.withValues(alpha: 0.5);
                        fontWeight = FontWeight.normal;
                        fontSize = 20.0;
                      } else if (_areLyricsSynced &&
                          _currentLyricIndex >= 0 &&
                          index > _currentLyricIndex) {
                        // Future lyrics - normal appearance
                        opacity = 0.7;
                        textColor =
                            colorScheme.onSurface.withValues(alpha: 0.8);
                        fontWeight = FontWeight.normal;
                        fontSize = 20.0;
                      } else if (!_areLyricsSynced &&
                          _parsedLyrics.isNotEmpty) {
                        opacity = 1.0;
                        textColor = Color.lerp(
                          colorScheme.onSurface.withValues(alpha: 0.7),
                          colorScheme.secondary,
                          1.0,
                        )!;
                        fontWeight = FontWeight.bold;
                        fontSize = 22.0;
                      } else {
                        // Default appearance for unsynced lyrics or edge cases
                        opacity = 0.7;
                        textColor =
                            colorScheme.onSurface.withValues(alpha: 0.8);
                        fontWeight = FontWeight.normal;
                        fontSize = 20.0;
                      }

                      return Opacity(
                        opacity: opacity,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8.0, horizontal: 16.0),
                          child: line.type == LyricLineType.loadingDots
                              ? _buildLoadingDots(textColor, fontSize, index)
                              : Text(
                                  line.text,
                                  textAlign: TextAlign.center,
                                  style: textTheme.titleLarge?.copyWith(
                                        color: textColor,
                                        fontWeight: fontWeight,
                                        fontSize: fontSize,
                                      ) ??
                                      TextStyle(
                                        color: textColor,
                                        fontWeight: fontWeight,
                                        fontSize: fontSize,
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
    if (playbarArtProvider != null &&
        playbarArtId == currentSong.id &&
        !PlaybarState.isArtworkLoading()) {
      return Image(
        key: ValueKey('art_${currentSong.id}'),
        image: playbarArtProvider,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            _placeholderArt(context, isRadio),
      );
    }

    // If we have a current art provider, use it
    if (_currentArtProvider != null) {
      return Image(
        key: ValueKey('art_${currentSong.id}'),
        image: _currentArtProvider!,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            _placeholderArt(context, isRadio),
      );
    }

    // If artwork is loading, show a subtle loading state
    if (_artLoading) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Container(
          key: ValueKey('loading_art_${currentSong.id}'),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.3),
                Theme.of(context)
                    .colorScheme
                    .secondaryContainer
                    .withValues(alpha: 0.3),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context)
                      .colorScheme
                      .onPrimaryContainer
                      .withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Fallback to placeholder
    return _placeholderArt(context, isRadio);
  }

  Widget _placeholderArt(BuildContext context, bool isRadio) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.7),
            Theme.of(context)
                .colorScheme
                .secondaryContainer
                .withValues(alpha: 0.7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          isRadio ? Icons.radio_rounded : Icons.music_note_rounded,
          size: 100,
          color: Theme.of(context)
              .colorScheme
              .onPrimaryContainer
              .withValues(alpha: 0.8),
        ),
      ),
    );
  }

  void _showPlaybackSpeedDialog(BuildContext context) async {
    // Disable on iOS
    if (Platform.isIOS) return;

    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    final colorScheme = Theme.of(context).colorScheme;

    // Load custom speed presets
    final prefs = await SharedPreferences.getInstance();
    final customSpeedPresetsJson =
        prefs.getStringList('customSpeedPresets') ?? [];
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
                final label =
                    speedLabels[speed] ?? '${speed.toStringAsFixed(2)}x';
                return _buildSpeedOption(
                    context, speed, label, currentSongProvider, colorScheme);
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

  Widget _buildSpeedOption(BuildContext context, double speed, String label,
      CurrentSongProvider provider, ColorScheme colorScheme) {
    final isSelected = provider.playbackSpeed == speed;

    return ListTile(
      title: Text(
        label,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? colorScheme.primary : colorScheme.onSurface,
        ),
      ),
      trailing:
          isSelected ? Icon(Icons.check, color: colorScheme.primary) : null,
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
      // For local files, we need to resolve the path properly
      // This method is kept for backward compatibility but should use the service
      return FileImage(File(artUrl));
    }
  }

  // 4. Extracted seek bar widget
  Widget _buildSeekBar(CurrentSongProvider currentSongProvider, bool isRadio,
      TextTheme textTheme) {
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

  /// Check if an album is already offline in the library
  Future<Album?> _findOfflineAlbum(String albumTitle, String artistName) async {
    try {
      final albumManager = AlbumManagerService();
      final savedAlbums = albumManager.savedAlbums;

      // First check if the album is saved in the album manager
      for (final savedAlbum in savedAlbums) {
        if (savedAlbum.title.toLowerCase() == albumTitle.toLowerCase() &&
            savedAlbum.artistName.toLowerCase() == artistName.toLowerCase()) {
          // Check if all tracks in this album are downloaded
          bool allTracksDownloaded = true;
          for (final track in savedAlbum.tracks) {
            if (!track.isDownloaded ||
                track.localFilePath == null ||
                track.localFilePath!.isEmpty) {
              allTracksDownloaded = false;
              break;
            }
          }

          if (allTracksDownloaded) {
            return savedAlbum;
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('Error checking for offline album: $e');
      return null;
    }
  }

  Future<void> _viewAlbum(BuildContext context, Song song) async {
    if (song.album == null || song.album!.isEmpty || song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Album information is not available for this song.')),
      );
      return;
    }

    // Check if album is already offline in library
    final offlineAlbum = await _findOfflineAlbum(song.album!, song.artist);
    if (offlineAlbum != null) {
      // Album is offline, navigate directly to it
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AlbumScreen(album: offlineAlbum),
        ),
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
      final albumDetails = song.albumId != null
          ? await _apiService.getAlbum(song.albumId!)
          : null;

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
            SnackBar(
                content:
                    Text('Could not find details for album: "${song.album}".')),
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
        const SnackBar(
            content:
                Text('Artist information is not available for this song.')),
      );
      return;
    }

    try {
      // Use artistId if available, otherwise use artist name
      final artistQuery =
          song.artistId.isNotEmpty ? song.artistId : song.artist;

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
    int selectedMinutes = _sleepTimerService.sleepTimerMinutes ?? 30;
    const List<int> presetMinutes = [30, 60, 90];

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28.0),
              ),
              elevation: 0,
              backgroundColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(24.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(28.0),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.bedtime,
                            color: Theme.of(context).colorScheme.primary,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sleep Timer',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              Text(
                                'Stop playback automatically',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Current selection display
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.timer,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$selectedMinutes minutes',
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Preset buttons
                    Text(
                      'Quick Select',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: presetMinutes.map((minutes) {
                        final isSelected = selectedMinutes == minutes;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          child: Material(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                setState(() {
                                  selectedMinutes = minutes;
                                });
                                HapticService().lightImpact();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                child: Text(
                                  '$minutes min',
                                  style: TextStyle(
                                    color: isSelected
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onPrimary
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),

                    // Custom slider
                    Text(
                      'Custom Duration',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 12),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        inactiveTrackColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        thumbColor: Theme.of(context).colorScheme.primary,
                        overlayColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.2),
                        valueIndicatorColor:
                            Theme.of(context).colorScheme.primary,
                        valueIndicatorTextStyle: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                      child: Slider(
                        value: selectedMinutes.toDouble(),
                        min: 1,
                        max: 180, // 3 hours max
                        divisions: 179,
                        label: '$selectedMinutes min',
                        onChanged: (value) {
                          setState(() {
                            selectedMinutes = value.round();
                          });
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '1 min',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                        Text(
                          '3 hours',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: selectedMinutes > 0
                                ? () {
                                    _sleepTimerService
                                        .startTimer(selectedMinutes);
                                    Navigator.of(context).pop();
                                    HapticService().mediumImpact();
                                  }
                                : null,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Start Timer'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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
          stream: currentSongProvider
              .positionStream, // Ensure this is a stable stream
          builder: (context, snapshot) {
            var position = snapshot.data ?? Duration.zero;
            if (position == Duration.zero &&
                currentSongProvider.currentPosition != Duration.zero) {
              position = currentSongProvider.currentPosition;
            }
            if (isRadio) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 32.0),
                child:
                    Text("LIVE", style: TextStyle(fontWeight: FontWeight.bold)),
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
            final double clampedValue =
                position.inMilliseconds.toDouble().clamp(0.0, maxValue);
            final double sliderVal =
                isSeeking ? (sliderValue ?? clampedValue) : clampedValue;
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
                      Text(
                          formatDuration(
                              Duration(milliseconds: sliderVal.round())),
                          style: textTheme.bodySmall),
                      Text(formatDuration(duration),
                          style: textTheme.bodySmall),
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
