import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../models/song.dart';
import 'song_detail_screen.dart';

class ArtistScreen extends StatefulWidget {
  final String artistId;
  const ArtistScreen({super.key, required this.artistId});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Map<String, dynamic>? _artistInfo;
  List<Song>? _tracks;
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _loadArtist();
  }

  Future<void> _loadArtist() async {
    try {
      final api = ApiService();
      final data = await api.getArtistById(widget.artistId);
      setState(() {
        _artistInfo = data['info'];
        _tracks = (data['tracks'] as List).map((raw) {
          final info = data['info'] as Map<String, dynamic>;
          return Song.fromAlbumTrackJson(
            raw as Map<String, dynamic>,
            raw['ALB_TITLE']?.toString() ?? '',
            raw['ALB_PICTURE']?.toString() ?? '',
            '',                              // no releaseDate from track JSON
            info['ART_NAME']?.toString() ?? '',
          );
        }).toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error || _artistInfo == null) {
      return Scaffold(body: Center(child: Text('Failed to load artist.')));
    }

    final info = _artistInfo!;
    final name = info['ART_NAME'] as String? ?? info['name'] as String? ?? 'Artist';
    final pictureId = info['ART_PICTURE'] as String? ?? '';
    final fansCount = info['NB_FAN']?.toString() ?? '0';

    final tracks = _tracks ?? [];

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    // build artist image URL
    final artistImageUrl = pictureId.isNotEmpty
      ? 'https://e-cdns-images.dzcdn.net/images/artist/$pictureId/500x500-000000-80-0-0.jpg'
      : '';

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Artist image
          if (artistImageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: Image.network(
                artistImageUrl,
                width: 150,
                height: 150,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.person, size: 100, color: colorScheme.onSurfaceVariant
                ),
              ),
            ),
          const SizedBox(height: 16),

          // Name & followers
          Center(
            child: Text(
              name,
              style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '$fansCount fans',
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 24),

          // Popular tracks header
          Text(
            'Popular Tracks',
            style: textTheme.titleMedium,
          ),
          const Divider(),

          // Track list
          ...tracks.map((song) {
            return ListTile(
              leading: song.albumArtUrl.isNotEmpty
                  ? Image.network(song.albumArtUrl, width: 48, height: 48, fit: BoxFit.cover)
                  : Icon(Icons.music_note, size: 48, color: colorScheme.onSurfaceVariant),
              title: Text(song.title),
              subtitle: Text(song.album ?? ''),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SongDetailScreen(song: song)),
              ),
            );
          }).toList(),
        ],
      ),
    );
  }
}
