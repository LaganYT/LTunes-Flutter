import 'dart:io';
import 'dart:typed_data'; // Added for Uint8List
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/playlist_manager_service.dart';
import 'playlist_detail_screen.dart';
import '../providers/current_song_provider.dart';
import '../widgets/playbar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import '../services/api_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart'; // <-- Add this import
import 'package:cached_network_image/cached_network_image.dart';

Future<ImageProvider> getRobustArtworkProvider(String artUrl) async {
  if (artUrl.isEmpty) return const AssetImage('assets/placeholder.png');
  if (artUrl.startsWith('http')) {
    return CachedNetworkImageProvider(artUrl);
  } else {
    final dir = await getApplicationDocumentsDirectory();
    final name = p.basename(artUrl);
    final fullPath = p.join(dir.path, name);
    if (await File(fullPath).exists()) {
      return FileImage(File(fullPath));
    } else {
      return const AssetImage('assets/placeholder.png');
    }
  }
}

Widget robustArtwork(String artUrl,
    {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  return FutureBuilder<ImageProvider>(
    future: getRobustArtworkProvider(artUrl),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          snapshot.hasData) {
        return Image(
          image: snapshot.data!,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => Container(
            width: width,
            height: height,
            color: Colors.grey[700],
            child: Icon(Icons.music_note,
                size: (width ?? 48) * 0.6, color: Colors.white70),
          ),
        );
      }
      return Container(
        width: width,
        height: height,
        color: Colors.grey[700],
        child: Icon(Icons.music_note,
            size: (width ?? 48) * 0.6, color: Colors.white70),
      );
    },
  );
}

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});
  @override
  PlaylistsScreenState createState() => PlaylistsScreenState();
}

class ImportJob {
  bool cancel = false;
  bool isImporting = true;
  int totalRows = 0;
  int matchedCount = 0;
  String? playlistName;
  bool autoSkipUnmatched = false;
  // For dialog state
  VoidCallback? notifyParent;
}

class SongEntry {
  final String title;
  final String artist;
  final String album;
  final int originalIndex;

  SongEntry({
    required this.title,
    required this.artist,
    required this.album,
    required this.originalIndex,
  });
}

class BatchResult {
  final SongEntry entry;
  final Song? matchedSong;
  final String? error;

  BatchResult({
    required this.entry,
    this.matchedSong,
    this.error,
  });
}

class ImportJobManager extends ChangeNotifier {
  static final ImportJobManager _instance = ImportJobManager._internal();
  factory ImportJobManager() => _instance;
  ImportJobManager._internal();

  final List<ImportJob> jobs = [];

  void addJob(ImportJob job) {
    jobs.add(job);
    notifyListeners();
  }

  void removeJob(ImportJob job) {
    jobs.remove(job);
    notifyListeners();
  }

  void update() {
    notifyListeners();
  }
}

class PlaylistsScreenState extends State<PlaylistsScreen> {
  final _manager = PlaylistManagerService();
  List<Playlist> _playlists = [];

  // Cache Future objects to prevent art flashing
  final Map<String, Future<String>> _localArtFutureCache = {};

  ImageProvider? _currentArtProvider;
  String? _currentArtKey;
  final bool _artLoading = false;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_reload);
    _reload();
  }

  void _reload() {
    setState(() => _playlists = List.from(_manager.playlists));
  }

  @override
  void dispose() {
    _manager.removeListener(_reload);
    super.dispose();
  }

  // helper to build the 2×2 or single‐image preview
  Widget _playlistThumbnail(Playlist playlist) {
    return LayoutBuilder(builder: (_, constraints) {
      final arts = playlist.songs
          .map((s) => s.albumArtUrl)
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList();
      final size = constraints.maxWidth;
      if (arts.isEmpty) {
        return Center(
          child: Icon(
            Icons.playlist_play,
            size: 70,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      if (arts.length == 1) {
        return robustArtwork(arts.first, width: size);
      }
      final grid = arts
          .take(4)
          .map((url) => robustArtwork(url, width: size / 2))
          .toList();
      return GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 1,
        crossAxisSpacing: 1,
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: grid,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ImportJobManager>.value(
      value: ImportJobManager(),
      child: Consumer<ImportJobManager>(
        builder: (context, importJobManager, _) {
          List<Widget> playlistCards = [];
          for (int i = 0; i < importJobManager.jobs.length; i++) {
            final job = importJobManager.jobs[i];
            playlistCards.add(
              GestureDetector(
                onTap: () => _showImportProgressDialog(job),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: 1.0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          color: Colors.orange[700],
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.hourglass_top,
                                    size: 48, color: Colors.white),
                                const SizedBox(height: 8),
                                const Text('Importing...',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold)),
                                if (job.totalRows > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(
                                        '${job.matchedCount} / ${job.totalRows}',
                                        style: const TextStyle(
                                            color: Colors.white)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(job.playlistName ?? 'Importing...',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Importing...',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: Colors.orange[700], fontSize: 12)),
                  ],
                ),
              ),
            );
          }
          playlistCards.addAll(_playlists.map((p) => GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => PlaylistDetailScreen(playlist: p)),
                ),
                onLongPress: () => _showPlaylistOptions(p),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: 1.0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          color: Colors.grey[800],
                          child: _playlistThumbnail(p),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      p.name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${p.songs.length} songs',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              )));
          return Scaffold(
            appBar: AppBar(
              title: const Text('Playlists'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.upload_file),
                  tooltip: 'Import Playlist (XLSX)',
                  onPressed: _showImportExplanationAndStart,
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48.0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 8.0),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search playlists...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24.0),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      hintStyle: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7)),
                    ),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                    onChanged: (query) {
                      setState(() {
                        _playlists = _manager.playlists
                            .where((playlist) => playlist.name
                                .toLowerCase()
                                .contains(query.toLowerCase()))
                            .toList();
                      });
                    },
                  ),
                ),
              ),
            ),
            body: playlistCards.isEmpty
                ? const Center(child: Text('No playlists yet.'))
                : GridView.count(
                    padding: const EdgeInsets.all(24.0),
                    crossAxisCount: 2,
                    crossAxisSpacing: 24.0,
                    mainAxisSpacing: 24.0,
                    childAspectRatio: 0.75,
                    children: playlistCards,
                  ),
            floatingActionButton: FloatingActionButton(
              onPressed: _createPlaylist,
              tooltip: 'Create Playlist',
              child: const Icon(Icons.add),
            ),
            bottomNavigationBar: const Padding(
              padding: EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 32.0),
              child: Hero(
                tag: 'global-playbar-hero',
                child: Playbar(),
              ),
            ),
          );
        },
      ),
    );
  }

  void _createPlaylist() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(hintText: 'Playlist Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _manager.addPlaylist(Playlist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: result,
        songs: [],
      ));
      _reload();
    }
  }

  void _showPlaylistOptions(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename Playlist'),
              onTap: () {
                Navigator.pop(context);
                _renamePlaylist(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to Queue'),
              onTap: () {
                Navigator.pop(context);
                _addPlaylistToQueue(playlist);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Delete Playlist',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _deletePlaylist(playlist);
              },
            ),
          ],
        );
      },
    );
  }

  void _renamePlaylist(Playlist playlist) async {
    final nameCtrl = TextEditingController(text: playlist.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != playlist.name) {
      await _manager.renamePlaylist(playlist.id, newName);
    }
  }

  void _deletePlaylist(Playlist playlist) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text(
            'Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _manager.removePlaylist(playlist);
    }
  }

  void _addPlaylistToQueue(Playlist playlist) {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context, listen: false);
    for (final song in playlist.songs) {
      currentSongProvider.addToQueue(song);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Added ${playlist.songs.length} songs from "${playlist.name}" to queue')),
    );
  }

  Future<void> _importPlaylistFromXLSX(ImportJob job) async {
    await WakelockPlus.enable(); // Keep device awake during import
    job.cancel = false;
    job.isImporting = true;
    job.totalRows = 0;
    job.matchedCount = 0;
    job.playlistName = null;
    void notifyParent() => ImportJobManager().update();
    job.notifyParent = notifyParent;
    ImportJobManager().update();
    debugPrint('Starting XLSX import...');
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    debugPrint('File picker result: $result');
    if (result == null || result.files.isEmpty) {
      debugPrint('No file selected or file picker returned empty.');
      job.isImporting = false;
      ImportJobManager().removeJob(job);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No file selected or file picker returned empty.')),
        );
      }
      ImportJobManager().update();
      await WakelockPlus.disable(); // Release wakelock
      return;
    }
    Uint8List? fileBytes = result.files.first.bytes;
    if (fileBytes == null && result.files.first.path != null) {
      fileBytes = await File(result.files.first.path!).readAsBytes();
    }
    debugPrint('File bytes: ${fileBytes?.length ?? 0}');
    if (fileBytes == null) {
      debugPrint('File bytes are null.');
      job.isImporting = false;
      ImportJobManager().removeJob(job);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File bytes are null.')),
        );
      }
      ImportJobManager().update();
      await WakelockPlus.disable(); // Release wakelock
      return;
    }

    try {
      debugPrint('Decoding Excel...');
      final excel = Excel.decodeBytes(fileBytes);
      final sheet = excel.tables.values.first;
      debugPrint('Parsed sheet, rows: ${sheet.maxRows}');
      if (sheet.maxRows == 0) throw Exception('No data found in XLSX');

      // Assume first row is header: id, name, artist, album
      final header = sheet
          .row(0)
          .map((cell) => cell?.value.toString().toLowerCase() ?? '')
          .toList();
      debugPrint('Parsed header: $header');
      final nameIdx = header.indexOf('name');
      final artistIdx = header.indexOf('artist');
      final albumIdx = header.indexOf('album');
      debugPrint(
          'Header indices: name=$nameIdx, artist=$artistIdx, album=$albumIdx');
      if ([nameIdx, artistIdx, albumIdx].contains(-1)) {
        debugPrint('Missing required columns.');
        throw Exception('Missing required columns (name, artist, album)');
      }

      // Parse all songs from the Excel file first
      final List<SongEntry> songEntries = [];
      for (var i = 1; i < sheet.maxRows; i++) {
        final row = sheet.row(i);
        final title = row[nameIdx]?.value.toString() ?? '';
        final artist = row[artistIdx]?.value.toString() ?? '';
        final album = row[albumIdx]?.value.toString() ?? '';

        if (title.isNotEmpty && (artist.isNotEmpty || album.isNotEmpty)) {
          songEntries.add(SongEntry(
            title: title,
            artist: artist,
            album: album,
            originalIndex: i,
          ));
        }
      }

      job.totalRows = songEntries.length;
      ImportJobManager().update();

      // Show progress dialog
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Importing Playlist'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                    'Processing ${job.matchedCount} / ${job.totalRows} entries'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Checkbox(
                      value: job.autoSkipUnmatched,
                      onChanged: (val) {
                        setState(() {
                          job.autoSkipUnmatched = val ?? false;
                        });
                      },
                    ),
                    const Text('Auto Skip Unmatched'),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    job.cancel = true;
                  });
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel Import'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );

      if (job.cancel) {
        debugPrint('Import cancelled by user.');
        job.isImporting = false;
        ImportJobManager().removeJob(job);
        await WakelockPlus.disable();
        return;
      }

      // Process songs in batches for better performance
      final List<Song> matchedSongs = [];
      final prefs = await SharedPreferences.getInstance();
      final int batchSize = prefs.getInt('maxConcurrentPlaylistMatches') ??
          5; // Get from settings
      final apiService = ApiService();

      for (int i = 0; i < songEntries.length; i += batchSize) {
        if (job.cancel) {
          debugPrint('Import cancelled by user.');
          break;
        }

        final endIndex = (i + batchSize < songEntries.length)
            ? i + batchSize
            : songEntries.length;
        final batch = songEntries.sublist(i, endIndex);

        debugPrint(
            'Processing batch ${(i ~/ batchSize) + 1}: ${batch.length} songs');

        // Process batch concurrently
        final batchResults = await _processSongBatch(batch, apiService, job);

        // Handle user selections for unmatched songs
        for (final result in batchResults) {
          if (result.matchedSong != null) {
            matchedSongs.add(result.matchedSong!);
            job.matchedCount = matchedSongs.length;
            ImportJobManager().update();
          } else if (!job.autoSkipUnmatched && mounted) {
            // Show user selection dialog for unmatched songs
            final userSelected = await _showSongSearchPopup(
                result.entry.title, result.entry.artist,
                missingFields: result.entry.artist.isEmpty);
            if (userSelected != null) {
              matchedSongs.add(userSelected);
              job.matchedCount = matchedSongs.length;
              ImportJobManager().update();
            }
          }
        }
      }

      job.isImporting = false;
      ImportJobManager().removeJob(job);

      if (job.cancel) {
        if (mounted) {
          // Prompt user to keep or discard matched songs
          final action = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('Import Cancelled'),
              content: const Text(
                  'Do you want to keep the songs that were already matched as a playlist, or discard them?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'discard'),
                  child: const Text('Delete Playlist'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'keep'),
                  child: const Text('Keep Playlist'),
                ),
              ],
            ),
          );
          if (action == 'keep' && matchedSongs.isNotEmpty) {
            await _createPlaylistFromMatchedSongs(matchedSongs);
          } else if (action == 'discard') {
            if (mounted && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Playlist import cancelled and discarded.')),
              );
            }
          }
        }
        await WakelockPlus.disable();
        return;
      }

      if (matchedSongs.isEmpty) {
        debugPrint('No songs matched in the imported file.');
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No songs matched in the imported file.')),
          );
        }
        await WakelockPlus.disable();
        return;
      }

      await _createPlaylistFromMatchedSongs(matchedSongs);
      await WakelockPlus.disable();
    } catch (e, stack) {
      debugPrint('Failed to import playlist: $e\n$stack');
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import playlist: $e')),
        );
      }
      await WakelockPlus.disable();
    }
  }

  Future<List<BatchResult>> _processSongBatch(
      List<SongEntry> batch, ApiService apiService, ImportJob job) async {
    final List<BatchResult> results = [];

    // Create futures for concurrent API calls
    final List<Future<BatchResult>> futures = batch.map((entry) async {
      return await _searchAndMatchSong(entry, apiService);
    }).toList();

    // Wait for all API calls to complete
    final batchResults = await Future.wait(futures);
    results.addAll(batchResults);

    return results;
  }

  Future<BatchResult> _searchAndMatchSong(
      SongEntry entry, ApiService apiService) async {
    try {
      String searchQuery;
      List<Song> searchResults = [];

      // Handle different scenarios based on available data
      if (entry.artist.isNotEmpty && entry.album.isNotEmpty) {
        // Full data available
        searchQuery = '${entry.title} ${entry.artist}';
      } else if (entry.artist.isNotEmpty) {
        // Only artist available
        searchQuery = '${entry.title} ${entry.artist}';
      } else if (entry.album.isNotEmpty) {
        // Only album available, search by title and album
        searchQuery = '${entry.title} ${entry.album}';
      } else {
        // Only title available
        searchQuery = entry.title;
      }

      try {
        // Use version-aware search if we have artist and title
        if (entry.artist.isNotEmpty) {
          searchResults = await apiService.fetchSongsVersionAware(
              entry.artist, entry.title);
        } else {
          searchResults = await apiService.fetchSongs(searchQuery);
        }
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('Status Code: 500')) {
          debugPrint('Skipping "${entry.title}" due to 500 error.');
          return BatchResult(
              entry: entry, matchedSong: null, error: '500 error');
        } else {
          rethrow;
        }
      }

      // Try exact match first
      Song? bestMatch = _findExactMatch(searchResults, entry);

      // If no exact match, try with stripped title/artist
      if (bestMatch == null && entry.artist.isNotEmpty) {
        final strippedTitle = _stripFeaturing(entry.title);
        final strippedArtist = _truncateArtistAtComma(entry.artist);

        if (strippedTitle != entry.title || strippedArtist != entry.artist) {
          try {
            final strippedQuery = '$strippedTitle $strippedArtist';
            searchResults = await apiService.fetchSongs(strippedQuery);
            bestMatch = _findExactMatch(
                searchResults,
                SongEntry(
                  title: strippedTitle,
                  artist: strippedArtist,
                  album: entry.album,
                  originalIndex: entry.originalIndex,
                ));
          } catch (e) {
            final errorStr = e.toString();
            if (errorStr.contains('Status Code: 500')) {
              debugPrint(
                  'Skipping stripped search for "${entry.title}" due to 500 error.');
              return BatchResult(
                  entry: entry, matchedSong: null, error: '500 error');
            }
          }
        }
      }

      return BatchResult(entry: entry, matchedSong: bestMatch, error: null);
    } catch (e) {
      debugPrint('Error processing song "${entry.title}": $e');
      return BatchResult(entry: entry, matchedSong: null, error: e.toString());
    }
  }

  Song? _findExactMatch(List<Song> searchResults, SongEntry entry) {
    for (final result in searchResults) {
      if (result.title.toLowerCase() == entry.title.toLowerCase() &&
          (entry.artist.isEmpty ||
              result.artist.toLowerCase() == entry.artist.toLowerCase())) {
        return result;
      }
    }
    return null;
  }

  Future<void> _createPlaylistFromMatchedSongs(List<Song> matchedSongs) async {
    final nameCtrl = TextEditingController();
    final playlistName = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name Your Playlist'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(hintText: 'Playlist Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, nameCtrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );

    if (playlistName == null || playlistName.isEmpty) {
      debugPrint('No playlist name entered.');
      return;
    }

    final playlist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: playlistName,
      songs: matchedSongs,
    );

    debugPrint('Created playlist: ${playlist.toJson()}');
    await _manager.addPlaylist(playlist);
    await _manager.savePlaylists();
    debugPrint(
        'Playlist added and saved. Current playlists: ${_manager.playlists.map((p) => p.name).toList()}');
    _reload();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Playlist import completed: ${matchedSongs.length} songs matched.')),
      );
    }
    ImportJobManager().update();
  }

  Future<Song?> _showSongSearchPopup(String localTitle, String localArtist,
      {bool missingFields = false}) async {
    final TextEditingController searchController =
        TextEditingController(text: '$localTitle $localArtist');
    List<Song> searchResults = [];
    bool isSearching = false;
    Song? selectedSong;
    final apiService = ApiService();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Select Song'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    if (missingFields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          'Song title or artist is missing. Please search for the correct song.',
                          style: const TextStyle(
                              color: Colors.red, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Text(
                      'Local: "$localTitle" by $localArtist',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        labelText: 'Search',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (value) async {
                        if (value.trim().isNotEmpty) {
                          setState(() {
                            isSearching = true;
                          });
                          try {
                            final results =
                                await apiService.fetchSongs(value.trim());
                            setState(() {
                              searchResults = results;
                              isSearching = false;
                            });
                          } catch (e) {
                            setState(() {
                              isSearching = false;
                            });
                            if (mounted && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text('Search error: $e'),
                                    backgroundColor: Colors.red),
                              );
                            }
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    if (isSearching)
                      const Center(child: CircularProgressIndicator()),
                    if (!isSearching && searchResults.isEmpty)
                      const Text('No results. Enter a search and press Enter.'),
                    if (!isSearching && searchResults.isNotEmpty)
                      Expanded(
                        child: ListView.builder(
                          itemCount: searchResults.length,
                          itemBuilder: (context, index) {
                            final song = searchResults[index];
                            return ListTile(
                              title: Text(song.title),
                              subtitle: Text(song.artist),
                              onTap: () {
                                // Ensure the selected song is not marked as local or imported
                                selectedSong = song.copyWith(
                                  isDownloaded: false,
                                  localFilePath: null,
                                  isImported: false,
                                );
                                Navigator.of(context).pop();
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
              ],
            );
          },
        );
      },
    );
    return selectedSong;
  }

  void _showImportExplanationAndStart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Playlist from XLSX'),
        content: const Text(
            'This feature allows you to import a playlist from an XLSX file (such as one exported from FreeYourMusic).\n\n'
            'For each row, the app will use the song name and artist to search for the best match in the online database, and build a playlist from the matched songs.\n\n'
            'Songs that cannot be matched will prompt the user to find a match. You will be able to name the imported playlist after the import completes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed == true) {
      final job = ImportJob();
      job.autoSkipUnmatched = false;
      ImportJobManager().addJob(job);
      if (mounted && context.mounted) {
        await _importPlaylistFromXLSX(job);
      }
    }
  }

  void _showImportProgressDialog(ImportJob job) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Importing Playlist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Processed ${job.matchedCount} / ${job.totalRows} entries'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: job.autoSkipUnmatched,
                    onChanged: (val) {
                      setState(() {
                        job.autoSkipUnmatched = val ?? false;
                      });
                      job.notifyParent?.call();
                    },
                  ),
                  const Text('Auto Skip Unmatched'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  job.cancel = true;
                });
                job.notifyParent?.call();
                Navigator.of(context).pop();
              },
              child: const Text('Cancel Import'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  String _stripFeaturing(String title) {
    // Remove (feat. ...), (ft. ...), (with ...), case-insensitive
    return title
        .replaceAll(
            RegExp(r'\s*\((feat\.|ft\.|with)[^)]*\)', caseSensitive: false), '')
        .trim();
  }

  String _truncateArtistAtComma(String artist) {
    final idx = artist.indexOf(',');
    if (idx == -1) return artist.trim();
    return artist.substring(0, idx).trim();
  }
}
