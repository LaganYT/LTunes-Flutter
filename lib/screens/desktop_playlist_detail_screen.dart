import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import '../services/error_handler_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'desktop_song_detail_screen.dart';

class DesktopPlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const DesktopPlaylistDetailScreen({
    super.key,
    required this.playlist,
  });

  @override
  State<DesktopPlaylistDetailScreen> createState() => _DesktopPlaylistDetailScreenState();
}

class _DesktopPlaylistDetailScreenState extends State<DesktopPlaylistDetailScreen> {
  List<Song> _playlistSongs = [];
  bool _isLoading = true;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final Map<String, String> _localArtPathCache = {};
  Set<String> _likedSongIds = {};

  @override
  void initState() {
    super.initState();
    _loadPlaylistSongs();
    _loadLikedSongIds();
  }

  Future<void> _loadPlaylistSongs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Use the songs directly from the playlist
      final songs = widget.playlist.songs;
      
      // Load local artwork paths
      for (final song in songs) {
        if (song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
          final path = await _resolveLocalArtPath(song.albumArtUrl);
          _localArtPathCache[song.id] = path;
        }
      }

      setState(() {
        _playlistSongs = songs;
        _isLoading = false;
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'load_playlist_songs');
      setState(() {
        _isLoading = false;
      });
    }
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

  Future<String> _resolveLocalArtPath(String artUrl) async {
    if (artUrl.isEmpty || artUrl.startsWith('http')) return '';
    
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

  Future<void> _removeFromPlaylist(Song song) async {
    try {
      final playlistManager = Provider.of<PlaylistManagerService>(context, listen: false);
      await playlistManager.removeSongFromPlaylist(widget.playlist, song);
      
      setState(() {
        _playlistSongs.removeWhere((s) => s.id == song.id);
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'remove_from_playlist');
    }
  }

  Future<void> _toggleLike(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('liked_songs') ?? [];
      
      if (_likedSongIds.contains(song.id)) {
        // Remove from liked songs
        raw.removeWhere((songJson) {
          try {
            final songData = jsonDecode(songJson) as Map<String, dynamic>;
            return songData['id'] == song.id;
          } catch (e) {
            return false;
          }
        });
      } else {
        // Add to liked songs
        raw.add(jsonEncode(song.toJson()));
      }
      
      await prefs.setStringList('liked_songs', raw);
      
      setState(() {
        if (_likedSongIds.contains(song.id)) {
          _likedSongIds.remove(song.id);
        } else {
          _likedSongIds.add(song.id);
        }
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'toggle_like');
    }
  }

  Future<void> _playPlaylist() async {
    if (_playlistSongs.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      currentSongProvider.playSong(_playlistSongs.first);
    }
  }

  Future<void> _shufflePlaylist() async {
    if (_playlistSongs.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final shuffledSongs = List<Song>.from(_playlistSongs)..shuffle();
      currentSongProvider.playSong(shuffledSongs.first);
    }
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Theme.of(context).colorScheme.surface,
            Theme.of(context).colorScheme.surface.withOpacity(0.8),
          ],
        ),
      ),
      child: Row(
        children: [
          // Playlist artwork with enhanced shadow
          Container(
            width: 300,
            height: 300,
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
              child: _buildPlaceholderArtwork(),
            ),
          ),
          const SizedBox(width: 32),
          // Playlist information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.playlist.name,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 32,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_playlistSongs.length} songs',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 20,
                  ),
                ),

                const SizedBox(height: 24),
                // Action buttons with Spotify-like styling
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _playlistSongs.isNotEmpty ? _playPlaylist : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9800), // LTunes orange
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _playlistSongs.isNotEmpty ? _shufflePlaylist : null,
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderArtwork() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.playlist_play,
        size: 64,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildSongsList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFF9800), // LTunes orange
        ),
      );
    }

    if (_playlistSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.playlist_play,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No songs in playlist',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add songs to get started',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _playlistSongs.length,
      itemBuilder: (context, index) {
        final song = _playlistSongs[index];
        final localArtPath = _localArtPathCache[song.id];
        final isLiked = _likedSongIds.contains(song.id);
        
        return Slidable(
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            children: [
              SlidableAction(
                onPressed: (_) => _removeFromPlaylist(song),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                icon: Icons.remove,
                label: 'Remove',
              ),
            ],
          ),
          child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: localArtPath != null && localArtPath.isNotEmpty
                    ? Image.file(
                        File(localArtPath),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => _buildSongPlaceholder(),
                      )
                    : CachedNetworkImage(
                        imageUrl: song.albumArtUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => _buildSongPlaceholder(),
                        errorWidget: (context, url, error) => _buildSongPlaceholder(),
                      ),
                ),
              ),
              title: Text(
                song.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                song.artist,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (song.duration != null)
                    Text(
                      _formatDuration(song.duration!),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _toggleLike(song),
                    icon: Icon(
                      isLiked ? Icons.favorite : Icons.favorite_border,
                      color: isLiked ? const Color(0xFFFF9800) : null,
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => DesktopSongDetailScreen(song: song),
                        ),
                      );
                    },
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              ),
              onTap: () {
                final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                currentSongProvider.playSong(song);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.music_note,
        size: 24,
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
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _buildSongsList(),
          ),
        ],
      ),
    );
  }
} 