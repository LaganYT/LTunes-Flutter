import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/album.dart';
import 'song_detail_screen.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import '../services/api_service.dart';
import '../services/unified_search_service.dart';
import '../services/error_handler_service.dart';
import '../services/album_manager_service.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/playlist.dart';
import '../services/loading_service.dart';

class DesktopSearchScreen extends StatefulWidget {
  const DesktopSearchScreen({super.key});

  @override
  State<DesktopSearchScreen> createState() => _DesktopSearchScreenState();
}

class _DesktopSearchScreenState extends State<DesktopSearchScreen> with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ApiService _apiService = ApiService();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final LoadingService _loadingService = LoadingService();
  
  List<Song> _songs = [];
  List<Album> _albums = [];
  List<dynamic> _artists = [];
  List<dynamic> _stations = [];
  List<SearchResult> _unifiedResults = [];
  
  bool _isLoading = false;
  bool _hasSearched = false;
  String _currentQuery = '';
  
  late TabController _tabController;
  Timer? _debounceTimer;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadRecentSearches();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tabController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRecentSearches() async {
    // Load recent searches from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    // Implementation for recent searches
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (query.isNotEmpty) {
        _performSearch(query);
      } else {
        setState(() {
          _hasSearched = false;
          _songs.clear();
          _albums.clear();
          _artists.clear();
          _stations.clear();
          _unifiedResults.clear();
        });
      }
    });
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _currentQuery = query;
    });

    try {
      // Perform unified search
      final unifiedService = UnifiedSearchService();
      final results = await unifiedService.search(query);
      
      setState(() {
        _unifiedResults = results;
        _hasSearched = true;
        _isLoading = false;
      });
    } catch (e) {
      _errorHandler.logError(e, context: 'desktop_search');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Widget _buildSearchHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Search',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search for songs, albums, artists...',
                prefixIcon: Icon(
                  Icons.search,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsContent() {
    if (!_hasSearched) {
      return _buildEmptyState();
    }

    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFFF9800), // LTunes orange
        ),
      );
    }

    if (_unifiedResults.isEmpty) {
      return _buildNoResults();
    }

    return Column(
      children: [
        // Tab bar for different result types
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
              Tab(text: 'All'),
              Tab(text: 'Songs'),
              Tab(text: 'Albums'),
              Tab(text: 'Artists'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Results content
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildAllResults(),
              _buildSongsResults(),
              _buildAlbumsResults(),
              _buildArtistsResults(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Search for your favorite music',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Find songs, albums, artists, and more',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'No results found',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try searching with different keywords',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllResults() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _unifiedResults.length,
      itemBuilder: (context, index) {
        final result = _unifiedResults[index];
        switch (result.type) {
          case SearchResultType.song:
            return _buildSongCard(result.item as Song);
          case SearchResultType.album:
            return _buildAlbumCard(result.item as Album);
          case SearchResultType.playlist:
            return _buildPlaylistCard(result.item as Playlist);
          case SearchResultType.radioStation:
            return _buildStationCard(result.item as RadioStation);
        }
      },
    );
  }

  Widget _buildSongsResults() {
    final songs = _unifiedResults
        .where((result) => result.type == SearchResultType.song)
        .map((result) => result.item as Song)
        .toList();

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        return _buildSongCard(songs[index]);
      },
    );
  }

  Widget _buildAlbumsResults() {
    final albums = _unifiedResults
        .where((result) => result.type == SearchResultType.album)
        .map((result) => result.item as Album)
        .toList();

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        return _buildAlbumCard(albums[index]);
      },
    );
  }

  Widget _buildArtistsResults() {
    final artists = _unifiedResults
        .where((result) => result.type == SearchResultType.playlist)
        .map((result) => result.item)
        .toList();

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        return _buildArtistCard(artists[index]);
      },
    );
  }

  Widget _buildSongCard(Song song) {
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
              builder: (context) => SongDetailScreen(song: song),
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
                  imageUrl: song.albumArtUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  placeholder: (context, url) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.music_note,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.music_note,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                      song.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song.artist,
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
  }

  Widget _buildAlbumCard(Album album) {
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
              builder: (context) => AlbumScreen(album: album),
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
                  placeholder: (context, url) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.album,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.album,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
  }

  Widget _buildArtistCard(dynamic artist) {
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
              builder: (context) => ArtistScreen(
                artistId: artist['ART_ID'] ?? '',
                artistName: artist['ARTIST_NAME'] ?? '',
                preloadedArtistInfo: artist,
              ),
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
                  imageUrl: artist['ARTIST_PICTURE'] ?? '',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  placeholder: (context, url) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.person,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.person,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                      artist['ARTIST_NAME'] ?? 'Unknown Artist',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Artist',
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
  }

  Widget _buildPlaylistCard(Playlist playlist) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () {
          // Handle playlist selection
        },
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Container(
                  color: const Color(0xFFFF9800).withOpacity(0.1), // LTunes orange
                  child: Icon(
                    Icons.playlist_play,
                    size: 48,
                    color: const Color(0xFFFF9800), // LTunes orange
                  ),
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
                      playlist.name,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Playlist',
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
  }

  Widget _buildStationCard(RadioStation station) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () {
          // Handle station selection
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
                  imageUrl: station.imageUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  placeholder: (context, url) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.radio,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    child: Icon(
                      Icons.radio,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                      station.name,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Radio Station',
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Column(
        children: [
          _buildSearchHeader(),
          Expanded(
            child: _buildResultsContent(),
          ),
        ],
      ),
    );
  }
} 