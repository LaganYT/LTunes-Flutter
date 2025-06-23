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

class AlbumArtView extends StatelessWidget {
  final String albumArtUrl;

  const AlbumArtView({super.key, required this.albumArtUrl});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: AspectRatio(
          aspectRatio: 1.0, // Assuming square album art
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.0),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  spreadRadius: 2,
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: albumArtUrl.startsWith('http')
                  ? CachedNetworkImage(
                      imageUrl: albumArtUrl,
                      placeholder: (context, url) => const CircularProgressIndicator(),
                      errorWidget: (context, url, error) => const Icon(Icons.error),
                    )
                  : (albumArtUrl.isNotEmpty
                      ? Image.file(
                          File(albumArtUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.error),
                        )
                      : const Icon(Icons.error)),
            ),
          ),
        ),
      ),
    );
  }
}
