import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';

class DownloadedSongsScreen extends StatefulWidget {
  const DownloadedSongsScreen({super.key});
  @override
  _DownloadedSongsScreenState createState() => _DownloadedSongsScreenState();
}

class _DownloadedSongsScreenState extends State<DownloadedSongsScreen> {
  List<Song> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('song_'));
    final dir = await getApplicationDocumentsDirectory();
    final sub = 'ltunes_downloads';
    final temp = <Song>[];
    for (var k in keys) {
      final js = prefs.getString(k);
      if (js == null) continue;
      final s = Song.fromJson(jsonDecode(js));
      if (!s.isDownloaded) continue;
      final path = File('${dir.path}/$sub/${s.localFilePath}');
      if (await path.exists()) temp.add(s);
    }
    setState(() => _songs = temp);
  }

  Future<void> _delete(Song s) async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/ltunes_downloads/${s.localFilePath}');
    if (await f.exists()) await f.delete();
    final prefs = await SharedPreferences.getInstance();
    final updated = s.copyWith(isDownloaded:false, localFilePath:null);
    await prefs.setString('song_${s.id}', jsonEncode(updated.toJson()));
    Provider.of<CurrentSongProvider>(context,listen:false).updateSongDetails(updated);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloaded')),
      body: _songs.isEmpty
          ? const Center(child: Text('No downloaded songs.'))
          : ListView.builder(
              itemCount: _songs.length,
              itemBuilder: (c, i) {
                final s = _songs[i];
                return ListTile(
                  leading: s.albumArtUrl.isNotEmpty
                    ? s.albumArtUrl.startsWith('http')
                      ? Image.network(
                          s.albumArtUrl,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        )
                      : Image.file(
                          File(s.albumArtUrl),
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        )
                    : const Icon(Icons.music_note, size: 40),
                  title: Text(s.title),
                  subtitle: Text(s.artist),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _delete(s),
                  ),
                  onTap: () {
                    final prov = Provider.of<CurrentSongProvider>(context,listen:false);
                    prov.playSong(s);
                    prov.setQueue(_songs, initialIndex: i);
                  },
                );
              },
            ),
    );
  }
}
