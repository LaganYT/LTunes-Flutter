import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import '../models/song.dart';
import '../models/album.dart';
import 'song_detail_screen.dart';
import 'album_screen.dart';
import '../widgets/playbar.dart';

class ArtistScreen extends StatefulWidget {
  final String artistId;
  final String? artistName; // Optional artist name for display while loading
  
  const ArtistScreen({super.key, required this.artistId, this.artistName});

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadArtistData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
      
      // Use artist name for search instead of ID
      final searchQuery = widget.artistName ?? widget.artistId;
      
      // Load artist info and tracks
      final artistData = await api.getArtistById(searchQuery);
      
      // Extract the actual artist ID from the response for albums
      final artistInfo = artistData['info'] as Map<String, dynamic>;
      final actualArtistId = artistInfo['ART_ID']?.toString() ?? widget.artistId;
      
      // Load artist albums using the actual ID
      List<Album>? albums;
      try {
        albums = await api.getArtistAlbums(actualArtistId);
      } catch (e) {
        // Albums loading failed, continue without them
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
          // Artist Image
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
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
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: Icon(
                          Icons.person,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: Icon(
                          Icons.person,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Container(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      child: Icon(
                        Icons.person,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          // Artist Name
          Text(
            name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          // Stats Row
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
        return Card(
          margin: const EdgeInsets.only(bottom: 8.0),
          child: ListTile(
            leading: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.0),
                color: Theme.of(context).colorScheme.surfaceVariant,
              ),
              child: track.albumArtUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8.0),
                      child: CachedNetworkImage(
                        imageUrl: track.albumArtUrl,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) => Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Icon(
                      Icons.music_note,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
            ),
            title: Text(
              track.title,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(track.album ?? 'Unknown Album'),
            trailing: track.duration != null
                ? Text(
                    '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SongDetailScreen(song: track),
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
            // Show loading dialog
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
            try {
              final fullAlbum = await api.fetchAlbumDetailsById(album.id);
              if (mounted) {
                Navigator.pop(context); // Remove loading dialog
                if (fullAlbum != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AlbumScreen(album: fullAlbum),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Could not load album details.')),
                  );
                }
              }
            } catch (e) {
              if (mounted) {
                Navigator.pop(context); // Remove loading dialog
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error: $e')),
                );
              }
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Album Cover
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
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
                              color: Theme.of(context).colorScheme.surfaceVariant,
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: Theme.of(context).colorScheme.surfaceVariant,
                              child: Icon(
                                Icons.album,
                                size: 48,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : Container(
                            color: Theme.of(context).colorScheme.surfaceVariant,
                            child: Icon(
                              Icons.album,
                              size: 48,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              
              // Album Title
              Text(
                album.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              
              // Release Year
              Text(
                album.releaseDate.isNotEmpty && album.releaseDate.length >= 4
                    ? album.releaseDate.substring(0, 4)
                    : 'Unknown Year',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        child: Playbar(),
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