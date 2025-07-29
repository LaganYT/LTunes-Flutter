import 'package:flutter/material.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
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

class DesktopLikedSongsScreen extends StatefulWidget {
  const DesktopLikedSongsScreen({super.key});

  @override
  State<DesktopLikedSongsScreen> createState() => _DesktopLikedSongsScreenState();
}

class _DesktopLikedSongsScreenState extends State<DesktopLikedSongsScreen> {
  List<Song> _likedSongs = [];
  bool _isLoading = true;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final Map<String, String> _localArtPathCache = {};

  @override
  void initState() {
    super.initState();
    _loadLikedSongs();
  }

  Future<void> _loadLikedSongs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('liked_songs') ?? [];
      
      final songs = raw.map((songJson) {
        try {
          final songData = jsonDecode(songJson) as Map<String, dynamic>;
          return Song.fromJson(songData);
        } catch (e) {
          debugPrint('Error parsing song: $e');
          return null;
        }
      }).whereType<Song>().toList();

      // Load local artwork paths
      for (final song in songs) {
        if (song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
          final path = await _resolveLocalArtPath(song.albumArtUrl);
          _localArtPathCache[song.id] = path;
        }
      }

      setState(() {
        _likedSongs = songs;
        _isLoading = false;
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'load_liked_songs');
      setState(() {
        _isLoading = false;
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

  Future<void> _removeFromLiked(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('liked_songs') ?? [];
      
      raw.removeWhere((songJson) {
        try {
          final songData = jsonDecode(songJson) as Map<String, dynamic>;
          return songData['id'] == song.id;
        } catch (e) {
          return false;
        }
      });
      
      await prefs.setStringList('liked_songs', raw);
      
      setState(() {
        _likedSongs.removeWhere((s) => s.id == song.id);
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'remove_from_liked');
    }
  }

  Future<void> _playAll() async {
    if (_likedSongs.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      currentSongProvider.playSong(_likedSongs.first);
    }
  }

  Future<void> _shuffleAll() async {
    if (_likedSongs.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final shuffledSongs = List<Song>.from(_likedSongs)..shuffle();
      currentSongProvider.playSong(shuffledSongs.first);
    }
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.favorite,
                color: const Color(0xFFFF9800), // LTunes orange
                size: 32,
              ),
              const SizedBox(width: 16),
              Text(
                'Liked Songs',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_likedSongs.length} songs',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _likedSongs.isNotEmpty ? _playAll : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play All'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800), // LTunes orange
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _likedSongs.isNotEmpty ? _shuffleAll : null,
                icon: const Icon(Icons.shuffle),
                label: const Text('Shuffle'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ],
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

    if (_likedSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No liked songs yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Like songs to see them here',
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
      itemCount: _likedSongs.length,
      itemBuilder: (context, index) {
        final song = _likedSongs[index];
        final localArtPath = _localArtPathCache[song.id];
        
        return Slidable(
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            children: [
              SlidableAction(
                onPressed: (_) => _removeFromLiked(song),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                icon: Icons.favorite_border,
                label: 'Unlike',
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
                        errorBuilder: (context, error, stackTrace) => _buildPlaceholderArtwork(),
                      )
                    : CachedNetworkImage(
                        imageUrl: song.albumArtUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => _buildPlaceholderArtwork(),
                        errorWidget: (context, url, error) => _buildPlaceholderArtwork(),
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
                  Icon(
                    Icons.favorite,
                    color: const Color(0xFFFF9800), // LTunes orange
                    size: 20,
                  ),
                  const SizedBox(width: 8),
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

  Widget _buildPlaceholderArtwork() {
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