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
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.0, // make the overall tile square
              ),
              itemCount: _albums.length,
              itemBuilder: (c, i) {
                final a = _albums[i];
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                     Expanded(
                       child: ClipRRect(
                         borderRadius: BorderRadius.circular(8),
                         child: Container(
                           color: Colors.white,
                           child: a.fullAlbumArtUrl.isNotEmpty
                               ? Image.network(
                                   a.fullAlbumArtUrl,
                                   fit: BoxFit.cover,
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
    );
  }
}
