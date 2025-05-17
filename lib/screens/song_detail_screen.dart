import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import 'package:audioplayers/audioplayers.dart';

class SongDetailScreen extends StatefulWidget {
  final Song song;

  const SongDetailScreen({super.key, required this.song});

  @override
  _SongDetailScreenState createState() => _SongDetailScreenState();
}

class _SongDetailScreenState extends State<SongDetailScreen> {
  bool _isDownloading = false;
  double _downloadProgress = 0;
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final AudioPlayer audioPlayer = AudioPlayer();
  bool isPlaying = false;

  @override
  void initState() {
    super.initState();
    audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        isPlaying = false;
      });
    });
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _downloadSong() async {
    setState(() => _isDownloading = true);
    String? audioUrl;
    try {
      final apiService = ApiService();
      audioUrl = await apiService.fetchAudioUrl(widget.song.artist, widget.song.title);
      if (audioUrl == null) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Failed to fetch audio URL.')),
        );
        setState(() => _isDownloading = false);
        return;
      }
      print('Fetching audio URL from: $audioUrl');
    } catch (e) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Error fetching audio URL: $e')),
      );
      setState(() => _isDownloading = false);
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/${widget.song.title}.mp3';
      final url = audioUrl;

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      final totalBytes = response.contentLength;
      List<int> bytes = [];

      response.stream.listen(
        (List<int> newBytes) {
          bytes.addAll(newBytes);
          setState(() {
            _downloadProgress = bytes.length / (totalBytes ?? 1);
          });
        },
        onDone: () async {
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          setState(() {
            _isDownloading = false;
            widget.song.localFilePath = filePath;
            widget.song.isDownloaded = true;
          });
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('Download complete!')),
          );
        },
        onError: (e) {
          setState(() => _isDownloading = false);
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(content: Text('Download failed: $e')),
          );
        },
        cancelOnError: true,
      );
    } catch (e) {
      setState(() => _isDownloading = false);
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Error downloading song: $e')),
      );
    }
  }

  Future<void> _playSong() async {
    try {
      if (widget.song.isDownloaded && widget.song.localFilePath != null) {
        if (isPlaying) {
          await audioPlayer.pause();
        } else {
          await audioPlayer.play(DeviceFileSource(widget.song.localFilePath!));
        }
        setState(() {
          isPlaying = !isPlaying;
        });
      } else {
        String? audioUrl = await ApiService().fetchAudioUrl(widget.song.artist, widget.song.title);
        if (audioUrl != null) {
          await audioPlayer.play(UrlSource(audioUrl));
          setState(() {
            isPlaying = true;
          });
        } else {
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('Song is not downloaded and could not fetch URL')),
          );
        }
      }
    } catch (e) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Error playing song: $e')),
      );
      setState(() {
        isPlaying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Song Details'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.song.title, style: Theme.of(context).textTheme.titleLarge),
              Text('Artist: ${widget.song.artist}'),
              Text('Album: ${widget.song.album ?? 'N/A'}'),
              Text('Release Date: ${widget.song.releaseDate ?? 'N/A'}'),
              const SizedBox(height: 20),
              Image.network(widget.song.albumArtUrl),
              const SizedBox(height: 20),
              if (_isDownloading) ...[
                LinearProgressIndicator(value: _downloadProgress),
                Text('Downloading... ${(_downloadProgress * 100).toStringAsFixed(2)}%'),
              ] else if (widget.song.isDownloaded) ...[
                const Text('Song downloaded!'),
              ] else ...[
                ElevatedButton(
                  onPressed: _downloadSong,
                  child: const Text('Download Song'),
                ),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _playSong,
                child: Text(isPlaying ? 'Pause Song' : 'Play Song'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  // TODO: Implement more song info functionality
                },
                child: const Text('More Song Info'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
