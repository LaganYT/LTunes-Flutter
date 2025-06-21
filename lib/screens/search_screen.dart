import 'package:flutter/material.dart';
import '../models/song.dart';
import 'song_detail_screen.dart'; // Ensure AddToPlaylistDialog is accessible
import '../services/api_service.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io'; // Required for File
import 'package:path_provider/path_provider.dart'; // Added import
import 'package:path/path.dart' as p; // Added import
import 'dart:convert'; // Added import
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'package:cached_network_image/cached_network_image.dart';

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
  // ignore: unused_field
  final PlaylistManagerService _playlistManagerService = PlaylistManagerService(); // Instance of PlaylistManagerService
  bool _showRadioTab = true;
  Set<String> _likedSongIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadShowRadioTab();
    _songsFuture = _getSongsFuture(); // Use new method
    _stationsFuture = _fetchRadioStations();
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0);
    _loadLikedSongIds();
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
      // just unlike, remove from list
      raw.removeWhere((s) {
        try {
          return (jsonDecode(s) as Map<String, dynamic>)['id'] == song.id;
        } catch (_) {
          return false;
        }
      });
      _likedSongIds.remove(song.id);
    } else {
      // like and queue if auto-download enabled
      raw.add(jsonEncode(song.toJson()));
      _likedSongIds.add(song.id);
      final bool autoDL = prefs.getBool('autoDownloadLikedSongs') ?? false;
      if (autoDL) {
        Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Queued "${song.title}" for download.')),
        );
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

  // Renamed from _fetchSongs and returns Future
  Future<List<Song>> _getSongsFuture() {
    return _apiService.fetchSongs(_searchQuery);
  }

  Future<List<dynamic>> _fetchRadioStations() async {
    final prefs = await SharedPreferences.getInstance();
    final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
    final country = usRadioOnly ? 'United States' : '';
    return _apiService.fetchStationsByCountry(country, name: _searchQuery);
  }

  void _onSearch(String value) async { // Made async
    final newQuery = value.trim();
    final oldQuery = _searchQuery;

    if (newQuery.isEmpty && oldQuery.isNotEmpty) {
      // Search was cleared, remove cache for oldQuery
      _apiService.clearSongCache(oldQuery);

      final prefs = await SharedPreferences.getInstance();
      final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
      final country = usRadioOnly ? 'United States' : '';
      _apiService.clearRadioStationCache(country, oldQuery);
    }

    setState(() {
      _searchQuery = newQuery;
      _songsFuture = _getSongsFuture(); // Update future
      _stationsFuture = _fetchRadioStations(); // Update future
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _handleRefreshMusic() async {
    _apiService.clearSongCache(_searchQuery); // Clear cache for the current query
    final newSongsFuture = _getSongsFuture();
    setState(() {
      _songsFuture = newSongsFuture;
    });
    await newSongsFuture; // Await completion for RefreshIndicator
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

  // Helper method to resolve local album art path
  // ignore: unused_element
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, fileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
  }

  // Helper method to get song with updated download status from SharedPreferences
  Future<Song> _getSongWithDownloadStatusInternal(Song songFromApi) async {
    final prefs = await SharedPreferences.getInstance();
    final songJson = prefs.getString('song_${songFromApi.id}');
    if (songJson != null) {
      try {
        final storedSongData = jsonDecode(songJson) as Map<String, dynamic>;
        final storedSong = Song.fromJson(storedSongData);
        if (storedSong.isDownloaded && storedSong.localFilePath != null && storedSong.localFilePath!.isNotEmpty) {
          // Ensure the local file actually exists before claiming it's playable locally
          final appDocDir = await getApplicationDocumentsDirectory();
          final fullPath = p.join(appDocDir.path, storedSong.localFilePath!);
          if (await File(fullPath).exists()) {
            return storedSong; // Return the version from storage with download info
          }
        }
      } catch (e) {
        debugPrint('Error reading stored song data for ${songFromApi.id}: $e');
        // Fall through to return songFromApi
      }
    }
    return songFromApi; // Return original API song if not found in storage or not validly downloaded
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Important for AutomaticKeepAliveClientMixin

    if (!_showRadioTab) {
      // only music search when radio tab is disabled
      return Scaffold(
        appBar: AppBar(
          title: const Text('Search'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurface),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _onSearch('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[900]
                      : Colors.grey[200],
                ),
              ),
            ),
          ),
        ),
        body: _buildMusicTab(),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
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
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Music'),
              Tab(text: 'Radio'),
            ],
            onTap: (index) { // Optional: re-fetch if needed when tab becomes visible, though cache handles it
              // if (index == 0 && _songsFuture == null) _fetchSongs(); // Example
              // if (index == 1 && _stationsFuture == null) _stationsFuture = _fetchRadioStations(); // Example
            },
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMusicTab(),
                _buildRadioTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMusicTab() {
    return FutureBuilder<List<Song>>(
      future: _songsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error: ${snapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No songs found.'));
        }

        final songs = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _handleRefreshMusic,
          child: ListView.separated(
            itemCount: songs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final song = songs[index];
              Widget leadingImage;
              // Album art for search results will likely always be network URLs from the API
              // but we include the check for robustness or future changes.
              if (song.albumArtUrl.isNotEmpty) {
                if (song.albumArtUrl.startsWith('http')) {
                  leadingImage = CachedNetworkImage(
                    imageUrl: song.albumArtUrl,
                    width: 40,
                    height: 40,
                    memCacheWidth: 80,
                    memCacheHeight: 80,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const Icon(Icons.album, size: 40),
                    errorWidget: (context, url, error) => const Icon(Icons.error, size: 40),
                  );
                } else {
                  leadingImage = Image.file(
                    File(song.albumArtUrl),
                    width: 40,
                    height: 40,
                    cacheWidth: 80,
                    cacheHeight: 80,
                    fit: BoxFit.cover,
                  );
                }
              } else {
                leadingImage = const Icon(Icons.album, size: 40);
              }

              return Dismissible(
                key: Key(song.id),
                direction: DismissDirection.horizontal, // Allow both directions
                dismissThresholds: const { 
                  DismissDirection.startToEnd: 0.25, 
                  DismissDirection.endToStart: 0.25, // Threshold for adding to playlist
                },
                confirmDismiss: (direction) async {
                  if (direction == DismissDirection.startToEnd) {
                    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                    // Always use canonical downloaded version
                    final songToAdd = await _getSongWithDownloadStatusInternal(song);
                    currentSongProvider.addToQueue(songToAdd);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${song.title} added to queue')),
                    );
                    return false;
                  } else if (direction == DismissDirection.endToStart) {
                    final songToAdd = await _getSongWithDownloadStatusInternal(song);
                    showDialog(
                      context: context,
                      builder: (BuildContext dialogContext) {
                        return AddToPlaylistDialog(song: songToAdd);
                      }
                    );
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
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: leadingImage,
                  ),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                  ),
                  trailing: IconButton(
                    icon: _likedSongIds.contains(song.id)
                        ? Icon(Icons.favorite, color: Theme.of(context).colorScheme.secondary)
                        : const Icon(Icons.favorite_border),
                    color: Theme.of(context).colorScheme.onSurface,
                    iconSize: 20,
                    onPressed: () => _toggleLike(song),
                  ),
                  onLongPress: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SongDetailScreen(song: song),
                      ),
                    );
                  },
                  onTap: () async {
                    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => const Center(child: CircularProgressIndicator()),
                    );
                    try {
                      // Get the song object, potentially updated with download info
                      final songToPlay = await _getSongWithDownloadStatusInternal(song);
                      
                      Navigator.of(context, rootNavigator: true).pop(); // Dismiss loading indicator
                      
                      // CurrentSongProvider.playSong will handle fetching URL (local or remote)
                      currentSongProvider.playSong(songToPlay);

                    } catch (e) {
                      Navigator.of(context, rootNavigator: true).pop(); // Dismiss loading indicator
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error preparing song: $e')),
                      );
                    }
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildRadioTab() {
    return FutureBuilder<List<dynamic>>(
      future: _stationsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error: ${snapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No radio stations found.'));
        }

        final stations = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _handleRefreshRadio,
          child: ListView.builder(
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final station = stations[index];
              return ListTile(
                leading: station['favicon'] != null && station['favicon'].isNotEmpty
                    ? Image.network(
                        station['favicon'],
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.radio, size: 50),
                      )
                    : const Icon(Icons.radio, size: 50),
                title: Text(
                  station['name'] ?? 'Unknown Station',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  station['country'] ?? 'Unknown Country',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  final url = station['url_resolved'];
                  if (url != null && url.isNotEmpty) {
                    Provider.of<CurrentSongProvider>(context, listen: false).playStream(
                      url,
                      stationName: station['name'] ?? 'Unknown Station',
                      stationFavicon: station['favicon'],
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Stream URL not available, try another station')),
                    );
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}