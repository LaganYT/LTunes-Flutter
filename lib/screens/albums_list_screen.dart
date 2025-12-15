import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/album.dart';
import '../services/album_manager_service.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import 'album_screen.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/artwork_service.dart'; // Import centralized artwork service
import '../services/haptic_service.dart'; // Import HapticService
import '../providers/current_song_provider.dart';

double _getSafeIconSize(double? width) {
  // Ensure we have a safe, finite icon size
  final safeWidth = width ?? 48.0;
  if (!safeWidth.isFinite || safeWidth <= 0) {
    return 24.0; // Default safe size
  }
  return (safeWidth * 0.6).clamp(16.0, 48.0);
}

double _getSafeDimension(double? dimension) {
  // Ensure we have a safe, finite dimension
  final safeDim = dimension ?? 48.0;
  if (!safeDim.isFinite || safeDim <= 0) {
    return 48.0; // Default safe size
  }
  return safeDim.clamp(16.0, double.infinity);
}

Future<ImageProvider> getRobustArtworkProvider(String artUrl) async {
  // Use centralized artwork service for consistent handling
  return await artworkService.getArtworkProvider(artUrl);
}

Widget robustArtwork(String artUrl,
    {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  return FutureBuilder<ImageProvider>(
    future: getRobustArtworkProvider(artUrl),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          snapshot.hasData) {
        return Image(
          image: snapshot.data!,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => Container(
            width: _getSafeDimension(width),
            height: _getSafeDimension(height),
            color: Colors.grey[700],
            child: Icon(Icons.music_note,
                size: _getSafeIconSize(width), color: Colors.white70),
          ),
        );
      }
      return Container(
        width: _getSafeDimension(width),
        height: _getSafeDimension(height),
        color: Colors.grey[700],
        child: Icon(Icons.music_note,
            size: _getSafeIconSize(width), color: Colors.white70),
      );
    },
  );
}

class AlbumsListScreen extends StatefulWidget {
  const AlbumsListScreen({super.key});
  @override
  State<AlbumsListScreen> createState() => _AlbumsListScreenState();
}

class _AlbumsListScreenState extends State<AlbumsListScreen> {
  final _manager = AlbumManagerService();
  List<Album> _albums = [];
  ImageProvider? _currentArtProvider;
  String? _currentArtKey;
  bool _artLoading = false;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_reload);
    _reload();
  }

  void _reload() {
    setState(() => _albums = List.from(_manager.savedAlbums));
  }

  Future<void> _updateArtProvider(String artUrl) async {
    setState(() {
      _artLoading = true;
    });
    try {
      _currentArtProvider = await artworkService.getArtworkProvider(artUrl);
    } catch (e) {
      debugPrint('Error loading artwork: $e');
      _currentArtProvider = null;
    }
    _currentArtKey = artUrl;
    if (mounted) {
      setState(() {
        _artLoading = false;
      });
    }
  }

  ImageProvider getArtworkProvider(String artUrl) {
    if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
    if (artUrl.startsWith('http')) {
      return CachedNetworkImageProvider(artUrl);
    } else {
      // For local files, we need to resolve the path properly
      // This method is kept for backward compatibility but should use the service
      return FileImage(File(artUrl));
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Albums'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48.0),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search albums...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24.0),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                hintStyle: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7)),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              onChanged: (query) {
                setState(() {
                  _albums = _manager.savedAlbums
                      .where((album) => album.title
                          .toLowerCase()
                          .contains(query.toLowerCase()))
                      .toList();
                });
              },
            ),
          ),
        ),
      ),
      body: _albums.isEmpty
          ? const Center(child: Text('No saved albums yet.'))
          : GridView.builder(
              padding: const EdgeInsets.all(24.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 24.0,
                mainAxisSpacing: 24.0,
                childAspectRatio: 0.75,
              ),
              itemCount: _albums.length,
              itemBuilder: (context, index) {
                final a = _albums[index];
                return GestureDetector(
                  onTap: () async {
                    await HapticService().lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
                    );
                  },
                  onLongPress: () async {
                    await HapticService().lightImpact();
                    _showAlbumOptions(context, a);
                  },
                  child: Column(
                    children: [
                      AspectRatio(
                        aspectRatio: 1.0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4.0),
                          child: Container(
                            child: robustArtwork(a.effectiveAlbumArtUrl,
                                width: double.infinity,
                                height: double.infinity),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        a.title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        a.artistName,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _showAlbumOptions(BuildContext context, Album album) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play Album'),
              onTap: () async {
                await HapticService().lightImpact();
                Navigator.pop(context);
                _playAlbum(album);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('View Details'),
              onTap: () async {
                await HapticService().lightImpact();
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AlbumScreen(album: album)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('View Artist'),
              onTap: () async {
                await HapticService().lightImpact();
                Navigator.pop(context);
                _viewArtist(album);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to Playlist'),
              onTap: () async {
                Navigator.pop(context);
                await _addAlbumToPlaylist(context, album);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Unsave Album',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                Navigator.pop(context);
                await _unsaveAlbum(album);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _addAlbumToPlaylist(BuildContext context, Album album) async {
    final playlistManager = PlaylistManagerService();
    final playlists = playlistManager.playlists;
    final TextEditingController searchController = TextEditingController();
    List<Playlist> filteredPlaylists = List.from(playlists);

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Center(child: Text('Add to playlist')),
              contentPadding: const EdgeInsets.fromLTRB(16.0, 20.0, 16.0, 0),
              content: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.of(context).size.height * 0.6,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24.0),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () {
                          // Implement new playlist creation logic here
                        },
                        child: const Text('New playlist',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: searchController,
                              decoration: InputDecoration(
                                hintText: 'Find playlist',
                                prefixIcon: Icon(Icons.search,
                                    color: Theme.of(context)
                                        .iconTheme
                                        .color
                                        ?.withValues(alpha: 0.7)),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24.0),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                contentPadding: const EdgeInsets.symmetric(
                                    vertical: 0, horizontal: 16),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  filteredPlaylists = playlists
                                      .where((playlist) => playlist.name
                                          .toLowerCase()
                                          .contains(value.toLowerCase()))
                                      .toList();
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filteredPlaylists.isEmpty
                          ? Center(
                              child: Text(
                                searchController.text.isNotEmpty
                                    ? 'No playlists found.'
                                    : 'No playlists available.',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filteredPlaylists.length,
                              itemBuilder: (BuildContext context, int index) {
                                final playlist = filteredPlaylists[index];
                                return ListTile(
                                  leading: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4.0),
                                      child: Container(
                                          color: Colors
                                              .grey), // Replace with playlist art logic
                                    ),
                                  ),
                                  title: Text(playlist.name),
                                  subtitle:
                                      Text('${playlist.songs.length} songs'),
                                  onTap: () async {
                                    final navigator = Navigator.of(context);
                                    final scaffoldMessenger =
                                        ScaffoldMessenger.of(context);
                                    for (final track in album.tracks) {
                                      await playlistManager.addSongToPlaylist(
                                          playlist, track);
                                    }
                                    navigator.pop();
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              'Added album to playlist: ${playlist.name}')),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _unsaveAlbum(Album album) async {
    final albumManager = AlbumManagerService();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    await albumManager.removeSavedAlbum(album.id);
    setState(() => _albums.removeWhere((a) => a.id == album.id));
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Album unsaved: ${album.title}')),
    );
  }

  void _playAlbum(Album album) {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    if (album.tracks.isNotEmpty) {
      currentSongProvider.smartPlayWithContext(album.tracks, album.tracks.first);
    }
  }

  void _viewArtist(Album album) {
    // Navigate to artist screen - for now, we'll just show a placeholder
    // since the app doesn't seem to have a dedicated artist screen
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Artist: ${album.artistName}')),
    );
  }
}
