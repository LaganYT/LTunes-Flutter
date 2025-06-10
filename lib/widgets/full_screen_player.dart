import 'dart:ui'; // For ImageFilter
import 'dart:convert'; // For jsonEncode
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart'; // Ensure CurrentSongProvider is imported
import '../models/song.dart'; // Ensure Song model is imported
import 'package:path_provider/path_provider.dart'; // For getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // For path joining
import 'dart:io'; // For File operations
import 'package:shared_preferences/shared_preferences.dart'; // For SharedPreferences
// ignore: unused_import
import '../services/playlist_manager_service.dart';
import '../screens/song_detail_screen.dart'; // For AddToPlaylistDialog

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

  @override
  void initState() {
    super.initState();

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

    // Trigger initial animations if a song is already playing
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
    }
    
    _currentSongProvider.addListener(_onSongChanged);
  }

  void _onSongChanged() {
    if (!mounted) return;

    final newSongId = _currentSongProvider.currentSong?.id;
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
      
      _previousSongId = newSongId;
      _slideOffsetX = 0.0; // Reset for next non-skip change
    }
  }

  @override
  void dispose() {
    _currentSongProvider.removeListener(_onSongChanged);
    _textFadeController.dispose();
    _albumArtSlideController.dispose();
    super.dispose();
  }

  // Method for downloading the current song - NOW USES PROVIDER
  Future<void> _downloadCurrentSong(Song song) async {
    // Use the CurrentSongProvider to handle the download
    Provider.of<CurrentSongProvider>(context, listen: false).downloadSongInBackground(song);

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
                              currentSongProvider.playSong(song);
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
          if (!isRadio) // "Queue" not applicable for radio
          IconButton(
            icon: const Icon(Icons.playlist_play_rounded),
            onPressed: () => _showQueueBottomSheet(context),
            tooltip: 'Show Queue',
          ),
          // Show download button only if not radio AND not already downloaded
          if (!isRadio && currentSong.isDownloaded == false) 
            IconButton(
              icon: const Icon(Icons.download_rounded),
              onPressed: () => _downloadCurrentSong(currentSong),
              tooltip: 'Download Song',
            ),
          if (!isRadio) // "Add to Playlist" not applicable for radio
            IconButton(
              icon: const Icon(Icons.playlist_add_rounded),
              onPressed: () => _showAddToPlaylistDialog(context, currentSong),
              tooltip: 'Add to Playlist',
            ),
        ],
            ),
      body: GestureDetector( // GestureDetector for swipe down to close
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
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colorScheme.primary.withOpacity(0.6),
                colorScheme.primaryContainer.withOpacity(0.8),
                colorScheme.background,
              ],
              stops: const [0.0, 0.35, 0.75],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0) + EdgeInsets.only(top: MediaQuery.of(context).padding.top + kToolbarHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Album Art Section
                Expanded(
                  flex: 5,
                  child: GestureDetector( // GestureDetector for horizontal swipe (song navigation) on Album Art
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
                        final position = snapshot.data ?? Duration.zero;
                        final duration = currentSongProvider.totalDuration ?? Duration.zero;
                        return Column(
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.0,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.0),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                                activeTrackColor: colorScheme.secondary,
                                inactiveTrackColor: colorScheme.onSurface.withOpacity(0.2),
                                thumbColor: colorScheme.secondary,
                                overlayColor: colorScheme.secondary.withOpacity(0.2),
                              ),
                              child: Slider(
                                value: (duration.inMilliseconds > 0 && position.inMilliseconds <= duration.inMilliseconds)
                                    ? position.inMilliseconds.toDouble()
                                    : 0.0,
                                min: 0.0,
                                max: duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0,
                                onChanged: isRadio ? null : (value) {
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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: Icon(
                        currentSongProvider.isShuffling ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
                        color: currentSongProvider.isShuffling ? colorScheme.secondary : colorScheme.onBackground.withOpacity(0.7),
                      ),
                      iconSize: 26,
                      onPressed: () => currentSongProvider.toggleShuffle(),
                      tooltip: 'Shuffle',
                    ),
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