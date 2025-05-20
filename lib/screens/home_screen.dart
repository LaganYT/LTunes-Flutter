import 'package:flutter/material.dart';
import '../models/song.dart';
import 'song_detail_screen.dart';
import '../services/api_service.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';

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

  void _onSlideToQueue(Song song) {
    // Logic to add the song to the queue
    final currentQueueProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    currentQueueProvider.addToQueue(song);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onSubmitted: _onSearch,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Search songs or artists...',
                hintStyle: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[700]),
                prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurface),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        color: Theme.of(context).colorScheme.onSurface,
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
                fillColor: isDark ? Colors.grey[900] : Colors.grey[200],
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<List<Song>>(
              future: _songsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  // Show empty list, loading handled by overlay below
                  return ListView();
                } else if (snapshot.hasError) {
                  return ListView(
                    children: [
                      const SizedBox(height: 200),
                      Center(
                        child: Text(
                          'Something went wrong. Please try again.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                        ),
                      ),
                    ],
                  );
                } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return ListView(
                    children: [
                      const SizedBox(height: 200),
                      Center(
                        child: Text(
                          'No songs found.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                        ),
                      ),
                    ],
                  );
                }
                final songs = snapshot.data!;
                return ListView.separated(
                  itemCount: songs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return GestureDetector(
                      onHorizontalDragEnd: (details) {
                        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
                          _onSlideToQueue(song);
                        }
                      },
                      child: ListTile(
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
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                        ),
                        subtitle: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.info_outline),
                          color: Theme.of(context).colorScheme.onSurface,
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SongDetailScreen(song: song),
                              ),
                            );
                          },
                        ),
                        onTap: () async {
                          final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (context) => const Center(child: CircularProgressIndicator()),
                          );
                          try {
                            final apiService = ApiService();
                            final audioUrl = await apiService.fetchAudioUrl(song.artist, song.title);
                            Navigator.of(context, rootNavigator: true).pop(); // Remove loading dialog
                            if (audioUrl != null && audioUrl.isNotEmpty) {
                              final songWithAudio = song.copyWith(audioUrl: audioUrl);
                              currentSongProvider.playSong(songWithAudio);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Failed to fetch audio URL.')),
                              );
                            }
                          } catch (e) {
                            Navigator.of(context, rootNavigator: true).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error fetching audio URL: $e')),
                            );
                          }
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Loading animation overlay
          FutureBuilder<List<Song>>(
            future: _songsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Container(
                  color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.7),
                  child: const Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

// TODO: Integrate Chrome media player feature (Media Session API for Flutter web).
// TODO: Integrate iOS/Android media controls using audio_session and platform media controls.
}
