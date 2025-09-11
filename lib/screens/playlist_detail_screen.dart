import 'dart:ui'; // Import for ImageFilter
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart'; // Ensure Song model is imported
import '../providers/current_song_provider.dart';
import 'dart:io'; // Required for File
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import '../services/api_service.dart'; // Import ApiService
import 'song_detail_screen.dart'; // Import for AddToPlaylistDialog
import '../widgets/playbar.dart';
import '../widgets/full_screen_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/album_manager_service.dart';
import '../services/artwork_service.dart'; // Import centralized artwork service
import 'package:flutter_slidable/flutter_slidable.dart';

Future<ImageProvider> getRobustArtworkProvider(String artUrl) async {
  // Use centralized artwork service for consistent handling
  return await artworkService.getArtworkProvider(artUrl);
}

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final PlaylistManagerService _playlistManager = PlaylistManagerService();

  // Cache Future objects to prevent art flashing
  final Map<String, Future<String>> _localArtFutureCache =
      {}; // For deleting playlist
  final Map<String, Future<ImageProvider>> _artProviderFutureCache =
      {}; // <-- Add this line

  // Helper method to resolve local album art path
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    // Use centralized artwork service for consistent path resolution
    return await artworkService.resolveLocalArtPath(fileName);
  }

  // Get cached Future for local art to prevent flashing
  Future<String> _getCachedLocalArtFuture(String fileName) {
    if (fileName.isEmpty || fileName.startsWith('http')) {
      return Future.value('');
    }
    if (!_localArtFutureCache.containsKey(fileName)) {
      _localArtFutureCache[fileName] = _resolveLocalArtPath(fileName);
    }
    return _localArtFutureCache[fileName]!;
  }

  // Get cached Future for robust artwork provider
  Future<ImageProvider> _getCachedArtProviderFuture(String artUrl) {
    if (!_artProviderFutureCache.containsKey(artUrl)) {
      _artProviderFutureCache[artUrl] = getRobustArtworkProvider(artUrl);
    }
    return _artProviderFutureCache[artUrl]!;
  }

  Future<void> _playPlaylistShuffle(Playlist currentPlaylist) async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (currentPlaylist.songs.isNotEmpty) {
      // Ensure shuffle is on
      if (!currentSongProvider.isShuffling) {
        currentSongProvider.toggleShuffle();
      }
      await currentSongProvider.smartPlayWithContext(
          currentPlaylist.songs, currentPlaylist.songs.first);
      navigator.push(
        MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
            content: Text('This playlist has no songs to shuffle play.')),
      );
    }
  }

  Future<void> _downloadAllSongs(Playlist currentPlaylist) async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    if (currentPlaylist.songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Playlist is empty. Nothing to download.')),
      );
      return;
    }

    final songsToDownload = currentPlaylist.songs
        .where((s) => !s.isImported && !s.isDownloaded)
        .toList();

    for (final song in songsToDownload) {
      currentSongProvider.queueSongForDownload(song);
    }

    if (songsToDownload.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Queued ${songsToDownload.length} songs for download.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('All songs are already downloaded or imported.')),
      );
    }
  }

  Future<void> _removeDownloadsFromPlaylist(Playlist currentPlaylist) async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    if (currentPlaylist.songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist is empty. Nothing to remove.')),
      );
      return;
    }

    // Get songs that are downloaded (not imported)
    final songsToRemoveDownloads = currentPlaylist.songs
        .where((s) => !s.isImported && s.isDownloaded)
        .toList();

    if (songsToRemoveDownloads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No downloaded songs to remove from this playlist.')),
      );
      return;
    }

    // Show confirmation dialog
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Remove Downloads?'),
          content: Text(
              'Are you sure you want to remove downloads for ${songsToRemoveDownloads.length} song(s) from this playlist? This will delete the local files but keep the songs in your library.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
            TextButton(
              child: Text('Remove',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    int removedCount = 0;
    final appDocDir = await getApplicationDocumentsDirectory();
    const String downloadsSubDir = 'ltunes_downloads';

    for (final song in songsToRemoveDownloads) {
      try {
        // Delete the local audio file
        if (song.localFilePath != null && song.localFilePath!.isNotEmpty) {
          final audioFile = File(
              p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
          if (await audioFile.exists()) {
            await audioFile.delete();
            debugPrint('Deleted audio file: ${audioFile.path}');
          }
        }

        // Delete the local album art file if it exists and is not used by other songs
        if (song.albumArtUrl.isNotEmpty &&
            !song.albumArtUrl.startsWith('http')) {
          // Check if any other song uses this cover
          bool coverIsUsedElsewhere = currentPlaylist.songs.any((other) =>
              other.id != song.id && other.albumArtUrl == song.albumArtUrl);

          if (!coverIsUsedElsewhere) {
            final albumArtFile = File(p.join(appDocDir.path, song.albumArtUrl));
            if (await albumArtFile.exists()) {
              await albumArtFile.delete();
              debugPrint('Deleted album art file: ${albumArtFile.path}');
            }
          }
        }

        // Fetch the original network album art URL
        String originalAlbumArtUrl = '';
        if (song.albumArtUrl.isNotEmpty &&
            !song.albumArtUrl.startsWith('http')) {
          // Try to fetch the original network URL for the album art
          try {
            final apiService = ApiService();
            // First try to find the song to get its album art URL
            final searchResults =
                await apiService.fetchSongs('${song.title} ${song.artist}');
            Song? exactMatch;
            for (final result in searchResults) {
              if (result.title.toLowerCase() == song.title.toLowerCase() &&
                  result.artist.toLowerCase() == song.artist.toLowerCase()) {
                exactMatch = result;
                break;
              }
            }

            if (exactMatch != null &&
                exactMatch.albumArtUrl.isNotEmpty &&
                exactMatch.albumArtUrl.startsWith('http')) {
              originalAlbumArtUrl = exactMatch.albumArtUrl;
            } else if (song.album != null && song.album!.isNotEmpty) {
              // Try to get the album art from the album
              final album = await apiService.getAlbum(song.album!, song.artist);
              if (album != null && album.fullAlbumArtUrl.isNotEmpty) {
                originalAlbumArtUrl = album.fullAlbumArtUrl;
              }
            }
          } catch (e) {
            debugPrint(
                'Error fetching original album art URL for ${song.title}: $e');
            // If we can't fetch the original URL, we'll leave it empty
          }
        }

        // Update song metadata to mark as not downloaded and restore network album art URL
        final updatedSong = song.copyWith(
          isDownloaded: false,
          localFilePath: null,
          albumArtUrl: originalAlbumArtUrl.isNotEmpty
              ? originalAlbumArtUrl
              : song.albumArtUrl,
        );

        // Update in SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'song_${updatedSong.id}', jsonEncode(updatedSong.toJson()));

        // Notify services
        currentSongProvider.updateSongDetails(updatedSong);
        PlaylistManagerService().updateSongInPlaylists(updatedSong);
        await AlbumManagerService().updateSongInAlbums(updatedSong);

        removedCount++;
      } catch (e) {
        debugPrint('Error removing download for song ${song.title}: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Removed downloads for $removedCount song(s) from playlist.')),
      );
    }
  }

  Future<void> _showRemoveSongDialog(Song songToRemove,
      int originalIndexInPlaylist, Playlist currentPlaylist) async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    // Capture mounted state outside async gap if used across await
    final bool isCurrentlyMounted = mounted;

    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must tap button
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Remove Song'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                    'Are you sure you want to remove "${songToRemove.title}" from this playlist?'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Remove'),
              onPressed: () async {
                // Make onPressed async
                Song? currentlyPlayingSong = currentSongProvider.currentSong;
                bool wasPlayingRemovedSong =
                    currentlyPlayingSong?.id == songToRemove.id;

                // Use PlaylistManagerService to remove the song
                await _playlistManager.removeSongFromPlaylist(
                    currentPlaylist, songToRemove);

                // The playlist instance from the manager will be updated,
                // so we need to fetch the latest version for queue updates.
                // However, for immediate UI update and queue logic, we can work with a modified local list.
                // The Consumer will handle getting the absolute latest from the manager.
                List<Song> updatedPlaylistSongs =
                    List.from(currentPlaylist.songs)
                      ..removeWhere((s) => s.id == songToRemove.id);

                if (isCurrentlyMounted) {
                  setState(() {
                    // UI will rebuild due to Consumer<PlaylistManagerService>
                    // or if we were directly mutating widget.playlist.songs (which we are not anymore for removal)
                  });
                }

                // List<Song> updatedPlaylistSongs = List.from(widget.playlist.songs); // Use currentPlaylist

                // Remove the song from the queue without triggering playback
                currentSongProvider.processSongLibraryRemoval(songToRemove.id);
                Navigator.of(dialogContext).pop(); // Close the dialog
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDeletePlaylistDialog(Playlist currentPlaylist) async {
    // Capture mounted state and context outside async gap if used across await
    final bool isCurrentlyMounted = mounted;
    final BuildContext currentContext = context; // Capture context

    return showDialog<void>(
      context: currentContext,
      barrierDismissible: false, // User must tap button
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete Playlist'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                    'Are you sure you want to delete the playlist "${currentPlaylist.name}"? This action cannot be undone.'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(currentContext).colorScheme.error),
              child: const Text('Delete'),
              onPressed: () async {
                await _playlistManager.removePlaylist(currentPlaylist);
                Navigator.of(dialogContext).pop(); // Close the dialog

                if (isCurrentlyMounted && currentContext.mounted) {
                  // Navigate back to the previous screen (LibraryScreen)
                  Navigator.of(currentContext).pop();
                  ScaffoldMessenger.of(currentContext).showSnackBar(
                    SnackBar(
                        content: Text(
                            'Playlist "${currentPlaylist.name}" deleted.')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  // Helper to build individual art piece for grid/single display
  Widget _buildArtImage(String artUrl, double size,
      {BoxFit fit = BoxFit.cover}) {
    Widget placeholder = Container(
      width: size,
      height: size,
      color: Colors.grey[700], // Placeholder color
      child: Icon(Icons.music_note, size: size * 0.6, color: Colors.white70),
    );

    if (artUrl.startsWith('http')) {
      return Image.network(
        artUrl,
        width: size,
        height: size,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    } else {
      return FutureBuilder<String>(
        future: _getCachedLocalArtFuture(artUrl),
        key: ValueKey<String>('playlist_detail_art_$artUrl'),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData &&
              snapshot.data!.isNotEmpty) {
            return Image.file(
              File(snapshot.data!),
              width: size,
              height: size,
              fit: fit,
              errorBuilder: (context, error, stackTrace) => placeholder,
            );
          }
          return placeholder; // Show placeholder while loading or if path is invalid
        },
      );
    }
  }

  Widget robustArtwork(String artUrl,
      {double? width, double? height, BoxFit fit = BoxFit.cover}) {
    return FutureBuilder<ImageProvider>(
      key: ValueKey('artwork_$artUrl'), // Add stable key
      future: _getCachedArtProviderFuture(artUrl), // Use cached future
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          return Image(
            image: snapshot.data!,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (context, error, stackTrace) => Container(
              width: width,
              height: height,
              color: Colors.grey[700],
              child: Icon(Icons.music_note,
                  size: (width ?? 48) * 0.6, color: Colors.white70),
            ),
          );
        }
        return Container(
          width: width,
          height: height,
          color: Colors.grey[700],
          child: Icon(Icons.music_note,
              size: (width ?? 48) * 0.6, color: Colors.white70),
        );
      },
    );
  }

  Widget _buildProminentPlaylistArt(
      List<String> artUrls, double containerSize) {
    if (artUrls.isEmpty) {
      return Container(
        width: containerSize,
        height: containerSize,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primaryContainer,
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Icon(Icons.music_note,
            color: Colors.white.withValues(alpha: 0.7),
            size: containerSize * 0.5),
      );
    }

    if (artUrls.length < 4) {
      // Display first art as a single image
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: robustArtwork(artUrls.first,
            width: containerSize, height: containerSize),
      );
    } else {
      // Display a 2x2 grid of the first 4 album arts
      double imageSize = containerSize / 2;
      return SizedBox(
        width: containerSize,
        height: containerSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: artUrls
                .take(4)
                .map((url) =>
                    robustArtwork(url, width: imageSize, height: imageSize))
                .toList(),
          ),
        ),
      );
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));

    if (duration.inHours > 0) {
      return "${duration.inHours} hr $twoDigitMinutes min";
    } else if (duration.inMinutes > 0) {
      return "$twoDigitMinutes min $twoDigitSeconds sec";
    } else {
      return "$twoDigitSeconds sec";
    }
  }

  String _calculateAndFormatPlaylistDuration(Playlist currentPlaylist) {
    if (currentPlaylist.songs.isEmpty) {
      return "0 sec";
    }
    Duration totalDuration = Duration.zero;
    for (var song in currentPlaylist.songs) {
      // Assuming song.duration is a Duration? object.
      // If song.duration is not available or is null, it won't be added.
      // This part needs the Song model to have a 'duration' field.
      // For now, we'll simulate it or handle null.
      // Example: if (song.duration != null) totalDuration += song.duration!;
      // As a placeholder if song.duration doesn't exist:
      // totalDuration += const Duration(minutes: 3, seconds: 30); // Placeholder

      // Assuming Song model has: Duration? duration;
      if (song.duration != null) {
        totalDuration += song.duration!;
      }
    }
    if (totalDuration == Duration.zero && currentPlaylist.songs.isNotEmpty) {
      // This case means songs exist but none had a parsable duration,
      // or the duration field isn't populated in the Song model.
      return "N/A";
    }
    return _formatDuration(totalDuration);
  }

  ImageProvider? _currentArtProvider;
  String? _currentArtId;
  bool _artLoading = false;

  Future<void> _updateArtProvider(String artUrl, String id) async {
    setState(() {
      _artLoading = true;
    });
    if (artUrl.startsWith('http')) {
      _currentArtProvider = CachedNetworkImageProvider(artUrl);
    } else {
      final path = await _getCachedLocalArtFuture(artUrl);
      if (path.isNotEmpty) {
        _currentArtProvider = FileImage(File(path));
      } else {
        _currentArtProvider = null;
      }
    }
    _currentArtId = id;
    if (mounted) {
      setState(() {
        _artLoading = false;
      });
    }
  }

  ImageProvider getArtworkProvider(String artUrl) {
    //if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
    if (artUrl.startsWith('http')) {
      return CachedNetworkImageProvider(artUrl);
    } else {
      return FileImage(File(artUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);

    return Consumer<PlaylistManagerService>(
      builder: (context, playlistManager, child) {
        // Get the latest playlist instance from the manager
        final Playlist currentPlaylist = playlistManager.playlists.firstWhere(
          (p) => p.id == widget.playlist.id,
          orElse: () =>
              widget.playlist, // Fallback, though ideally it's always found
        );

        final bool hasSongs = currentPlaylist.songs.isNotEmpty;
        final bool isFullyDownloaded = currentPlaylist.isFullyDownloaded;

        List<String> uniqueAlbumArtUrls = currentPlaylist.songs
            .map((song) => song.albumArtUrl)
            .where((artUrl) => artUrl.isNotEmpty)
            .toSet()
            .toList();

        Widget flexibleSpaceBackground;
        if (uniqueAlbumArtUrls.isNotEmpty) {
          // Use the first art for the blurred background
          if (uniqueAlbumArtUrls.first.startsWith('http')) {
            flexibleSpaceBackground = Image.network(
              uniqueAlbumArtUrls.first,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  Container(color: Colors.grey[850]),
            );
          } else {
            flexibleSpaceBackground = FutureBuilder<String>(
              future: _getCachedLocalArtFuture(uniqueAlbumArtUrls.first),
              key: ValueKey<String>(
                  'playlist_detail_bg_${uniqueAlbumArtUrls.first}'),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData &&
                    snapshot.data!.isNotEmpty) {
                  return Image.file(File(snapshot.data!), fit: BoxFit.cover);
                }
                return Container(color: Colors.grey[850]); // Placeholder
              },
            );
          }
        } else {
          flexibleSpaceBackground = Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.5)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          );
        }

        const double prominentArtSize = 160.0;
        final double systemTopPadding = MediaQuery.of(context).padding.top;

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 360.0,
                pinned: true,
                stretch: true,
                flexibleSpace: FlexibleSpaceBar(
                  title: Builder(builder: (context) {
                    final settings = context.dependOnInheritedWidgetOfExactType<
                        FlexibleSpaceBarSettings>();
                    if (settings == null) return const SizedBox.shrink();

                    // Calculate how "collapsed" the bar is.
                    // currentExtent goes from maxExtent down to minExtent.
                    // We want the title to appear when currentExtent is very close to minExtent.
                    // Calculate opacity for title fade-in, safely guarding division by zero
                    final double delta =
                        settings.maxExtent - settings.minExtent;
                    final double collapseThreshold = delta * 0.1;
                    final double extentDelta =
                        settings.currentExtent - settings.minExtent;
                    double opacity;
                    if (collapseThreshold > 0) {
                      // Fade in when within threshold of collapse
                      opacity = extentDelta < collapseThreshold
                          ? (1.0 - (extentDelta / collapseThreshold))
                              .clamp(0.0, 1.0)
                          : 0.0;
                    } else {
                      // If no scroll range, show only when fully collapsed
                      opacity = (settings.currentExtent == settings.minExtent)
                          ? 1.0
                          : 0.0;
                    }

                    return Opacity(
                      opacity: opacity,
                      child: Text(
                        currentPlaylist.name, // Use currentPlaylist
                        style: const TextStyle(
                          fontSize: 16.0,
                          color: Colors
                              .white, // Ensure text color is set for visibility
                          shadows: [
                            // Optional: add a slight shadow for better readability
                            Shadow(
                              blurRadius: 1.0,
                              color: Colors.black54,
                              offset: Offset(0.5, 0.5),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }),
                  centerTitle: true,
                  titlePadding: const EdgeInsets.only(
                      bottom: 16.0, left: 48.0, right: 48.0),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      flexibleSpaceBackground,
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      // Use Padding to position the content column correctly
                      Padding(
                        padding: EdgeInsets.only(
                          top: systemTopPadding +
                              kToolbarHeight +
                              5, // Minimal space for status bar, app bar
                          left: 16.0,
                          right: 16.0,
                          bottom:
                              0.0, // No padding at the bottom of the content area
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment
                              .start, // Align content to the start (top) of the padded area
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Main playlist info card
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  width: 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      // Enhanced artwork with glow effect
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.white
                                                  .withValues(alpha: 0.1),
                                              blurRadius: 8,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: _buildProminentPlaylistArt(
                                            uniqueAlbumArtUrls,
                                            prominentArtSize),
                                      ),
                                      const SizedBox(width: 20),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            // Playlist name with better styling
                                            Text(
                                              currentPlaylist.name,
                                              style: const TextStyle(
                                                fontSize: 26,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                                letterSpacing: -0.5,
                                                shadows: [
                                                  Shadow(
                                                    blurRadius: 4,
                                                    color: Colors.black,
                                                    offset: Offset(0, 2),
                                                  )
                                                ],
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 12),
                                            // Stats row with icons
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.queue_music,
                                                  size: 16,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.8),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '${currentPlaylist.songs.length} songs',
                                                  style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.9),
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      shadows: const [
                                                        Shadow(
                                                            blurRadius: 2,
                                                            color:
                                                                Colors.black54)
                                                      ]),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.access_time,
                                                  size: 16,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.8),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  _calculateAndFormatPlaylistDuration(
                                                      currentPlaylist),
                                                  style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.8),
                                                      fontSize: 14,
                                                      shadows: const [
                                                        Shadow(
                                                            blurRadius: 1,
                                                            color:
                                                                Colors.black54)
                                                      ]),
                                                ),
                                              ],
                                            ),
                                            if (isFullyDownloaded &&
                                                hasSongs) ...[
                                              const SizedBox(height: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.greenAccent
                                                      .withValues(alpha: 0.2),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  border: Border.all(
                                                    color: Colors.greenAccent
                                                        .withValues(alpha: 0.3),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.offline_pin,
                                                        color:
                                                            Colors.greenAccent,
                                                        size: 14),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      'Downloaded',
                                                      style: TextStyle(
                                                          color: Colors
                                                              .greenAccent,
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w600),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  // Action buttons row - positioned inside the playlist card
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Play All button
                                      Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.8),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.3),
                                              blurRadius: 8,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: IconButton(
                                          onPressed: hasSongs
                                              ? () async {
                                                  await currentSongProvider
                                                      .smartPlayWithContext(
                                                          currentPlaylist.songs,
                                                          currentPlaylist
                                                              .songs.first);
                                                }
                                              : null,
                                          icon: const Icon(Icons.play_arrow,
                                              size: 20, color: Colors.white),
                                          style: IconButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            padding: const EdgeInsets.all(12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // Shuffle button
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.3),
                                            width: 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.white
                                                  .withValues(alpha: 0.1),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: IconButton(
                                          onPressed: hasSongs
                                              ? () => _playPlaylistShuffle(
                                                  currentPlaylist)
                                              : null,
                                          icon: const Icon(Icons.shuffle,
                                              size: 20, color: Colors.white),
                                          style: IconButton.styleFrom(
                                            backgroundColor: Colors.white
                                                .withValues(alpha: 0.05),
                                            padding: const EdgeInsets.all(12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (hasSongs) ...[
                                        const SizedBox(width: 12),
                                        // Download/Remove Downloads button
                                        Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(
                                              color: isFullyDownloaded
                                                  ? Colors.red
                                                      .withValues(alpha: 0.3)
                                                  : Colors.white
                                                      .withValues(alpha: 0.2),
                                              width: 1.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: (isFullyDownloaded
                                                        ? Colors.red
                                                        : Colors.white)
                                                    .withValues(alpha: 0.1),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: IconButton(
                                            onPressed: isFullyDownloaded
                                                ? () =>
                                                    _removeDownloadsFromPlaylist(
                                                        currentPlaylist)
                                                : () => _downloadAllSongs(
                                                    currentPlaylist),
                                            icon: Icon(
                                                isFullyDownloaded
                                                    ? Icons.remove_circle
                                                    : Icons.download,
                                                size: 20,
                                                color: isFullyDownloaded
                                                    ? Colors.red
                                                        .withValues(alpha: 0.9)
                                                    : Colors.white.withValues(
                                                        alpha: 0.9)),
                                            style: IconButton.styleFrom(
                                              backgroundColor: isFullyDownloaded
                                                  ? Colors.red
                                                      .withValues(alpha: 0.1)
                                                  : Colors.white
                                                      .withValues(alpha: 0.05),
                                              padding: const EdgeInsets.all(12),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Delete Playlist button
                                        Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error
                                                  .withValues(alpha: 0.3),
                                              width: 1.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error
                                                    .withValues(alpha: 0.1),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: IconButton(
                                            onPressed: () =>
                                                _showDeletePlaylistDialog(
                                                    currentPlaylist),
                                            icon: Icon(Icons.playlist_remove,
                                                size: 20,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error
                                                    .withValues(alpha: 0.9)),
                                            style: IconButton.styleFrom(
                                              backgroundColor: Theme.of(context)
                                                  .colorScheme
                                                  .error
                                                  .withValues(alpha: 0.1),
                                              padding: const EdgeInsets.all(12),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!hasSongs)
                SliverFillRemaining(
                  // Use SliverFillRemaining for empty state
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.music_off_outlined,
                            size: 60,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(height: 16),
                        Text(
                          'This playlist is empty.',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add some songs from your library.',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverReorderableList(
                  itemBuilder: (context, index) {
                    final song =
                        currentPlaylist.songs[index]; // Use currentPlaylist
                    final Key itemKey = ValueKey(song.id);

                    // Use robustArtwork for all song icons
                    Widget listItemLeading =
                        robustArtwork(song.albumArtUrl, width: 50, height: 50);

                    return ReorderableDelayedDragStartListener(
                      key: itemKey,
                      index: index,
                      child: Slidable(
                        endActionPane: ActionPane(
                          motion: const DrawerMotion(),
                          extentRatio: 0.32,
                          children: [
                            SlidableAction(
                              onPressed: (context) {
                                showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return AddToPlaylistDialog(song: song);
                                  },
                                );
                              },
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onPrimary,
                              icon: Icons.playlist_add,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            SlidableAction(
                              onPressed: (context) {
                                _showRemoveSongDialog(
                                    song, index, currentPlaylist);
                              },
                              backgroundColor:
                                  Theme.of(context).colorScheme.error,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onError,
                              icon: Icons.remove_circle,
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16.0, vertical: 8.0),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: listItemLeading,
                            ),
                            title: Text(
                              song.title,
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                  fontWeight: FontWeight.w500),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.artist.isNotEmpty
                                  ? song.artist
                                  : "Unknown Artist",
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.7)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.drag_handle,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5)),
                              ],
                            ),
                            onTap: () async {
                              await currentSongProvider.smartPlayWithContext(
                                  currentPlaylist.songs, song);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                  itemCount:
                      currentPlaylist.songs.length, // Use currentPlaylist
                  proxyDecorator:
                      (Widget child, int index, Animation<double> animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (BuildContext context, Widget? child) {
                        final double animValue =
                            Curves.easeInOut.transform(animation.value);
                        final double elevation = lerpDouble(
                            0, 8, animValue)!; // Elevate when dragging
                        final double scale = lerpDouble(
                            1, 1.05, animValue)!; // Slightly scale up
                        return Material(
                          // Material for shadow and proper rendering of the proxy
                          elevation: elevation,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest, // Or another suitable color for drag proxy
                          shadowColor: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(
                              8), // Optional: match ListTile's visual style
                          child: Transform.scale(scale: scale, child: child),
                        );
                      },
                      child: child,
                    );
                  },
                  onReorder: (int oldIndex, int newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) {
                        newIndex -= 1;
                      }
                      // Create a mutable copy for reordering
                      List<Song> reorderedSongs =
                          List.from(currentPlaylist.songs);
                      final Song item = reorderedSongs.removeAt(oldIndex);
                      reorderedSongs.insert(newIndex, item);

                      // Create an updated playlist object with the new song order
                      Playlist updatedPlaylist =
                          currentPlaylist.copyWith(songs: reorderedSongs);

                      _playlistManager
                          .updatePlaylist(updatedPlaylist)
                          .then((_) {
                        // PlaylistManagerService will notify its listeners,
                        // and the Consumer will rebuild with the new order.
                      }).catchError((error) {
                        // Optional: Handle error during saving
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Error saving playlist order: $error')),
                          );
                        }
                        // Optionally, revert the order in UI if save fails, though this can be complex.
                      });

                      // Only update the queue if the currently playing song is from this playlist
                      // and only if the current queue context matches this playlist
                      Song? currentlyPlayingSong =
                          currentSongProvider.currentSong;
                      if (currentlyPlayingSong != null) {
                        // Check if the current song is from this playlist
                        int songIndexInPlaylist = updatedPlaylist.songs
                            .indexWhere((s) => s.id == currentlyPlayingSong.id);
                        if (songIndexInPlaylist != -1) {
                          // Check if the current queue context matches this playlist
                          final currentQueue = currentSongProvider.queue;
                          if (currentQueue.length ==
                              updatedPlaylist.songs.length) {
                            // Compare if all songs in the queue match the playlist (in any order)
                            bool queueMatchesPlaylist = currentQueue.every(
                                (queueSong) => updatedPlaylist.songs.any(
                                    (playlistSong) =>
                                        playlistSong.id == queueSong.id));

                            if (queueMatchesPlaylist) {
                              // Update the queue order without changing context
                              currentSongProvider.reorderQueue(
                                  oldIndex, newIndex);
                            }
                          }
                        }
                      }
                    });
                  },
                ),
            ],
          ),
          bottomNavigationBar: const Padding(
            padding: EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 32.0),
            child: Hero(
              tag: 'global-playbar-hero',
              child: Playbar(),
            ),
          ),
        );
      },
    );
  }
}
