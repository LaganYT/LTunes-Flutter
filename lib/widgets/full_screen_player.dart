import 'dart:ui'; // For ImageFilter
import 'dart:convert'; // For jsonEncode
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart'; // Ensure CurrentSongProvider is imported
import '../models/song.dart'; // Ensure Song model is imported
import '../models/lyrics_data.dart'; // Import LyricsData
import 'package:path_provider/path_provider.dart'; // For getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // For path joining
import 'dart:io'; // For File operations
import 'package:shared_preferences/shared_preferences.dart'; // For SharedPreferences
import 'package:palette_generator/palette_generator.dart'; // Added for color extraction
// ignore: unused_import
import '../services/playlist_manager_service.dart';
import '../services/api_service.dart'; // Import ApiService
import '../screens/song_detail_screen.dart'; // For AddToPlaylistDialog
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart'; // Import for synced lyrics

// Helper class for parsed lyric lines
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});
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

  late CurrentSongProvider _currentSongProvider;
  late ApiService _apiService;

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

  @override
  void initState() {
    super.initState();
    _apiService = ApiService();

    _textFadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _textFadeAnimation = CurvedAnimation(
      parent: _textFadeController,
      curve: Curves.easeIn,
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

    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    _previousSongId = _currentSongProvider.currentSong?.id;

    // Initial lyrics state reset (lyrics will be loaded on demand or if _showLyrics is true)
    _resetLyricsState();

    if (_currentSongProvider.currentSong != null) {
      // Initial appearance: art fades/slides in from right, text fades in
      _albumArtSlideAnimation = Tween<Offset>(
        begin: const Offset(0.3, 0.0), // Slight slide from right for initial
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _albumArtSlideController,
        curve: Curves.easeInOut,
      ));
      _albumArtSlideController.forward();
      _textFadeController.forward();
      // If lyrics view should be shown initially (e.g., persisted state, not covered here)
      // and lyrics are not fetched, trigger loading.
      // For now, lyrics are not shown by default on init.
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updatePalette(_currentSongProvider.currentSong);
    });

    _currentSongProvider.addListener(_onSongChanged);
    _loadLikeState(); // load initial like state
  }

  void _resetLyricsState() {
    if (mounted) {
      setState(() {
        _parsedLyrics = [];
        _currentLyricIndex = -1;
        _areLyricsSynced = false;
        _lyricsFetchedForCurrentSong = false;
        _lyricsLoading = false;
        // _showLyrics remains as is, or reset if desired:
        // _showLyrics = false; 
      });
    }
  }

  void _onSongChanged() {
    if (!mounted) return;

    final newSong = _currentSongProvider.currentSong;
    final newSongId = newSong?.id;

    if (newSongId != _previousSongId) {
      // Update slide animation based on _slideOffsetX
      // If _slideOffsetX is 0.0, it means the art should just fade (or appear if no fade controller for art)
      // For this implementation, if _slideOffsetX is 0, it means slide from a subtle default (e.g. slight scale/fade or no slide)
      // Let's make it so that if _slideOffsetX is 0, it slides in from a default direction (e.g. right, subtly) or just fades.
      // The user request is "icon to slide in", so it should always slide.
      
      double effectiveSlideOffsetX = _slideOffsetX;
      if (_previousSongId == null && newSongId != null) { // First song loaded after screen init
          effectiveSlideOffsetX = 0.3; // Default slide from right for first song
      } else if (_slideOffsetX == 0.0 && newSongId != null) { // Song changed by non-skip action (e.g. queue end, direct selection)
          effectiveSlideOffsetX = 0.3; // Default slide from right
      }


      _albumArtSlideAnimation = Tween<Offset>(
        begin: Offset(effectiveSlideOffsetX, 0.0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _albumArtSlideController,
        curve: Curves.easeInOut,
      ));

      _albumArtSlideController.forward(from: 0.0);
      _textFadeController.forward(from: 0.0);

      _updatePalette(newSong);
      _resetLyricsState(); // Reset lyrics state for the new song

      // If the song is downloaded but lyrics are missing, try to fetch and save them.
      if (newSong != null &&
          newSong.isDownloaded &&
          (newSong.syncedLyrics == null || newSong.syncedLyrics!.isEmpty) &&
          (newSong.plainLyrics == null || newSong.plainLyrics!.isEmpty)) {
        // Fire and forget: This will run in the background.
        _fetchAndSaveLyricsForSong(newSong);
      }

      if (_showLyrics && newSong != null) { // If lyrics view was active, load for new song
        _loadAndProcessLyrics(newSong);
      }

      _previousSongId = newSongId;
      _slideOffsetX = 0.0; // Reset for next non-skip change
       _loadLikeState();
    }
  }

  // New method to fetch and save lyrics for a downloaded song
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
        _currentLyricIndex = -1;
      });
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

  Future<void> _updatePalette(Song? song) async {
    if (song == null || song.albumArtUrl.isEmpty) return;
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
      // Darken or lighten the extracted dominant color based on theme
      final baseColor = palette.dominantColor?.color ?? Theme.of(context).colorScheme.background;
      final hsl = HSLColor.fromColor(baseColor);

      // Determine theme brightness
      final Brightness currentBrightness = Theme.of(context).brightness;
      final bool isDarkMode = currentBrightness == Brightness.dark;

      final adjustedColor = hsl.withLightness(isDarkMode ? 0.2 : 0.8).toColor(); // 0.2 for dark, 0.8 for light

      setState(() {
        _dominantColor = adjustedColor;
      });
    } catch (_) {
      // ignore any errors
    }
  }

  @override
  void dispose() {
    _currentSongProvider.removeListener(_onSongChanged);
    _textFadeController.dispose();
    _albumArtSlideController.dispose();
    super.dispose();
  }

  Future<void> _downloadCurrentSong(Song song) async {
    // Use the CurrentSongProvider to handle the download
    Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);

    // Show a snackbar indicating the download has started
    // You might want to check if the song is already downloading via provider state
    // to avoid redundant messages, but downloadSongInBackground itself has checks.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Download started for "${song.title}"...')),
    );
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, // Make sheet background transparent
      builder: (BuildContext bc) {
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
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 8.0, 16.0), // Adjusted padding
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
                              Navigator.pop(context); // Close the bottom sheet
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Queue cleared')),
                              );
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
                    Expanded(
                      child: Center(
                        child: Text(
                          'Queue is empty.',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        controller: controller,
                        itemCount: queue.length,
                        itemBuilder: (BuildContext context, int index) {
                          final song = queue[index];
                          final bool isCurrentlyPlaying = song.id == currentSong?.id;
                          return ListTile(
                            leading: FutureBuilder<String>(
                              future: _resolveLocalArtPath(song.albumArtUrl),
                              builder: (context, snapshot) {
                                Widget imageWidget;
                                if (song.albumArtUrl.startsWith('http')) {
                                  imageWidget = Image.network(
                                    song.albumArtUrl, width: 40, height: 40, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                                  );
                                } else if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                                  imageWidget = Image.file(
                                    File(snapshot.data!), width: 40, height: 40, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                                  );
                                } else {
                                  imageWidget = const Icon(Icons.music_note, size: 40);
                                }
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: imageWidget,
                                );
                              },
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isCurrentlyPlaying ? FontWeight.bold : FontWeight.normal,
                                color: isCurrentlyPlaying ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            subtitle: Text(
                              song.artist.isNotEmpty ? song.artist : "Unknown Artist",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                             trailing: isCurrentlyPlaying
                                ? Icon(Icons.bar_chart_rounded, color: Theme.of(context).colorScheme.primary)
                                : null,
                            onTap: () {
                              currentSongProvider.playSong(song); // Ensure the clicked song plays
                              Navigator.pop(context); // Close the bottom sheet
                            },
                          );
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
      setState(() {
        _currentLyricIndex = newIndex;
      });
      if (newIndex != -1 && _lyricsScrollController.isAttached) {
        _lyricsScrollController.scrollTo(
          index: newIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.3, // Scroll to make the item appear 30% from the top
        );
      }
    }
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
      list.removeWhere((s) {
        try {
          return Song.fromJson(jsonDecode(s) as Map<String, dynamic>).id == song.id;
        } catch (_) {
          return false;
        }
      });
    } else {
      list.add(jsonStr);
    }
    await prefs.setStringList('liked_songs', list);
    setState(() => _isLiked = !_isLiked);
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
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

    Widget albumArtWidget;
    if (currentSong.albumArtUrl.isNotEmpty) {
      if (currentSong.albumArtUrl.startsWith('http')) {
        albumArtWidget = Image.network(
          currentSong.albumArtUrl,
          fit: BoxFit.cover,
          key: ValueKey<String>('art_${currentSong.id}_network'),
          errorBuilder: (context, error, stackTrace) => _placeholderArt(context, isRadio),
        );
      } else {
        albumArtWidget = FutureBuilder<String>(
          future: _resolveLocalArtPath(currentSong.albumArtUrl),
          key: ValueKey<String>('art_${currentSong.id}_local'),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
              return Image.file(
                File(snapshot.data!),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => _placeholderArt(context, isRadio),
              );
            }
            return _placeholderArt(context, isRadio);
          },
        );
      }
    } else {
      albumArtWidget = _placeholderArt(context, isRadio);
    }

    // Determine if lyrics should be shown (only if available and toggle is on)
    // final bool canShowLyrics = _parsedLyrics.isNotEmpty && _showLyrics; // Old logic

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
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
          if (!isRadio) // Like button not applicable for radio
            IconButton(
              icon: Icon(_isLiked ? Icons.favorite : Icons.favorite_border),
              onPressed: _toggleLike,
              tooltip: _isLiked ? 'Unlike' : 'Like',
              iconSize: 22.0, // Slightly larger for better visibility
            ),
          if (!isRadio)
            // Always visible Toggle Lyrics Button
            IconButton(
              icon: Icon(_showLyrics ? Icons.music_note_rounded : Icons.lyrics_outlined),
              onPressed: () {
                final song = _currentSongProvider.currentSong;
                if (song == null) return;

                bool newShowLyricsState = !_showLyrics;

                if (newShowLyricsState && !_lyricsFetchedForCurrentSong) {
                  _loadAndProcessLyrics(song);
                }
                
                setState(() {
                  _showLyrics = newShowLyricsState;
                });
              },
              iconSize: 22.0,
              tooltip: _showLyrics ? 'Hide Lyrics' : 'Show Lyrics',
            ),
          if (!isRadio)
            IconButton(
              icon: const Icon(Icons.playlist_play_rounded),
              onPressed: () => _showQueueBottomSheet(context),
              tooltip: 'Show Queue',
              iconSize: 24.0, // Slightly larger for better visibility
            ),
          if (!isRadio)
            if (currentSong.isDownloaded)
              const IconButton(
                icon: Icon(Icons.check_circle_outline_rounded),
                tooltip: 'Downloaded',
                onPressed: null, // Disabled as it's already downloaded
                iconSize: 24.0, // Slightly larger for better visibility
              )
            else
              IconButton(
                icon: const Icon(Icons.download_rounded),
                onPressed: () => _downloadCurrentSong(currentSong),
                tooltip: 'Download Song',
                iconSize: 24.0, // Slightly larger for better visibility
              ),
          if (!isRadio) // "Add to Playlist" not applicable for radio
            IconButton(
              icon: const Icon(Icons.playlist_add_rounded),
              onPressed: () => _showAddToPlaylistDialog(context, currentSong),
              tooltip: 'Add to Playlist',
              iconSize: 24.0, // Slightly larger for better visibility
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
        child: Container(
          decoration: BoxDecoration(
            color: _dominantColor, 
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0) + EdgeInsets.only(top: MediaQuery.of(context).padding.top + kToolbarHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Album Art Section OR Lyrics Section
                Expanded(
                  flex: 5,
                  child: _showLyrics
                      ? (_lyricsLoading
                          ? const Center(child: CircularProgressIndicator())
                          : (_parsedLyrics.isNotEmpty
                              ? _buildLyricsView(context)
                              : Center(
                                  child: Text(
                                    _lyricsFetchedForCurrentSong ? "No lyrics available." : "Loading lyrics...",
                                    style: textTheme.titleMedium?.copyWith(color: colorScheme.onBackground.withOpacity(0.7)),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                            )
                        )
                      : GestureDetector( 
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
                        child: SlideTransition(
                          position: _albumArtSlideAnimation,
                          child: Hero(
                            tag: 'albumArt_${currentSong.id}',
                            child: Material(
                              elevation: 12.0,
                              borderRadius: BorderRadius.circular(16.0),
                              shadowColor: Colors.black.withOpacity(0.5),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16.0),
                                child: albumArtWidget,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Song Info Section
                Expanded(
                  flex: 3,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FadeTransition(
                        opacity: _textFadeAnimation,
                        child: Text(
                          currentSong.title,
                          key: ValueKey<String>('title_${currentSong.id}'),
                          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.onBackground),
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
                          style: textTheme.titleMedium?.copyWith(color: colorScheme.onBackground.withOpacity(0.7)),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                // Seek Bar Section
                Column(
                  children: [
                    StreamBuilder<Duration>(
                      stream: currentSongProvider.onPositionChanged,
                      builder: (context, snapshot) {
                        var position = snapshot.data ?? Duration.zero;
                        final duration = currentSongProvider.totalDuration ?? Duration.zero;
                        
                        // When looping a single song, the position reported can exceed the duration
                        // just before it loops. To provide a smoother UI experience and show it
                        // resetting to 0:00 as requested, we adjust the position value here.
                        if (loopMode == LoopMode.song && !isRadio && duration > Duration.zero && position >= duration) {
                          position = Duration.zero;
                        }

                        // Update lyrics based on position
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                           if (mounted && _areLyricsSynced) _updateCurrentLyricIndex(position); // Only if synced
                        });

                        return Column(
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context),
                              child: Slider(
                                value: position.inMilliseconds.toDouble(),
                                min: 0.0,
                                max: duration.inMilliseconds.toDouble() > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                                onChanged: (value) {
                                  if (isRadio) return;
                                  currentSongProvider.seek(Duration(milliseconds: value.round()));
                                },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_formatDuration(position), style: textTheme.bodySmall?.copyWith(color: colorScheme.onBackground.withOpacity(0.7))),
                                  Text(_formatDuration(duration), style: textTheme.bodySmall?.copyWith(color: colorScheme.onBackground.withOpacity(0.7))),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Controls Section
                Row(
                  mainAxisAlignment: isRadio
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.spaceBetween,
                  children: [
                    if (!isRadio)
                      IconButton(
                       icon: Icon(
                         currentSongProvider.isShuffling ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                         color: currentSongProvider.isShuffling ? colorScheme.secondary : colorScheme.onBackground.withOpacity(0.7),
                       ),
                       iconSize: 26,
                       onPressed: () => currentSongProvider.toggleShuffle(),
                       tooltip: 'Shuffle',
                     ),
                    if (!isRadio)
                      IconButton(
                       icon: const Icon(Icons.skip_previous_rounded),
                       iconSize: 42,
                       color: colorScheme.onBackground,
                       onPressed: () {
                        _slideOffsetX = -1.0; // Slide from left
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
                            color: colorScheme.secondary.withOpacity(0.4),
                            blurRadius: 10,
                            spreadRadius: 2,
                          )
                        ]
                      ),
                      child: IconButton(
                        icon: isLoading 
                            ? SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 2.5, color: colorScheme.onSecondary))
                            : Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        iconSize: 48,
                        color: colorScheme.onSecondary,
                        onPressed: isLoading ? null : () {
                          if (isPlaying) {
                            currentSongProvider.pauseSong();
                          } else {
                            currentSongProvider.resumeSong();
                          }
                        },
                        tooltip: isPlaying ? 'Pause' : 'Play',
                      ),
                    ),
                    if (!isRadio)
                      IconButton(
                       icon: const Icon(Icons.skip_next_rounded),
                       iconSize: 42,
                       color: colorScheme.onBackground,
                       onPressed: () {
                         _slideOffsetX = 1.0; // Slide from right
                         currentSongProvider.playNext();
                       },
                       tooltip: 'Next Song',
                     ),
                    if (!isRadio)
                      IconButton(
                       icon: Icon(
                         loopMode == LoopMode.none ? Icons.repeat_rounded : 
                         loopMode == LoopMode.queue ? Icons.repeat_on_rounded : Icons.repeat_one_on_rounded,
                         color: loopMode != LoopMode.none ? colorScheme.secondary : colorScheme.onBackground.withOpacity(0.7),
                       ),
                       iconSize: 26,
                       onPressed: () => currentSongProvider.toggleLoop(),
                       tooltip: loopMode == LoopMode.none ? 'Repeat Off' : 
                                loopMode == LoopMode.queue ? 'Repeat Queue' : 'Repeat Song',
                     ),
                  ],
                ),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 16), // For bottom padding
              ],
            ),
          ),
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
          style: textTheme.titleMedium?.copyWith(color: colorScheme.onBackground.withOpacity(0.7)),
        ),
      );
    }

    return ScrollablePositionedList.builder(
      itemCount: _parsedLyrics.length,
      itemScrollController: _lyricsScrollController,
      itemPositionsListener: _lyricsPositionsListener,
      itemBuilder: (context, index) {
        final line = _parsedLyrics[index];
        final bool isCurrent = _areLyricsSynced && index == _currentLyricIndex; // Highlight only if synced
        return GestureDetector(
          onTap: () {
            if (_areLyricsSynced && currentSongProvider.currentSong != null && !currentSongProvider.isCurrentlyPlayingRadio) {
              currentSongProvider.seek(line.timestamp);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
            child: Text(
              line.text,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                color: isCurrent ? colorScheme.secondary : colorScheme.onBackground.withOpacity(isCurrent ? 1.0 : 0.6),
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                fontSize: isCurrent ? 22 : 20, // Slightly larger for current line if synced
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholderArt(BuildContext context, bool isRadio) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primaryContainer.withOpacity(0.7),
            Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          isRadio ? Icons.radio_rounded : Icons.music_note_rounded,
          size: 100,
          color: Theme.of(context).colorScheme.onPrimaryContainer.withOpacity(0.8),
        ),
      ),
    );
  }
}