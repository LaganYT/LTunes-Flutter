import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/playlist_manager.dart';
import '../models/playlist.dart'; // Import the Playlist class from the models folder
import 'playlist_detail_screen.dart'; // Import the PlaylistDetailScreen
import '../providers/current_song_provider.dart'; // Import the CurrentSongProvider

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with TickerProviderStateMixin {
  final PlaylistManager _playlistManager = PlaylistManager();
  List<FileSystemEntity> _songs = [];
  final AudioPlayer audioPlayer = AudioPlayer();
  String? _currentlyPlayingSongPath;
  bool isPlaying = false;
  final TextEditingController _playlistNameController = TextEditingController();
  late TabController _tabController;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    audioPlayer.onPlayerComplete.listen((_) {
      setState(() {
        isPlaying = false;
        _currentlyPlayingSongPath = null;
      });
    });
    _loadDownloadedSongs();
    _initializePlaylists();
  }

  Future<void> _loadDownloadedSongs() async {
    setState(() => _isLoading = true);
    final directory = await getApplicationDocumentsDirectory();
    final songsDir = Directory(directory.path);
    final files = songsDir.listSync();
    final mp3Files = files.where((file) => file is File && file.path.endsWith('.mp3')).toList();

    final prefs = await SharedPreferences.getInstance();
    for (var songFile in mp3Files) {
      final songName = songFile.path.split('/').last.replaceAll('.mp3', '');
      final songJson = prefs.getString('song_$songName');
      if (songJson == null) continue;

      try {
        final songData = jsonDecode(songJson);
        if (songData is Map<String, dynamic>) {
          Song.fromJson(songData);
        } else {
          throw const FormatException('Invalid song data format');
        }
      } catch (e) {
        await prefs.remove('song_$songName');
      }
    }

    setState(() {
      _songs = mp3Files;
      _isLoading = false;
    });
  }

  Future<void> _deleteDownloadedSong(FileSystemEntity songFile) async {
    try {
      final file = File(songFile.path);
      if (await file.exists()) {
        await file.delete();
      }
      final prefs = await SharedPreferences.getInstance();
      final songName = songFile.path.split('/').last.replaceAll('.mp3', '');
      await prefs.remove('song_$songName');
      setState(() {
        _songs.remove(songFile);
        if (_currentlyPlayingSongPath == songFile.path) {
          isPlaying = false;
          _currentlyPlayingSongPath = null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $songName')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting song: $e')),
      );
    }
  }

  @override
  void dispose() {
    // Ensure no unsafe ancestor lookups by cleaning up properly
    _tabController.dispose();
    _playlistNameController.dispose();
    _searchController.dispose();
    audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _initializePlaylists() async {
    await _playlistManager.loadPlaylists();
    setState(() {});
  }

  Future<void> _createPlaylist(BuildContext context) async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create New Playlist'),
          content: TextField(
            controller: _playlistNameController,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
            TextButton(
              child: const Text('Create'),
              onPressed: () async {
                final playlistName = _playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  // Use millisecondsSinceEpoch to create a unique id.
                  final newPlaylist = Playlist(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: playlistName,
                    songs: [],
                  );
                  _playlistManager.addPlaylist(newPlaylist);
                  await _playlistManager.savePlaylists();
                  setState(() {}); // refresh UI
                }
                Navigator.of(context).pop();
                _playlistNameController.clear();
              },
            ),
          ],
        );
      },
    );
  }

  void _onSearch(String value) {
    setState(() => _searchQuery = value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: _tabController.index == 0 ? const Text('Playlists') : const Text('Downloads'),
        actions: [
          if (_tabController.index == 0)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _createPlaylist(context),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: _tabController.index == 0 ? 'Search playlists...' : 'Search downloaded songs...',
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
          Column(
            children: [
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'Playlists'),
                  Tab(text: 'Downloads'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildPlaylistsTab(),
                    _buildDownloadedSongsTab(),
                  ],
                ),
              ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.7),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistsTab() {
    final filteredPlaylists = _playlistManager.playlists
        .where((playlist) => playlist.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return filteredPlaylists.isEmpty
        ? Center(
            child: Text(
              'No playlists available.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          )
        : GridView.builder(
            padding: const EdgeInsets.all(8.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8.0,
              mainAxisSpacing: 8.0,
              childAspectRatio: 3 / 4,
            ),
            itemCount: filteredPlaylists.length,
            itemBuilder: (context, index) {
              final playlist = filteredPlaylists[index];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PlaylistDetailScreen(playlist: playlist),
                    ),
                  );
                },
                child: Card(
                  elevation: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          child: playlist.songs.isNotEmpty
                              ? Image.network(
                                  playlist.songs.first.albumArtUrl,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Icon(Icons.music_note, size: 40, color: Theme.of(context).colorScheme.onSurface),
                                )
                              : Container(
                                  color: Colors.grey[300],
                                  child: Center(
                                    child: Icon(Icons.music_note, size: 40, color: Theme.of(context).colorScheme.onSurface),
                                  ),
                                ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          playlist.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
  }

  Widget _buildDownloadedSongsTab() {
    final filteredSongs = _songs
        .where((songFile) => songFile.path.split('/').last.replaceAll('.mp3', '').toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return filteredSongs.isEmpty
        ? Center(
            child: Text(
              'No downloaded songs yet.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          )
        : ListView.builder(
            itemCount: filteredSongs.length,
            itemBuilder: (context, index) {
              final songFile = filteredSongs[index];
              final songName = songFile.path.split('/').last.replaceAll('.mp3', '');
              return ListTile(
                title: Text(
                  songName,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.delete, color: Colors.red),
                      tooltip: 'Delete Download',
                      onPressed: () => _deleteDownloadedSong(songFile),
                    ),
                  ],
                ),
                onTap: () {
                  // Play the song on tap.
                  final songObj = Song(
                    title: songName,
                    artist: 'Unknown Artist',
                    albumArtUrl: '',
                    localFilePath: songFile.path,
                    isDownloaded: true,
                  );
                  Provider.of<CurrentSongProvider>(context, listen: false).playSong(songObj);
                },
              );
            },
          );
  }

}
