import 'package:flutter/material.dart';

class LyricsScreen extends StatelessWidget {
  final String songTitle;
  final String lyrics;

  const LyricsScreen({
    super.key,
    required this.songTitle,
    required this.lyrics,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Lyrics - $songTitle'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          lyrics.trim(),
          style: const TextStyle(fontSize: 16.0),
        ),
      ),
    );
  }
}
