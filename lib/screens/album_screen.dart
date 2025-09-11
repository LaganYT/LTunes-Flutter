import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/album.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../services/album_manager_service.dart';
import '../services/api_service.dart'; // Import ApiService
import '../widgets/full_screen_player.dart'; // For navigation to player
import '../screens/song_detail_screen.dart'; // For navigation to song details
import '../widgets/playbar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/playlist_manager_service.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

class AlbumScreen extends StatefulWidget {
  final Album album;

  const AlbumScreen({super.key, required this.album});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen>
    with TickerProviderStateMixin {
  late bool _isSaved;
  final AlbumManagerService _albumManager = AlbumManagerService();
  late bool _areAllTracksDownloaded;
  CurrentSongProvider? _currentSongProvider;

  // --- For filtering saved songs ---
  bool _showOnlySavedSongs = false;
  bool _overrideShowAll = false; // If user taps 'Show All Songs'
  Set<String> _likedSongIds = {};
  Set<String> _playlistSongIds = {};
  bool _loadingSavedSongs = false;

  // Helper function to safely create TextStyle with valid fontSize
  TextStyle _safeTextStyle(
    TextStyle? baseStyle, {
    Color? color,
    FontWeight? fontWeight,
    List<Shadow>? shadows,
    double? fallbackFontSize,
  }) {
    // Check if base style has valid fontSize
    if (baseStyle != null &&
        baseStyle.fontSize != null &&
        baseStyle.fontSize!.isFinite) {
      return baseStyle.copyWith(
        color: color,
        fontWeight: fontWeight,
        shadows: shadows,
      );
    }

    // Use fallback with safe fontSize
    return TextStyle(
      color: color,
      fontWeight: fontWeight,
      shadows: shadows,
      fontSize: fallbackFontSize ?? 16.0,
    );
  }

  @override
  void initState() {
    super.initState();
    _isSaved = _albumManager.isAlbumSaved(widget.album.id);
    _albumManager.addListener(_onAlbumManagerStateChanged);
    _areAllTracksDownloaded = false; // Initial value

    _loadShowOnlySavedSongsSetting(); // Load the filter setting
    _loadSavedSongIds(); // Load liked and playlist song IDs

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _currentSongProvider =
            Provider.of<CurrentSongProvider>(context, listen: false);
        _currentSongProvider?.addListener(_onCurrentSongProviderChanged);

        // Prime the provider with the status of already downloaded tracks
        _primeProviderWithDownloadedTracksStatus();

        _updateAllTracksDownloadedStatus(); // Initial check
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-prime provider every time dependencies change (e.g., after hot reload or provider reset)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _primeProviderWithDownloadedTracksStatus();
        _updateAllTracksDownloadedStatus();
      }
    });
  }

  void _onCurrentSongProviderChanged() {
    _updateAllTracksDownloadedStatus();
  }

  // New method to ensure CurrentSongProvider is aware of persisted downloaded tracks
  void _primeProviderWithDownloadedTracksStatus() {
    if (_currentSongProvider == null || widget.album.tracks.isEmpty) {
      return;
    }
    final currentSongProvider = _currentSongProvider!;
    for (final track in widget.album.tracks) {
      final bool isPersistedAsDownloaded = track.isDownloaded;
      final bool isMarkedCompleteByProvider =
          currentSongProvider.downloadProgress[track.id] == 1.0;
      final bool isActiveDownload =
          currentSongProvider.activeDownloadTasks.containsKey(track.id);

      if (isPersistedAsDownloaded &&
          !isMarkedCompleteByProvider &&
          !isActiveDownload) {
        // This track is marked as downloaded in its metadata,
        // but the provider doesn't show it as 100% complete yet,
        // and it's not an active download.
        // Call queueSongForDownload to make the provider check the file.
        // If the file exists, the provider will update its progress to 1.0
        // and notify listeners, which will trigger _updateAllTracksDownloadedStatus.
        currentSongProvider.queueSongForDownload(track);
      }
    }
  }

  void _updateAllTracksDownloadedStatus() {
    if (!mounted) return;

    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    bool newAllDownloadedStatus;

    if (widget.album.tracks.isEmpty) {
      newAllDownloadedStatus = false;
    } else {
      newAllDownloadedStatus = true; // Assume true, prove false
      for (final track in widget.album.tracks) {
        final progress = currentSongProvider.downloadProgress[track.id];
        final bool isPersistedAsDownloaded = track.isDownloaded;

        if (progress == 1.0) {
          // Explicitly marked as 100% downloaded by provider
          continue;
        } else if (progress != null && progress < 1.0) {
          // Actively downloading or failed, not fully downloaded
          newAllDownloadedStatus = false;
          break;
        } else if (progress == null && isPersistedAsDownloaded) {
          // Not in provider's active/completed download map for this session,
          // but the track data says it's downloaded. Assume it is.
          // To ensure this state is reflected in downloadProgress for future checks by provider,
          // one might consider calling queueSongForDownload which would update progress to 1.0
          // if file exists. For display purposes, this assumption is generally okay.
          // If the file was deleted externally, this would be stale until user tries to play/download.
          bool foundInActiveDownloads =
              currentSongProvider.activeDownloadTasks.containsKey(track.id);
          if (foundInActiveDownloads) {
            // If it's in active downloads but progress is null, it's not done.
            newAllDownloadedStatus = false;
            break;
          }
          continue;
        } else {
          // Not in progress map (progress == null) AND not persistedAsDownloaded,
          // or other states. Definitely not downloaded.
          newAllDownloadedStatus = false;
          break;
        }
      }
    }

    if (_areAllTracksDownloaded != newAllDownloadedStatus) {
      setState(() {
        _areAllTracksDownloaded = newAllDownloadedStatus;
      });
    }
  }

  void _onAlbumManagerStateChanged() {
    if (mounted) {
      final newSavedState = _albumManager.isAlbumSaved(widget.album.id);
      if (_isSaved != newSavedState) {
        setState(() {
          _isSaved = newSavedState;
        });
      }
    }
  }

  @override
  void dispose() {
    _albumManager.removeListener(_onAlbumManagerStateChanged);
    _currentSongProvider?.removeListener(_onCurrentSongProviderChanged);
    super.dispose();
  }

  Duration _calculateTotalDuration() {
    Duration total = Duration.zero;
    for (var track in widget.album.tracks) {
      if (track.duration != null) {
        total += track.duration!;
      }
    }
    return total;
  }

  String _formatDuration(Duration? duration) {
    if (duration == null || duration.inSeconds == 0) return '0 min 0 sec';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours hr ${minutes.toString().padLeft(2, '0')} min';
    } else if (minutes > 0) {
      return '$minutes min ${seconds.toString().padLeft(2, '0')} sec';
    } else {
      return '${seconds.toString().padLeft(2, '0')} sec';
    }
  }

  void _playAlbum() async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (widget.album.tracks.isNotEmpty) {
      // Increment album play count in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final albumKeys = prefs.getKeys().where((k) => k.startsWith('album_'));
      for (final key in albumKeys) {
        final albumJson = prefs.getString(key);
        if (albumJson != null) {
          try {
            final albumMap = Map<String, dynamic>.from(jsonDecode(albumJson));
            if ((albumMap['title'] as String?) == widget.album.title) {
              int playCount = (albumMap['playCount'] as int?) ?? 0;
              playCount++;
              albumMap['playCount'] = playCount;
              await prefs.setString(key, jsonEncode(albumMap));
            }
          } catch (e) {
            debugPrint(
                'Error incrementing album play count from album screen: $e');
          }
        }
      }
      await currentSongProvider.playAllWithContext(widget.album.tracks);
      navigator.push(
        MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('This album has no tracks to play.')),
      );
    }
  }

  void _playAlbumShuffle() async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (widget.album.tracks.isNotEmpty) {
      // Ensure shuffle is on
      if (!currentSongProvider.isShuffling) {
        currentSongProvider.toggleShuffle();
      }
      await currentSongProvider.playAllWithContext(widget.album.tracks);
      navigator.push(
        MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
            content: Text('This album has no tracks to shuffle play.')),
      );
    }
  }

  void _downloadAlbum() {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    int queuedCount = 0;
    int alreadyProcessedCount =
        0; // Tracks already downloaded or being processed

    if (widget.album.tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album is empty. Nothing to download.')),
      );
      return;
    }

    for (final track in widget.album.tracks) {
      // Skip if track is imported
      if (track.isImported) {
        alreadyProcessedCount++;
        continue;
      }

      // Check if already downloaded (persisted state)
      bool isPersistedAsDownloaded = track.isDownloaded;

      // Check if actively being downloaded by the provider
      bool isActiveDownload =
          currentSongProvider.activeDownloadTasks.containsKey(track.id);

      // Check if provider has marked it as 100% downloaded in this session
      bool isMarkedCompleteByProvider =
          currentSongProvider.downloadProgress[track.id] == 1.0;

      if (isPersistedAsDownloaded ||
          isActiveDownload ||
          isMarkedCompleteByProvider) {
        alreadyProcessedCount++;
        continue; // Skip this track
      }

      // If none of the above, queue it
      currentSongProvider.queueSongForDownload(track);
      queuedCount++;
    }

    if (queuedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $queuedCount track(s) for download.')),
      );
    } else if (alreadyProcessedCount == widget.album.tracks.length) {
      // This means all tracks were either already downloaded or are being processed
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('All tracks are already downloaded or being processed.')),
      );
    } else {
      // This case should ideally not be hit if the logic is correct and album is not empty.
      // It implies no tracks were queued and not all tracks were already processed.
      // Could happen if album has tracks but all failed some pre-check not covered,
      // or if there's a logic flaw.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No new tracks were queued for download.')),
      );
    }
  }

  Future<void> _removeDownloadsFromAlbum() async {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    if (widget.album.tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album is empty. Nothing to remove.')),
      );
      return;
    }

    // Get tracks that are downloaded (not imported)
    // Use the same logic as _updateAllTracksDownloadedStatus
    final tracksToRemoveDownloads = <Song>[];
    for (final track in widget.album.tracks) {
      if (track.isImported) continue; // Skip imported tracks

      final progress = currentSongProvider.downloadProgress[track.id];
      final bool isPersistedAsDownloaded = track.isDownloaded;

      bool isDownloaded = false;
      if (progress == 1.0) {
        // Explicitly marked as 100% downloaded by provider
        isDownloaded = true;
      } else if (progress == null && isPersistedAsDownloaded) {
        // Not in provider's active/completed download map for this session,
        // but the track data says it's downloaded
        bool foundInActiveDownloads =
            currentSongProvider.activeDownloadTasks.containsKey(track.id);
        if (!foundInActiveDownloads) {
          isDownloaded = true;
        }
      }

      if (isDownloaded) {
        tracksToRemoveDownloads.add(track);
      }
    }

    if (tracksToRemoveDownloads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No downloaded tracks to remove from this album.')),
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
              'Are you sure you want to remove downloads for ${tracksToRemoveDownloads.length} track(s) from this album? This will delete the local files but keep the tracks in your library.'),
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

    for (final track in tracksToRemoveDownloads) {
      try {
        // Delete the local audio file
        if (track.localFilePath != null && track.localFilePath!.isNotEmpty) {
          final audioFile = File(
              p.join(appDocDir.path, downloadsSubDir, track.localFilePath!));
          if (await audioFile.exists()) {
            await audioFile.delete();
            debugPrint('Deleted audio file: ${audioFile.path}');
          }
        }

        // Delete the local album art file if it exists and is not used by other tracks
        if (track.albumArtUrl.isNotEmpty &&
            !track.albumArtUrl.startsWith('http')) {
          // Check if any other track uses this cover
          bool coverIsUsedElsewhere = widget.album.tracks.any((other) =>
              other.id != track.id && other.albumArtUrl == track.albumArtUrl);

          if (!coverIsUsedElsewhere) {
            final albumArtFile =
                File(p.join(appDocDir.path, track.albumArtUrl));
            if (await albumArtFile.exists()) {
              await albumArtFile.delete();
              debugPrint('Deleted album art file: ${albumArtFile.path}');
            }
          }
        }

        // Fetch the original network album art URL
        String originalAlbumArtUrl = '';
        if (track.albumArtUrl.isNotEmpty &&
            !track.albumArtUrl.startsWith('http')) {
          // Try to fetch the original network URL for the album art
          try {
            final apiService = ApiService();
            // First try to find the track to get its album art URL
            final searchResults =
                await apiService.fetchSongs('${track.title} ${track.artist}');
            Song? exactMatch;
            for (final result in searchResults) {
              if (result.title.toLowerCase() == track.title.toLowerCase() &&
                  result.artist.toLowerCase() == track.artist.toLowerCase()) {
                exactMatch = result;
                break;
              }
            }

            if (exactMatch != null &&
                exactMatch.albumArtUrl.isNotEmpty &&
                exactMatch.albumArtUrl.startsWith('http')) {
              originalAlbumArtUrl = exactMatch.albumArtUrl;
            } else if (track.album != null && track.album!.isNotEmpty) {
              // Try to get the album art from the album
              final album =
                  await apiService.getAlbum(track.album!, track.artist);
              if (album != null && album.fullAlbumArtUrl.isNotEmpty) {
                originalAlbumArtUrl = album.fullAlbumArtUrl;
              }
            }
          } catch (e) {
            debugPrint(
                'Error fetching original album art URL for ${track.title}: $e');
            // If we can't fetch the original URL, we'll leave it empty
          }
        }

        // Update track metadata to mark as not downloaded and restore network album art URL
        final updatedTrack = track.copyWith(
          isDownloaded: false,
          localFilePath: null,
          albumArtUrl: originalAlbumArtUrl.isNotEmpty
              ? originalAlbumArtUrl
              : track.albumArtUrl,
        );

        // Update in SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'song_${updatedTrack.id}', jsonEncode(updatedTrack.toJson()));

        // Clear download progress from provider
        currentSongProvider.downloadProgress.remove(track.id);

        // Notify services
        currentSongProvider.updateSongDetails(updatedTrack);
        PlaylistManagerService().updateSongInPlaylists(updatedTrack);
        await AlbumManagerService().updateSongInAlbums(updatedTrack);

        removedCount++;
      } catch (e) {
        debugPrint('Error removing download for track ${track.title}: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Removed downloads for $removedCount track(s) from album.')),
      );
    }
  }

  void _toggleSaveAlbum() {
    if (_isSaved) {
      _albumManager.removeSavedAlbum(widget.album.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${widget.album.title}" unsaved.')),
      );
    } else {
      _albumManager.addSavedAlbum(widget.album);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${widget.album.title}" saved to library.')),
      );
    }
  }

  Widget _buildProminentAlbumArt(BuildContext context) {
    // Consistent size with playlist prominent art
    final imageSize = 160.0;

    String imageUrl = '';
    if (widget.album.effectiveAlbumArtUrl.isNotEmpty) {
      imageUrl = widget.album.effectiveAlbumArtUrl;
    } else if (widget.album.tracks.isNotEmpty &&
        widget.album.tracks.first.albumArtUrl.isNotEmpty &&
        widget.album.tracks.first.albumArtUrl.startsWith('http')) {
      imageUrl = widget.album.tracks.first.albumArtUrl;
    }

    Widget placeholder = Container(
      width: imageSize,
      height: imageSize,
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
      child: Icon(Icons.album,
          color: Colors.white.withValues(alpha: 0.7), size: imageSize * 0.5),
    );

    if (imageUrl.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: placeholder,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8.0),
      child: imageUrl.startsWith('http')
          ? Image.network(
              imageUrl,
              width: imageSize,
              height: imageSize,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
            )
          : FutureBuilder<String>(
              future: () async {
                final directory = await getApplicationDocumentsDirectory();
                final fileName = p.basename(imageUrl);
                final fullPath = p.join(directory.path, fileName);
                return await File(fullPath).exists() ? fullPath : '';
              }(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData &&
                    snapshot.data!.isNotEmpty) {
                  return Image.file(
                    File(snapshot.data!),
                    width: imageSize,
                    height: imageSize,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => placeholder,
                  );
                }
                return placeholder;
              },
            ),
    );
  }

  // ignore: unused_element
  Widget _buildTrackList() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.album.tracks.length,
      itemBuilder: (context, index) {
        final track = widget.album.tracks[index];
        return ListTile(
          leading: Text(
            '${index + 1}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  track.title,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          subtitle: Text(
            track.artist,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: track.duration != null
              ? Text(
                  _formatDuration(track.duration),
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : null,
          onTap: () {
            final currentSongProvider =
                Provider.of<CurrentSongProvider>(context, listen: false);
            currentSongProvider.setQueue(widget.album.tracks,
                initialIndex: index);
            currentSongProvider.playSong(widget.album.tracks[index]);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
            );
          },
          onLongPress: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SongDetailScreen(song: track),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadShowOnlySavedSongsSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final showOnlySaved = prefs.getBool('showOnlySavedSongsInAlbums') ?? false;
    setState(() {
      _showOnlySavedSongs = showOnlySaved;
    });
  }

  Future<void> _loadSavedSongIds() async {
    setState(() {
      _loadingSavedSongs = true;
    });
    // Load liked song IDs
    final prefs = await SharedPreferences.getInstance();
    final rawLiked = prefs.getStringList('liked_songs') ?? [];
    final likedIds = rawLiked
        .map((s) {
          try {
            return (jsonDecode(s) as Map<String, dynamic>)['id'] as String;
          } catch (_) {
            return null;
          }
        })
        .whereType<String>()
        .toSet();
    // Load playlist song IDs
    final playlistManager = PlaylistManagerService();
    await playlistManager.ensurePlaylistsLoaded();
    final playlistSongIds = <String>{};
    for (final playlist in playlistManager.playlists) {
      for (final song in playlist.songs) {
        playlistSongIds.add(song.id);
      }
    }
    setState(() {
      _likedSongIds = likedIds;
      _playlistSongIds = playlistSongIds;
      _loadingSavedSongs = false;
    });
  }

  bool _isSongSaved(Song song) {
    return _likedSongIds.contains(song.id) ||
        _playlistSongIds.contains(song.id);
  }

  List<Song> get _filteredTracks {
    if ((_showOnlySavedSongs && !_overrideShowAll) && widget.album.isSaved) {
      // Only show songs that are liked or in a playlist
      return widget.album.tracks.where((t) => _isSongSaved(t)).toList();
    }
    return widget.album.tracks;
  }

  void _toggleShowAllSongs() {
    setState(() {
      _overrideShowAll = !_overrideShowAll;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool hasTracks = widget.album.tracks.isNotEmpty;
    final systemTopPadding = MediaQuery.of(context).padding.top;

    String backgroundArtUrl = '';
    if (widget.album.fullAlbumArtUrl.isNotEmpty &&
        widget.album.fullAlbumArtUrl.startsWith('http')) {
      backgroundArtUrl = widget.album.fullAlbumArtUrl;
    } else if (hasTracks &&
        widget.album.tracks.first.albumArtUrl.isNotEmpty &&
        widget.album.tracks.first.albumArtUrl.startsWith('http')) {
      backgroundArtUrl = widget.album.tracks.first.albumArtUrl;
    }

    Widget flexibleSpaceBackground;
    if (backgroundArtUrl.isNotEmpty) {
      flexibleSpaceBackground = Image.network(
        backgroundArtUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Container(color: Colors.grey[850]),
      );
    } else {
      flexibleSpaceBackground = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.primary,
              colorScheme.primaryContainer.withValues(alpha: 0.5)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    return Scaffold(
      // appBar removed, will be part of CustomScrollView
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 390.0, // Adjusted to match playlist screen
            pinned: true,
            stretch: true,
            // leading: IconButton for back button is implicitly handled by SliverAppBar
            flexibleSpace: FlexibleSpaceBar(
              title: Builder(builder: (context) {
                final settings = context.dependOnInheritedWidgetOfExactType<
                    FlexibleSpaceBarSettings>();
                if (settings == null) return const SizedBox.shrink();
                final double delta = settings.maxExtent - settings.minExtent;
                final double collapseThreshold = delta * 0.1;
                double opacity = 0.0;
                if (delta > 0) {
                  if ((settings.currentExtent - settings.minExtent) <
                      collapseThreshold) {
                    opacity = 1.0 -
                        ((settings.currentExtent - settings.minExtent) /
                            collapseThreshold);
                    opacity = opacity.clamp(0.0, 1.0);
                  }
                } else if (settings.currentExtent == settings.minExtent) {
                  opacity = 1.0;
                }
                return Opacity(
                  opacity: opacity,
                  child: Text(
                    widget.album.title,
                    style: _safeTextStyle(textTheme.headlineSmall,
                        color: Colors.white,
                        shadows: const [
                          Shadow(
                              blurRadius: 1.0,
                              color: Colors.black54,
                              offset: Offset(0.5, 0.5))
                        ],
                        fallbackFontSize: 16.0),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }),
              centerTitle: true,
              titlePadding:
                  const EdgeInsets.only(bottom: 16.0, left: 48.0, right: 48.0),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  flexibleSpaceBackground,
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.6),
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
                        // Main album info card
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
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // Enhanced artwork with glow effect
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.white
                                              .withValues(alpha: 0.1),
                                          blurRadius: 8,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: _buildProminentAlbumArt(context),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        // Album name with better styling
                                        Text(
                                          widget.album.title,
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
                                        // Artist name with icon
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.person,
                                              size: 16,
                                              color: Colors.white
                                                  .withValues(alpha: 0.8),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              widget.album.artistName,
                                              style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.9),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500,
                                                  shadows: const [
                                                    Shadow(
                                                        blurRadius: 2,
                                                        color: Colors.black54)
                                                  ]),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
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
                                              '${widget.album.tracks.length} songs',
                                              style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.9),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500,
                                                  shadows: const [
                                                    Shadow(
                                                        blurRadius: 2,
                                                        color: Colors.black54)
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
                                              _formatDuration(
                                                  _calculateTotalDuration()),
                                              style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.8),
                                                  fontSize: 14,
                                                  shadows: const [
                                                    Shadow(
                                                        blurRadius: 1,
                                                        color: Colors.black54)
                                                  ]),
                                            ),
                                          ],
                                        ),
                                        if (_areAllTracksDownloaded &&
                                            hasTracks) ...[
                                          const SizedBox(height: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 6),
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Colors.greenAccent
                                                      .withValues(alpha: 0.3),
                                                  Colors.green
                                                      .withValues(alpha: 0.2),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: Colors.greenAccent
                                                    .withValues(alpha: 0.5),
                                                width: 1.5,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.greenAccent
                                                      .withValues(alpha: 0.2),
                                                  blurRadius: 4,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.offline_pin,
                                                    color: Colors.greenAccent,
                                                    size: 16),
                                                const SizedBox(width: 6),
                                                Text(
                                                  'Downloaded',
                                                  style: TextStyle(
                                                      color: Colors.greenAccent,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      shadows: const [
                                                        Shadow(
                                                          blurRadius: 1,
                                                          color: Colors.black54,
                                                        ),
                                                      ]),
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
                              // Action buttons row - positioned inside the album card
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Play All button
                                  Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Theme.of(context).colorScheme.primary,
                                          Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.8),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
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
                                      onPressed: hasTracks ? _playAlbum : null,
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
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color:
                                            Colors.white.withValues(alpha: 0.3),
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
                                      onPressed:
                                          hasTracks ? _playAlbumShuffle : null,
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
                                  if (hasTracks) ...[
                                    const SizedBox(width: 12),
                                    // Download/All Downloaded button
                                    Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: _areAllTracksDownloaded
                                              ? Colors.red
                                                  .withValues(alpha: 0.3)
                                              : Colors.white
                                                  .withValues(alpha: 0.2),
                                          width: 1.5,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: (_areAllTracksDownloaded
                                                    ? Colors.red
                                                    : Colors.white)
                                                .withValues(alpha: 0.1),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: IconButton(
                                        onPressed: _areAllTracksDownloaded
                                            ? _removeDownloadsFromAlbum
                                            : _downloadAlbum,
                                        icon: Icon(
                                            _areAllTracksDownloaded
                                                ? Icons.remove_circle
                                                : Icons.download,
                                            size: 20,
                                            color: _areAllTracksDownloaded
                                                ? Colors.red
                                                    .withValues(alpha: 0.9)
                                                : Colors.white
                                                    .withValues(alpha: 0.9)),
                                        style: IconButton.styleFrom(
                                          backgroundColor:
                                              _areAllTracksDownloaded
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
                                    // Save/Remove button
                                    Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: _isSaved
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                                  .withValues(alpha: 0.3)
                                              : Colors.white
                                                  .withValues(alpha: 0.2),
                                          width: 1.5,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: (_isSaved
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .error
                                                    : Colors.white)
                                                .withValues(alpha: 0.1),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: IconButton(
                                        onPressed: _toggleSaveAlbum,
                                        icon: Icon(
                                            _isSaved
                                                ? Icons.bookmark_remove
                                                : Icons.bookmark_add,
                                            size: 20,
                                            color: _isSaved
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .error
                                                    .withValues(alpha: 0.9)
                                                : Colors.white
                                                    .withValues(alpha: 0.9)),
                                        style: IconButton.styleFrom(
                                          backgroundColor: _isSaved
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .error
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
          if (hasTracks) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 16.0, right: 16.0, top: 24.0, bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Tracks',
                        style: _safeTextStyle(textTheme.titleLarge,
                            color: colorScheme.onSurface,
                            fallbackFontSize: 22.0)),
                    if (_showOnlySavedSongs && widget.album.isSaved)
                      TextButton(
                        onPressed: _toggleShowAllSongs,
                        child: Text(_overrideShowAll
                            ? 'Show Only Saved Songs'
                            : 'Show All Songs'),
                      ),
                  ],
                ),
              ),
            ),
            if (_loadingSavedSongs)
              const SliverToBoxAdapter(
                child: Center(
                    child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: CircularProgressIndicator(),
                )),
              ),
            if (_filteredTracks.isNotEmpty) ...[
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final track = _filteredTracks[index];
                    return Slidable(
                      key: Key(track.id),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        extentRatio: 0.32, // enough for two square buttons
                        children: [
                          SlidableAction(
                            onPressed: (context) {
                              final currentSongProvider =
                                  Provider.of<CurrentSongProvider>(context,
                                      listen: false);
                              currentSongProvider.addToQueue(track);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content:
                                        Text('${track.title} added to queue')),
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
                              showDialog(
                                context: context,
                                builder: (BuildContext dialogContext) {
                                  return AddToPlaylistDialog(song: track);
                                },
                              );
                            },
                            backgroundColor:
                                Theme.of(context).colorScheme.secondary,
                            foregroundColor:
                                Theme.of(context).colorScheme.onSecondary,
                            icon: Icons.library_add,
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
                            child: Container(
                              width: 50,
                              height: 50,
                              color: Colors.grey[700],
                              child: track.albumArtUrl.isNotEmpty
                                  ? track.albumArtUrl.startsWith('http')
                                      ? Image.network(
                                          track.albumArtUrl,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) =>
                                                  Icon(
                                            Icons.music_note,
                                            size: 30,
                                            color: Colors.white70,
                                          ),
                                        )
                                      : FutureBuilder<String>(
                                          future: () async {
                                            final directory =
                                                await getApplicationDocumentsDirectory();
                                            final fileName =
                                                p.basename(track.albumArtUrl);
                                            final fullPath = p.join(
                                                directory.path, fileName);
                                            return await File(fullPath).exists()
                                                ? fullPath
                                                : '';
                                          }(),
                                          builder: (context, snapshot) {
                                            if (snapshot.connectionState ==
                                                    ConnectionState.done &&
                                                snapshot.hasData &&
                                                snapshot.data!.isNotEmpty) {
                                              return Image.file(
                                                File(snapshot.data!),
                                                width: 50,
                                                height: 50,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error,
                                                        stackTrace) =>
                                                    Icon(
                                                  Icons.music_note,
                                                  size: 30,
                                                  color: Colors.white70,
                                                ),
                                              );
                                            }
                                            return Icon(
                                              Icons.music_note,
                                              size: 30,
                                              color: Colors.white70,
                                            );
                                          },
                                        )
                                  : Icon(
                                      Icons.music_note,
                                      size: 30,
                                      color: Colors.white70,
                                    ),
                            ),
                          ),
                          title: Text(
                            track.title,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.artist.isNotEmpty
                                ? track.artist
                                : widget.album.artistName,
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
                              Text(
                                track.duration != null
                                    ? '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}'
                                    : '-:--',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5)),
                              ),
                            ],
                          ),
                          onTap: () async {
                            final currentSongProvider =
                                Provider.of<CurrentSongProvider>(context,
                                    listen: false);
                            final navigator =
                                Navigator.of(context); // Capture before async
                            await currentSongProvider.smartPlayWithContext(
                                widget.album.tracks,
                                widget.album.tracks[index]);
                            navigator.push(
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const FullScreenPlayer()),
                            );
                          },
                          onLongPress: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    SongDetailScreen(song: track),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  childCount: _filteredTracks.length,
                ),
              ),
            ],
          ] else ...[
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.music_off_outlined,
                        size: 60, color: colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                      'This album has no tracks.',
                      style: _safeTextStyle(textTheme.titleMedium,
                          color: colorScheme.onSurfaceVariant,
                          fallbackFontSize: 16.0),
                    ),
                  ],
                ),
              ),
            )
          ],
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
  }
}
