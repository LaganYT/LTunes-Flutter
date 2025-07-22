import 'dart:io';
import 'dart:typed_data'; // Added for Uint8List
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/playlist_manager_service.dart';
import 'playlist_detail_screen.dart';
import '../providers/current_song_provider.dart';
import '../widgets/playbar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import '../services/api_service.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});
  @override
  _PlaylistsScreenState createState() => _PlaylistsScreenState();
}

class _ImportJob {
  bool cancel = false;
  bool isImporting = true;
  int totalRows = 0;
  int matchedCount = 0;
  String? playlistName;
  bool autoSkipUnmatched = false;
  // For dialog state
  VoidCallback? notifyParent;
}

class ImportJobManager extends ChangeNotifier {
  static final ImportJobManager _instance = ImportJobManager._internal();
  factory ImportJobManager() => _instance;
  ImportJobManager._internal();

  final List<_ImportJob> jobs = [];

  void addJob(_ImportJob job) {
    jobs.add(job);
    notifyListeners();
  }

  void removeJob(_ImportJob job) {
    jobs.remove(job);
    notifyListeners();
  }

  void update() {
    notifyListeners();
  }
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final _manager = PlaylistManagerService();
  List<Playlist> _playlists = [];
  
  // Cache Future objects to prevent art flashing
  final Map<String, Future<String>> _localArtFutureCache = {};

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
        return _buildArtWidget(arts.first, size);
      }
      final grid = arts.take(4).map((url) => _buildArtWidget(url, size / 2)).toList();
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

  Widget _buildArtWidget(String url, double sz) {
    if (url.startsWith('http')) {
      return Image.network(url, width: sz, height: sz, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.music_note, size: 24)));
    }
    // local file case
    return FutureBuilder<String>(
      future: _getCachedLocalArtFuture(url),
      key: ValueKey<String>('playlist_art_$url'),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.done && snap.data!.isNotEmpty) {
          return Image.file(File(snap.data!), width: sz, height: sz, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.music_note, size: 24)));
        }
        return const Center(child: Icon(Icons.music_note, size: 24));
      },
    );
  }

  // Get cached Future for local art to prevent flashing
  Future<String> _getCachedLocalArtFuture(String url) {
    if (url.isEmpty || url.startsWith('http')) {
      return Future.value('');
    }
    
    if (!_localArtFutureCache.containsKey(url)) {
      _localArtFutureCache[url] = () async {
        final dir = await getApplicationDocumentsDirectory();
        final name = p.basename(url);
        final fp = p.join(dir.path, name);
        return File(fp).existsSync() ? fp : '';
      }();
    }
    
    return _localArtFutureCache[url]!;
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
                                const Icon(Icons.hourglass_top, size: 48, color: Colors.white),
                                const SizedBox(height: 8),
                                const Text('Importing...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                if (job.totalRows > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text('${job.matchedCount} / ${job.totalRows}', style: const TextStyle(color: Colors.white)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(job.playlistName ?? 'Importing...', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Importing...', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.orange[700], fontSize: 12)),
                  ],
                ),
              ),
            );
          }
          playlistCards.addAll(_playlists.map((p) => GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: p)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                      hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                    ),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                    onChanged: (query) {
                      setState(() {
                        _playlists = _manager.playlists.where((playlist) => playlist.name.toLowerCase().contains(query.toLowerCase())).toList();
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
              child: const Icon(Icons.add),
              tooltip: 'Create Playlist',
            ),
            bottomNavigationBar: const Padding(
              padding: EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 32.0),
              child: Playbar(),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Create')),
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
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('Delete Playlist', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Save')),
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
        content: Text('Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _manager.removePlaylist(playlist);
    }
  }

  void _addPlaylistToQueue(Playlist playlist) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    for (final song in playlist.songs) {
      currentSongProvider.addToQueue(song);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added ${playlist.songs.length} songs from "${playlist.name}" to queue')),
    );
  }

  Future<void> _importPlaylistFromXLSX(_ImportJob job) async {
    job.cancel = false;
    job.isImporting = true;
    job.totalRows = 0;
    job.matchedCount = 0;
    job.playlistName = null;
    void notifyParent() => ImportJobManager().update();
    job.notifyParent = notifyParent;
    ImportJobManager().update();
    print('Starting XLSX import...');
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    print('File picker result: $result');
    if (result == null || result.files.isEmpty) {
      print('No file selected or file picker returned empty.');
      job.isImporting = false;
      ImportJobManager().removeJob(job);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No file selected or file picker returned empty.')),
        );
      }
      ImportJobManager().update();
      return;
    }
    Uint8List? fileBytes = result.files.first.bytes;
    if (fileBytes == null && result.files.first.path != null) {
      fileBytes = await File(result.files.first.path!).readAsBytes();
    }
    print('File bytes: ${fileBytes?.length ?? 0}');
    if (fileBytes == null) {
      print('File bytes are null.');
      job.isImporting = false;
      ImportJobManager().removeJob(job);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File bytes are null.')),
        );
      }
      ImportJobManager().update();
      return;
    }

    try {
      print('Decoding Excel...');
      final excel = Excel.decodeBytes(fileBytes);
      final sheet = excel.tables.values.first;
      print('Parsed sheet, rows: ${sheet.maxRows}');
      if (sheet.maxRows == 0) throw Exception('No data found in XLSX');

      // Assume first row is header: id, name, artist, album
      final header = sheet.row(0).map((cell) => cell?.value.toString().toLowerCase() ?? '').toList();
      print('Parsed header: $header');
      final nameIdx = header.indexOf('name');
      final artistIdx = header.indexOf('artist');
      final albumIdx = header.indexOf('album');
      print('Header indices: name=$nameIdx, artist=$artistIdx, album=$albumIdx');
      if ([nameIdx, artistIdx, albumIdx].contains(-1)) {
        print('Missing required columns.');
        throw Exception('Missing required columns (name, artist, album)');
      }

      final apiService = ApiService();
      final List<Song> matchedSongs = [];
      int totalRows = 0;
      int matchedCount = 0;

      // Show progress dialog unless importing in background
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
                Text('Matched ${job.matchedCount} of ${job.totalRows} songs'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Checkbox(
                      value: job.autoSkipUnmatched,
                      onChanged: (val) {
                        setState(() { job.autoSkipUnmatched = val ?? false; });
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
                  setState(() { job.cancel = true; });
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

      for (var i = 1; i < sheet.maxRows; i++) {
        if (job.cancel) {
          print('Import cancelled by user.');
          job.isImporting = false;
          ImportJobManager().removeJob(job);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Playlist import cancelled.')),
            );
          }
          ImportJobManager().update();
          return;
        }
        job.totalRows = sheet.maxRows - 1;
        job.matchedCount = matchedSongs.length;
        ImportJobManager().update();
        totalRows++;
        final row = sheet.row(i);
        final title = row[nameIdx]?.value.toString() ?? '';
        final artist = row[artistIdx]?.value.toString() ?? '';
        if (title.isEmpty || artist.isEmpty) continue;
        print('Searching for "$title" by "$artist"...');
        List<Song> searchResults = [];
        try {
          searchResults = await apiService.fetchSongs('$title $artist');
        } catch (e) {
          // If the error is a 500 error, skip this song
          final errorStr = e.toString();
          if (errorStr.contains('Status Code: 500')) {
            print('Skipping "$title" by "$artist" due to 500 error.');
            continue;
          } else {
            // For other errors, rethrow
            rethrow;
          }
        }
        Song? bestMatch;
        for (final result in searchResults) {
          if (result.title.toLowerCase() == title.toLowerCase() &&
              result.artist.toLowerCase() == artist.toLowerCase()) {
            bestMatch = result;
            break;
          }
        }
        if (bestMatch != null) {
          matchedSongs.add(bestMatch);
          matchedCount++;
        } else {
          print('No match found for "$title" by "$artist"');
          if (job.autoSkipUnmatched) {
            print('Auto-skip enabled, skipping unmatched song.');
            continue;
          }
          // Show popup for user to select a song or skip
          final userSelected = await _showSongSearchPopup(title, artist);
          if (userSelected != null) {
            matchedSongs.add(userSelected);
            matchedCount++;
          }
        }
      }
      Navigator.of(context).pop(); // Close progress dialog
      job.isImporting = false;
      ImportJobManager().removeJob(job);
      if (matchedSongs.isEmpty) {
        print('No songs matched in the imported file.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No songs matched in the imported file.')),
          );
        }
        return;
      }

      final nameCtrl = TextEditingController();
      final playlistName = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Imported Playlist Name'),
          content: TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('OK')),
          ],
        ),
      );
      print('Playlist name dialog result: $playlistName');
      if (playlistName == null || playlistName.isEmpty) {
        print('No playlist name entered.');
        return;
      }

      final playlist = Playlist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: playlistName,
        songs: matchedSongs,
      );
      print('Created playlist: ${playlist.toJson()}');
      await _manager.addPlaylist(playlist);
      await _manager.savePlaylists();
      print('Playlist added and saved. Current playlists: ${_manager.playlists.map((p) => p.name).toList()}');
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playlist import completed: $matchedCount of $totalRows songs matched.')),
        );
      }
      ImportJobManager().update();
    } catch (e, stack) {
      print('Failed to import playlist: $e\n$stack');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import playlist: $e')),
      );
    }
  }

  Future<Song?> _showSongSearchPopup(String localTitle, String localArtist) async {
    final TextEditingController searchController = TextEditingController(text: '$localTitle $localArtist');
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
                    Text(
                      'Local: "$localTitle" by $localArtist',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                          setState(() { isSearching = true; });
                          try {
                            final results = await apiService.fetchSongs(value.trim());
                            setState(() {
                              searchResults = results;
                              isSearching = false;
                            });
                          } catch (e) {
                            setState(() { isSearching = false; });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Search error: $e'), backgroundColor: Colors.red),
                            );
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
                                selectedSong = song;
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
          'Songs that cannot be matched will prompt the user to find a match. You will be able to name the imported playlist after the import completes.'
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed == true) {
      final job = _ImportJob();
      job.autoSkipUnmatched = false;
      ImportJobManager().addJob(job);
      await _importPlaylistFromXLSX(job);
    }
  }

  void _showImportProgressDialog(_ImportJob job) {
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
              Text('Matched ${job.matchedCount} of ${job.totalRows} songs'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: job.autoSkipUnmatched,
                    onChanged: (val) {
                      setState(() { job.autoSkipUnmatched = val ?? false; });
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
                setState(() { job.cancel = true; });
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
}