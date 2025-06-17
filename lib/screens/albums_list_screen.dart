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
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Wrap(
                spacing: 16.0,
                runSpacing: 16.0,
                alignment: WrapAlignment.center,
                children: _albums.map((a) {
                  return GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AlbumScreen(album: a)),
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
                                child: a.fullAlbumArtUrl.isNotEmpty
                                    ? Image.network(
                                        a.fullAlbumArtUrl,
                                        fit: BoxFit.cover,
                                        width: 140,
                                        height: 140,
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
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }
}
