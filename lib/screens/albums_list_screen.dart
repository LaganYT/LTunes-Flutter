import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/album.dart';
import '../services/album_manager_service.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import 'album_screen.dart';
import '../widgets/playbar.dart';

class AlbumsListScreen extends StatefulWidget {
  const AlbumsListScreen({super.key});
  @override
  _AlbumsListScreenState createState() => _AlbumsListScreenState();
}

class _AlbumsListScreenState extends State<AlbumsListScreen> {
  final _manager = AlbumManagerService();
  List<Album> _albums = [];

  @override
  void initState() {
    super.initState();
    _manager.addListener(_reload);
    _reload();
  }

  void _reload() {
    setState(() => _albums = List.from(_manager.savedAlbums));
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
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              onChanged: (query) {
                setState(() {
                  _albums = _manager.savedAlbums.where((album) => album.title.toLowerCase().contains(query.toLowerCase())).toList();
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
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
                  ),
                  onLongPress: () => _showAlbumOptions(context, a),
                  child: Column(
                    children: [
                      AspectRatio(
                        aspectRatio: 1.0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4.0),
                          child: Container(
                            child: a.fullAlbumArtUrl.startsWith('http')
                                ? CachedNetworkImage(
                                    imageUrl: a.fullAlbumArtUrl,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 300,
                                    memCacheHeight: 300,
                                    placeholder: (context, url) =>
                                        const Center(child: Icon(Icons.album, size: 40)),
                                    errorWidget: (context, url, error) =>
                                        const Center(child: Icon(Icons.error, size: 40)),
                                  )
                                : const Center(child: Icon(Icons.album, size: 40)),
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
      bottomNavigationBar: const Padding(
        padding: EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 24.0),
        child: Playbar(),
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
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to Playlist'),
              onTap: () async {
                Navigator.pop(context);
                await _addAlbumToPlaylist(context, album);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('Unsave Album', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
    final TextEditingController _searchController = TextEditingController();
    List<Playlist> _filteredPlaylists = List.from(playlists);

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
                        child: const Text('New playlist', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              decoration: InputDecoration(
                                hintText: 'Find playlist',
                                prefixIcon: Icon(Icons.search, color: Theme.of(context).iconTheme.color?.withOpacity(0.7)),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24.0),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  _filteredPlaylists = playlists
                                      .where((playlist) => playlist.name.toLowerCase().contains(value.toLowerCase()))
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
                      child: _filteredPlaylists.isEmpty
                          ? Center(
                              child: Text(
                                _searchController.text.isNotEmpty ? 'No playlists found.' : 'No playlists available.',
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: _filteredPlaylists.length,
                              itemBuilder: (BuildContext context, int index) {
                                final playlist = _filteredPlaylists[index];
                                return ListTile(
                                  leading: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4.0),
                                      child: Container(color: Colors.grey), // Replace with playlist art logic
                                    ),
                                  ),
                                  title: Text(playlist.name),
                                  subtitle: Text('${playlist.songs.length} songs'),
                                  onTap: () async {
                                    for (final track in album.tracks) {
                                      await playlistManager.addSongToPlaylist(playlist, track);
                                    }
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Added album to playlist: ${playlist.name}')),
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
    await albumManager.removeSavedAlbum(album.id);
    setState(() => _albums.removeWhere((a) => a.id == album.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Album unsaved: ${album.title}')),
    );
  }
}
