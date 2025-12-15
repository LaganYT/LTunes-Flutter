import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import 'songs_list_screen.dart';
import '../services/haptic_service.dart'; // Import HapticService
import 'package:path_provider/path_provider.dart';
import 'dart:io' as io;
import 'package:path/path.dart' as p;

class ArtistsListScreen extends StatefulWidget {
  const ArtistsListScreen({super.key});
  @override
  ArtistsListScreenState createState() => ArtistsListScreenState();
}

class ArtistsListScreenState extends State<ArtistsListScreen> {
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
    final appDocDir = await getApplicationDocumentsDirectory();
    const String downloadsSubDir = 'ltunes_downloads';
    for (var k in all) {
      final json = prefs.getString(k);
      if (json != null) {
        try {
          final song = Song.fromJson(jsonDecode(json));
          if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
            final file = io.File(p.join(appDocDir.path, downloadsSubDir, song.localFilePath!));
            if (await file.exists()) {
              temp.add(song);
            }
          }
        } catch (_) {}
      }
    }
    final uniq = temp
        .map((s) => s.artist)
        .where((artist) => artist.isNotEmpty && temp.any((song) => song.artist == artist))
        .toSet()
        .toList()
      ..sort();
    setState(() {
      _songs = temp;
      _artists = uniq;
      _allArtists = uniq; // Initialize the copy
    });
  }

  /// Loads network or local image, falls back to placeholder on error.
  Widget _artistImage(String artUrl) {
    if (artUrl.isEmpty) {
      return const Icon(Icons.person, size: 80, color: Colors.white54);
    }
    if (artUrl.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: artUrl,
        fit: BoxFit.cover,
        placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
        errorWidget: (context, url, error) => const Icon(Icons.person, size: 80, color: Colors.white54),
      );
    } else {
      // Local file case: resolve the full path and display with Image.file
      return FutureBuilder<String>(
        future: (() async {
          final dir = await getApplicationDocumentsDirectory();
          final fname = p.basename(artUrl);
          final path = p.join(dir.path, fname);
          return await io.File(path).exists() ? path : '';
        })(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
            return Image.file(
              io.File(snapshot.data!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 80, color: Colors.white54),
            );
          }
          return const Icon(Icons.person, size: 80, color: Colors.white54);
        },
      );
    }
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
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              onChanged: (query) {
                setState(() {
                  // Only include artists that have at least one song in the library after filtering
                  _artists = _allArtists
                      .where((artist) => artist.toLowerCase().contains(query.toLowerCase()) &&
                          _songs.any((song) => song.artist == artist))
                      .toList();
                });
              },
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          _artists.isEmpty
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
                      onTap: () async {
                        await HapticService().lightImpact();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SongsScreen(artistFilter: name),
                          ),
                        );
                      },
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
        ],
      ),
    );
  }
}
