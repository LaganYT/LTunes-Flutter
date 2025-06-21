import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import 'playlist_detail_screen.dart';
import '../providers/current_song_provider.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});
  @override
  _PlaylistsScreenState createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final _manager = PlaylistManagerService();
  List<Playlist> _playlists = [];

  @override
  void initState() {
    super.initState();
    _manager.addListener(_reload);
    _reload();
  }

  void _reload() {
    setState(() => _playlists = List.from(_manager.playlists));
  }

  @override
  void dispose() {
    _manager.removeListener(_reload);
    super.dispose();
  }

  // helper to build the 2×2 or single‐image preview
  Widget _playlistThumbnail(Playlist playlist) {
    return LayoutBuilder(builder: (_, constraints) {
      final arts = playlist.songs
          .map((s) => s.albumArtUrl)
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList();
      final size = constraints.maxWidth;
      if (arts.isEmpty) {
        return Center(
          child: Icon(
            Icons.playlist_play,
            size: 70,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      if (arts.length == 1) {
        return _buildArtWidget(arts.first, size);
      }
      final grid = arts.take(4).map((url) => _buildArtWidget(url, size / 2)).toList();
      return GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 1,
        crossAxisSpacing: 1,
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: grid,
      );
    });
  }

  Widget _buildArtWidget(String url, double sz) {
    if (url.startsWith('http')) {
      return Image.network(url, width: sz, height: sz, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.music_note, size: 24)));
    }
    // local file case
    return FutureBuilder<String>(
      future: () async {
        final dir = await getApplicationDocumentsDirectory();
        final name = p.basename(url);
        final fp = p.join(dir.path, name);
        return File(fp).existsSync() ? fp : '';
      }(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.done && snap.data!.isNotEmpty) {
          return Image.file(File(snap.data!), width: sz, height: sz, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.music_note, size: 24)));
        }
        return const Center(child: Icon(Icons.music_note, size: 24));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search playlists...',
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
                  _playlists = _manager.playlists.where((playlist) => playlist.name.toLowerCase().contains(query.toLowerCase())).toList();
                });
              },
            ),
          ),
        ),
      ),
      body: _playlists.isEmpty
          ? const Center(child: Text('No playlists yet.'))
          : GridView.builder(
              padding: const EdgeInsets.all(24.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 24.0,
                mainAxisSpacing: 24.0,
                childAspectRatio: 0.75,
              ),
              itemCount: _playlists.length,
              itemBuilder: (context, index) {
                final p = _playlists[index];
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: p)),
                  ),
                  onLongPress: () => _showPlaylistOptions(p),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: 1.0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            color: Colors.grey[800],
                            child: _playlistThumbnail(p),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${p.songs.length} songs',
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
      floatingActionButton: FloatingActionButton(
        onPressed: _createPlaylist,
        child: const Icon(Icons.add),
        tooltip: 'Create Playlist',
      ),
    );
  }

  void _createPlaylist() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(hintText: 'Playlist Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _manager.addPlaylist(Playlist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: result,
        songs: [],
      ));
      _reload();
    }
  }

  void _showPlaylistOptions(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename Playlist'),
              onTap: () {
                Navigator.pop(context);
                _renamePlaylist(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to Queue'),
              onTap: () {
                Navigator.pop(context);
                _addPlaylistToQueue(playlist);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('Delete Playlist', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _deletePlaylist(playlist);
              },
            ),
          ],
        );
      },
    );
  }

  void _renamePlaylist(Playlist playlist) async {
    final nameCtrl = TextEditingController(text: playlist.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != playlist.name) {
      await _manager.renamePlaylist(playlist.id, newName);
    }
  }

  void _deletePlaylist(Playlist playlist) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _manager.removePlaylist(playlist);
    }
  }

  void _addPlaylistToQueue(Playlist playlist) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    for (final song in playlist.songs) {
      currentSongProvider.addToQueue(song);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added ${playlist.songs.length} songs from "${playlist.name}" to queue')),
    );
  }
}