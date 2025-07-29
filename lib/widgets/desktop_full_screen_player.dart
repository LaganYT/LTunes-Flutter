import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import '../models/song.dart';
import '../models/lyrics_data.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/error_handler_service.dart';
import '../services/api_service.dart';
import '../services/sleep_timer_service.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'dart:math' as math;

// Helper class for parsed lyric lines
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});
}

class DesktopFullScreenPlayer extends StatefulWidget {
  const DesktopFullScreenPlayer({super.key});

  @override
  State<DesktopFullScreenPlayer> createState() => _DesktopFullScreenPlayerState();
}

class _DesktopFullScreenPlayerState extends State<DesktopFullScreenPlayer> with TickerProviderStateMixin {
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
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final ApiService _apiService = ApiService();
  final SleepTimerService _sleepTimerService = SleepTimerService();
  Set<String> _likedSongIds = {};

  // Lyrics State
  bool _showLyrics = false;
  List<LyricLine> _parsedLyrics = [];
  int _currentLyricIndex = -1;
  bool _areLyricsSynced = false; 
  bool _lyricsLoading = false;
  bool _lyricsFetchedForCurrentSong = false;

  final ItemScrollController _lyricsScrollController = ItemScrollController();
  final ItemPositionsListener _lyricsPositionsListener = ItemPositionsListener.create();

  // Animation controllers
  late AnimationController _textFadeController;
  late Animation<double> _textFadeAnimation;

  @override
  void initState() {
    super.initState();

    _textFadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _textFadeAnimation = CurvedAnimation(
      parent: _textFadeController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _currentSongProvider?.removeListener(_onSongChanged);
    _textFadeController.dispose();
    super.dispose();
  }

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
    _loadLikedSongIds();
  }

  Future<void> _loadLikedSongIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('liked_songs') ?? [];
    final ids = raw.map((s) {
      try {
        return (jsonDecode(s) as Map<String, dynamic>)['id'] as String;
      } catch (_) {
        return null;
      }
    }).whereType<String>().toSet();
    
    if (mounted) {
      setState(() {
        _likedSongIds = ids;
      });
    }
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
          
          // Reset lyrics state for new song
          _lyricsFetchedForCurrentSong = false;
          _parsedLyrics = [];
          _currentLyricIndex = -1;
          _areLyricsSynced = false;
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
    if (_currentArtId == song.id && _currentArtProvider != null) return;
    
    setState(() {
      _artLoading = true;
    });
    
    if (song.albumArtUrl.startsWith('http')) {
      _currentArtProvider = CachedNetworkImageProvider(song.albumArtUrl);
      _currentArtId = song.id;
      setState(() {
        _artLoading = false;
      });
    } else {
      _resolveLocalArtPath(song.albumArtUrl).then((path) {
        if (mounted && song.id == _currentSongProvider?.currentSong?.id) {
          if (path.isNotEmpty) {
            _currentArtProvider = FileImage(File(path));
            _currentArtId = song.id;
          }
          setState(() {
            _artLoading = false;
          });
        }
      }).catchError((e) {
        debugPrint('Error updating art provider: $e');
        if (mounted) {
          setState(() {
            _artLoading = false;
          });
        }
      });
    }
  }

  Future<void> _toggleLike() async {
    final currentSong = _currentSongProvider?.currentSong;
    if (currentSong == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('liked_songs') ?? [];
      
      if (_likedSongIds.contains(currentSong.id)) {
        // Remove from liked songs
        raw.removeWhere((songJson) {
          try {
            final songData = jsonDecode(songJson) as Map<String, dynamic>;
            return songData['id'] == currentSong.id;
          } catch (e) {
            return false;
          }
        });
      } else {
        // Add to liked songs
        raw.add(jsonEncode(currentSong.toJson()));
      }
      
      await prefs.setStringList('liked_songs', raw);
      
      setState(() {
        if (_likedSongIds.contains(currentSong.id)) {
          _likedSongIds.remove(currentSong.id);
        } else {
          _likedSongIds.add(currentSong.id);
        }
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'toggle_like');
    }
  }

  Future<void> _loadAndProcessLyrics(Song song) async {
    if (_lyricsLoading) return;
    
    setState(() {
      _lyricsLoading = true;
    });

    try {
      final lyricsData = await _apiService.fetchLyrics(song.artist, song.title);
      if (lyricsData != null && mounted) {
        _parseLyrics(lyricsData.displayLyrics);
        setState(() {
          _lyricsFetchedForCurrentSong = true;
          _lyricsLoading = false;
        });
      } else {
        setState(() {
          _lyricsLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading lyrics: $e');
      setState(() {
        _lyricsLoading = false;
      });
    }
  }

  void _parseLyrics(String lyrics) {
    final lines = lyrics.split('\n');
    final parsed = <LyricLine>[];
    
    for (final line in lines) {
      final match = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]').firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final milliseconds = int.parse(match.group(3)!.padRight(3, '0'));
        
        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
        
        final text = line.replaceAll(RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]'), '').trim();
        if (text.isNotEmpty) {
          parsed.add(LyricLine(timestamp: timestamp, text: text));
        }
      }
    }
    
    _parsedLyrics = parsed;
    _areLyricsSynced = parsed.isNotEmpty;
  }

  void _updateLyricsIndex() {
    if (!_areLyricsSynced || _parsedLyrics.isEmpty) return;
    
    final currentPosition = _currentSongProvider?.currentPosition ?? Duration.zero;
    int newIndex = -1;
    
    for (int i = 0; i < _parsedLyrics.length; i++) {
      if (_parsedLyrics[i].timestamp <= currentPosition) {
        newIndex = i;
      } else {
        break;
      }
    }
    
    if (newIndex != _currentLyricIndex && newIndex >= 0) {
      setState(() {
        _currentLyricIndex = newIndex;
      });
      
      // Auto-scroll to current lyric
      if (_showLyrics && _lyricsScrollController.isAttached) {
        _lyricsScrollController.scrollTo(
          index: math.max(0, newIndex - 2),
          duration: const Duration(milliseconds: 300),
        );
      }
    }
  }

  void _showPlaybackSpeedDialog(BuildContext context) {
    final currentSpeed = _currentSongProvider?.playbackSpeed ?? 1.0;
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playback Speed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: speeds.map((speed) => ListTile(
            title: Text('${speed}x'),
            trailing: currentSpeed == speed ? const Icon(Icons.check, color: Color(0xFFFF9800)) : null,
            onTap: () {
              _currentSongProvider?.setPlaybackSpeed(speed);
              Navigator.of(context).pop();
            },
          )).toList(),
        ),
      ),
    );
  }

  void _showSleepTimerDialog(BuildContext context) {
    final times = [15, 30, 45, 60, 90, 120];
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sleep Timer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...times.map((minutes) => ListTile(
              title: Text('$minutes minutes'),
              onTap: () {
                                 _sleepTimerService.startTimer(minutes);
                Navigator.of(context).pop();
              },
            )),
            ListTile(
              title: const Text('Cancel Timer'),
              onTap: () {
                                 _sleepTimerService.cancelTimer();
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumArt() {
    final currentSong = _currentSongProvider?.currentSong;
    if (currentSong == null) {
      return Container(
        width: 300,
        height: 300,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.music_note,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Container(
      width: 280,
      height: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _currentArtProvider != null && _currentArtId == currentSong.id
          ? Image(
              image: _currentArtProvider!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _buildPlaceholderArtwork(),
            )
          : CachedNetworkImage(
              imageUrl: currentSong.albumArtUrl,
              fit: BoxFit.cover,
              placeholder: (context, url) => _buildPlaceholderArtwork(),
              errorWidget: (context, url, error) => _buildPlaceholderArtwork(),
            ),
      ),
    );
  }

  Widget _buildPlaceholderArtwork() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.album,
        size: 64,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildSongInfo() {
    final currentSong = _currentSongProvider?.currentSong;
    if (currentSong == null) {
      return Column(
        children: [
          Text(
            'No song playing',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start playing a song to see details',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final isLiked = _likedSongIds.contains(currentSong.id);

    return Column(
      children: [
        Text(
          currentSong.title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          currentSong.artist,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _toggleLike,
              icon: Icon(
                isLiked ? Icons.favorite : Icons.favorite_border,
                color: isLiked ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurfaceVariant,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            IconButton(
              onPressed: () {
                final song = _currentSongProvider?.currentSong;
                if (song == null) return;
                bool newShowLyricsState = !_showLyrics;
                if (newShowLyricsState && !_lyricsFetchedForCurrentSong) {
                  _loadAndProcessLyrics(song);
                }
                setState(() {
                  _showLyrics = newShowLyricsState;
                });
              },
              icon: Icon(
                _showLyrics ? Icons.music_note_rounded : Icons.lyrics_outlined,
                color: _showLyrics ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurfaceVariant,
                size: 28,
              ),
            ),
            if (!Platform.isMacOS) ...[
              const SizedBox(width: 16),
              IconButton(
                onPressed: () => _showPlaybackSpeedDialog(context),
                icon: Icon(
                  Icons.speed,
                  color: (_currentSongProvider?.playbackSpeed ?? 1.0) != 1.0 
                    ? const Color(0xFFFF9800) 
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
            ],
            IconButton(
              onPressed: () => _showSleepTimerDialog(context),
              icon: Icon(
                Icons.bedtime,
                color: _sleepTimerService.sleepTimerEndTime != null 
                  ? const Color(0xFFFF9800) 
                  : Theme.of(context).colorScheme.onSurfaceVariant,
                size: 28,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    final currentSong = _currentSongProvider?.currentSong;
    if (currentSong == null) return const SizedBox.shrink();

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 6,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor: const Color(0xFFFF9800), // LTunes orange
            inactiveTrackColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.2),
            thumbColor: const Color(0xFFFF9800), // LTunes orange
          ),
          child: Slider(
            value: _currentSongProvider!.currentPosition.inMilliseconds.toDouble(),
            max: (_currentSongProvider!.totalDuration ?? Duration.zero).inMilliseconds.toDouble(),
            onChanged: (value) {
              final newPosition = Duration(milliseconds: value.toInt());
              _currentSongProvider!.audioHandler.seek(newPosition);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_currentSongProvider!.currentPosition),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                _formatDuration(_currentSongProvider!.totalDuration ?? Duration.zero),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Consumer<CurrentSongProvider>(
          builder: (context, provider, _) => IconButton(
            icon: Icon(
              provider.isShuffling ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
              color: provider.isShuffling ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurface,
            ),
            onPressed: () => provider.toggleShuffle(),
          ),
        ),
        const SizedBox(width: 16),
        IconButton(
          icon: Icon(
            Icons.skip_previous,
            color: Theme.of(context).colorScheme.onSurface,
            size: 32,
          ),
          onPressed: () => _currentSongProvider?.playPrevious(),
        ),
        const SizedBox(width: 16),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFF9800), // LTunes orange
            shape: BoxShape.circle,
          ),
          child: Consumer<CurrentSongProvider>(
            builder: (context, provider, _) {
              final isLoading = provider.isLoadingAudio;
              final isPlaying = provider.isPlaying;
              return IconButton(
                icon: isLoading
                    ? const SizedBox(
                        width: 48, 
                        height: 48, 
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5, 
                          color: Colors.white,
                        ),
                      )
                    : Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                iconSize: 36,
                color: Colors.white,
                onPressed: isLoading ? null : () {
                  if (isPlaying) {
                    provider.pauseSong();
                  } else {
                    provider.resumeSong();
                  }
                },
              );
            },
          ),
        ),
        const SizedBox(width: 16),
        IconButton(
          icon: Icon(
            Icons.skip_next,
            color: Theme.of(context).colorScheme.onSurface,
            size: 32,
          ),
          onPressed: () => _currentSongProvider?.playNext(),
        ),
        const SizedBox(width: 16),
        Consumer<CurrentSongProvider>(
          builder: (context, provider, _) => IconButton(
            icon: Icon(
              provider.loopMode == LoopMode.none
                  ? Icons.repeat_rounded
                  : provider.loopMode == LoopMode.queue
                      ? Icons.repeat_on_rounded
                      : Icons.repeat_one_on_rounded,
              color: provider.loopMode != LoopMode.none
                  ? const Color(0xFFFF9800)
                  : Theme.of(context).colorScheme.onSurface,
            ),
            onPressed: () => provider.toggleLoop(),
          ),
        ),
      ],
    );
  }

  Widget _buildLyricsView() {
    if (_lyricsLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFF9800),
        ),
      );
    }

    if (_parsedLyrics.isEmpty) {
      return Center(
        child: Text(
          "No lyrics available.",
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ScrollablePositionedList.builder(
      itemCount: _parsedLyrics.length,
      itemScrollController: _lyricsScrollController,
      itemPositionsListener: _lyricsPositionsListener,
      itemBuilder: (context, index) {
        final line = _parsedLyrics[index];
        final bool isCurrent = _areLyricsSynced && index == _currentLyricIndex;
        
        return GestureDetector(
          onTap: () {
            if (_areLyricsSynced && _currentSongProvider?.currentSong != null) {
              _currentSongProvider?.seek(line.timestamp);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Text(
              line.text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: isCurrent 
                  ? const Color(0xFFFF9800)
                  : Theme.of(context).colorScheme.onSurface,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  Widget _buildQueue() {
    final queue = _currentSongProvider?.queue ?? [];
    final currentSong = _currentSongProvider?.currentSong;
    
    if (queue.isEmpty) {
      return Expanded(
        child: Center(
          child: Text(
            'No songs in queue',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Queue',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: queue.length,
              itemBuilder: (context, index) {
                final song = queue[index];
                final isCurrentSong = song.id == currentSong?.id;
                
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: song.albumArtUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => _buildQueuePlaceholder(),
                        errorWidget: (context, url, error) => _buildQueuePlaceholder(),
                      ),
                    ),
                  ),
                  title: Text(
                    song.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isCurrentSong ? FontWeight.w600 : FontWeight.normal,
                      color: isCurrentSong ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isCurrentSong
                    ? Icon(
                        Icons.play_arrow,
                        color: const Color(0xFFFF9800),
                        size: 20,
                      )
                    : null,
                  onTap: () {
                    _currentSongProvider?.playSong(song);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueuePlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.music_note,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    // Update lyrics index periodically
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateLyricsIndex();
    });

    return Dialog(
      backgroundColor: Colors.transparent,
              child: Container(
          width: 1000,
          height: 700,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.background,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          children: [
            // Header with close button
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.music_note,
                    color: const Color(0xFFFF9800),
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Now Playing',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: Row(
                children: [
                  // Main Player Area
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          if (!_showLyrics) ...[
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _buildAlbumArt(),
                                  const SizedBox(height: 20),
                                  _buildSongInfo(),
                                ],
                              ),
                            ),
                            _buildProgressBar(),
                            const SizedBox(height: 16),
                            _buildControls(),
                            const SizedBox(height: 16),
                          ] else ...[
                            Expanded(
                              child: _buildLyricsView(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Queue Sidebar
                  Container(
                    width: 300,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                    ),
                    child: _buildQueue(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
} 