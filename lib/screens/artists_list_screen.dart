import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import 'songs_list_screen.dart';

class ArtistsListScreen extends StatefulWidget {
  const ArtistsListScreen({super.key});
  @override
  _ArtistsListScreenState createState() => _ArtistsListScreenState();
}

class _ArtistsListScreenState extends State<ArtistsListScreen> {
  List<Song> _songs = [];
  List<String> _artists = [];
  List<String> _allArtists = []; // Keep a copy of all artists for search

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final all = prefs.getKeys().where((k) => k.startsWith('song_'));
    final temp = <Song>[];
    for (var k in all) {
      final json = prefs.getString(k);
      if (json != null) temp.add(Song.fromJson(jsonDecode(json)));
    }
    final uniq = temp.map((s) => s.artist).toSet().toList()..sort();
    setState(() {
      _songs = temp;
      _artists = uniq;
      _allArtists = uniq; // Initialize the copy
    });
  }

  /// Loads network or local image, falls back to placeholder on error.
  Widget _artistImage(String artUrl) {
    if (artUrl.isEmpty || !artUrl.startsWith('http')) {
      return const Icon(Icons.person, size: 80, color: Colors.white54);
    }
    return CachedNetworkImage(
      imageUrl: artUrl,
      fit: BoxFit.cover,
      placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
      errorWidget: (context, url, error) => const Icon(Icons.person, size: 80, color: Colors.white54),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Artists'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search artists...',
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
                  _artists = _allArtists.where((artist) => artist.toLowerCase().contains(query.toLowerCase())).toList();
                });
              },
            ),
          ),
        ),
      ),
      body: _artists.isEmpty
          ? const Center(child: Text('No artists found.'))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.8,
              ),
              itemCount: _artists.length,
              itemBuilder: (c, i) {
                final name = _artists[i];
                final arts = _songs
                    .where((s) => s.artist == name && s.albumArtUrl.isNotEmpty)
                    .map((s) => s.albumArtUrl)
                    .toList();
                final artUrl = arts.isNotEmpty ? arts.first : '';
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SongsScreen(artistFilter: name),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: 1.0,
                        child: ClipOval(
                          child: _artistImage(artUrl),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
