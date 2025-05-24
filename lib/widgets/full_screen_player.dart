import 'dart:ui'; // For ImageFilter
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart'; // Imports LoopMode enum now
import '../models/song.dart';
import 'dart:io'; // For File
import 'package:path_provider/path_provider.dart'; // For getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // For path joining

class FullScreenPlayer extends StatefulWidget {
  // Removed song parameter as Provider will supply the current song
  const FullScreenPlayer({super.key});

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer> {
  double _slideOffsetX = 1.0; // To control slide direction

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


  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong; // Can be null if nothing is playing or selected
    final bool isPlaying = currentSongProvider.isPlaying;
    final bool isLoading = currentSongProvider.isLoadingAudio;
    final bool isRadio = currentSongProvider.isCurrentlyPlayingRadio;

    // Determine display values based on whether it's a regular song or radio
    String displayTitle = currentSong?.title ?? currentSongProvider.stationName ?? "Nothing Playing";
    String displayArtist = currentSong?.artist ?? (isRadio ? "Radio" : "Unknown Artist");
    String displayAlbumArtUrl = currentSong?.albumArtUrl ?? currentSongProvider.stationFavicon ?? "";
    String displayAlbum = currentSong?.album ?? (isRadio ? "Live Stream" : "");

    // final bool hasAlbumArt = displayAlbumArtUrl.isNotEmpty; // No longer needed for background logic

    Widget albumArtWidget;
    if (displayAlbumArtUrl.isNotEmpty) {
      if (displayAlbumArtUrl.startsWith('http')) {
        albumArtWidget = Image.network(
          displayAlbumArtUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _placeholderArt(context, isRadio),
        );
      } else {
        albumArtWidget = FutureBuilder<String>(
          future: _resolveLocalArtPath(displayAlbumArtUrl),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
              return Image.file(File(snapshot.data!), fit: BoxFit.cover);
            }
            return _placeholderArt(context, isRadio); // Placeholder while loading or if error
          },
        );
      }
    } else {
      albumArtWidget = _placeholderArt(context, isRadio); // Placeholder if no URL
    }

    // Prepare actions for AppBar dynamically
    List<Widget> appBarActions = [];

    // Add download button conditionally
    if (!isRadio && currentSong != null && !currentSong.isDownloaded) {
      appBarActions.add(
        IconButton(
          icon: const Icon(Icons.download_rounded, color: Colors.white),
          tooltip: 'Download',
          onPressed: () { // No need for null check here as condition is already met
            Provider.of<CurrentSongProvider>(context, listen: false)
                .downloadSongInBackground(currentSong);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Downloading ${currentSong.title}'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      );
    }
    if (!isRadio) {
      // Add queue button (conditionally enabled based on isRadio)
      appBarActions.add(
        IconButton(
          icon: const Icon(Icons.queue_music_rounded, color: Colors.white),
          tooltip: 'Queue',
          onPressed: isRadio ? null : () => _showQueueBottomSheet(context),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true, // Make body extend behind AppBar
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          displayAlbum, // Show album name or "Live Stream"
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: appBarActions,
      ),
      body: Stack(
        children: [
          // Background
          Container(
            decoration: BoxDecoration( // Always use gradient
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primaryContainer.withOpacity(0.7),
                  Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.7),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 0.0, // No blur
                sigmaY: 0.0, // No blur
              ),
              child: Container(
                color: Colors.black.withOpacity(0.6), // Darken the background
              ),
            ),
          ),
          // Player UI
          GestureDetector(
            onHorizontalDragEnd: (details) {
              if (isRadio) return; // Disable swipe for radio
              if (details.primaryVelocity! > 0) {
                // Swiped right (previous)
                setState(() {
                  _slideOffsetX = -1.0; // New content comes from left
                });
                currentSongProvider.playPrevious();
              } else if (details.primaryVelocity! < 0) {
                // Swiped left (next)
                setState(() {
                  _slideOffsetX = 1.0; // New content comes from right
                });
                currentSongProvider.playNext();
              }
            },
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity! > 0) {
                // Swiped down
                Navigator.of(context).pop();
              }
            },
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(_slideOffsetX, 0.0),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeOutQuint)).animate(animation), // Added CurveTween
                      child: child,
                    );
                  },
                  child: Column(
                    key: ValueKey<String>(currentSong?.id ?? 'no_song_playing'), // Key to trigger animation
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Spacer(flex: 1),
                      // Album Art
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12.0),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Hero(
                            tag: 'current-song-art', // Ensure this tag is unique or managed
                            child: albumArtWidget,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      // Song Title
                      Text(
                        displayTitle,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      // Artist Name
                      Text(
                        displayArtist,
                        style: TextStyle(fontSize: 18, color: Colors.white.withOpacity(0.8)),
                        textAlign: TextAlign.center,
                         maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(flex: 2),
                      // Seek Bar
                      StreamBuilder<Duration>(
                        stream: currentSongProvider.onPositionChanged,
                        builder: (context, snapshot) {
                          final position = snapshot.data ?? Duration.zero;
                          final duration = currentSongProvider.totalDuration ?? Duration.zero;
                          double sliderValue = 0.0;
                          if (duration.inMilliseconds > 0) {
                            sliderValue = position.inMilliseconds.toDouble() / duration.inMilliseconds.toDouble();
                            sliderValue = sliderValue.clamp(0.0, 1.0); // Ensure value is within 0.0 and 1.0
                          }
                          
                          // For radio, disable seeking and show live indicator or just current time
                          if (isRadio) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.wifi_tethering, color: Colors.white70, size: 16),
                                  const SizedBox(width: 8),
                                  Text(
                                    'LIVE: ${_formatDuration(position)}',
                                    style: TextStyle(color: Colors.white.withOpacity(0.8)),
                                  ),
                                ],
                              ),
                            );
                          }

                          return Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3.0,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.0),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white.withOpacity(0.3),
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  value: sliderValue,
                                  onChanged: (value) {
                                    final newPosition = Duration(milliseconds: (value * duration.inMilliseconds).round());
                                    currentSongProvider.seek(newPosition);
                                  },
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_formatDuration(position), style: TextStyle(color: Colors.white.withOpacity(0.8))),
                                    Text(_formatDuration(duration), style: TextStyle(color: Colors.white.withOpacity(0.8))),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      // Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          if (!isRadio)
                            IconButton(
                              icon: Icon(
                                currentSongProvider.isShuffling ? Icons.shuffle_rounded : Icons.shuffle_rounded,
                                color: currentSongProvider.isShuffling ? Theme.of(context).colorScheme.primary : Colors.white,
                                fill: currentSongProvider.isShuffling ? 1.0 : 0.0, // Ensures the icon looks filled
                              ),
                              iconSize: 28,
                              tooltip: 'Shuffle',
                              onPressed: () => currentSongProvider.toggleShuffle(), // isRadio check already handled by visibility
                            ),
                          if (!isRadio)
                            IconButton(
                              icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                              iconSize: 36,
                              tooltip: 'Previous',
                              onPressed: () {
                                setState(() {
                                  _slideOffsetX = -1.0;
                                });
                                currentSongProvider.playPrevious();
                              }, // isRadio check already handled by visibility
                            ),
                          if (isLoading)
                            Container(
                              width: 70, height: 70,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                            )
                          else
                            IconButton(
                              icon: Icon(isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded, color: Colors.white),
                              iconSize: 70,
                              tooltip: isPlaying ? 'Pause' : 'Play',
                              onPressed: () {
                                if (isPlaying) {
                                  currentSongProvider.pauseSong();
                                } else {
                                  currentSongProvider.resumeSong();
                                }
                              },
                            ),
                          if (!isRadio)
                            IconButton(
                              icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                              iconSize: 36,
                              tooltip: 'Next',
                              onPressed: () {
                                setState(() {
                                  _slideOffsetX = 1.0;
                                });
                                currentSongProvider.playNext();
                              }, // isRadio check already handled by visibility
                            ),
                          if (!isRadio)
                            IconButton(
                              icon: Icon(
                                currentSongProvider.loopMode == LoopMode.song 
                                  ? Icons.repeat_one_rounded 
                                  : Icons.repeat_rounded,
                            color: currentSongProvider.loopMode != LoopMode.none 
                              ? Theme.of(context).colorScheme.primary 
                              : Colors.white,
                          ),
                          iconSize: 28,
                          tooltip: currentSongProvider.loopMode == LoopMode.none 
                              ? 'Loop Off' 
                              : currentSongProvider.loopMode == LoopMode.queue 
                                  ? 'Loop Queue' 
                                  : 'Loop Song',
                          onPressed: () => currentSongProvider.toggleLoop(), // isRadio check already handled by visibility
                        ),
                      ],
                    ),
                    const Spacer(flex: 1),
                  ],
                ),
              ),
            ),
          ),
      )],
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