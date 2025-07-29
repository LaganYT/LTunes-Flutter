import 'package:flutter/material.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../services/album_manager_service.dart';
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

class DesktopAlbumScreen extends StatefulWidget {
  final Album album;

  const DesktopAlbumScreen({
    super.key,
    required this.album,
  });

  @override
  State<DesktopAlbumScreen> createState() => _DesktopAlbumScreenState();
}

class _DesktopAlbumScreenState extends State<DesktopAlbumScreen> {
  bool _isSaved = false;
  bool _isLoading = false;
  String? _localArtPath;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  Set<String> _likedSongIds = {};

  @override
  void initState() {
    super.initState();
    _loadAlbumStatus();
    _loadLocalArtwork();
    _loadLikedSongIds();
  }

  Future<void> _loadAlbumStatus() async {
    final albumManager = Provider.of<AlbumManagerService>(context, listen: false);
    final isSaved = albumManager.savedAlbums.any((album) => album.id == widget.album.id);
    
    setState(() {
      _isSaved = isSaved;
    });
  }

  Future<void> _loadLocalArtwork() async {
    if (widget.album.effectiveAlbumArtUrl.startsWith('http')) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = widget.album.effectiveAlbumArtUrl;
      final filePath = p.join(directory.path, fileName);
      final file = File(filePath);
      
      if (await file.exists()) {
        setState(() {
          _localArtPath = filePath;
        });
      }
    } catch (e) {
      debugPrint('Error loading local artwork: $e');
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

  Future<void> _toggleSave() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final albumManager = Provider.of<AlbumManagerService>(context, listen: false);
      
      if (_isSaved) {
        await albumManager.removeSavedAlbum(widget.album.id);
      } else {
        await albumManager.addSavedAlbum(widget.album);
      }
      
      setState(() {
        _isSaved = !_isSaved;
        _isLoading = false;
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'toggle_save_album');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _playAlbum() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    if (widget.album.tracks.isNotEmpty) {
      currentSongProvider.playSong(widget.album.tracks.first);
    }
  }

  Future<void> _shuffleAlbum() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    if (widget.album.tracks.isNotEmpty) {
      final shuffledTracks = List<Song>.from(widget.album.tracks)..shuffle();
      currentSongProvider.playSong(shuffledTracks.first);
    }
  }

  Future<void> _toggleLike(Song song) async {
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
          // Album artwork with enhanced shadow
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
              child: _localArtPath != null
                ? Image.file(
                    File(_localArtPath!),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => _buildPlaceholderArtwork(),
                  )
                : CachedNetworkImage(
                    imageUrl: widget.album.effectiveAlbumArtUrl,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => _buildPlaceholderArtwork(),
                    errorWidget: (context, url, error) => _buildPlaceholderArtwork(),
                  ),
            ),
          ),
          const SizedBox(width: 32),
          // Album information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.album.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 32,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.album.artistName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.album.tracks.length} tracks',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 16,
                  ),
                ),
                if (widget.album.releaseDate.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Released ${widget.album.releaseDate}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                // Action buttons with Spotify-like styling
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _playAlbum,
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
                      onPressed: _shuffleAlbum,
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
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _toggleSave,
                      icon: Icon(_isSaved ? Icons.favorite : Icons.favorite_border),
                      label: Text(_isSaved ? 'Saved' : 'Save'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isSaved 
                          ? const Color(0xFFFF9800) // LTunes orange
                          : Theme.of(context).colorScheme.surface,
                        foregroundColor: _isSaved 
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
        Icons.album,
        size: 64,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildTracksList() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tracks',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.album.tracks.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final track = widget.album.tracks[index];
                final isLiked = _likedSongIds.contains(track.id);
                
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _localArtPath != null
                        ? Image.file(
                            File(_localArtPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => _buildTrackPlaceholder(),
                          )
                        : CachedNetworkImage(
                            imageUrl: track.albumArtUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => _buildTrackPlaceholder(),
                            errorWidget: (context, url, error) => _buildTrackPlaceholder(),
                          ),
                    ),
                  ),
                  title: Text(
                    track.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    track.artist,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (track.duration != null)
                        Text(
                          _formatDuration(track.duration!),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => _toggleLike(track),
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
                              builder: (context) => DesktopSongDetailScreen(song: track),
                            ),
                          );
                        },
                        icon: const Icon(Icons.info_outline),
                      ),
                    ],
                  ),
                  onTap: () {
                    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                    currentSongProvider.playSong(track);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.music_note,
        size: 20,
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
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 24),
            _buildTracksList(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
} 