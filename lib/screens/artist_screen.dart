import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart';
import 'song_detail_screen.dart';
import 'album_screen.dart';
import '../widgets/playbar.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_slidable/flutter_slidable.dart';

class ArtistScreen extends StatefulWidget {
  final String artistId;
  final String? artistName;
  final Map<String, dynamic>? preloadedArtistInfo;
  final List<Song>? preloadedArtistTracks;
  final List<Album>? preloadedArtistAlbums;
  
  const ArtistScreen({
    super.key,
    required this.artistId,
    this.artistName,
    this.preloadedArtistInfo,
    this.preloadedArtistTracks,
    this.preloadedArtistAlbums,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _artistInfo;
  List<Song>? _tracks;
  List<Album>? _albums;
  bool _loading = true;
  bool _error = false;
  String? _errorMessage;
  late TabController _tabController;
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  
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

  Future<void> _toggleLike(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('liked_songs') ?? [];
    final isLiked = _likedSongIds.contains(song.id);

    if (isLiked) {
      raw.removeWhere((s) {
        try {
          return (jsonDecode(s) as Map<String, dynamic>)['id'] == song.id;
        } catch (_) {
          return false;
        }
      });
      _likedSongIds.remove(song.id);
    } else {
      raw.add(jsonEncode(song.toJson()));
      _likedSongIds.add(song.id);
      final bool autoDL = prefs.getBool('autoDownloadLikedSongs') ?? false;
      if (autoDL) {
        Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);
      }
    }

    await prefs.setStringList('liked_songs', raw);
    setState(() {});
  }

  Future<void> _loadArtistData() async {
    try {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = false;
        });
      }

      final api = ApiService();
      
      final searchQuery = widget.artistName ?? widget.artistId;
      final artistData = await api.getArtistById(searchQuery);
      
      final artistInfo = artistData['info'] as Map<String, dynamic>;
      final actualArtistId = artistInfo['ART_ID']?.toString() ?? widget.artistId;
      
      List<Album>? albums;
      try {
        albums = await api.getArtistAlbums(actualArtistId);
      } catch (e) {
        albums = [];
      }

      if (mounted) {
        setState(() {
          _artistInfo = artistData['info'];
          _tracks = (artistData['tracks'] as List).map((raw) {
            final info = artistData['info'] as Map<String, dynamic>;
            return Song.fromAlbumTrackJson(
              raw as Map<String, dynamic>,
              raw['ALB_TITLE']?.toString() ?? '',
              raw['ALB_PICTURE']?.toString() ?? '',
              '',
              info['ART_NAME']?.toString() ?? '',
            );
          }).toList();
          _albums = albums;
          _loading = false;
        });
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'loadArtistData');
      if (mounted) {
        setState(() {
          _error = true;
          _errorMessage = e.toString();
          _loading = false;
        });
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'loading artist data');
      }
    }
  }

  String _formatNumber(int? number) {
    if (number == null) return '0';
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  Widget _buildHeader() {
    final info = _artistInfo!;
    final name = info['ART_NAME'] as String? ?? info['name'] as String? ?? widget.artistName ?? 'Artist';
    final pictureId = info['ART_PICTURE'] as String? ?? '';
    final fansCount = info['NB_FAN'] as int? ?? 0;
    final albumCount = info['NB_ALBUM'] as int? ?? _albums?.length ?? 0;

    final artistImageUrl = pictureId.isNotEmpty
        ? 'https://e-cdns-images.dzcdn.net/images/artist/$pictureId/500x500-000000-80-0-0.jpg'
        : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipOval(
              child: artistImageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: artistImageUrl,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    )
                  : Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.person,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatItem(
                context,
                'Fans',
                _formatNumber(fansCount),
                Icons.favorite,
              ),
              _buildStatItem(
                context,
                'Albums',
                albumCount.toString(),
                Icons.album,
              ),
              _buildStatItem(
                context,
                'Tracks',
                (_tracks?.length ?? 0).toString(),
                Icons.music_note,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(BuildContext context, String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(
          icon,
          color: Theme.of(context).colorScheme.primary,
          size: 20,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildPopularTracks() {
    if (_tracks == null || _tracks!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Text('No tracks available'),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: _tracks!.length,
      itemBuilder: (context, index) {
        final track = _tracks![index];
        final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
        final bool isRadioPlayingGlobal = currentSongProvider.isCurrentlyPlayingRadio;

        return Card(
          margin: const EdgeInsets.only(bottom: 8.0),
          child: Slidable(
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.32,
              children: [
                SlidableAction(
                  onPressed: (context) {
                    if (!isRadioPlayingGlobal) {
                      currentSongProvider.addToQueue(track);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${track.title} added to queue')),
                      );
                    }
                  },
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  icon: Icons.playlist_add,
                  borderRadius: BorderRadius.circular(12),
                ),
                SlidableAction(
                  onPressed: (context) {
                    if (!isRadioPlayingGlobal) {
                      showDialog(
                        context: context,
                        builder: (BuildContext dialogContext) {
                          return AddToPlaylistDialog(song: track);
                        },
                      );
                    }
                  },
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                  icon: Icons.library_add,
                  borderRadius: BorderRadius.circular(12),
                ),
              ],
            ),
            child: ListTile(
              leading: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.0),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: track.albumArtUrl.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: CachedNetworkImage(
                          imageUrl: track.albumArtUrl,
                          fit: BoxFit.cover,
                          errorWidget: (context, url, error) => Icon(
                            Icons.music_note,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.music_note,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
              ),
              title: Text(
                track.title,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: Text(track.album ?? 'Unknown Album'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (track.isDownloaded)
                    const Icon(Icons.download_done, color: Colors.green, size: 20),
                  IconButton(
                    icon: Icon(
                      _likedSongIds.contains(track.id)
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: _likedSongIds.contains(track.id) ? Colors.red : null,
                    ),
                    onPressed: () => _toggleLike(track),
                  ),
                ],
              ),
              onTap: () async {
                await currentSongProvider.playWithContext(_tracks!, track);
              },
              onLongPress: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SongDetailScreen(song: track),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlbums() {
    if (_albums == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(),
        ),
      );
    }
    
    if (_albums!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Text('No albums available'),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16.0,
        mainAxisSpacing: 16.0,
        childAspectRatio: 0.75,
      ),
      itemCount: _albums!.length,
      itemBuilder: (context, index) {
        final album = _albums![index];
        return GestureDetector(
          onTap: () async {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (BuildContext context) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              },
            );

            final api = ApiService();
            final navigator = Navigator.of(context);
            final scaffoldMessenger = ScaffoldMessenger.of(context);
            try {
              final fullAlbum = await api.fetchAlbumDetailsById(album.id);
              if (mounted) {
                navigator.pop();
                if (fullAlbum != null) {
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => AlbumScreen(album: fullAlbum),
                    ),
                  );
                } else {
                  scaffoldMessenger.showSnackBar(
                    const SnackBar(content: Text('Could not load album details.')),
                  );
                }
              }
            } catch (e) {
              if (mounted) {
                navigator.pop();
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text('Error: $e')),
                );
              }
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12.0),
                    child: album.fullAlbumArtUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: album.fullAlbumArtUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.album,
                                size: 48,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          )
                        : Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.album,
                              size: 48,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                album.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                album.releaseDate.isNotEmpty && album.releaseDate.length >= 4
                    ? album.releaseDate.substring(0, 4)
                    : 'Unknown Year',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.artistName ?? 'Artist'),
        ),
        body: const SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_error || _artistInfo == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.artistName ?? 'Artist'),
        ),
        body: SafeArea(
          child: _errorHandler.buildLoadingErrorWidget(
            context,
            _errorMessage ?? 'Failed to load artist data',
            title: 'Failed to Load Artist',
            onRetry: _loadArtistData,
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverAppBar(
                expandedHeight: 260.0,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  background: _buildHeader(),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _SliverTabBarDelegate(
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(text: 'Popular'),
                      Tab(text: 'Albums'),
                    ],
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildPopularTracks(),
              _buildAlbums(),
            ],
          ),
        ),
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

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _SliverTabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar;
  }
}