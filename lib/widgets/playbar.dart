import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/current_song_provider.dart'; // Ensure this is the correct path to CurrentSongProvider
import '../models/playlist_manager.dart';
import '../screens/song_detail_screen.dart'; // Import the SongDetailScreen

class Playbar extends StatefulWidget {
  static _PlaybarState of(BuildContext context) =>
      context.findAncestorStateOfType<_PlaybarState>()!;

  const Playbar({super.key});

  @override
  _PlaybarState createState() => _PlaybarState();
}

class _PlaybarState extends State<Playbar> {
  @override
  Widget build(BuildContext context) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context);
    final Song? currentSong = currentSongProvider.currentSong;
    final bool isPlaying = currentSongProvider.isPlaying;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SongDetailScreen(song: currentSong!), // Navigate to full-screen player
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        padding: const EdgeInsets.all(8.0),
        child: currentSong != null
            ? Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: currentSong.albumArtUrl.isNotEmpty
                        ? Image.network(
                            currentSong.albumArtUrl,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Icon(Icons.music_note, size: 40, color: Theme.of(context).colorScheme.onSurface),
                          )
                        : Icon(Icons.music_note, size: 40, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          currentSong.artist.isNotEmpty ? currentSong.artist : 'Unknown Artist',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Theme.of(context).colorScheme.onSurface),
                    onPressed: () {
                      if (isPlaying) {
                        currentSongProvider.pauseSong();
                      } else {
                        currentSongProvider.playSong(currentSong);
                      }
                    
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.playlist_add),
                    onPressed: () {
                      _showAddToPlaylistDialog(context, currentSong);
                    },
                  ),
                ],
              )
            : const Padding(
                padding: EdgeInsets.all(8.0),
                child: Card(
                  color: Color(0xFFF5F5F5),
                  elevation: 0,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.music_note, size: 32, color: Colors.grey),
                        SizedBox(width: 12),
                        Text(
                          'No song selected',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (context) => AddToPlaylistDialog(song: song),
    );
  }
}

class AddToPlaylistDialog extends StatefulWidget {
  final Song song;

  const AddToPlaylistDialog({super.key, required this.song});

  @override
  _AddToPlaylistDialogState createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  final PlaylistManager _playlistManager = PlaylistManager();

  @override
  void initState() {
    super.initState();
    _initializePlaylists();
  }

  Future<void> _initializePlaylists() async {
    await _playlistManager.loadPlaylists();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playlists = _playlistManager.playlists;

    return AlertDialog(
      title: const Text('Add to Playlist'),
      content: playlists.isEmpty
          ? const Text('No playlists available. Create one in the Library.')
          : SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (BuildContext context, int index) {
                  final playlist = playlists[index];
                  return ListTile(
                    title: Text(playlist.name),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      tooltip: 'Delete Playlist',
                      onPressed: () async {
                        setState(() {
                          _playlistManager.removePlaylist(playlist);
                        });
                        await _playlistManager.savePlaylists();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Deleted playlist "${playlist.name}"')),
                        );
                      },
                    ),
                    onTap: () async {
                      _playlistManager.addSongToPlaylist(playlist, widget.song);
                      await _playlistManager.savePlaylists();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Added to ${playlist.name}')),
                      );
                    },
                  );
                },
              ),
            ),
      actions: [
        TextButton(
          child: const Text('Cancel'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
