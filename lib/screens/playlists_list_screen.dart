import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/playlist_manager_service.dart';
import 'playlist_detail_screen.dart';

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
        return Icon(
          Icons.playlist_play,
          size: size,
          color: Theme.of(context).colorScheme.primary,
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
        errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 24));
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
            errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 24));
        }
        return const Icon(Icons.music_note, size: 24);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      body: _playlists.isEmpty
          ? const Center(child: Text('No playlists yet.'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Wrap(
                spacing: 16.0,
                runSpacing: 16.0,
                alignment: WrapAlignment.center,
                children: _playlists.map((p) {
                  return GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: p)),
                    ),
                    child: SizedBox(
                      width: 140,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 140,
                            height: 140,
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
                    ),
                  );
                }).toList(),
              ),
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
}