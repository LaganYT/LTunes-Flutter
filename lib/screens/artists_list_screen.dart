import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    setState(() { _songs = temp; _artists = uniq; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Artists')),
      body: _artists.isEmpty
          ? const Center(child: Text('No artists found.'))
          : ListView.builder(
              itemCount: _artists.length,
              itemBuilder: (c, i) {
                final name = _artists[i];
                final count = _songs.where((s) => s.artist == name).length;
                return ListTile(
                  title: Text(name),
                  subtitle: Text('$count songs'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SongsScreen(artistFilter: name),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
