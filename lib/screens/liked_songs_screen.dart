import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart'; // ensure this is present
import 'package:path/path.dart' as p;
// ignore: unused_import
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart';
import 'song_detail_screen.dart'; // for AddToPlaylistDialog

class LikedSongsScreen extends StatefulWidget {
  const LikedSongsScreen({Key? key}) : super(key: key);
  @override
  _LikedSongsScreenState createState() => _LikedSongsScreenState();
  }

class _LikedSongsScreenState extends State<LikedSongsScreen> {
  List<Song> _likedSongs = [];

  @override
  void initState() {
    super.initState();
    _loadLikedSongs();
    Provider.of<CurrentSongProvider>(context, listen: false).addListener(_onSongDataChanged);
  }

  @override
  void dispose() {
    Provider.of<CurrentSongProvider>(context, listen: false).removeListener(_onSongDataChanged);
    super.dispose();
  }

  void _onSongDataChanged() {
    if (mounted) {
      _loadLikedSongs();
    }
  }

  Future<void> _loadLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final raw = prefs.getStringList('liked_songs') ?? [];
    final songs = raw.map((s) {
      try {
        final songData = jsonDecode(s) as Map<String, dynamic>;
        final songId = songData['id'];
        // Check for an updated canonical version in SharedPreferences
        final canonicalSongJson = prefs.getString('song_$songId');
        if (canonicalSongJson != null) {
          return Song.fromJson(jsonDecode(canonicalSongJson) as Map<String, dynamic>);
        }
        return Song.fromJson(songData);
      } catch (_) {
        return null;
      }
    }).whereType<Song>().toList();

    if (mounted) {
      try {
        setState(() {
          _likedSongs = songs;
        });
      } catch (_) {
        // Widget no longer mounted, ignore
      }
    }
  }

  Future<void> _removeLikedSong(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('liked_songs') ?? [];
    raw.removeWhere((s) {
      try {
        return (jsonDecode(s) as Map<String, dynamic>)['id'] == song.id;
      } catch (_) {
        return false;
      }
    });
    await prefs.setStringList('liked_songs', raw);
    if (!mounted) return;
    setState(() => _likedSongs.removeWhere((s) => s.id == song.id));
  }

  Future<void> _downloadAllLikedSongs() async {
    final songsToDownload = (await Future.wait(_likedSongs.map((song) async {
      if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = p.join(directory.path, song.localFilePath!);
        if (await File(filePath).exists()) {
          return null;
        }
      }
      return song;
    })))
        .whereType<Song>()
        .toList();

    if (!mounted) return;

    if (songsToDownload.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All liked songs are already downloaded.')),
      );
      return;
    }

    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    for (final song in songsToDownload) {
      currentSongProvider.queueSongForDownload(song);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued ${songsToDownload.length} songs for download.')),
    );
  }

  // resolve a local art filename to a full path or return empty
  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    final dir = await getApplicationDocumentsDirectory();
    final full = p.join(dir.path, p.basename(fileName));
    return await File(full).exists() ? full : '';
  }

  // format a Duration into human-friendly string
  String _formatDuration(Duration d) {
    String two(int n)=>n.toString().padLeft(2,'0');
    final m = two(d.inMinutes.remainder(60)), s = two(d.inSeconds.remainder(60));
    if (d.inHours>0) return "${d.inHours} hr $m min";
    if (d.inMinutes>0) return "$m min $s sec";
    return "$s sec";
  }

  // sum up liked songs durations
  String _calculateAndFormatPlaylistDuration() {
    if (_likedSongs.isEmpty) return "0 sec";
    Duration total=Duration.zero;
    for(var s in _likedSongs){
      if (s.duration != null) total += s.duration!;
    }
    return total == Duration.zero ? "N/A" : _formatDuration(total);
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<CurrentSongProvider>(context, listen: false);
    final hasSongs = _likedSongs.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        centerTitle: true,
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 16, left: 20, right: 20, bottom: 16),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Heart icon collage placeholder
                      Container(
                        width: 120, height: 120,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Colors.grey[700],
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: Center(
                          child: Icon(
                            Icons.favorite,
                            color: Theme.of(context).colorScheme.secondary,
                            size: 64,
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // Info & buttons
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text('Liked Songs',
                                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('${_likedSongs.length} songs',
                                style: Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 2),
                            Text(_calculateAndFormatPlaylistDuration(),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[400])),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Play & Shuffle
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: hasSongs
                              ? () async {
                                  // Always use canonical downloaded versions
                                  final provider = Provider.of<CurrentSongProvider>(context, listen: false);
                                  await provider.setQueue(_likedSongs, initialIndex: 0);
                                  provider.playSong(_likedSongs.first);
                                }
                              : null,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play All'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: hasSongs
                              ? () async {
                                  final provider = Provider.of<CurrentSongProvider>(context, listen: false);
                                  if (!provider.isShuffling) provider.toggleShuffle();
                                  await provider.setQueue(_likedSongs, initialIndex: 0);
                                }
                              : null,
                          icon: const Icon(Icons.shuffle),
                          label: const Text('Shuffle'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Download & Remove
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: hasSongs ? _downloadAllLikedSongs : null,
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Download'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!hasSongs)
            SliverFillRemaining(
              child: Center(child: Text('No liked songs yet.', style: Theme.of(context).textTheme.bodyLarge)),
            )
          else ...[
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final song = _likedSongs[i];
                  return Dismissible(
                    key: Key(song.id),
                    direction: DismissDirection.horizontal,
                    confirmDismiss: (direction) async {
                      if (direction == DismissDirection.startToEnd) {
                        provider.addToQueue(song);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('${song.title} added to queue')),
                        );
                        return false;
                      } else if (direction == DismissDirection.endToStart) {
                        showDialog(
                          context: context,
                          builder: (_) => AddToPlaylistDialog(song: song),
                        );
                        return false;
                      }
                      return false;
                    },
                    background: Container(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                      child: Row(
                        children: [
                          Icon(Icons.playlist_add, color: Theme.of(context).colorScheme.onPrimary),
                          const SizedBox(width: 8),
                          Text('Add to Queue', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
                        ],
                      ),
                    ),
                    secondaryBackground: Container(
                      color: Theme.of(context).colorScheme.secondary.withOpacity(0.8),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('Add to Playlist', style: TextStyle(color: Theme.of(context).colorScheme.onSecondary)),
                          const SizedBox(width: 8),
                          Icon(Icons.library_add, color: Theme.of(context).colorScheme.onSecondary),
                        ],
                      ),
                    ),
                    child: ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4.0),
                        child: song.albumArtUrl.isNotEmpty
                            ? (song.albumArtUrl.startsWith('http')
                                ? CachedNetworkImage(
                                    imageUrl: song.albumArtUrl,
                                    width: 40,
                                    height: 40,
                                    memCacheWidth: 80,
                                    memCacheHeight: 80,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => const Icon(Icons.album, size: 40),
                                    errorWidget: (context, url, error) => const Icon(Icons.error, size: 40),
                                  )
                                : FutureBuilder<String>(
                                    future: _resolveLocalArtPath(song.albumArtUrl),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                                        return Image.file(
                                          File(snapshot.data!),
                                          width: 40,
                                          height: 40,
                                          cacheWidth: 80,
                                          cacheHeight: 80,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.error, size: 40),
                                        );
                                      }
                                      if (snapshot.connectionState == ConnectionState.waiting) {
                                        return const Icon(Icons.album, size: 40);
                                      }
                                      return const Icon(Icons.error, size: 40);
                                    },
                                  ))
                            : const Icon(Icons.album, size: 40),
                      ),
                      title: Text(song.title),
                      subtitle: Text(song.artist),
                      // swap delete icon for heart
                      trailing: IconButton(
                        icon: Icon(Icons.favorite, color: Theme.of(context).colorScheme.secondary),
                        onPressed: () => _removeLikedSong(song),
                      ),
                      onTap: () {
                        // queue all liked songs and play starting at this one
                        provider.setQueue(_likedSongs, initialIndex: i);
                      },
                    ),
                  );
                },
                childCount: _likedSongs.length,
              ),
            ),
          ],
        ],
      ),
    );
  }
}