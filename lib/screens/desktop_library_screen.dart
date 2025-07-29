import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/album.dart';
import '../providers/current_song_provider.dart';
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart';
import '../services/auto_fetch_service.dart';
import '../services/unified_search_service.dart';
import 'playlist_detail_screen.dart';
import 'album_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'download_queue_screen.dart';
import 'playlists_list_screen.dart';
import 'artists_list_screen.dart';
import 'albums_list_screen.dart';
import 'songs_list_screen.dart';
import 'liked_songs_screen.dart';
import 'song_detail_screen.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../widgets/unified_search_widget.dart';
import 'package:cached_network_image/cached_network_image.dart';

class DesktopLibraryScreen extends StatefulWidget {
  const DesktopLibraryScreen({super.key});

  @override
  State<DesktopLibraryScreen> createState() => _DesktopLibraryScreenState();
}

class _DesktopLibraryScreenState extends State<DesktopLibraryScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final ValueNotifier<int> _refreshNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool?> usRadioOnlyNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> showRadioTabNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> autoDownloadLikedSongsNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<List<double>> customSpeedPresetsNotifier = ValueNotifier<List<double>>([]);
  final ValueNotifier<bool> listeningStatsEnabledNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool?> autoCheckForUpdatesNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<String> currentAppVersionNotifier = ValueNotifier<String>('Loading...');
  final ValueNotifier<String> latestKnownVersionNotifier = ValueNotifier<String>('N/A');
  final ValueNotifier<bool?> showOnlySavedSongsInAlbumsNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<int> maxConcurrentDownloadsNotifier = ValueNotifier<int>(1);
  final ValueNotifier<int> maxConcurrentPlaylistMatchesNotifier = ValueNotifier<int>(5);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    usRadioOnlyNotifier.value = prefs.getBool('usRadioOnly');
    showRadioTabNotifier.value = prefs.getBool('showRadioTab');
    autoDownloadLikedSongsNotifier.value = prefs.getBool('autoDownloadLikedSongs');
    showOnlySavedSongsInAlbumsNotifier.value = prefs.getBool('showOnlySavedSongsInAlbums');
    maxConcurrentDownloadsNotifier.value = prefs.getInt('maxConcurrentDownloads') ?? 1;
    maxConcurrentPlaylistMatchesNotifier.value = prefs.getInt('maxConcurrentPlaylistMatches') ?? 5;
    
    final customSpeedPresetsJson = prefs.getString('customSpeedPresets');
    if (customSpeedPresetsJson != null) {
      try {
        final List<dynamic> presets = jsonDecode(customSpeedPresetsJson);
        customSpeedPresetsNotifier.value = presets.map<double>((e) => e.toDouble()).toList();
      } catch (e) {
        customSpeedPresetsNotifier.value = [];
      }
    }
    
    autoCheckForUpdatesNotifier.value = prefs.getBool('autoCheckForUpdates');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Column(
        children: [
          // Header with gradient background
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Theme.of(context).colorScheme.surface,
                  Theme.of(context).colorScheme.surface.withOpacity(0.8),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.library_music,
                      color: const Color(0xFFFF9800),
                      size: 32,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Your Library',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 32,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Search bar with Spotify-like styling
                SizedBox(
                  width: 400,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search your library...',
                      hintStyle: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: const Color(0xFFFF9800),
                          width: 2,
                        ),
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Tabs with Spotify-like styling
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                  width: 1,
                ),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Playlists'),
                Tab(text: 'Albums'),
                Tab(text: 'Artists'),
                Tab(text: 'Songs'),
              ],
              labelColor: const Color(0xFFFF9800),
              unselectedLabelColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              indicatorColor: const Color(0xFFFF9800),
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.normal,
                fontSize: 16,
              ),
            ),
          ),
          
          // Content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildPlaylistsTab(),
                _buildAlbumsTab(),
                _buildArtistsTab(),
                _buildSongsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistsTab() {
    return Consumer<PlaylistManagerService>(
      builder: (context, playlistManager, child) {
        final playlists = playlistManager.playlists;
        
        if (playlists.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.playlist_play,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'No playlists yet',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create your first playlist to get started',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    // TODO: Implement create playlist
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Create Playlist'),
                ),
              ],
            ),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 0.8,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            return _buildPlaylistCard(playlist);
          },
        );
      },
    );
  }

  Widget _buildPlaylistCard(Playlist playlist) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaylistDetailScreen(playlist: playlist),
          ),
        );
      },
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                                 decoration: BoxDecoration(
                   color: const Color(0xFFFF9800).withOpacity(0.1), // LTunes orange
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                                 child: Icon(
                   Icons.playlist_play,
                   size: 48,
                   color: const Color(0xFFFF9800), // LTunes orange
                 ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${playlist.songs.length} songs',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumsTab() {
    return Consumer<AlbumManagerService>(
      builder: (context, albumManager, child) {
        final albums = albumManager.savedAlbums;
        
        if (albums.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.album,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'No albums yet',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your saved albums will appear here',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 0.8,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            return _buildAlbumCard(album);
          },
        );
      },
    );
  }

  Widget _buildAlbumCard(Album album) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AlbumScreen(album: album),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: album.effectiveAlbumArtUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: album.effectiveAlbumArtUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      placeholder: (context, url) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.album, size: 48),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.album, size: 48),
                      ),
                    )
                  : Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.album, size: 48),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            album.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            album.artistName,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildArtistsTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Artists',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your favorite artists will appear here',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongsTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_note,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Songs',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your library songs will appear here',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }
} 