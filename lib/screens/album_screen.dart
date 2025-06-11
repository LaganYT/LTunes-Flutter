import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/album.dart';
import '../models/song.dart'; // Ensure Song class is imported
import '../providers/current_song_provider.dart';
import '../services/album_manager_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io'; // For File operations
import '../widgets/full_screen_player.dart'; // For navigation to player
import '../screens/song_detail_screen.dart'; // For navigation to song details

class AlbumScreen extends StatefulWidget {
  final Album album;

  const AlbumScreen({super.key, required this.album});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late bool _isSaved;
  final AlbumManagerService _albumManager = AlbumManagerService();

  @override
  void initState() {
    super.initState();
    _isSaved = _albumManager.isAlbumSaved(widget.album.id);
    _albumManager.addListener(_onAlbumManagerStateChanged);
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
    super.dispose();
  }

  // ignore: unused_element
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    return await File(fullPath).exists() ? fullPath : '';
  }

  // Helper function to get a song prepared for playback (local if available)
  Song _getPlayableSong(Song song) {
    if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
      return song.copyWith(audioUrl: song.localFilePath);
    }
    return song;
  }

  // Helper function to get a list of songs prepared for playback
  List<Song> _getPlayableQueue(List<Song> songs) {
    return songs.map((s) => _getPlayableSong(s)).toList();
  }

  void _playAlbum() {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    if (widget.album.tracks.isNotEmpty) {
      final playableQueue = _getPlayableQueue(widget.album.tracks);
      currentSongProvider.setQueue(playableQueue, initialIndex: 0);
      currentSongProvider.playSong(playableQueue.first);
      // Navigate to FullScreenPlayer
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
        );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This album has no tracks to play.')),
      );
    }
  }

  void _downloadAlbum() {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    int queuedCount = 0;
    for (final track in widget.album.tracks) {
      if (!track.isDownloaded) { // Check if already downloaded
        currentSongProvider.queueSongForDownload(track);
        queuedCount++;
      }
    }
    if (queuedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $queuedCount track(s) for download.')),
      );
    } else if (widget.album.tracks.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All tracks in this album are already downloaded or the album is empty.')),
      );
    } else {
       ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album is empty. Nothing to download.')),
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
    // The listener _onAlbumManagerStateChanged will update _isSaved and rebuild UI
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    Widget appBarBackground;
    if (widget.album.fullAlbumArtUrl.isNotEmpty) {
      appBarBackground = Image.network(
        widget.album.fullAlbumArtUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800]),
      );
    } else {
      appBarBackground = Container(color: Colors.grey[800]);
    }
    
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 350.0,
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              centerTitle: true,
              background: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect( // For rounded corners on the main image if desired at this level
                     // borderRadius: BorderRadius.circular(12.0), // Example
                    child: appBarBackground,
                  ),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                    child: Container(
                      color: Colors.black.withOpacity(0.4),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16.0).copyWith(top: kToolbarHeight + 20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Hero(
                          tag: 'album-art-${widget.album.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12.0),
                            child: Image.network(
                              widget.album.fullAlbumArtUrl,
                              width: 180,
                              height: 180,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => 
                                Container(
                                  width: 180, height: 180, 
                                  color: colorScheme.surfaceVariant,
                                  child: Icon(Icons.album, size: 80, color: colorScheme.onSurfaceVariant)
                                ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text( // Added album title here
                          widget.album.title,
                          style: textTheme.headlineSmall?.copyWith(
                            color: Colors.white, 
                            fontWeight: FontWeight.bold,
                            shadows: [
                              const Shadow(blurRadius: 2, color: Colors.black87)
                            ]
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2, // Allow for longer titles
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4), // Adjusted spacing
                        Text(
                          widget.album.artistName,
                          style: textTheme.titleMedium?.copyWith(color: Colors.white.withOpacity(0.9), shadows: [
                            const Shadow(blurRadius: 1, color: Colors.black54)
                          ]),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.album.tracks.length} tracks • ${widget.album.releaseDate}',
                          style: textTheme.bodySmall?.copyWith(color: Colors.white.withOpacity(0.8), shadows: [
                             const Shadow(blurRadius: 1, color: Colors.black54)
                          ]),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_circle_fill_outlined),
                              iconSize: 36,
                              color: Colors.white,
                              tooltip: 'Play Album',
                              onPressed: _playAlbum,
                            ),
                            IconButton(
                              icon: const Icon(Icons.download_for_offline_outlined),
                              iconSize: 36,
                              color: Colors.white,
                              tooltip: 'Download Album',
                              onPressed: _downloadAlbum,
                            ),
                            IconButton(
                              icon: Icon(_isSaved ? Icons.bookmark_added_outlined : Icons.bookmark_add_outlined),
                              iconSize: 36,
                              color: _isSaved ? colorScheme.primary : Colors.white,
                              tooltip: _isSaved ? 'Unsave Album' : 'Save Album',
                              onPressed: _toggleSaveAlbum,
                            ),
                          ],
                        ),
                        const SizedBox(height: 24), // Added bottom margin
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final track = widget.album.tracks[index];
                return ListTile(
                  leading: Text('${index + 1}', style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                  title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(track.artist.isNotEmpty ? track.artist : widget.album.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(
                    track.duration != null ? '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}' : '-:--',
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  onTap: () {
                    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                    final playableQueue = _getPlayableQueue(widget.album.tracks);
                    final playableTrack = playableQueue[index]; // Get the potentially modified track from the new queue

                    currentSongProvider.setQueue(playableQueue, initialIndex: index);
                    currentSongProvider.playSong(playableTrack);
                     Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const FullScreenPlayer()),
                      );
                  },
                  onLongPress: () { // Navigate to SongDetailScreen on long press
                     Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => SongDetailScreen(song: track),
                        ),
                      );
                  },
                );
              },
              childCount: widget.album.tracks.length,
            ),
          ),
        ],
      ),
    );
  }
}
