import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart';
import 'desktop_song_detail_screen.dart';
import 'desktop_album_screen.dart';
import '../providers/current_song_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_slidable/flutter_slidable.dart';

class DesktopArtistScreen extends StatefulWidget {
  final String artistId;
  final String? artistName;
  final Map<String, dynamic>? preloadedArtistInfo;
  final List<Song>? preloadedArtistTracks;
  final List<Album>? preloadedArtistAlbums;
  
  const DesktopArtistScreen({
    super.key,
    required this.artistId,
    this.artistName,
    this.preloadedArtistInfo,
    this.preloadedArtistTracks,
    this.preloadedArtistAlbums,
  });

  @override
  State<DesktopArtistScreen> createState() => _DesktopArtistScreenState();
}

class _DesktopArtistScreenState extends State<DesktopArtistScreen> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _artistInfo;
  List<Song>? _tracks;
  List<Album>? _albums;
  bool _loading = true;
  bool _error = false;
  String? _errorMessage;
  late TabController _tabController;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final ApiService _apiService = ApiService();
  
  // Like functionality
  Set<String> _likedSongIds = {};
  
  // Download functionality
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadLikedSongIds();
    
    if (widget.preloadedArtistInfo != null && widget.preloadedArtistTracks != null && widget.preloadedArtistAlbums != null) {
      setState(() {
        _artistInfo = widget.preloadedArtistInfo;
        _tracks = widget.preloadedArtistTracks;
        _albums = widget.preloadedArtistAlbums;
        _loading = false;
      });
      Future.microtask(_loadArtistData);
    } else {
      _loadArtistData();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  Future<void> _loadArtistData() async {
    if (_artistInfo != null) return;

    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final artistData = await _apiService.getArtistById(widget.artistId);
      final albumsData = await _apiService.getArtistAlbums(widget.artistId);

      if (mounted) {
        setState(() {
          _artistInfo = artistData;
          _albums = albumsData;
          _loading = false;
        });
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'load_artist_data');
      if (mounted) {
        setState(() {
          _error = true;
          _errorMessage = e.toString();
          _loading = false;
        });
      }
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
    if (_loading) {
      return Container(
        padding: const EdgeInsets.all(24),
        child: const Center(
          child: CircularProgressIndicator(
            color: Color(0xFFFF9800), // LTunes orange
          ),
        ),
      );
    }

    if (_error || _artistInfo == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Error loading artist',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          // Artist image
          Container(
            width: 300,
            height: 300,
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
              child: CachedNetworkImage(
                imageUrl: _artistInfo!['ARTIST_PICTURE'] ?? '',
                fit: BoxFit.cover,
                placeholder: (context, url) => _buildPlaceholderImage(),
                errorWidget: (context, url, error) => _buildPlaceholderImage(),
              ),
            ),
          ),
          const SizedBox(width: 32),
          // Artist information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _artistInfo!['ARTIST_NAME'] ?? 'Unknown Artist',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                if (_tracks != null) ...[
                  Text(
                    '${_tracks!.length} tracks',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_albums != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_albums!.length} albums',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                // Action buttons
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _tracks != null && _tracks!.isNotEmpty ? _playArtist : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9800), // LTunes orange
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _tracks != null && _tracks!.isNotEmpty ? _shuffleArtist : null,
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
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.person,
        size: 64,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  void _playArtist() {
    if (_tracks != null && _tracks!.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      currentSongProvider.playSong(_tracks!.first);
    }
  }

  void _shuffleArtist() {
    if (_tracks != null && _tracks!.isNotEmpty) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final shuffledTracks = List<Song>.from(_tracks!)..shuffle();
      currentSongProvider.playSong(shuffledTracks.first);
    }
  }

  Widget _buildTabs() {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
            ),
          ),
          child: TabBar(
            controller: _tabController,
            labelColor: const Color(0xFFFF9800), // LTunes orange
            unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
            indicatorColor: const Color(0xFFFF9800), // LTunes orange
            tabs: const [
              Tab(text: 'Popular Tracks'),
              Tab(text: 'Albums'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildTracksTab(),
              _buildAlbumsTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTracksTab() {
    if (_tracks == null || _tracks!.isEmpty) {
      return Center(
        child: Text(
          'No tracks available',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _tracks!.length,
      itemBuilder: (context, index) {
        final track = _tracks![index];
        final isLiked = _likedSongIds.contains(track.id);
        
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
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
          ),
        );
      },
    );
  }

  Widget _buildAlbumsTab() {
    if (_albums == null || _albums!.isEmpty) {
      return Center(
        child: Text(
          'No albums available',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _albums!.length,
      itemBuilder: (context, index) {
        final album = _albums![index];
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DesktopAlbumScreen(album: album),
                ),
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    child: CachedNetworkImage(
                      imageUrl: album.effectiveAlbumArtUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      placeholder: (context, url) => _buildAlbumPlaceholder(),
                      errorWidget: (context, url, error) => _buildAlbumPlaceholder(),
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          album.title,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          album.artistName,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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

  Widget _buildAlbumPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.album,
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
            child: _buildTabs(),
          ),
        ],
      ),
    );
  }
} 