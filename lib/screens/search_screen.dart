import 'package:flutter/material.dart';
import '../models/song.dart';
import 'song_detail_screen.dart';
import '../services/api_service.dart';
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  late Future<List<Song>> _songsFuture;
  late Future<List<dynamic>> _stationsFuture;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _fetchSongs();
    _stationsFuture = _fetchRadioStations(); // Initialize _stationsFuture here
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0); // Set default tab to "Music"
  }

  void _fetchSongs() {
    _songsFuture = ApiService().fetchSongs(_searchQuery);
  }

  Future<List<dynamic>> _fetchRadioStations() async {
    final url = Uri.parse('https://ltn-api.vercel.app/api/radio${_searchQuery.isNotEmpty ? '?name=$_searchQuery' : ''}');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        try {
          return json.decode(response.body) as List<dynamic>;
        } catch (e) {
          throw Exception('Error decoding JSON: $e\nResponse body: ${response.body}');
        }
      } else if (response.statusCode == 404) {
        return []; // Return an empty list if no stations are found
      } else {
        throw Exception('Failed to load radio stations. Status code: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching radio stations: $e');
    }
  }

  void _onSearch(String value) {
    setState(() {
      _searchQuery = value.trim();
      _fetchSongs();
      _stationsFuture = _fetchRadioStations();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Search music or radio...',
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
                fillColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.grey[200],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Music'),
              Tab(text: 'Radio'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMusicTab(),
                _buildRadioTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMusicTab() {
    return FutureBuilder<List<Song>>(
      future: _songsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error: ${snapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No songs found.'));
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
                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.music_note, size: 40),
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
                  Navigator.of(context, rootNavigator: true).pop();
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
            );
          },
        );
      },
    );
  }

  Widget _buildRadioTab() {
    return FutureBuilder<List<dynamic>>(
      future: _stationsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error: ${snapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No radio stations found.'));
        }

        final stations = snapshot.data!;
        return ListView.builder(
          itemCount: stations.length,
          itemBuilder: (context, index) {
            final station = stations[index];
            return ListTile(
              leading: station['favicon'] != null && station['favicon'].isNotEmpty
                  ? Image.network(
                      station['favicon'],
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.radio, size: 50),
                    )
                  : const Icon(Icons.radio, size: 50),
              title: Text(
                station['name'] ?? 'Unknown Station',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                station['country'] ?? 'Unknown Country',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                final url = station['url_resolved'];
                if (url != null && url.isNotEmpty) {
                  Provider.of<CurrentSongProvider>(context, listen: false).playStream(
                    url,
                    stationName: station['name'] ?? 'Unknown Station',
                    stationFavicon: station['favicon'],
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Stream URL not available, try another station')),
                  );
                }
              },
            );
          },
        );
      },
    );
  }
}
