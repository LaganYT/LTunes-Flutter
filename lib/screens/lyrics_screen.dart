import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';

class LyricsScreen extends StatefulWidget {
  final String songTitle;
  final String lyrics;
  final String albumArtUrl;
  final String? songId; // Add optional songId parameter

  const LyricsScreen({
    super.key,
    required this.songTitle,
    required this.lyrics,
    required this.albumArtUrl,
    this.songId, // Optional songId for identification
  });

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  bool _showLyrics = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showLyrics ? 'Lyrics - ${widget.songTitle}' : 'Album Art - ${widget.songTitle}'),
      ),
      body: GestureDetector(
        onTap: () {
          setState(() {
            _showLyrics = !_showLyrics;
          });
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: _showLyrics
              ? LyricsView(key: const ValueKey('lyrics'), lyrics: widget.lyrics)
              : AlbumArtView(key: const ValueKey('albumArt'), albumArtUrl: widget.albumArtUrl),
        ),
      ),
    );
  }
}

class LyricsView extends StatelessWidget {
  final String lyrics;

  const LyricsView({super.key, required this.lyrics});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Text(
        lyrics.trim(),
        style: const TextStyle(fontSize: 16.0),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class AlbumArtView extends StatefulWidget {
  final String albumArtUrl;
  const AlbumArtView({super.key, required this.albumArtUrl});
  @override
  State<AlbumArtView> createState() => _AlbumArtViewState();
}

class _AlbumArtViewState extends State<AlbumArtView> {
  ImageProvider? _currentArtProvider;
  String? _currentArtKey;
  bool _artLoading = false;

  @override
  void initState() {
    super.initState();
    _updateArtProvider(widget.albumArtUrl);
  }

  Future<void> _updateArtProvider(String artUrl) async {
    setState(() { _artLoading = true; });
    if (artUrl.startsWith('http')) {
      _currentArtProvider = CachedNetworkImageProvider(artUrl);
    } else if (artUrl.isNotEmpty) {
      _currentArtProvider = FileImage(File(artUrl));
    } else {
      _currentArtProvider = null;
    }
    _currentArtKey = artUrl;
    if (mounted) setState(() { _artLoading = false; });
  }

  @override
  void didUpdateWidget(covariant AlbumArtView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumArtUrl != widget.albumArtUrl) {
      _updateArtProvider(widget.albumArtUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: AspectRatio(
          aspectRatio: 1.0,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.0),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  spreadRadius: 2,
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _currentArtProvider != null
                  ? Image(
                      key: ValueKey(_currentArtKey),
                      image: _currentArtProvider!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.error),
                    )
                  : const Icon(Icons.error),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ImageProvider getArtworkProvider(String artUrl) {
  if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
  if (artUrl.startsWith('http')) {
    return CachedNetworkImageProvider(artUrl);
  } else {
    return FileImage(File(artUrl));
  }
}
