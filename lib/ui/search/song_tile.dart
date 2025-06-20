import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';

/// A ListTile widget for displaying a song.
///
/// It includes a trailing "like" button and a long-press gesture to show
/// more information about the song in a dialog.
class SongTile extends StatelessWidget {
  final MediaItem mediaItem;
  final VoidCallback onPlay;
  final VoidCallback onLike;
  final bool isLiked;

  const SongTile({
    super.key,
    required this.mediaItem,
    required this.onPlay,
    required this.onLike,
    this.isLiked = false,
  });

  void _showSongInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(mediaItem.title),
        content: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              if (mediaItem.artist != null) Text('Artist: ${mediaItem.artist}'),
              if (mediaItem.album != null) Text('Album: ${mediaItem.album}'),
              if (mediaItem.duration != null)
                Text('Duration: ${mediaItem.duration.toString().split('.').first}'),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            child: const Text('Close'),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showSongInfo(context),
      child: ListTile(
        leading: mediaItem.artUri != null
            ? Image.network(
                mediaItem.artUri.toString(),
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.music_note, size: 50),
              )
            : const Icon(Icons.music_note, size: 50),
        title: Text(mediaItem.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(mediaItem.artist ?? 'Unknown Artist', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border),
          tooltip: 'Like',
          onPressed: onLike,
        ),
        onTap: onPlay,
      ),
    );
  }
}
