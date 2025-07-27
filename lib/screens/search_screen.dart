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

// Enum for content types
enum ContentType {
  song,
  album,
  artist,
  station,
}

// Unified search result item
class SearchResultItem {
  final ContentType type;
  final dynamic data;
  final double relevanceScore;

  SearchResultItem({
    required this.type,
    required this.data,
    required this.relevanceScore,
  });
}

// Cache for station icons to prevent flashing
final Map<String, String> _stationIconCache = {};
final Map<String, Future<String>> _stationIconFutures = {};

Future<String> cacheStationIcon(String imageUrl, String stationId) async {
  if (imageUrl.isEmpty || !imageUrl.startsWith('http')) return '';
  
  // Check if we already have a cached result
  if (_stationIconCache.containsKey(stationId)) {
    return _stationIconCache[stationId]!;
  }
  
  // Check if we already have a future for this station
  if (_stationIconFutures.containsKey(stationId)) {
    final result = await _stationIconFutures[stationId]!;
    return result;
  }
  
  // Create a new future for this station
  final future = _cacheStationIconInternal(imageUrl, stationId);
  _stationIconFutures[stationId] = future;
  
  try {
    final result = await future;
    _stationIconCache[stationId] = result;
    _stationIconFutures.remove(stationId);
    return result;
  } catch (e) {
    _stationIconFutures.remove(stationId);
    rethrow;
  }
}

Future<String> _cacheStationIconInternal(String imageUrl, String stationId) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'stationicon_$stationId.jpg';
    final filePath = p.join(directory.path, fileName);
    final file = File(filePath);
    if (await file.exists()) {
      return filePath;
    }
    // Download the image
    final response = await HttpClient().getUrl(Uri.parse(imageUrl));
    final imageResponse = await response.close();
    if (imageResponse.statusCode == 200) {
      final bytes = await consolidateHttpClientResponseBytes(imageResponse);
      await file.writeAsBytes(bytes);
      return filePath;
    }
  } catch (e) {
    debugPrint('Error caching station icon: $e');
  }
  return '';
}

// Widget for displaying radio station icons without flashing
class RadioStationIcon extends StatefulWidget {
  final String imageUrl;
  final String stationId;
  final double size;
  final BorderRadius? borderRadius;

  const RadioStationIcon({
    super.key,
    required this.imageUrl,
    required this.stationId,
    required this.size,
    this.borderRadius,
  });

  @override
  State<RadioStationIcon> createState() => _RadioStationIconState();
}

class _RadioStationIconState extends State<RadioStationIcon> {
  String? _cachedPath;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(RadioStationIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl || oldWidget.stationId != widget.stationId) {
      _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    if (widget.imageUrl.isEmpty) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final cachedPath = await cacheStationIcon(widget.imageUrl, widget.stationId);
      if (mounted) {
        setState(() {
          _cachedPath = cachedPath;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.radio,
          size: widget.size * 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    if (_hasError || _cachedPath == null || _cachedPath!.isEmpty) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.radio,
          size: widget.size * 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        child: Image.file(
          File(_cachedPath!),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.radio,
              size: widget.size * 0.6,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late TabController _tabController;
  final ApiService _apiService = ApiService();
  final UnifiedSearchService _unifiedSearchService = UnifiedSearchService();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final AlbumManagerService _albumManager = AlbumManagerService();
  
  // Search results
  List<SearchResultItem> _musicResults = [];
  List<SearchResultItem> _stationResults = [];
  
  // Loading states
  bool _isLoadingMusic = false;
  bool _isLoadingStations = false;
  
  // Performance: Search debouncing
  Timer? _searchDebounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 500);
  
  // Setting change listener
  Timer? _settingChangeTimer;
  
  // Performance: Cache for song download status
  final Map<String, Song> _songDownloadStatusCache = {};
  
  // Liked songs tracking
  Set<String> _likedSongIds = {};
  
  // Radio tab visibility
  bool _showRadioTab = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Initialize tab controller immediately with default value
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0);
    
    _loadRadioTabSetting();
    _albumManager.addListener(_onAlbumManagerStateChanged);
    _loadLikedSongIds();
    _loadInitialContent();
    
    // Listen for setting changes
    _listenForSettingChanges();
  }

  Future<void> _loadRadioTabSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final showRadioTab = prefs.getBool('showRadioTab') ?? true;
    
    if (showRadioTab != _showRadioTab) {
      setState(() {
        _showRadioTab = showRadioTab;
        // Update tab controller with correct length based on setting
        _tabController.dispose();
        _tabController = TabController(
          length: _showRadioTab ? 2 : 1, 
          vsync: this, 
          initialIndex: 0
        );
      });
    } else {
      // Just update the state without recreating the controller
      setState(() {
        _showRadioTab = showRadioTab;
      });
    }
  }

  void _listenForSettingChanges() {
    // Check for setting changes periodically
    _settingChangeTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final prefs = await SharedPreferences.getInstance();
      final showRadioTab = prefs.getBool('showRadioTab') ?? true;
      
      if (showRadioTab != _showRadioTab) {
        setState(() {
          _showRadioTab = showRadioTab;
          // Dispose old controller and create new one with correct length
          _tabController.dispose();
          _tabController = TabController(
            length: _showRadioTab ? 2 : 1, 
            vsync: this, 
            initialIndex: 0
          );
        });
      }
    });
  }

  void _onAlbumManagerStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _settingChangeTimer?.cancel();
    try {
      _tabController.dispose();
    } catch (e) {
      // Controller might already be disposed, ignore
    }
    _searchController.dispose();
    _albumManager.removeListener(_onAlbumManagerStateChanged);
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

  Future<void> _loadInitialContent() async {
    if (_searchQuery.isEmpty) {
      _loadInitialMusic();
      _loadInitialStations();
    }
  }

  Future<void> _loadInitialMusic() async {
    setState(() {
      _isLoadingMusic = true;
    });

    try {
      // Load only songs when no search query
      final songs = await _apiService.fetchSongs('');
      
      if (mounted) {
        final results = <SearchResultItem>[];
        
        // Add songs (top 50)
        for (final song in songs.take(50)) {
          results.add(SearchResultItem(
            type: ContentType.song,
            data: song,
            relevanceScore: 1.0,
          ));
        }
        
        setState(() {
          _musicResults = results;
          _isLoadingMusic = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMusic = false;
        });
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'loading music');
      }
    }
  }

  Future<void> _loadInitialStations() async {
    setState(() {
      _isLoadingStations = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
      final country = usRadioOnly ? 'United States' : '';
      final stations = await _apiService.fetchStationsByCountry(country);
      
      if (mounted) {
        final results = <SearchResultItem>[];
        
        // Add stations (top 50)
        for (final station in stations.take(50)) {
          results.add(SearchResultItem(
            type: ContentType.station,
            data: station,
            relevanceScore: 1.0,
          ));
        }
        
        setState(() {
          _stationResults = results;
          _isLoadingStations = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingStations = false;
        });
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'loading stations');
      }
    }
  }

  // Performance: Debounced search
  void _onSearch(String value) async {
    _searchDebounceTimer?.cancel();
    
    _searchDebounceTimer = Timer(_debounceDelay, () async {
      final newQuery = value.trim();
      
      if (mounted) {
        setState(() {
          _searchQuery = newQuery;
        });
        
        if (newQuery.isEmpty) {
          _loadInitialContent();
        } else {
          _performSearch(newQuery);
        }
      }
    });
  }

  Future<void> _performSearch(String query) async {
    _searchMusic(query);
    _searchStations(query);
  }

  Future<void> _searchMusic(String query) async {
    setState(() {
      _isLoadingMusic = true;
    });

    try {
      final results = <SearchResultItem>[];
      
      // Search songs
      final songs = await _apiService.fetchSongs(query);
      for (final song in songs) {
        results.add(SearchResultItem(
          type: ContentType.song,
          data: song,
          relevanceScore: _calculateRelevance(song.title, query) + _calculateRelevance(song.artist, query),
        ));
      }
      
      // Search albums
      final albums = await _apiService.searchAlbums(query);
      for (final album in albums) {
        results.add(SearchResultItem(
          type: ContentType.album,
          data: album,
          relevanceScore: _calculateRelevance(album.title, query) + _calculateRelevance(album.artistName, query),
        ));
      }
      
      // Search artists
      final artists = await _apiService.searchArtists(query);
      for (final artist in artists) {
        final artistName = artist['ART_NAME'] as String? ?? artist['name'] as String? ?? '';
        results.add(SearchResultItem(
          type: ContentType.artist,
          data: artist,
          relevanceScore: _calculateRelevance(artistName, query),
        ));
      }
      
      // Sort by relevance score
      results.sort((a, b) => b.relevanceScore.compareTo(a.relevanceScore));
      
      if (mounted) {
        setState(() {
          _musicResults = results;
          _isLoadingMusic = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMusic = false;
        });
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'searching music');
      }
    }
  }

  Future<void> _searchStations(String query) async {
    setState(() {
      _isLoadingStations = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
      final country = usRadioOnly ? 'United States' : '';
      final stations = await _apiService.fetchStationsByCountry(country, name: query);
      
      final results = <SearchResultItem>[];
      
      for (final station in stations) {
        results.add(SearchResultItem(
          type: ContentType.station,
          data: station,
          relevanceScore: _calculateRelevance(station['name'] ?? '', query),
        ));
      }
      
      // Sort by relevance score
      results.sort((a, b) => b.relevanceScore.compareTo(a.relevanceScore));
      
      if (mounted) {
        setState(() {
          _stationResults = results;
          _isLoadingStations = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingStations = false;
        });
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'searching stations');
      }
    }
  }

  double _calculateRelevance(String text, String query) {
    final textLower = text.toLowerCase();
    final queryLower = query.toLowerCase();
    
    // Exact match gets highest score
    if (textLower == queryLower) {
      return 1.0;
    }
    
    // Starts with query gets high score
    if (textLower.startsWith(queryLower)) {
      return 0.9;
    }
    
    // Contains query gets medium score
    if (textLower.contains(queryLower)) {
      return 0.7;
    }
    
    // Word boundary matches get lower score
    final words = textLower.split(' ');
    for (final word in words) {
      if (word.startsWith(queryLower)) {
        return 0.6;
      }
    }
    
    return 0.3; // Default low score for partial matches
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

  Future<void> _toggleAlbumSave(Album album) async {
    final isSaved = _albumManager.isAlbumSaved(album.id);
    
    if (isSaved) {
      await _albumManager.removeSavedAlbum(album.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${album.title} removed from library')),
      );
    } else {
      await _albumManager.addSavedAlbum(album);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${album.title} added to library')),
      );
    }
    
    setState(() {});
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

  // Build song list item
  Widget _buildSongListItem(Song song) {
    return FutureBuilder<Song>(
      future: _getSongWithDownloadStatusInternal(song),
      builder: (context, snapshot) {
        final songWithStatus = snapshot.data ?? song;
        final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
        final bool isRadioPlayingGlobal = currentSongProvider.isCurrentlyPlayingRadio;

        return Slidable(
          key: Key(songWithStatus.id),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.32,
            children: [
              SlidableAction(
                onPressed: (context) {
                  if (!isRadioPlayingGlobal) {
                    currentSongProvider.addToQueue(songWithStatus);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${songWithStatus.title} added to queue')),
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
                        return AddToPlaylistDialog(song: songWithStatus);
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
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
              await currentSongProvider.playWithContext([songWithStatus], songWithStatus);
            },
            onLongPress: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SongDetailScreen(song: songWithStatus),
                ),
              );
            },
            ),
          ),
        );
      },
    );
  }

  // Build album list item
  Widget _buildAlbumListItem(Album album) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: album.fullAlbumArtUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: album.fullAlbumArtUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 112,
                    memCacheHeight: 112,
                    placeholder: (context, url) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.album),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.album),
                    ),
                  )
                : Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.album),
                  ),
          ),
        ),
        title: Text(
          album.title,
          style: const TextStyle(fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              album.artistName,
              style: TextStyle(color: Colors.grey[600]),
              overflow: TextOverflow.ellipsis,
            ),
            if (album.trackCount != null)
              Text(
                '${album.trackCount} tracks',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
          ],
        ),
        trailing: IconButton(
          icon: Icon(
            _albumManager.isAlbumSaved(album.id) 
                ? Icons.bookmark 
                : Icons.bookmark_border,
            color: _albumManager.isAlbumSaved(album.id) 
                ? Theme.of(context).colorScheme.primary 
                : null,
          ),
          onPressed: () => _toggleAlbumSave(album),
        ),

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

          try {
            // Fetch full album details with tracks
            final fullAlbum = await _apiService.fetchAlbumDetailsById(album.id);
            if (mounted) {
              Navigator.of(context).pop(); // Remove loading dialog
              if (fullAlbum != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AlbumScreen(album: fullAlbum),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not load album details.')),
                );
              }
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop(); // Remove loading dialog
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error loading album: $e')),
              );
            }
          }
        },
      ),
    );
  }

  // Build artist list item
  Widget _buildArtistListItem(dynamic artist) {
    // Handle the actual API response structure
    final artistName = artist['ART_NAME'] as String? ?? 
                      artist['name'] as String? ?? 
                      'Unknown Artist';
    final artistPicture = artist['ART_PICTURE'] as String? ?? 
                         artist['picture'] as String?;
    
    // Construct the artist picture URL if we have the picture ID
    String? artistImageUrl;
    if (artistPicture != null && artistPicture.isNotEmpty) {
      artistImageUrl = 'https://e-cdns-images.dzcdn.net/images/artist/$artistPicture/1000x1000-000000-80-0-0.jpg';
    }
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: artistImageUrl != null && artistImageUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: artistImageUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 112,
                    memCacheHeight: 112,
                    placeholder: (context, url) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.person),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.person),
                    ),
                  )
                : Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.person),
                  ),
          ),
        ),
        title: Text(
          artistName,
          style: const TextStyle(fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Artist',
          style: TextStyle(color: Colors.grey[600]),
        ),

        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ArtistScreen(
                artistId: artist['ART_ID']?.toString() ?? artist['id']?.toString() ?? '',
                artistName: artistName,
              ),
            ),
          );
        },
      ),
    );
  }

  // Build station list item
  Widget _buildStationListItem(dynamic station) {
    final stationName = station['name'] as String? ?? 'Unknown Station';
    final stationCountry = station['country'] as String? ?? 'Unknown Country';
    final stationFavicon = station['favicon'] as String?;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: stationFavicon != null && stationFavicon.isNotEmpty
                ? RadioStationIcon(
                    imageUrl: stationFavicon,
                    stationId: stationName.hashCode.toString(),
                    size: 56,
                    borderRadius: BorderRadius.circular(8),
                  )
                : Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.radio),
                  ),
          ),
        ),
        title: Text(
          stationName,
          style: const TextStyle(fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          stationCountry,
          style: TextStyle(color: Colors.grey[600]),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () {
            final streamUrl = station['streamUrl'] ?? station['url'] ?? '';
            final stationFavicon = station['favicon'] ?? station['imageUrl'] ?? '';
            
            final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
            currentSongProvider.playStream(
              streamUrl,
              stationName: stationName,
              stationFavicon: stationFavicon,
            );
          },
        ),
        onTap: () {
          final streamUrl = station['streamUrl'] ?? station['url'] ?? '';
          final stationFavicon = station['favicon'] ?? station['imageUrl'] ?? '';
          
          final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
          currentSongProvider.playStream(
            streamUrl,
            stationName: stationName,
            stationFavicon: stationFavicon,
          );
        },
      ),
    );
  }

  // Build unified list item based on content type
  Widget _buildListItem(SearchResultItem item) {
    switch (item.type) {
      case ContentType.song:
        return _buildSongListItem(item.data as Song);
      case ContentType.album:
        return _buildAlbumListItem(item.data as Album);
      case ContentType.artist:
        return _buildArtistListItem(item.data);
      case ContentType.station:
        return _buildStationListItem(item.data);
    }
  }

  // Build music tab content
  Widget _buildMusicTab() {
    if (_isLoadingMusic) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_musicResults.isEmpty) {
      return _errorHandler.buildEmptyStateWidget(
        context,
        title: _searchQuery.isEmpty ? 'No Music Available' : 'No Music Found',
        message: _searchQuery.isEmpty 
            ? 'Unable to load music. Please check your connection and try again.'
            : 'No music found for "$_searchQuery". Try a different search term.',
        icon: _searchQuery.isEmpty ? Icons.music_note : Icons.search_off,
        onAction: _searchQuery.isEmpty ? _loadInitialMusic : null,
        actionText: _searchQuery.isEmpty ? 'Retry' : null,
      );
    }

    return RefreshIndicator(
      onRefresh: _searchQuery.isEmpty ? _loadInitialMusic : () => _searchMusic(_searchQuery),
      child: ListView.builder(
        itemCount: _musicResults.length,
        itemBuilder: (context, index) => _buildListItem(_musicResults[index]),
      ),
    );
  }

  // Build stations tab content
  Widget _buildStationsTab() {
    if (_isLoadingStations) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_stationResults.isEmpty) {
      return _errorHandler.buildEmptyStateWidget(
        context,
        title: _searchQuery.isEmpty ? 'No Radio Stations Available' : 'No Radio Stations Found',
        message: _searchQuery.isEmpty 
            ? 'Unable to load radio stations. Please check your connection and try again.'
            : 'No radio stations found for "$_searchQuery". Try a different search term.',
        icon: _searchQuery.isEmpty ? Icons.radio : Icons.search_off,
        onAction: _searchQuery.isEmpty ? _loadInitialStations : null,
        actionText: _searchQuery.isEmpty ? 'Retry' : null,
      );
    }

    return RefreshIndicator(
      onRefresh: _searchQuery.isEmpty ? _loadInitialStations : () => _searchStations(_searchQuery),
      child: ListView.builder(
        itemCount: _stationResults.length,
        itemBuilder: (context, index) => _buildListItem(_stationResults[index]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
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
                      _buildMusicTab(),
                      _buildStationsTab(),
                    ],
                  )
                : _buildMusicTab(),
          ),
        ],
      ),
    );
  }
}