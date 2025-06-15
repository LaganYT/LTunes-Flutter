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
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.75, // allow extra height for labels
              ),
              itemCount: _playlists.length,
              itemBuilder: (c, i) {
                final p = _playlists[i];
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: p)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                     AspectRatio(
                       aspectRatio: 1.0, // square cover area
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            color: Colors.white,
                            child: Center(child: _playlistThumbnail(p)),
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
    );
  }
}