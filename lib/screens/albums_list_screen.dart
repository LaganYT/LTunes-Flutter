import 'package:flutter/material.dart';
import '../models/album.dart';
import '../services/album_manager_service.dart';
import 'album_screen.dart';

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
      appBar: AppBar(title: const Text('Albums')),
      body: _albums.isEmpty
          ? const Center(child: Text('No saved albums yet.'))
          : ListView.builder(
              itemCount: _albums.length,
              itemBuilder: (c, i) {
                final a = _albums[i];
                return ListTile(
                  leading: a.fullAlbumArtUrl.isNotEmpty
                      ? Image.network(a.fullAlbumArtUrl, width: 40, height: 40, fit: BoxFit.cover)
                      : const Icon(Icons.album),
                  title: Text(a.title),
                  subtitle: Text(a.artistName),
                  trailing: IconButton(
                    icon: const Icon(Icons.bookmark_remove, color: Colors.red),
                    onPressed: () => _manager.removeSavedAlbum(a.id),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
                  ),
                );
              },
            ),
    );
  }
}
