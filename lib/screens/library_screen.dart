import 'dart:io';
import 'dart:convert'; // Required for jsonDecode
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Required for SharedPreferences
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/album.dart'; // Import Album model
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart'; // Import AlbumManagerService
import '../services/auto_fetch_service.dart';
import '../services/unified_search_service.dart';
import 'playlist_detail_screen.dart'; // Import for navigation
import 'album_screen.dart'; // Import AlbumScreen for navigation
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart'; // Required for getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // Required for path manipulation
import 'package:uuid/uuid.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart'; // Import for metadata
import 'download_queue_screen.dart'; // Import for the new Download Queue screen
import 'playlists_list_screen.dart';
import 'artists_list_screen.dart';
import 'albums_list_screen.dart';
import 'songs_list_screen.dart';
import 'liked_songs_screen.dart'; // new import
import 'song_detail_screen.dart';
import 'dart:async';
import 'package:flutter/foundation.dart'; // For consolidateHttpClientResponseBytes
import '../widgets/unified_search_widget.dart';

// Place this at the top level, outside any class
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

// A simple model for a radio station.
class RadioStation {
  final String id;
  final String name;
  final String imageUrl;
  final String streamUrl;

  RadioStation({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.streamUrl,
  });

  // fromJson and toJson for SharedPreferences
  factory RadioStation.fromJson(Map<String, dynamic> json) {
    return RadioStation(
      id: json['id'] as String,
      name: json['name'] as String,
      imageUrl: json['imageUrl'] as String,
      streamUrl: json['streamUrl'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'imageUrl': imageUrl,
      'streamUrl': streamUrl,
    };
  }
}

// Global manager for recently played radio stations.
final radioRecentsManager = RadioRecentsManager();

class RadioRecentsManager extends ChangeNotifier {
  static final RadioRecentsManager _instance = RadioRecentsManager._internal();
  factory RadioRecentsManager() => _instance;
  RadioRecentsManager._internal();

  CurrentSongProvider? _provider;
  bool _isInitialized = false;

  void init(CurrentSongProvider provider) {
    if (_isInitialized) return;
    _provider = provider;
    _provider!.addListener(_handleMediaItemChange);
    _isInitialized = true;
  }

  @override
  void dispose() {
    _provider?.removeListener(_handleMediaItemChange);
    _isInitialized = false; // Allow re-initialization if needed
    super.dispose();
  }

  Future<void> clearRecentStations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('recent_radio_stations');
    notifyListeners();
  }

  Future<void> _addStationToRecents(RadioStation station) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? stationsJson = prefs.getStringList('recent_radio_stations');
    List<RadioStation> currentStations = [];
    if (stationsJson != null) {
      try {
        currentStations = stationsJson
            .map((s) => RadioStation.fromJson(jsonDecode(s) as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('Could not parse recent stations: $e');
      }
    }

    // Prevent adding the same station multiple times if the listener fires rapidly
    if (currentStations.isNotEmpty && currentStations.first.id == station.id) {
      return;
    }

    // Remove if it already exists to move it to the front
    currentStations.removeWhere((s) => s.id == station.id);

    // Add to the front
    currentStations.insert(0, station);

    // Cache the station icon if needed
    await cacheStationIcon(station.imageUrl, station.id);

    // Limit to a reasonable number, e.g., 20
    if (currentStations.length > 20) {
      currentStations = currentStations.sublist(0, 20);
    }

    // Save back to SharedPreferences
    final List<String> updatedStationsJson = currentStations.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('recent_radio_stations', updatedStationsJson);
    await cleanupCachedStationIcons(currentStations);
    // Notify listeners that the list of recent stations has changed.
    notifyListeners();
  }

  void _handleMediaItemChange() {
    final mediaItem = _provider?.audioHandler.mediaItem.value;
    if (mediaItem == null) return;

    // Heuristic to identify a radio stream.
    if (mediaItem.artist == 'Radio Station') {
      final audioUrl = mediaItem.extras?['audioUrl'] as String? ?? mediaItem.id;

      final station = RadioStation(
        id: mediaItem.extras?['songId'] as String? ?? mediaItem.id,
        name: mediaItem.title,
        imageUrl: mediaItem.artUri?.toString() ?? '',
        streamUrl: audioUrl,
      );

      if (station.id.isNotEmpty && station.name.isNotEmpty && station.streamUrl.isNotEmpty) {
        _addStationToRecents(station);
      }
    }
  }
}

// Helper to clean up unused cached station icons
Future<void> cleanupCachedStationIcons(List<RadioStation> currentStations) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final files = directory.listSync();
    final validFilenames = currentStations.map((s) => 'stationicon_${s.id}.jpg').toSet();
    for (final file in files) {
      if (file is File && file.path.contains('stationicon_') && file.path.endsWith('.jpg')) {
        final filename = p.basename(file.path);
        if (!validFilenames.contains(filename)) {
          try {
            await file.delete();
          } catch (e) {
            debugPrint('Error deleting old station icon: $e');
          }
        }
      }
    }
  } catch (e) {
    debugPrint('Error cleaning up station icons: $e');
  }
}

// Enum definitions for sorting
// enum PlaylistSortType { nameAsc, nameDesc, songCountAsc, songCountDesc } // Removed
// enum AlbumSortType { titleAsc, titleDesc, artistAsc, artistDesc } // Removed
// enum SongSortType { titleAsc, titleDesc, artistAsc, artistDesc } // Removed

class ModernLibraryScreen extends StatefulWidget {
  const ModernLibraryScreen({super.key});

  @override
  ModernLibraryScreenState createState() => ModernLibraryScreenState();
}

class ModernLibraryScreenState extends State<ModernLibraryScreen> with AutomaticKeepAliveClientMixin {
  List<Song> _songs = [];
  List<Playlist> _playlists = [];
  List<Album> _savedAlbums = []; // New list for saved albums
  List<RadioStation> _recentStations = []; // New list for recent stations
  // final AudioPlayer audioPlayer = AudioPlayer(); // REMOVED
  // ignore: unused_field
  String? _currentlyPlayingSongPath;
  bool isPlaying = false;
  final TextEditingController _playlistNameController = TextEditingController();
  final PlaylistManagerService _playlistManager = PlaylistManagerService();
  final AlbumManagerService _albumManager = AlbumManagerService(); // Instance of AlbumManagerService
  final Uuid _uuid = const Uuid(); // For generating unique IDs

  late CurrentSongProvider _currentSongProvider; // To listen for song updates

  // Search functionality
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Sort state variables
  // PlaylistSortType _playlistSortType = PlaylistSortType.nameAsc; // Removed
  // AlbumSortType _albumSortType = AlbumSortType.titleAsc; // Removed
  // SongSortType _songSortType = SongSortType.titleAsc; // Removed

  // SharedPreferences keys for sorting
  // static const String _playlistSortPrefKey = 'playlistSortType_v2'; // Removed
  // static const String _albumSortPrefKey = 'albumSortType_v2'; // Removed
  // static const String _songSortPrefKey = 'songSortType_v2'; // Removed


  // cache local‐art lookup futures by filename
  // ignore: unused_field
  final Map<String, String> _localArtPathCache = {};
  
  // Cache Future objects to prevent art flashing
  final Map<String, Future<String>> _localArtFutureCache = {};
  
  // Performance: Debounced search
  Timer? _searchDebounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 300);
  late VoidCallback _searchListener;
  
  // Performance: Lazy loading
  // static const int _pageSize = 20;
  // int _currentPage = 0;
  // bool _hasMoreItems = true;
  final ScrollController _scrollController = ScrollController();
  
  // Performance: Loading states
  bool _isLoadingSongs = false;
  bool _isLoadingPlaylists = false;
  bool _isLoadingAlbums = false;
  bool _isLoadingStations = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchListener = () => _onSearchChanged(_searchController.text);
    _searchController.addListener(_searchListener);
    
    // Performance: Add scroll listener for lazy loading
    _scrollController.addListener(_onScroll);
    
    // Initial loads
    _loadData();

    // Listen to PlaylistManagerService
    // This listener will call _loadPlaylists when playlist data changes.
    _playlistManager.addListener(_onPlaylistChanged);
    _albumManager.addListener(_onSavedAlbumsChanged); // Listen to AlbumManagerService
    radioRecentsManager.addListener(_loadRecentStations); // Listen for global changes
    
    // audioPlayer.onPlayerComplete.listen((event) { // REMOVED
    //   setState(() {
    //     isPlaying = false;
    //     _currentlyPlayingSongPath = null;
    //     // Consider updating based on CurrentSongProvider state if it's managing global playback
    //   });
    // });
  }

  void _loadData() {
    _loadDownloadedSongs(); 
    _loadPlaylists();       
    _loadSavedAlbums();     
    _loadRecentStations();
  }

  // Future<void> _loadSortPreferences() async { // Removed
  //   final prefs = await SharedPreferences.getInstance();
  //   setState(() {
  //     _playlistSortType = _enumFromString(prefs.getString(_playlistSortPrefKey), PlaylistSortType.values, PlaylistSortType.nameAsc);
  //     _albumSortType = _enumFromString(prefs.getString(_albumSortPrefKey), AlbumSortType.values, AlbumSortType.titleAsc);
  //     _songSortType = _enumFromString(prefs.getString(_songSortPrefKey), SongSortType.values, SongSortType.titleAsc);
  //   });
  // }

  // ignore: unused_element
  // Future<void> _saveSortPreference(String key, String value) async { // Removed
  //   final prefs = await SharedPreferences.getInstance();
  //   await prefs.setString(key, value);
  // }

  // T _enumFromString<T>(String? value, List<T> enumValues, T defaultValue) { // Removed if only used by sort
  //   if (value == null) return defaultValue;
  //   return enumValues.firstWhere((e) => e.toString().split('.').last == value, orElse: () => defaultValue);
  // }

  // void _applySortAndRefresh() { // Removed
  //   if (!mounted) return;

  //   // Apply sorting based on current tab and sort type
  //   if (_searchQuery.isNotEmpty) {
  //     // Filtering happens in build methods, no need to sort
  //     setState(() {});
  //     return;
  //   }

  //   _sortPlaylists();
  //   _sortAlbums();
  //   _sortSongs();
  //   setState(() {});
  // }

  // void _sortPlaylists() { // Removed
  //   _playlists.sort((a, b) {
  //     switch (_playlistSortType) {
  //       case PlaylistSortType.nameAsc:
  //         return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  //       case PlaylistSortType.nameDesc:
  //         return b.name.toLowerCase().compareTo(a.name.toLowerCase());
  //       case PlaylistSortType.songCountAsc:
  //         return a.songs.length.compareTo(b.songs.length);
  //       case PlaylistSortType.songCountDesc:
  //         return b.songs.length.compareTo(a.songs.length);
  //     }
  //   });
  // }

  // void _sortAlbums() { // Removed
  //   _savedAlbums.sort((a, b) {
  //     switch (_albumSortType) {
  //       case AlbumSortType.titleAsc:
  //         return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  //       case AlbumSortType.titleDesc:
  //         return b.title.toLowerCase().compareTo(a.title.toLowerCase());
  //       case AlbumSortType.artistAsc:
  //         return a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase());
  //       case AlbumSortType.artistDesc:
  //         return b.artistName.toLowerCase().compareTo(a.artistName.toLowerCase());
  //     }
  //   });
  // }

  // void _sortSongs() { // Removed
  //   _songs.sort((a, b) {
  //     switch (_songSortType) {
  //       case SongSortType.titleAsc:
  //         return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  //       case SongSortType.titleDesc:
  //         return b.title.toLowerCase().compareTo(a.title.toLowerCase());
  //       case SongSortType.artistAsc:
  //         return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
  //       case SongSortType.artistDesc:
  //         return b.artist.toLowerCase().compareTo(a.artist.toLowerCase());
  //     }
  //   });
  // }


  // Performance: Debounced search
  void _onSearchChanged(String value) {
    _searchDebounceTimer?.cancel();
    
    _searchDebounceTimer = Timer(_debounceDelay, () {
      if (!mounted) return;
      
      setState(() {
        _searchQuery = value.toLowerCase();
        // Reset pagination for new search
        // _currentPage = 0;
        // _hasMoreItems = true;
      });
      
      // Scroll to top when search results appear
      if (value.isNotEmpty && _scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Setup listener for CurrentSongProvider here as context is available.
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    // This listener will call _loadDownloadedSongs when song data changes (e.g., download status).
    _currentSongProvider.addListener(_onSongDataChanged);
    // Initialize the global manager. It will only init once.
    radioRecentsManager.init(_currentSongProvider);
  }

  void _onPlaylistChanged() {
    // PlaylistManagerService notified changes, reload playlists
    if (mounted) {
      _loadPlaylists(); // This will call setState after loading
    }
  }

  void _onSavedAlbumsChanged() { // New listener method
    if (mounted) {
      _loadSavedAlbums(); // This will call setState after loading
    }
  }

  void _onSongDataChanged() {
    // CurrentSongProvider notified changes (e.g., download finished, metadata updated)
    // Reload downloaded songs list
    if (mounted) {
      _loadDownloadedSongs(); // This will call setState after loading
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.removeListener(_searchListener);
    _searchController.dispose();
    // audioPlayer.dispose(); // REMOVED
    _playlistNameController.dispose();
    _playlistManager.removeListener(_onPlaylistChanged);
    _albumManager.removeListener(_onSavedAlbumsChanged); // Remove listener
    _currentSongProvider.removeListener(_onSongDataChanged); // Remove listener
    radioRecentsManager.removeListener(_loadRecentStations); // Clean up listener
    _scrollController.dispose();
    super.dispose();
  }

  // Performance: Lazy loading scroll listener
  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMoreItems();
    }
  }

  // Performance: Load more items for lazy loading
  void _loadMoreItems() {
    // if (!_hasMoreItems) return;
    
    setState(() {
      // _currentPage++;
      _loadData();
    });
  }

  // Search filter state
  bool _showSongs = true;
  bool _showAlbums = true;
  bool _showPlaylists = true;
  bool _showRadioStations = true;
  bool _searchInLyrics = true;

  // Unified search results builder
  Widget _buildUnifiedSearchResults() {
    final results = <Widget>[];
    
    // Search in songs (including lyrics if enabled)
    final songMatches = _songs.where((song) {
      final matchesTitle = song.title.toLowerCase().contains(_searchQuery);
      final matchesArtist = song.artist.toLowerCase().contains(_searchQuery);
      final matchesAlbum = song.album != null && song.album!.toLowerCase().contains(_searchQuery);
      final matchesLyrics = _searchInLyrics && song.plainLyrics != null && 
                           song.plainLyrics!.toLowerCase().contains(_searchQuery);
      
      return matchesTitle || matchesArtist || matchesAlbum || matchesLyrics;
    }).map((song) {
      // Determine match type for highlighting
      final matchesTitle = song.title.toLowerCase().contains(_searchQuery);
      final matchesArtist = song.artist.toLowerCase().contains(_searchQuery);
      final matchesAlbum = song.album != null && song.album!.toLowerCase().contains(_searchQuery);
      final matchesLyrics = _searchInLyrics && song.plainLyrics != null && 
                           song.plainLyrics!.toLowerCase().contains(_searchQuery);
      
      return {
        'song': song,
        'matchesTitle': matchesTitle,
        'matchesArtist': matchesArtist,
        'matchesAlbum': matchesAlbum,
        'matchesLyrics': matchesLyrics,
      };
    }).toList();
    
    // Search in playlists
    final playlistMatches = _playlists.where((playlist) =>
      playlist.name.toLowerCase().contains(_searchQuery)
    ).toList();
    
    // Search in albums
    final albumMatches = _savedAlbums.where((album) =>
      album.title.toLowerCase().contains(_searchQuery) ||
      album.artistName.toLowerCase().contains(_searchQuery)
    ).toList();
    
    // Search in radio stations
    final stationMatches = _recentStations.where((station) =>
      station.name.toLowerCase().contains(_searchQuery)
    ).toList();
    
    // Add filter buttons at the top
    results.add(_buildSearchFilters());
    
    if (_showSongs && songMatches.isNotEmpty) {
      results.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 4.0),
          child: Text(
            'Songs (${songMatches.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      );
      results.addAll(songMatches.map((match) => _buildSongSearchTile(
        match['song'] as Song,
        matchesTitle: match['matchesTitle'] as bool,
        matchesArtist: match['matchesArtist'] as bool,
        matchesAlbum: match['matchesAlbum'] as bool,
        matchesLyrics: match['matchesLyrics'] as bool,
      )));
    }
    
    if (_showPlaylists && playlistMatches.isNotEmpty) {
      results.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 4.0),
          child: Text(
            'Playlists (${playlistMatches.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      );
      results.addAll(playlistMatches.map((playlist) => _buildPlaylistSearchTile(playlist)));
    }
    
    if (_showAlbums && albumMatches.isNotEmpty) {
      results.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 4.0),
          child: Text(
            'Albums (${albumMatches.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      );
      results.addAll(albumMatches.map((album) => _buildAlbumSearchTile(album)));
    }
    
    if (_showRadioStations && stationMatches.isNotEmpty) {
      results.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 4.0),
          child: Text(
            'Radio Stations (${stationMatches.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      );
      results.addAll(stationMatches.map((station) => _buildRadioStationSearchTile(station)));
    }
    
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 32.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 8),
              Text(
                'No results found for "$_searchQuery"',
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    
    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.zero,
      children: results,
    );
  }

  Widget _buildSearchFilters() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildFilterChip('Songs', _showSongs, (value) {
              setState(() {
                _showSongs = value;
              });
            }),
            const SizedBox(width: 8),
            _buildFilterChip('Albums', _showAlbums, (value) {
              setState(() {
                _showAlbums = value;
              });
            }),
            const SizedBox(width: 8),
            _buildFilterChip('Playlists', _showPlaylists, (value) {
              setState(() {
                _showPlaylists = value;
              });
            }),
            const SizedBox(width: 8),
            _buildFilterChip('Radio', _showRadioStations, (value) {
              setState(() {
                _showRadioStations = value;
              });
            }),
            const SizedBox(width: 8),
            _buildFilterChip('Lyrics', _searchInLyrics, (value) {
              setState(() {
                _searchInLyrics = value;
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, bool isSelected, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: onChanged,
      selectedColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
      checkmarkColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        color: isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  Widget _buildSongSearchTile(
    Song song, {
    bool matchesTitle = false,
    bool matchesArtist = false,
    bool matchesAlbum = false,
    bool matchesLyrics = false,
  }) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    // Get lyrics context if it matches
    String? lyricsContext;
    if (matchesLyrics && song.plainLyrics != null) {
      final lyrics = song.plainLyrics!;
      final queryIndex = lyrics.toLowerCase().indexOf(_searchQuery.toLowerCase());
      if (queryIndex != -1) {
        final start = (queryIndex - 30).clamp(0, lyrics.length);
        final end = (queryIndex + _searchQuery.length + 30).clamp(0, lyrics.length);
        lyricsContext = lyrics.substring(start, end);
        if (start > 0) lyricsContext = '...$lyricsContext';
        if (end < lyrics.length) lyricsContext = '$lyricsContext...';
      }
    }
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: song.albumArtUrl.isNotEmpty
              ? (song.albumArtUrl.startsWith('http')
                  ? Image.network(
                      song.albumArtUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 56),
                    )
                  : FutureBuilder<String>(
                      future: _getCachedLocalArtFuture(song.albumArtUrl),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done &&
                            snapshot.hasData &&
                            snapshot.data!.isNotEmpty) {
                          return Image.file(
                            File(snapshot.data!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 56),
                          );
                        }
                        return const Icon(Icons.music_note, size: 56);
                      },
                    ))
              : const Icon(Icons.music_note, size: 56),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                song.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (matchesLyrics)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'LYRICS',
                  style: TextStyle(
                    fontSize: 8,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              song.artist.isNotEmpty ? song.artist : 'Unknown Artist',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (song.album != null && song.album!.isNotEmpty)
              Text(
                song.album!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (matchesLyrics && lyricsContext != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  lyricsContext,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (song.isDownloaded)
              const Icon(Icons.download_done, color: Colors.green, size: 20),
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 28),
              onPressed: () async {
                await currentSongProvider.playWithContext([song], song);
              },
            ),
          ],
        ),
        onTap: () async {
          await currentSongProvider.playWithContext([song], song);
        },
        onLongPress: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SongDetailScreen(song: song),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaylistSearchTile(Playlist playlist) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.purple.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: const Icon(Icons.playlist_play, color: Colors.purple, size: 28),
        ),
        title: Text(
          playlist.name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${playlist.songs.length} songs',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlaylistDetailScreen(playlist: playlist),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAlbumSearchTile(Album album) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: album.effectiveAlbumArtUrl.isNotEmpty
              ? (album.effectiveAlbumArtUrl.startsWith('http')
                  ? Image.network(
                      album.effectiveAlbumArtUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.album, size: 56),
                    )
                  : FutureBuilder<String>(
                      future: _getCachedLocalArtFuture(album.effectiveAlbumArtUrl),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done &&
                            snapshot.hasData &&
                            snapshot.data!.isNotEmpty) {
                          return Image.file(
                            File(snapshot.data!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.album, size: 56),
                          );
                        }
                        return const Icon(Icons.album, size: 56);
                      },
                    ))
              : const Icon(Icons.album, size: 56),
        ),
        title: Text(
          album.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              album.artistName,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${album.tracks.length} tracks',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AlbumScreen(album: album),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRadioStationSearchTile(RadioStation station) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: RadioStationIcon(
            imageUrl: station.imageUrl,
            stationId: station.id,
            size: 56,
            borderRadius: BorderRadius.circular(8.0),
          ),
        ),
        title: Text(
          station.name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: const Text(
          'Radio Station',
          style: TextStyle(fontSize: 14),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_arrow, size: 28),
          onPressed: () async {
            final radioSong = Song(
              title: station.name,
              id: station.id,
              artist: 'Radio',
              albumArtUrl: station.imageUrl,
              audioUrl: station.streamUrl,
              extras: {'isRadio': true, 'streamUrl': station.streamUrl},
            );
            await currentSongProvider.playWithContext([radioSong], radioSong);
          },
        ),
        onTap: () async {
          final radioSong = Song(
            title: station.name,
            id: station.id,
            artist: 'Radio',
            albumArtUrl: station.imageUrl,
            audioUrl: station.streamUrl,
            extras: {'isRadio': true, 'streamUrl': station.streamUrl},
          );
          await currentSongProvider.playWithContext([radioSong], radioSong);
        },
      ),
    );
  }

  // Performance: Optimized song loading with caching
  Future<void> _loadDownloadedSongs() async {
    if (_isLoadingSongs) return;
    
    setState(() {
      _isLoadingSongs = true;
    });
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> keys = prefs.getKeys();
      final List<Song> loadedSongs = [];
      final appDocDir = await getApplicationDocumentsDirectory();
      const String downloadsSubDir = 'ltunes_downloads';

      for (String key in keys) {
        if (key.startsWith('song_')) {
          final String? songJson = prefs.getString(key);
          if (songJson != null) {
            try {
              Map<String, dynamic> songMap = jsonDecode(songJson) as Map<String, dynamic>;
              Song song = Song.fromJson(songMap);
              bool metadataUpdated = false;

              // Migration and validation for localFilePath
              if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
                String fileName = song.localFilePath!;
                if (song.localFilePath!.contains(Platform.pathSeparator)) {
                  fileName = p.basename(song.localFilePath!);
                }
                final fullPath = p.join(appDocDir.path, downloadsSubDir, fileName);
                
                if (await File(fullPath).exists()) {
                  if (song.localFilePath != fileName) {
                    song = song.copyWith(localFilePath: fileName);
                    songMap['localFilePath'] = fileName;
                    metadataUpdated = true;
                  }
                } else {
                  song = song.copyWith(isDownloaded: false, localFilePath: null);
                  songMap['isDownloaded'] = false;
                  songMap['localFilePath'] = null;
                  metadataUpdated = true;
                }
              } else if (song.isDownloaded) {
                song = song.copyWith(isDownloaded: false, localFilePath: null);
                songMap['isDownloaded'] = false;
                songMap['localFilePath'] = null;
                metadataUpdated = true;
              }

              // Migration and validation for albumArtUrl
              if (song.albumArtUrl.isNotEmpty && !song.albumArtUrl.startsWith('http')) {
                String artFileName = song.albumArtUrl;
                if (song.albumArtUrl.contains(Platform.pathSeparator)) {
                  artFileName = p.basename(song.albumArtUrl);
                }
                final fullArtPath = p.join(appDocDir.path, artFileName);

                if (await File(fullArtPath).exists()) {
                  if (song.albumArtUrl != artFileName) {
                    song = song.copyWith(albumArtUrl: artFileName);
                    songMap['albumArtUrl'] = artFileName;
                    metadataUpdated = true;
                  }
                }
              }
              
              if (metadataUpdated) {
                await prefs.setString(key, jsonEncode(songMap));
              }

              if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
                final checkFile = File(p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
                if (await checkFile.exists()) {
                  loadedSongs.add(song);
                }
              }
            } catch (e) {
              debugPrint('Error decoding song from SharedPreferences for key $key: $e');
            }
          }
        }
      }
      
      if (mounted) {
        setState(() {
          _songs = loadedSongs;
          _isLoadingSongs = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading downloaded songs: $e');
      if (mounted) {
        setState(() {
          _isLoadingSongs = false;
        });
      }
    }
  }

  Future<void> _loadPlaylists() async {
    if (_isLoadingPlaylists) return;
    
    setState(() {
      _isLoadingPlaylists = true;
    });
    
    try {
      if (mounted) {
        setState(() {
          _playlists = List.from(_playlistManager.playlists);
          _isLoadingPlaylists = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading playlists: $e');
      if (mounted) {
        setState(() {
          _isLoadingPlaylists = false;
        });
      }
    }
  }
  
  Future<void> _loadSavedAlbums() async {
    if (_isLoadingAlbums) return;
    
    setState(() {
      _isLoadingAlbums = true;
    });
    
    try {
      if (mounted) {
        setState(() {
          _savedAlbums = List.from(_albumManager.savedAlbums);
          _isLoadingAlbums = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading saved albums: $e');
      if (mounted) {
        setState(() {
          _isLoadingAlbums = false;
        });
      }
    }
  }

  Future<void> _loadRecentStations() async {
    if (_isLoadingStations) return;
    
    setState(() {
      _isLoadingStations = true;
    });
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String>? stationsJson = prefs.getStringList('recent_radio_stations');
      if (stationsJson != null) {
        try {
          final stations = stationsJson
              .map((s) => RadioStation.fromJson(jsonDecode(s) as Map<String, dynamic>))
              .toList();
          if (mounted) {
            setState(() {
              _recentStations = stations;
              _isLoadingStations = false;
            });
          }
        } catch (e) {
          debugPrint('Could not load recent stations, clearing them. Error: $e');
          await prefs.remove('recent_radio_stations');
          if (mounted) {
            setState(() {
              _recentStations = [];
              _isLoadingStations = false;
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoadingStations = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading recent stations: $e');
      if (mounted) {
        setState(() {
          _isLoadingStations = false;
        });
      }
    }
  }

  // Performance: Cached local art path resolution
  Future<String> _getCachedLocalArtPath(String fileName) async {
    if (fileName.isEmpty || fileName.startsWith('http')) return '';
    
    if (_localArtPathCache.containsKey(fileName)) {
      return _localArtPathCache[fileName] ?? '';
    }
    
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        _localArtPathCache[fileName] = fullPath;
        debugPrint('Found local album art (cached): $fullPath');
        return fullPath;
      } else {
        debugPrint('Local album art not found (cached): $fullPath');
      }
    } catch (e) {
      debugPrint('Error caching local art path: $e');
    }
    return '';
  }

  // Get cached Future for local art to prevent flashing
  Future<String> _getCachedLocalArtFuture(String fileName) {
    if (fileName.isEmpty || fileName.startsWith('http')) {
      return Future.value('');
    }
    
    if (!_localArtFutureCache.containsKey(fileName)) {
      _localArtFutureCache[fileName] = _getCachedLocalArtPath(fileName);
    }
    
    return _localArtFutureCache[fileName]!;
  }

  // Performance: Filter items based on search query
  // List<Song> get _filteredSongs {
  //   if (_searchQuery.isEmpty) return _songs;
  //   return _songs.where((song) =>
  //     song.title.toLowerCase().contains(_searchQuery) ||
  //     song.artist.toLowerCase().contains(_searchQuery) ||
  //     (song.album?.toLowerCase().contains(_searchQuery) ?? false)
  //   ).toList();
  // }

  // List<Playlist> get _filteredPlaylists {
  //   if (_searchQuery.isEmpty) return _playlists;
  //   return _playlists.where((playlist) =>
  //     playlist.name.toLowerCase().contains(_searchQuery)
  //   ).toList();
  // }

  // List<Album> get _filteredAlbums {
  //   if (_searchQuery.isEmpty) return _savedAlbums;
  //   return _savedAlbums.where((album) =>
  //     album.title.toLowerCase().contains(_searchQuery) ||
  //     album.artistName.toLowerCase().contains(_searchQuery)
  //   ).toList();
  // }

  // List<RadioStation> get _filteredStations {
  //   if (_searchQuery.isEmpty) return _recentStations;
  //   return _recentStations.where((station) =>
  //     station.name.toLowerCase().contains(_searchQuery)
  //   ).toList();
  // }


  Future<void> _deletePlaylist(BuildContext context, Playlist playlist) async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete Playlist "${playlist.name}"?'),
          content: const Text('Are you sure you want to delete this playlist? This action cannot be undone.'),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: Text('Delete', style: TextStyle(color: Colors.red[700])),
              onPressed: () async { // Make async
                final navigator = Navigator.of(context); // Capture before async
                final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
                await _playlistManager.removePlaylist(playlist); // await the operation
                // _loadPlaylists(); // No longer needed here, listener will handle it.
                navigator.pop();
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text('Playlist "${playlist.name}" deleted.')),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _createPlaylist(BuildContext context) async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create New Playlist'),
          content: TextField(
            controller: _playlistNameController,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
            TextButton(
              child: const Text('Create'),
              onPressed: () async { // Make async
                final playlistName = _playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  final newPlaylist = Playlist(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: playlistName,
                    songs: [],
                  );
                  await _playlistManager.addPlaylist(newPlaylist); // await the operation
                  // _loadPlaylists(); // No longer needed here, listener will handle it.
                }
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
          ],
        );
      },
    );
  }

  // _addSongsToPlaylistDialog and _removeSongFromPlaylist methods remain,
  // though their primary use might shift to PlaylistDetailScreen.
  // For now, they are kept as they might be invoked from there or future features.
  // ignore: unused_element
  Future<void> _addSongsToPlaylistDialog(BuildContext context, Playlist playlist) async {
    if (_songs.isEmpty) {
      final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
      if (mounted && context.mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('No downloaded songs available to add.')),
        );
      }
      return;
    }

    // _songs is already List<Song>, so direct use or copy
    List<Song> availableSongs = List<Song>.from(_songs);

    // Filter out songs already in the playlist
    availableSongs.removeWhere((s) => playlist.songs.any((ps) => ps.id == s.id));

    if (availableSongs.isEmpty) {
      final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
      if (mounted && context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('All downloaded songs are already in "${playlist.name}".')),
        );
      }
      return;
    }
    
    final List<Song> selectedSongs = await showDialog<List<Song>>(
      context: context,
      builder: (BuildContext context) {
        final List<Song> tempSelectedSongs = [];
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text('Add to "${playlist.name}"'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableSongs.length,
                  itemBuilder: (context, index) {
                    final song = availableSongs[index];
                    final isSelected = tempSelectedSongs.contains(song);
                    return CheckboxListTile(
                      title: Text(song.title),
                      value: isSelected,
                      onChanged: (bool? value) {
                        setStateDialog(() {
                          if (value == true) {
                            tempSelectedSongs.add(song);
                          } else {
                            tempSelectedSongs.remove(song);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: const Text('Add Selected'),
                  onPressed: () {
                    Navigator.of(context).pop(tempSelectedSongs);
                  },
                ),
              ],
            );
          }
        );
      },
    ) ?? []; // Return empty list if dialog is dismissed

    if (selectedSongs.isNotEmpty) {
      final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
      for (var song in selectedSongs) {
        await _playlistManager.addSongToPlaylist(playlist, song); // await
      }
      // _loadPlaylists(); // No longer needed here, listener will handle it.
      if (mounted && context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('${selectedSongs.length} song(s) added to "${playlist.name}"')),
        );
      }
    }
  }

  // ignore: unused_element
  Future<void> _removeSongFromPlaylist(Playlist playlist, Song song) async {
    await _playlistManager.removeSongFromPlaylist(playlist, song); // await
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    // _loadPlaylists(); // No longer needed here, listener will handle it.
    if (mounted && context.mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Removed "${song.title}" from "${playlist.name}"')),
      );
    }
  }

  Future<void> _deleteDownloadedSong(Song songToDelete) async {
    // Show confirmation dialog
    final navigator = Navigator.of(context); // Capture before async
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    final bool? confirmed = await showDialog<bool>(
      context: navigator.context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete "${songToDelete.title}"?'),
          content: const Text('Are you sure you want to delete this downloaded song? This action cannot be undone.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                navigator.pop(false); // User canceled
              },
            ),
            TextButton(
              child: Text('Delete', style: TextStyle(color: Colors.red[700])),
              onPressed: () {
                navigator.pop(true); // User confirmed
              },
            ),
          ],
        );
      },
    );

    // If user did not confirm, or dismissed the dialog, do nothing
    if (confirmed != true) {
      return;
    }

    try {
      // Stop playback if this song is currently playing from local file
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final audioHandler = currentSongProvider.audioHandler; // Use public getter
      final currentMediaItem = audioHandler.mediaItem.value;

      // ignore: unused_local_variable
      bool wasPlayingThisDeletedSong = false;
      if (currentMediaItem != null &&
          currentMediaItem.extras?['songId'] == songToDelete.id &&
          (currentMediaItem.extras?['isLocal'] as bool? ?? false)) {
        wasPlayingThisDeletedSong = true;
      }

      if (songToDelete.localFilePath != null && songToDelete.localFilePath!.isNotEmpty) {
        final appDocDir = await getApplicationDocumentsDirectory();
        const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager
        // Correct path for deletion, including the subdirectory
        final fullPath = p.join(appDocDir.path, downloadsSubDir, songToDelete.localFilePath!);
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('Deleted file: $fullPath');
        } else {
          debugPrint('File not found for deletion: $fullPath');
        }
      }

      // Update metadata
      final updatedSong = songToDelete.copyWith(isDownloaded: false, localFilePath: null);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('song_${updatedSong.id}', jsonEncode(updatedSong.toJson()));

      // remove from any playlists that contain it
      for (var playlist in _playlists) {
        await _playlistManager.removeSongFromPlaylist(playlist, updatedSong);
      }

      // Update album download status
      await AlbumManagerService().updateSongInAlbums(updatedSong);

      // notify provider and refresh
      currentSongProvider.updateSongDetails(updatedSong);
      PlaylistManagerService().updateSongInPlaylists(updatedSong);
      
      // If the deleted song was playing, the audio_handler's queue update (via updateSongDetails)
      // should handle transitioning playback or stopping.
      // If it was playing locally, updateSongDetails will replace the MediaItem with one
      // that's not local, and if it can't be streamed, playback might stop or skip.
      // If it was the only song, playback will stop.

      // The _loadDownloadedSongs will be called by the listener _onSongDataChanged
      // due to currentSongProvider.updateSongDetails.

      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Deleted "${updatedSong.title}"')),
        );
      }
    } catch (e) {
      debugPrint('Error deleting song: $e');
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Error deleting song: $e')),
        );
      }
    }
  }

  // ignore: unused_element
  Future<void> _importSongs() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom, // Changed from FileType.audio
        allowedExtensions: ['mp3', 'wav', 'm4a', 'mp4', 'flac', 'opus'], // Added new extensions
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        Directory appDocDir = await getApplicationDocumentsDirectory();
        const String downloadsSubDir = 'ltunes_downloads';
        final Directory fullDownloadsDir = Directory(p.join(appDocDir.path, downloadsSubDir));
        if (!await fullDownloadsDir.exists()) {
          await fullDownloadsDir.create(recursive: true);
        }
        
        int importCount = 0;

        if (context.mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('Importing songs...')),
          );
        }

        for (var file in result.files) {
          if (file.path == null) continue;
          final originalPath = file.path!;

          // SKIP duplicates robustly:
          final already = prefs.getKeys().any((k) {
            final js = prefs.getString(k);
            if (js == null) return false;
            final m = jsonDecode(js) as Map<String, dynamic>;
            final audioUrl = m['audioUrl'];
            return audioUrl?.toString() == originalPath;
          });
          if (already) continue;

          final origName = p.basename(originalPath).toLowerCase();
          debugPrint('Processing file: $origName');
          final ext = p.extension(origName);
          final base = p.basenameWithoutExtension(origName);
          final newName = '${_uuid.v4()}_$base$ext';
          final destPath = p.join(fullDownloadsDir.path, newName);

          try {
            final copied = await File(originalPath).copy(destPath);

            // Extract metadata
            AudioMetadata? metadata;
            // Try to extract metadata for all formats, including M4A and MP4
            try {
              // getImage: true to attempt to load album art
              metadata = readMetadata(copied, getImage: true); 
            } catch (e) {
              debugPrint('Error reading metadata for $origName: $e');
              // Proceed with default values if metadata reading fails
            }

            String songId = _uuid.v4(); // Generate a unique ID for the song
            String albumArtFileName = ''; // Will store just the filename

            if (metadata?.pictures.isNotEmpty ?? false) {
              debugPrint('Found ${metadata!.pictures.length} picture(s) in metadata for $origName');
              final picture = (metadata.pictures.isNotEmpty) ? metadata.pictures.first : null;
              if (picture != null && picture.bytes.isNotEmpty && picture.bytes.length > 100) { // Ensure minimum size for valid image
                debugPrint('Picture mimetype: ${picture.mimetype}, size: ${picture.bytes.length} bytes');
                // Determine file extension from mime type or default to .jpg
                String extension = '.jpg'; // Default extension
                if (picture.mimetype.isNotEmpty) {
                  if (picture.mimetype.endsWith('png')) {
                    extension = '.png';
                  } else if (picture.mimetype.endsWith('jpeg') || picture.mimetype.endsWith('jpg')) {
                    extension = '.jpg';
                  } else if (picture.mimetype.endsWith('webp')) {
                    extension = '.webp';
                  } else if (picture.mimetype.endsWith('gif')) {
                    extension = '.gif';
                  }
                }
                // Add more formats as needed
                
                albumArtFileName = 'albumart_$songId$extension'; // Just the filename
                // Album art is saved in the root of appDocDir, not the downloadsSubDir
                String fullAlbumArtPath = p.join(appDocDir.path, albumArtFileName); 
                
                try {
                  final albumArtFile = File(fullAlbumArtPath);
                  await albumArtFile.writeAsBytes(picture.bytes);
                  debugPrint('Successfully saved album art: $fullAlbumArtPath (${picture.bytes.length} bytes)');
                  
                  // Verify the file was created and has content
                  if (await albumArtFile.exists() && await albumArtFile.length() > 0) {
                    debugPrint('Album art file verified: ${await albumArtFile.length()} bytes');
                  } else {
                    debugPrint('Warning: Album art file may not have been created properly');
                    albumArtFileName = ''; // Clear if file creation failed
                  }
                  // albumArtPath = fullAlbumArtFullPath; // No, store filename
                } catch (e) {
                  debugPrint('Error saving album art for $origName: $e');
                  albumArtFileName = ''; // Clear if saving failed
                }
              }
            } else {
              debugPrint('No pictures found in metadata for $origName');
            }
            
            Song newSong = Song(
              id: songId,
              title: metadata?.title ?? p.basenameWithoutExtension(origName),
              artist: metadata?.artist ?? 'Unknown Artist',
              album: metadata?.album,
              albumArtUrl: albumArtFileName, // Store just the filename
              audioUrl: destPath, // Store full path for initial playback before metadata save
              isDownloaded: true, // Mark as downloaded
              localFilePath: newName, // Store just the filename for persistence
              duration: metadata?.duration,
              isImported: true, // Mark as imported
            );

            // Persist song metadata
            await prefs.setString('song_${newSong.id}', jsonEncode(newSong.toJson()));
            
            // Auto-fetch metadata if enabled
            final autoFetchService = AutoFetchService();
            await autoFetchService.autoFetchMetadataForNewImport(newSong);
            
            importCount++;
          } catch (e) {
            debugPrint('Error processing file $origName: $e');
            // Optionally, delete partially copied file if error occurs during metadata/saving
            final tempFile = File(destPath);
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          }
        }

        // await _loadDownloadedSongs(); // This will be triggered by _onSongDataChanged if CurrentSongProvider notifies appropriately
                                // For direct import, if CurrentSongProvider isn't involved in notifying about these new files,
                                // calling _loadDownloadedSongs() directly or ensuring a notification path is valid.
                                // The listener _onSongDataChanged should handle updates if songs are managed via CurrentSongProvider.
                                // If import directly modifies SharedPreferences, then _loadDownloadedSongs() is the correct refresh.
                                // The listener _onSongDataChanged should ideally be triggered if these new songs are "globally" announced.
                                // For now, assuming the provider pattern will eventually lead to a notification.
                                // If not, a direct call to _loadDownloadedSongs() here after the loop would be needed.
                                // However, the current structure relies on listeners.

        if (context.mounted) {
          scaffoldMessenger.removeCurrentSnackBar();
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text('$importCount song(s) imported successfully.')),
          );
        }
        // Manually trigger a reload if the provider pattern doesn't cover this specific import case for notifications.
        // This ensures the UI updates immediately after import.
        if (importCount > 0) {
            _loadDownloadedSongs(); // This will also trigger sorting // Comment updated, sorting is removed
        }
      } else {
        // User canceled the picker or no files selected
        if (context.mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('No songs selected for import.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error importing songs: $e');
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('An error occurred during import: $e')),
        );
      }
    }
  }

  // ignore: unused_element
  Widget _buildPlaylistsView() {
    List<Playlist> filteredPlaylists = _playlists;
    if (_searchQuery.isNotEmpty) {
      filteredPlaylists = _playlists
          .where((playlist) =>
              playlist.name.toLowerCase().contains(_searchQuery))
          .toList();
    }

    return Column( // Wrap content in a Column
      children: [
        Expanded( // Make ListView take remaining space
          child: filteredPlaylists.isEmpty
              ? Center(child: Text(_searchQuery.isNotEmpty ? 'No playlists found matching "$_searchQuery".' : 'No playlists yet. Create one using the button below!')) // Updated text
              : ListView.builder(
                  itemCount: filteredPlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = filteredPlaylists[index];
                    
                    // Logic to determine leading widget based on album art
                    List<String> uniqueAlbumArtUrls = playlist.songs
                        .map((song) => song.albumArtUrl)
                        .where((artUrl) => artUrl.isNotEmpty)
                        .toSet() // Get unique URLs
                        .toList();

                    Widget leadingWidget;
                    const double leadingSize = 56.0;

                    if (uniqueAlbumArtUrls.isEmpty) {
                      leadingWidget = Icon(Icons.playlist_play, size: leadingSize, color: Theme.of(context).colorScheme.primary);
                    } else if (uniqueAlbumArtUrls.length < 4) {
                      leadingWidget = _buildPlaylistArtWidget(uniqueAlbumArtUrls.first, leadingSize);
                    } else {
                      // Display a 2x2 grid of the first 4 album arts
                      List<Widget> gridImages = uniqueAlbumArtUrls
                          .take(4)
                          .map((artUrl) => _buildPlaylistArtWidget(artUrl, leadingSize / 2)) // Each image is half the size
                          .toList();
                      
                      leadingWidget = SizedBox(
                        width: leadingSize,
                        height: leadingSize,
                        child: GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(), // Disable scrolling within the grid
                          mainAxisSpacing: 1, // Optional spacing
                          crossAxisSpacing: 1, // Optional spacing
                          padding: EdgeInsets.zero,
                          children: gridImages,
                        ),
                      );
                    }

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8.0), // Match album art clip
                          child: leadingWidget,
                        ),
                        title: Text(playlist.name, style: Theme.of(context).textTheme.titleMedium),
                        subtitle: Text('${playlist.songs.length} songs', style: Theme.of(context).textTheme.bodySmall),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, color: Colors.red[700]),
                          tooltip: 'Delete Playlist',
                          onPressed: () {
                            _deletePlaylist(context, playlist);
                          },
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => PlaylistDetailScreen(playlist: playlist),
                            ),
                          ).then((_) {
                            // Listener _onPlaylistChanged handles refresh
                          });
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildSavedAlbumsView() { // New method for "Albums" tab
    List<Album> filteredAlbums = _savedAlbums;
    if (_searchQuery.isNotEmpty) {
      filteredAlbums = _savedAlbums
          .where((album) =>
              album.title.toLowerCase().contains(_searchQuery) ||
              album.artistName.toLowerCase().contains(_searchQuery))
          .toList();
    }

    if (filteredAlbums.isEmpty) {
      return Center(child: Text(_searchQuery.isNotEmpty ? 'No albums found matching "$_searchQuery".' : 'No saved albums yet. Find albums in Search and save them!'));
    }

    return ListView.builder(
      itemCount: filteredAlbums.length,
      itemBuilder: (context, index) {
        final album = filteredAlbums[index];
        Widget leadingImage;
        
        // Use the effective album art URL which prioritizes local over network
        final artUrl = album.effectiveAlbumArtUrl;
        if (artUrl.isNotEmpty) {
          if (artUrl.startsWith('http')) {
            // Network image
            leadingImage = Image.network(
              artUrl,
              width: 56, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.album, size: 40),
            );
          } else {
            // Local image - use the same pattern as songs
            leadingImage = FutureBuilder<String>(
              future: _getCachedLocalArtFuture(artUrl),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData &&
                    snapshot.data!.isNotEmpty) {
                  return Image.file(
                    File(snapshot.data!),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.album, size: 40),
                  );
                }
                return const Icon(Icons.album, size: 40);
              },
            );
          }
        } else {
          leadingImage = const Icon(Icons.album, size: 40);
        }

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: leadingImage,
            ),
            title: Text(album.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(album.artistName, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton( // "Unsave" button
              icon: Icon(Icons.bookmark_remove_outlined, color: Theme.of(context).colorScheme.error),
              tooltip: 'Unsave Album',
              onPressed: () async {
                // Show confirmation dialog
                final bool? confirmed = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: Text('Unsave "${album.title}"?'),
                      content: const Text('Are you sure you want to remove this album from your saved albums?'),
                      actions: <Widget>[
                        TextButton(
                          child: const Text('Cancel'),
                          onPressed: () {
                            Navigator.of(context).pop(false); // User canceled
                          },
                        ),
                        TextButton(
                          child: Text('Unsave', style: TextStyle(color: Colors.red[700])),
                          onPressed: () {
                            Navigator.of(context).pop(true); // User confirmed
                          },
                        ),
                      ],
                    );
                  },
                );

                // If user did not confirm, or dismissed the dialog, do nothing
                if (confirmed != true) {
                  return;
                }

                await _albumManager.removeSavedAlbum(album.id);
                final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
                if (mounted && context.mounted) { // Check if the widget is still in the tree
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text('"${album.title}" unsaved.')),
                  );
                }
                // Listener _onSavedAlbumsChanged handles refresh
              },
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlbumScreen(album: album),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Widget _buildDownloadedSongsView() {
    // Do not listen here, we'll scope rebuilds to each item
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    // _songs list already contains completed, downloaded songs
    final List<Song> completedSongs = List.from(_songs);

    final activeDownloadsMap = currentSongProvider.activeDownloadTasks;
    final bool hasActiveDownloads = activeDownloadsMap.isNotEmpty;

    // Filter completed songs if search query is present
    List<Song> songsToDisplay = completedSongs;
    if (_searchQuery.isNotEmpty) {
      songsToDisplay = completedSongs.where((song) {
        return song.title.toLowerCase().contains(_searchQuery) ||
               (song.artist.toLowerCase().contains(_searchQuery));
      }).toList();
    }
    
    return Column( 
      children: [
        if (hasActiveDownloads) 
          Consumer<CurrentSongProvider>( 
            builder: (context, provider, child) {
              final activeCount = provider.activeDownloadTasks.length;
              final queuedCount = provider.songsQueuedForDownload.length;
              final totalDownloadQueueCount = activeCount + queuedCount;

              if (totalDownloadQueueCount == 0) return const SizedBox.shrink(); 

              return Card(
                margin: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 0), 
                child: ListTile(
                  leading: const Icon(Icons.downloading),
                  title: Text('$totalDownloadQueueCount song(s) in download queue...'),
                  subtitle: const Text('Tap to view queue'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 18),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const DownloadQueueScreen()),
                    );
                  },
                ),
              );
            },
          ),
        Expanded( 
          child: songsToDisplay.isEmpty
              ? Center(child: Text(_searchQuery.isNotEmpty ? 'No songs found matching "$_searchQuery".' : 'No downloaded songs yet.'))
              : ListView.builder(
                  itemCount: songsToDisplay.length,
                  itemBuilder: (context, index) {
                    final songObj = songsToDisplay[index];
                    // This ListTile is now only for completed songs

                    return ListTile(
                      key: Key(songObj.id),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: songObj.albumArtUrl.isNotEmpty
                          ? (songObj.albumArtUrl.startsWith('http')
                              ? Image.network(
                                  songObj.albumArtUrl,
                                  width: 40, height: 40, fit: BoxFit.cover, 
                                  errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40), 
                                )
                              : FutureBuilder<String>(
                                  future: (() async {
                                    final dir = await getApplicationDocumentsDirectory();
                                    String artFileName = songObj.albumArtUrl;
                                    if (artFileName.contains(Platform.pathSeparator)) {
                                      artFileName = p.basename(artFileName);
                                    }
                                    final fullPath = p.join(dir.path, artFileName);
                                    if (await File(fullPath).exists()) return fullPath;
                                    return '';
                                  })(),
                                  builder: (context, snap) {
                                    if (snap.connectionState == ConnectionState.done
                                        && snap.hasData && snap.data!.isNotEmpty) {
                                      return Image.file(
                                        File(snap.data!),
                                        width: 40, height: 40, fit: BoxFit.cover, 
                                        errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40), 
                                      );
                                    }
                                    return const Icon(Icons.music_note, size: 40); 
                                  },
                                ))
                          : const Icon(Icons.music_note, size: 40), 
                      ),
                      title: Text(songObj.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(songObj.artist.isNotEmpty ? songObj.artist : "Unknown Artist", maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        tooltip: 'Delete Download',
                        onPressed: () => _deleteDownloadedSong(songObj), // This line remains the same, but the method now has a dialog
                      ),
                      onTap: () async {
                        // When tapping a completed song, play it.
                        // The queue will be set to ALL completed downloaded songs,
                        // respecting the current order of the Downloads tab (load order).
                        final provider = Provider.of<CurrentSongProvider>(context, listen: false);
                        await provider.playWithContext(completedSongs, songObj);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // Helper widget to build album art for playlists (handles local and network)
  Widget _buildPlaylistArtWidget(String artUrl, double size) {
    Widget placeholder = Icon(Icons.music_note, size: size * 0.7, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5));
    
    return SizedBox(
      width: size,
      height: size,
      child: artUrl.startsWith('http')
          ? Image.network(
              artUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => placeholder,
            )
          : FutureBuilder<String>(
              future: _getCachedLocalArtFuture(artUrl),
              key: ValueKey<String>('playlist_art_$artUrl'),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
                  return Image.file(
                    File(snapshot.data!),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder,
                  );
                }
                // Show placeholder while loading or if path is invalid/empty
                return placeholder;
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // pick a small subset of _songs as "recently added"
    final recentSongs = _songs.length > 10 ? _songs.sublist(_songs.length - 10).reversed.toList() : _songs.reversed.toList();

    // Playlists are loaded from SharedPreferences; assuming they are in order of addition or have an ID that can be sorted.
    // For simplicity, let's take the last few playlists. If playlists have a creation timestamp, sort by that.
    // Assuming _playlists are loaded in a somewhat consistent order (e.g., by ID or addition time).
    // To get "recent", we might need to sort them if they have a creation date, or just take the last few.
    // For now, let's take the last 5 added. If PlaylistManager stores them in order of addition, this works.
    // Otherwise, Playlist model would need a creationDate field.
    final recentPlaylists = _playlists.length > 5 ? _playlists.sublist(_playlists.length - 5).reversed.toList() : _playlists.reversed.toList();

    // Similarly for saved albums, take the last few.
    // AlbumManagerService loads them, assuming order of addition or an ID that implies recency.
    final recentSavedAlbums = _savedAlbums.length > 5 ? _savedAlbums.sublist(_savedAlbums.length - 5).reversed.toList() : _savedAlbums.reversed.toList();

    // Take all recent stations, assuming they are already ordered by recency.
    final recentStations = _recentStations;


    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => _onSearchChanged(value),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Search your library...',
                prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurface),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        color: Theme.of(context).colorScheme.onSurface,
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
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
            body: _searchQuery.isNotEmpty
          ? _buildUnifiedSearchResults()
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
          // main categories
          ListTile(
            leading: Icon(Icons.favorite, color: Theme.of(context).colorScheme.primary),
            title: const Text('Liked Songs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.playlist_play, color: Theme.of(context).colorScheme.primary),
            title: const Text('Playlists'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.person, color: Theme.of(context).colorScheme.primary),
            title: const Text('Artists'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ArtistsListScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.album, color: Theme.of(context).colorScheme.primary),
            title: const Text('Albums'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AlbumsListScreen()),
            ),
          ),
          ListTile(
            leading: Icon(Icons.music_note, color: Theme.of(context).colorScheme.primary),
            title: const Text('Songs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SongsScreen()),
            ),
          ),
          Consumer<CurrentSongProvider>(
            builder: (context, provider, child) {
              final active = provider.activeDownloadTasks.length;
              final queued = provider.songsQueuedForDownload.length;
              final total = active + queued;
              if (total == 0) return const SizedBox.shrink();
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: const Icon(Icons.downloading),
                  title: Text('$total song(s) in download queue'),
                  subtitle: const Text('Tap to view queue'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DownloadQueueScreen()),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          // section header
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Jump back in!',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),

          // horizontal carousel of recent songs
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: recentSongs.length,
              itemBuilder: (context, i) {
                final song = recentSongs[i];
                return GestureDetector(
                  onTap: () {
                    final prov = Provider.of<CurrentSongProvider>(context, listen: false);
                    prov.setQueue(recentSongs, initialIndex: i); 
                  },
                  child: Container(
                    width: 140,
                    margin: EdgeInsets.only(right: i == recentSongs.length - 1 ? 0 : 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // artwork
                        SizedBox(
                          width: 140,
                          height: 140,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: song.albumArtUrl.isNotEmpty
                                ? (song.albumArtUrl.startsWith('http')
                                    ? Image.network(song.albumArtUrl, fit: BoxFit.cover)
                                    : FutureBuilder<String>(
                                        future: _getCachedLocalArtFuture(song.albumArtUrl),
                                        key: ValueKey<String>('recent_song_art_${song.id}'),
                                        builder: (_, snap) => (snap.hasData && snap.data!.isNotEmpty)
                                            ? Image.file(File(snap.data!), fit: BoxFit.cover)
                                            : Container(color: Colors.grey[800]),
                                      ))
                                : Container(color: Colors.grey[800]),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // title & artist
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          song.artist.isNotEmpty ? song.artist : 'Unknown Artist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 24),

          // Recently Added Playlists Section
          if (recentPlaylists.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Recently Created Playlists',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190, // Adjust height as needed
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: recentPlaylists.length,
                itemBuilder: (context, i) {
                  final playlist = recentPlaylists[i];
                  
                  List<String> uniqueAlbumArtUrls = playlist.songs
                      .map((song) => song.albumArtUrl)
                      .where((artUrl) => artUrl.isNotEmpty)
                      .toSet()
                      .toList();

                  Widget leadingWidget;
                  const double itemArtSize = 140.0; // Size for the artwork in the carousel

                  if (uniqueAlbumArtUrls.isEmpty) {
                    leadingWidget = Container(
                      width: itemArtSize,
                      height: itemArtSize,
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.playlist_play, size: itemArtSize * 0.6, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                    );
                  } else if (uniqueAlbumArtUrls.length < 4) {
                    leadingWidget = ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _buildPlaylistArtWidget(uniqueAlbumArtUrls.first, itemArtSize));
                  } else {
                    List<Widget> gridImages = uniqueAlbumArtUrls
                        .take(4)
                        .map((artUrl) => _buildPlaylistArtWidget(artUrl, itemArtSize / 2))
                        .toList();
                    
                    leadingWidget = ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: itemArtSize,
                        height: itemArtSize,
                        child: GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: 1,
                          crossAxisSpacing: 1,
                          padding: EdgeInsets.zero,
                          children: gridImages,
                        ),
                      ),
                    );
                  }

                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PlaylistDetailScreen(playlist: playlist),
                        ),
                      );
                    },
                    child: Container(
                      width: 140, // Width of the entire card
                      margin: EdgeInsets.only(right: i == recentPlaylists.length - 1 ? 0 : 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: itemArtSize, // Fixed height for the art part
                            child: leadingWidget,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            '${playlist.songs.length} songs',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Recently Saved Albums Section
          if (recentSavedAlbums.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Recently Saved Albums',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190, // Adjust height as needed, consistent with other carousels
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: recentSavedAlbums.length,
                itemBuilder: (context, i) {
                  final album = recentSavedAlbums[i];
                  const double itemArtSize = 140.0;

                  Widget albumArtWidget;
                  if (album.fullAlbumArtUrl.isNotEmpty) {
                    albumArtWidget = Image.network(
                      album.fullAlbumArtUrl,
                      width: itemArtSize,
                      height: itemArtSize,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: itemArtSize,
                        height: itemArtSize,
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.album, size: itemArtSize * 0.6, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                      ),
                    );
                  } else {
                    albumArtWidget = Container(
                      width: itemArtSize,
                      height: itemArtSize,
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.album, size: itemArtSize * 0.6, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                    );
                  }

                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AlbumScreen(album: album),
                        ),
                      );
                    },
                    child: Container(
                      width: 140, // Width of the entire card
                      margin: EdgeInsets.only(right: i == recentSavedAlbums.length - 1 ? 0 : 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: itemArtSize, // Fixed height for the art part
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: albumArtWidget,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            album.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            album.artistName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Recently Played Radio Stations Section
          if (recentStations.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Recently Played Stations',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190, // Consistent height
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: recentStations.length,
                itemBuilder: (context, i) {
                  final station = recentStations[i];
                  const double itemArtSize = 140.0;

                  Widget stationArtWidget = RadioStationIcon(
                    imageUrl: station.imageUrl,
                    stationId: station.id,
                    size: itemArtSize,
                    borderRadius: BorderRadius.circular(8),
                  );

                  return GestureDetector(
                    onTap: () {
                      // When a recent station is tapped, play it.
                      // The listener _handleRadioStationPlay will automatically move it to the top of recents.
                      final song = Song(
                        id: station.id,
                        title: station.name,
                        artist: 'Radio Station', // Marker for our listener
                        album: 'Live Radio',
                        albumArtUrl: station.imageUrl,
                        audioUrl: station.streamUrl,
                        isDownloaded: false,
                        localFilePath: null,
                        duration: null,
                        isImported: false,
                      );
                      Provider.of<CurrentSongProvider>(context, listen: false).playSong(song);
                    },
                    child: Container(
                      width: 140, // Width of the entire card
                      margin: EdgeInsets.only(right: i == recentStations.length - 1 ? 0 : 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: itemArtSize, // Fixed height for the art part
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: stationArtWidget,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            station.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
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