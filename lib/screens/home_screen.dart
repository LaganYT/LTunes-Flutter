import 'package:flutter/material.dart';
import '../models/song.dart';
import 'song_detail_screen.dart';
import '../services/api_service.dart';
import 'package:provider/provider.dart';
import '../main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<Song>> _songsFuture;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchSongs();
  }

  void _fetchSongs() {
    _songsFuture = ApiService().fetchSongs(_searchQuery);
  }

  Future<void> _refresh() async {
    setState(() {
      _fetchSongs();
    });
    await _songsFuture;
  }

  void _onSearch(String value) {
    setState(() {
      _searchQuery = value.trim();
      _fetchSongs();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LTunes'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onSubmitted: _onSearch,
              decoration: InputDecoration(
                hintText: 'Search songs or artists...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearch('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[200],
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Song>>(
          future: _songsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            } else if (snapshot.hasError) {
              return ListView(
                children: const [
                  SizedBox(height: 200),
                  Center(child: Text('Something went wrong. Please try again.')),
                ],
              );
            } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 200),
                  Center(child: Text('No songs found.')),
                ],
              );
            }
            final songs = snapshot.data!;
            return ListView.separated(
              itemCount: songs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final song = songs[index];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      song.albumArtUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.music_note, size: 40),
                    ),
                  ),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SongDetailScreen(song: song),
                        ),
                      );
                    },
                  ),
                  onTap: () {
                    // Play song
                    Provider.of<CurrentSongProvider>(context, listen: false).playSong(song);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
