import 'package:flutter/material.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import '../services/album_manager_service.dart';
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

class DesktopSongDetailScreen extends StatefulWidget {
  final Song song;

  const DesktopSongDetailScreen({
    super.key,
    required this.song,
  });

  @override
  State<DesktopSongDetailScreen> createState() => _DesktopSongDetailScreenState();
}

class _DesktopSongDetailScreenState extends State<DesktopSongDetailScreen> {
  bool _isLiked = false;
  bool _isDownloaded = false;
  bool _isInQueue = false;
  bool _isLoading = false;
  String? _localArtPath;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  @override
  void initState() {
    super.initState();
    _loadSongStatus();
    _loadLocalArtwork();
  }

  Future<void> _loadSongStatus() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if song is liked
    final likedSongs = prefs.getStringList('liked_songs') ?? [];
    final isLiked = likedSongs.any((songJson) {
      try {
        final songData = jsonDecode(songJson) as Map<String, dynamic>;
        return songData['id'] == widget.song.id;
      } catch (e) {
        return false;
      }
    });

    // Check if song is downloaded
    final downloadedSongs = prefs.getStringList('downloaded_songs') ?? [];
    final isDownloaded = downloadedSongs.any((songJson) {
      try {
        final songData = jsonDecode(songJson) as Map<String, dynamic>;
        return songData['id'] == widget.song.id;
      } catch (e) {
        return false;
      }
    });

    // Check if song is in queue
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    final isInQueue = currentSongProvider.queue.any((song) => song.id == widget.song.id);

    if (mounted) {
      setState(() {
        _isLiked = isLiked;
        _isDownloaded = isDownloaded;
        _isInQueue = isInQueue;
      });
    }
  }

  Future<void> _loadLocalArtwork() async {
    if (widget.song.albumArtUrl.startsWith('http')) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = widget.song.albumArtUrl;
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

  Future<void> _toggleLike() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final likedSongs = prefs.getStringList('liked_songs') ?? [];
      
      if (_isLiked) {
        // Remove from liked songs
        likedSongs.removeWhere((songJson) {
          try {
            final songData = jsonDecode(songJson) as Map<String, dynamic>;
            return songData['id'] == widget.song.id;
          } catch (e) {
            return false;
          }
        });
      } else {
        // Add to liked songs
        likedSongs.add(jsonEncode(widget.song.toJson()));
      }
      
      await prefs.setStringList('liked_songs', likedSongs);
      
      setState(() {
        _isLiked = !_isLiked;
        _isLoading = false;
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'toggle_like');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _addToQueue() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentSongProvider.addToQueue(widget.song);
    
    setState(() {
      _isInQueue = true;
    });
  }

  Future<void> _removeFromQueue() async {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    await currentSongProvider.processSongLibraryRemoval(widget.song.id);
    
    setState(() {
      _isInQueue = false;
    });
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          // Album artwork
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
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
                    imageUrl: widget.song.albumArtUrl,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => _buildPlaceholderArtwork(),
                    errorWidget: (context, url, error) => _buildPlaceholderArtwork(),
                  ),
            ),
          ),
          const SizedBox(width: 24),
          // Song information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.song.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.song.artist,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                                 if (widget.song.album != null)
                   Text(
                     widget.song.album!,
                     style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                       color: Theme.of(context).colorScheme.onSurfaceVariant,
                     ),
                   ),
                const SizedBox(height: 24),
                // Action buttons
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _toggleLike,
                      icon: Icon(_isLiked ? Icons.favorite : Icons.favorite_border),
                      label: Text(_isLiked ? 'Liked' : 'Like'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isLiked 
                          ? const Color(0xFFFF9800) // LTunes orange
                          : Theme.of(context).colorScheme.surface,
                        foregroundColor: _isLiked 
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isInQueue ? _removeFromQueue : _addToQueue,
                      icon: Icon(_isInQueue ? Icons.remove_from_queue : Icons.add_to_queue),
                      label: Text(_isInQueue ? 'Remove from Queue' : 'Add to Queue'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        // TODO: Implement download functionality
                      },
                      icon: Icon(_isDownloaded ? Icons.download_done : Icons.download),
                      label: Text(_isDownloaded ? 'Downloaded' : 'Download'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
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
        Icons.music_note,
        size: 64,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildSongDetails() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Song Details',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildDetailRow('Title', widget.song.title),
                  _buildDetailRow('Artist', widget.song.artist),
                  if (widget.song.album != null)
                    _buildDetailRow('Album', widget.song.album!),
                  if (widget.song.duration != null)
                    _buildDetailRow('Duration', _formatDuration(widget.song.duration!)),
                  if (widget.song.releaseDate != null && widget.song.releaseDate!.isNotEmpty)
                    _buildDetailRow('Release Date', widget.song.releaseDate!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
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
            _buildSongDetails(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
} 