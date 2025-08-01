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

class _AlbumScreenState extends State<AlbumScreen> {
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
        _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
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
      final bool isMarkedCompleteByProvider = currentSongProvider.downloadProgress[track.id] == 1.0;
      final bool isActiveDownload = currentSongProvider.activeDownloadTasks.containsKey(track.id);

      if (isPersistedAsDownloaded && !isMarkedCompleteByProvider && !isActiveDownload) {
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

    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
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
          bool foundInActiveDownloads = currentSongProvider.activeDownloadTasks.containsKey(track.id);
          if (foundInActiveDownloads) { // If it's in active downloads but progress is null, it's not done.
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
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
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
            debugPrint('Error incrementing album play count from album screen: $e');
          }
        }
      }
      await currentSongProvider.playWithContext(widget.album.tracks, widget.album.tracks.first);
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
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    if (widget.album.tracks.isNotEmpty) {
      // Ensure shuffle is on
      if (!currentSongProvider.isShuffling) {
        currentSongProvider.toggleShuffle();
      }
      await currentSongProvider.playWithContext(widget.album.tracks, widget.album.tracks.first);
      navigator.push(
        MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('This album has no tracks to shuffle play.')),
      );
    }
  }

  void _downloadAlbum() {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    int queuedCount = 0;
    int alreadyProcessedCount = 0; // Tracks already downloaded or being processed

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
      bool isActiveDownload = currentSongProvider.activeDownloadTasks.containsKey(track.id);
      
      // Check if provider has marked it as 100% downloaded in this session
      bool isMarkedCompleteByProvider = currentSongProvider.downloadProgress[track.id] == 1.0;

      if (isPersistedAsDownloaded || isActiveDownload || isMarkedCompleteByProvider) {
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
        const SnackBar(content: Text('All tracks are already downloaded or being processed.')),
      );
    } else {
      // This case should ideally not be hit if the logic is correct and album is not empty.
      // It implies no tracks were queued and not all tracks were already processed.
      // Could happen if album has tracks but all failed some pre-check not covered,
      // or if there's a logic flaw.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No new tracks were queued for download.')),
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
    } else if (widget.album.tracks.isNotEmpty && widget.album.tracks.first.albumArtUrl.isNotEmpty && widget.album.tracks.first.albumArtUrl.startsWith('http')) {
      imageUrl = widget.album.tracks.first.albumArtUrl;
    }

    Widget placeholder = Container(
      width: imageSize,
      height: imageSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
              child: Icon(Icons.album, color: Colors.white.withValues(alpha: 0.7), size: imageSize * 0.5),
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
            final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
            currentSongProvider.setQueue(widget.album.tracks, initialIndex: index);
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
    setState(() { _loadingSavedSongs = true; });
    // Load liked song IDs
    final prefs = await SharedPreferences.getInstance();
    final rawLiked = prefs.getStringList('liked_songs') ?? [];
    final likedIds = rawLiked.map((s) {
      try {
        return (jsonDecode(s) as Map<String, dynamic>)['id'] as String;
      } catch (_) {
        return null;
      }
    }).whereType<String>().toSet();
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
    return _likedSongIds.contains(song.id) || _playlistSongIds.contains(song.id);
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
    if (widget.album.fullAlbumArtUrl.isNotEmpty && widget.album.fullAlbumArtUrl.startsWith('http')) {
      backgroundArtUrl = widget.album.fullAlbumArtUrl;
    } else if (hasTracks && widget.album.tracks.first.albumArtUrl.isNotEmpty && widget.album.tracks.first.albumArtUrl.startsWith('http')) {
      backgroundArtUrl = widget.album.tracks.first.albumArtUrl;
    }

    Widget flexibleSpaceBackground;
    if (backgroundArtUrl.isNotEmpty) {
      flexibleSpaceBackground = Image.network(
        backgroundArtUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[850]),
      );
    } else {
      flexibleSpaceBackground = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [colorScheme.primary, colorScheme.primaryContainer.withValues(alpha: 0.5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    final playAllButtonStyle = ElevatedButton.styleFrom(
      backgroundColor: theme.colorScheme.surface,
      foregroundColor: theme.colorScheme.onSurface,
      padding: const EdgeInsets.symmetric(vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );

    final shuffleButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.7)),
      padding: const EdgeInsets.symmetric(vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
    
          final secondaryButtonColor = Colors.white.withValues(alpha: 0.85);
      final secondaryButtonSideColor = Colors.white.withValues(alpha: 0.4);

    final removeButtonStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
      ),
    );
    
    final saveButtonStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: secondaryButtonSideColor),
      ),
    );


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
              title: Builder(
                builder: (context) {
                  final settings = context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
                  if (settings == null) return const SizedBox.shrink();
                  final double delta = settings.maxExtent - settings.minExtent;
                  final double collapseThreshold = delta * 0.1;
                  double opacity = 0.0;
                  if (delta > 0) {
                    if ((settings.currentExtent - settings.minExtent) < collapseThreshold) {
                        opacity = 1.0 - ((settings.currentExtent - settings.minExtent) / collapseThreshold);
                        opacity = opacity.clamp(0.0, 1.0);
                    }
                  } else if (settings.currentExtent == settings.minExtent) {
                    opacity = 1.0;
                  }
                  return Opacity(
                    opacity: opacity,
                    child: Text(
                      widget.album.title,
                      style: const TextStyle(
                        fontSize: 16.0,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 1.0, color: Colors.black54, offset: Offset(0.5, 0.5))],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }
              ),
              centerTitle: true,
              titlePadding: const EdgeInsets.only(bottom: 16.0, left: 48.0, right: 48.0),
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
                  Padding(
                    padding: EdgeInsets.only(
                      top: systemTopPadding + kToolbarHeight + 10,
                      left: 16.0,
                      right: 16.0,
                      bottom: 16.0,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildProminentAlbumArt(context),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    widget.album.title,
                                    style: textTheme.headlineSmall
                                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold, shadows: const [
                                          Shadow(blurRadius: 3, color: Colors.black)
                                        ]),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.album.artistName,
                                    style: textTheme.titleMedium
                                        ?.copyWith(color: Colors.white70, shadows: const [Shadow(blurRadius: 2, color: Colors.black87)]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${widget.album.tracks.length} Songs',
                                    style: textTheme.titleMedium?.copyWith(
                                      color: Colors.white60,
                                      shadows: const [Shadow(blurRadius: 2, color: Colors.black54)],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatDuration(_calculateTotalDuration()),
                                    style: textTheme.bodyMedium?.copyWith(
                                      color: Colors.white60,
                                      shadows: const [Shadow(blurRadius: 1, color: Colors.black54)],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play All'),
                                onPressed: hasTracks ? _playAlbum : null,
                                style: playAllButtonStyle,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.shuffle),
                                label: const Text('Shuffle'),
                                onPressed: hasTracks ? _playAlbumShuffle : null,
                                style: shuffleButtonStyle,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            if (hasTracks)
                              if (_areAllTracksDownloaded)
                                Expanded(
                                  child: TextButton.icon(
                                                icon: Icon(Icons.check_circle_outline, color: secondaryButtonColor.withValues(alpha: 0.7)),
            label: Text('All Downloaded', style: TextStyle(color: secondaryButtonColor.withValues(alpha: 0.7))),
                                    onPressed: null, // Disabled
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                        side: BorderSide(color: secondaryButtonSideColor.withValues(alpha: 0.5)),
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Expanded(
                                  child: TextButton.icon(
                                    icon: Icon(Icons.download_for_offline_outlined, color: secondaryButtonColor),
                                    label: Text('Download', style: TextStyle(color: secondaryButtonColor)),
                                    onPressed: _downloadAlbum,
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                        side: BorderSide(color: secondaryButtonSideColor),
                                      ),
                                    ),
                                  ),
                                ),
                            if (hasTracks) const SizedBox(width: 12),
                            Expanded(
                              child: TextButton.icon(
                                icon: Icon(
                                  _isSaved ? Icons.delete_outline : Icons.bookmark_add_outlined,
                                  color: _isSaved ? theme.colorScheme.error.withValues(alpha: 0.9) : secondaryButtonColor,
                                ),
                                label: Text(
                                  _isSaved ? 'Remove' : 'Save',
                                  style: TextStyle(color: _isSaved ? theme.colorScheme.error.withValues(alpha: 0.9) : secondaryButtonColor),
                                ),
                                onPressed: _toggleSaveAlbum,
                                style: _isSaved ? removeButtonStyle : saveButtonStyle,
                              ),
                            ),
                          ],
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
                padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 24.0, bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Tracks', style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface)),
                    if (_showOnlySavedSongs && widget.album.isSaved)
                      TextButton(
                        onPressed: _toggleShowAllSongs,
                        child: Text(_overrideShowAll ? 'Show Only Saved Songs' : 'Show All Songs'),
                      ),
                  ],
                ),
              ),
            ),
            if (_loadingSavedSongs)
              const SliverToBoxAdapter(
                child: Center(child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: CircularProgressIndicator(),
                )),
              ),
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
                            final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                            currentSongProvider.addToQueue(track);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('${track.title} added to queue')),
                            );
                          },
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
                          backgroundColor: Theme.of(context).colorScheme.secondary,
                          foregroundColor: Theme.of(context).colorScheme.onSecondary,
                          icon: Icons.library_add,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                      leading: Text(
                        '${index + 1}',
                        style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      title: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        track.artist.isNotEmpty ? track.artist : widget.album.artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      trailing: Text(
                        track.duration != null ? '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}' : '-:--',
                        style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      onTap: () async {
                        final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                        final navigator = Navigator.of(context); // Capture before async
                        await currentSongProvider.playWithContext(widget.album.tracks, widget.album.tracks[index]);
                        navigator.push(
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
                    ),
                  );
                },
                childCount: _filteredTracks.length,
              ),
            ),
          ] else ...[
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.music_off_outlined, size: 60, color: colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(
                      'This album has no tracks.',
                      style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
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
