import 'package:flutter/material.dart';
import '../models/song.dart';
import 'song_detail_screen.dart'; // Ensure AddToPlaylistDialog is accessible
import '../services/api_service.dart';
import '../services/error_handler_service.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io'; // Required for File
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import
import 'dart:convert'; // Added import
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late Future<List<Song>> _songsFuture;
  late Future<List<dynamic>> _stationsFuture;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late TabController _tabController;
  final ApiService _apiService = ApiService();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  bool _showRadioTab = true;
  Set<String> _likedSongIds = {};
  
  // Performance: Search debouncing
  Timer? _searchDebounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 500);
  
  // Performance: Lazy loading
  static const int _pageSize = 20;
  int _currentPage = 0;
  bool _hasMoreSongs = true;
  final List<Song> _allSongs = [];
  final ScrollController _scrollController = ScrollController();
  
  // Performance: Cache for song download status
  final Map<String, Song> _songDownloadStatusCache = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadShowRadioTab();
    _songsFuture = _getSongsFuture();
    _stationsFuture = _fetchRadioStations();
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0);
    _loadLikedSongIds();
    
    // Performance: Add scroll listener for lazy loading
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Performance: Lazy loading scroll listener
  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMoreSongs();
    }
  }

  // Performance: Load more songs for lazy loading
  void _loadMoreSongs() {
    if (!_hasMoreSongs || _searchQuery.isNotEmpty) return; // Only for top charts
    
    setState(() {
      _currentPage++;
      _songsFuture = _getSongsFuture();
    });
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

  Future<void> _loadShowRadioTab() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showRadioTab = prefs.getBool('showRadioTab') ?? true;
    });
  }

  // Performance: Optimized song fetching with pagination
  Future<List<Song>> _getSongsFuture() async {
    try {
      final songs = await _apiService.fetchSongs(_searchQuery);
      
      if (_searchQuery.isEmpty) {
        // For top charts, implement pagination
        final startIndex = _currentPage * _pageSize;
        final endIndex = startIndex + _pageSize;
        
        if (startIndex < songs.length) {
          final pageSongs = songs.sublist(startIndex, endIndex > songs.length ? songs.length : endIndex);
          _allSongs.addAll(pageSongs);
          _hasMoreSongs = endIndex < songs.length;
          return _allSongs;
        } else {
          _hasMoreSongs = false;
          return _allSongs;
        }
      } else {
        // For search results, return all results
        return songs;
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'fetchSongs');
      if (mounted) {
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'fetching songs');
      }
      return [];
    }
  }

  Future<List<dynamic>> _fetchRadioStations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
      final country = usRadioOnly ? 'United States' : '';
      return await _apiService.fetchStationsByCountry(country, name: _searchQuery);
    } catch (e) {
      _errorHandler.logError(e, context: 'fetchRadioStations');
      if (mounted) {
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'fetching radio stations');
      }
      return [];
    }
  }

  // Performance: Debounced search
  void _onSearch(String value) async {
    _searchDebounceTimer?.cancel();
    
    _searchDebounceTimer = Timer(_debounceDelay, () async {
      final newQuery = value.trim();
      final oldQuery = _searchQuery;

      if (newQuery.isEmpty && oldQuery.isNotEmpty) {
        _apiService.clearSongCache(oldQuery);

        final prefs = await SharedPreferences.getInstance();
        final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
        final country = usRadioOnly ? 'United States' : '';
        _apiService.clearRadioStationCache(country, oldQuery);
      }

      if (mounted) {
        setState(() {
          _searchQuery = newQuery;
          if (newQuery.isEmpty) {
            // Reset pagination for top charts
            _currentPage = 0;
            _allSongs.clear();
            _hasMoreSongs = true;
          }
          _songsFuture = _getSongsFuture();
          _stationsFuture = _fetchRadioStations();
        });
      }
    });
  }

  Future<void> _handleRefreshMusic() async {
    _apiService.clearSongCache(_searchQuery);
    if (_searchQuery.isEmpty) {
      _currentPage = 0;
      _allSongs.clear();
      _hasMoreSongs = true;
    }
    final newSongsFuture = _getSongsFuture();
    setState(() {
      _songsFuture = newSongsFuture;
    });
    await newSongsFuture;
  }

  Future<void> _handleRefreshRadio() async {
    final prefs = await SharedPreferences.getInstance();
    final usRadioOnly = prefs.getBool('usRadioOnly') ?? false;
    final country = usRadioOnly ? 'United States' : '';

    _apiService.clearRadioStationCache(country, _searchQuery);
    
    final newStationsFuture = _fetchRadioStations();
    setState(() {
      _stationsFuture = newStationsFuture;
    });
    await newStationsFuture;
  }

  // Performance: Optimized song download status resolution
  Future<Song> _getSongWithDownloadStatusInternal(Song songFromApi) async {
    // Check cache first
    if (_songDownloadStatusCache.containsKey(songFromApi.id)) {
      return _songDownloadStatusCache[songFromApi.id]!;
    }
    
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('song_${songFromApi.id}');
    if (songJson != null) {
      try {
        final storedSongData = jsonDecode(songJson) as Map<String, dynamic>;
        final storedSong = Song.fromJson(storedSongData);
        if (storedSong.isDownloaded && storedSong.localFilePath != null && storedSong.localFilePath!.isNotEmpty) {
          final appDocDir = await getApplicationDocumentsDirectory();
          final fullPath = p.join(appDocDir.path, storedSong.localFilePath!);
          if (await File(fullPath).exists()) {
            // Cache the result
            _songDownloadStatusCache[songFromApi.id] = storedSong;
            return storedSong;
          }
        }
      } catch (e) {
        debugPrint('Error reading stored song data for ${songFromApi.id}: $e');
      }
    }
    
    // Cache the original song
    _songDownloadStatusCache[songFromApi.id] = songFromApi;
    return songFromApi;
  }

  // Performance: Optimized song list item widget
  Widget _buildSongListItem(Song song) {
    return FutureBuilder<Song>(
      future: _getSongWithDownloadStatusInternal(song),
      builder: (context, snapshot) {
        final songWithStatus = snapshot.data ?? song;
        final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
        final bool isRadioPlayingGlobal = currentSongProvider.isCurrentlyPlayingRadio;

        return Dismissible(
          key: Key(songWithStatus.id),
          direction: DismissDirection.horizontal,
          dismissThresholds: const {
            DismissDirection.startToEnd: 0.25,
            DismissDirection.endToStart: 0.25,
          },
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              if (!isRadioPlayingGlobal) {
                currentSongProvider.addToQueue(songWithStatus);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${songWithStatus.title} added to queue')),
                );
              }
              return false;
            } else if (direction == DismissDirection.endToStart) {
              if (!isRadioPlayingGlobal) {
                showDialog(
                  context: context,
                  builder: (BuildContext dialogContext) {
                    return AddToPlaylistDialog(song: songWithStatus);
                  },
                );
              }
              return false;
            }
            return false;
          },
          background: Container(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Icon(Icons.playlist_add, color: Theme.of(context).colorScheme.onPrimary),
                const SizedBox(width: 8),
                Text('Add to Queue', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
              ],
            ),
          ),
          secondaryBackground: Container(
            color: Theme.of(context).colorScheme.secondary.withOpacity(0.8),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Add to Playlist', style: TextStyle(color: Theme.of(context).colorScheme.onSecondary)),
                const SizedBox(width: 8),
                Icon(Icons.library_add, color: Theme.of(context).colorScheme.onSecondary),
              ],
            ),
          ),
          child: ListTile(
            leading: SizedBox(
              width: 56,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: songWithStatus.albumArtUrl.isNotEmpty
                    ? songWithStatus.albumArtUrl.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: songWithStatus.albumArtUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 112,
                            memCacheHeight: 112,
                            placeholder: (context, url) => Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.music_note),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.music_note),
                            ),
                          )
                        : FutureBuilder<String>(
                            future: _resolveLocalArtPath(songWithStatus.albumArtUrl),
                            builder: (context, artSnapshot) {
                              if (artSnapshot.connectionState == ConnectionState.done &&
                                  artSnapshot.hasData &&
                                  artSnapshot.data!.isNotEmpty) {
                                return Image.file(
                                  File(artSnapshot.data!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Container(
                                        color: Colors.grey[300],
                                        child: const Icon(Icons.music_note),
                                      ),
                                );
                              }
                              return Container(
                                color: Colors.grey[300],
                                child: const Icon(Icons.music_note),
                              );
                            },
                          )
                    : Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.music_note),
                      ),
              ),
            ),
            title: Text(
              songWithStatus.title,
              style: const TextStyle(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              songWithStatus.artist,
              style: TextStyle(color: Colors.grey[600]),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (songWithStatus.isDownloaded)
                  const Icon(Icons.download_done, color: Colors.green, size: 20),
                IconButton(
                  icon: Icon(
                    _likedSongIds.contains(songWithStatus.id)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: _likedSongIds.contains(songWithStatus.id) ? Colors.red : null,
                  ),
                  onPressed: () => _toggleLike(songWithStatus),
                ),
              ],
            ),
            onTap: () async {
              // Play the song immediately
              await currentSongProvider.playWithContext([songWithStatus], songWithStatus);
            },
            onLongPress: () {
              // Show more info
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SongDetailScreen(song: songWithStatus),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // Performance: Optimized local art path resolution
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Search...',
                prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurface),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        color: Theme.of(context).colorScheme.onSurface,
                        onPressed: () {
                          _searchController.clear();
                          _onSearch('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.grey[200],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_showRadioTab)
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Music'),
                Tab(text: 'Radio'),
              ],
            ),
          Expanded(
            child: _showRadioTab
                ? TabBarView(
                    controller: _tabController,
                    children: [
                      // Music Tab
                      RefreshIndicator(
                        onRefresh: _handleRefreshMusic,
                        child: FutureBuilder<List<Song>>(
                          future: _songsFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            if (snapshot.hasError) {
                              return _errorHandler.buildLoadingErrorWidget(
                                context,
                                snapshot.error!,
                                title: 'Failed to Load Songs',
                                onRetry: () {
                                  setState(() {
                                    _songsFuture = _getSongsFuture();
                                  });
                                },
                              );
                            }
                            final songs = snapshot.data ?? [];
                            if (songs.isEmpty) {
                              return _errorHandler.buildEmptyStateWidget(
                                context,
                                title: _searchQuery.isEmpty ? 'No Songs Available' : 'No Songs Found',
                                message: _searchQuery.isEmpty 
                                    ? 'Unable to load top charts. Please check your connection and try again.'
                                    : 'No songs found for "${_searchQuery}". Try a different search term.',
                                icon: _searchQuery.isEmpty ? Icons.cloud_off : Icons.search_off,
                                onAction: _searchQuery.isEmpty ? () {
                                  setState(() {
                                    _songsFuture = _getSongsFuture();
                                  });
                                } : null,
                                actionText: _searchQuery.isEmpty ? 'Retry' : null,
                              );
                            }
                            return ListView.builder(
                              controller: _scrollController,
                              itemCount: songs.length + (_hasMoreSongs && _searchQuery.isEmpty ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == songs.length) {
                                  return const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }
                                return _buildSongListItem(songs[index]);
                              },
                            );
                          },
                        ),
                      ),
                      // Radio Tab
                      RefreshIndicator(
                        onRefresh: _handleRefreshRadio,
                        child: FutureBuilder<List<dynamic>>(
                          future: _stationsFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            if (snapshot.hasError) {
                              return _errorHandler.buildLoadingErrorWidget(
                                context,
                                snapshot.error!,
                                title: 'Failed to Load Radio Stations',
                                onRetry: () {
                                  setState(() {
                                    _stationsFuture = _fetchRadioStations();
                                  });
                                },
                              );
                            }
                            final stations = snapshot.data ?? [];
                            if (stations.isEmpty) {
                              return _errorHandler.buildEmptyStateWidget(
                                context,
                                title: _searchQuery.isEmpty ? 'No Radio Stations Available' : 'No Radio Stations Found',
                                message: _searchQuery.isEmpty 
                                    ? 'Unable to load radio stations. Please check your connection and try again.'
                                    : 'No radio stations found for "${_searchQuery}". Try a different search term.',
                                icon: _searchQuery.isEmpty ? Icons.radio : Icons.search_off,
                                onAction: _searchQuery.isEmpty ? () {
                                  setState(() {
                                    _stationsFuture = _fetchRadioStations();
                                  });
                                } : null,
                                actionText: _searchQuery.isEmpty ? 'Retry' : null,
                              );
                            }
                            return ListView.builder(
                              itemCount: stations.length,
                              itemBuilder: (context, index) {
                                final station = stations[index];
                                return ListTile(
                                  leading: station['favicon'] != null
                                      ? CachedNetworkImage(
                                          imageUrl: station['favicon'],
                                          width: 56,
                                          height: 56,
                                          fit: BoxFit.cover,
                                          memCacheWidth: 112,
                                          memCacheHeight: 112,
                                          placeholder: (context, url) => Container(
                                            width: 56,
                                            height: 56,
                                            color: Colors.grey[300],
                                            child: const Icon(Icons.radio),
                                          ),
                                          errorWidget: (context, url, error) => Container(
                                            width: 56,
                                            height: 56,
                                            color: Colors.grey[300],
                                            child: const Icon(Icons.radio),
                                          ),
                                        )
                                      : Container(
                                          width: 56,
                                          height: 56,
                                          color: Colors.grey[300],
                                          child: const Icon(Icons.radio),
                                        ),
                                  title: Text(station['name'] ?? 'Unknown Station'),
                                  subtitle: Text(station['country'] ?? 'Unknown Country'),
                                                                     onTap: () {
                                     final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                                     currentSongProvider.playStream(
                                       station['url'] ?? '',
                                       stationName: station['name'] ?? 'Unknown Station',
                                       stationFavicon: station['favicon'],
                                     );
                                   },
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  )
                : RefreshIndicator(
                    onRefresh: _handleRefreshMusic,
                    child: FutureBuilder<List<Song>>(
                      future: _songsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        if (snapshot.hasError) {
                          return _errorHandler.buildLoadingErrorWidget(
                            context,
                            snapshot.error!,
                            title: 'Failed to Load Songs',
                            onRetry: () {
                              setState(() {
                                _songsFuture = _getSongsFuture();
                              });
                            },
                          );
                        }
                        final songs = snapshot.data ?? [];
                        if (songs.isEmpty) {
                          return const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.music_note, size: 64, color: Colors.grey),
                                SizedBox(height: 16),
                                Text(
                                  'No songs found',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: _scrollController,
                          itemCount: songs.length + (_hasMoreSongs && _searchQuery.isEmpty ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == songs.length) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            return _buildSongListItem(songs[index]);
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}