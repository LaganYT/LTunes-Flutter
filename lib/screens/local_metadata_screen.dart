import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/version_service.dart';
import '../services/playlist_manager_service.dart';
import '../services/metadata_history_service.dart';
import '../providers/current_song_provider.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

class LocalMetadataScreen extends StatefulWidget {
  const LocalMetadataScreen({super.key});

  @override
  State<LocalMetadataScreen> createState() => _LocalMetadataScreenState();
}

class _LocalMetadataScreenState extends State<LocalMetadataScreen> {
  List<Song> _localSongs = [];
  List<Song> _customMetadataSongs = []; // New state for custom metadata songs
  bool _isLoading = true;
  final ApiService _apiService = ApiService();
  final Map<String, bool> _fetchingSongs = {};
  final Map<String, String?> _fetchErrors = {};
  bool _isBatchFetching = false;
  Set<String> _ignoredSongIds = {};

  // New state variables for auto-fetch
  bool _autoFetchEnabled = false;
  // --- Metadata history state ---
  List<MetadataFetchHistory> _metadataHistory = [];

  @override
  void initState() {
    super.initState();
    _loadIgnoredSongs();
    _loadAutoFetchSetting();
    _loadLocalSongs();
    _loadMetadataHistory();
  }

  Future<void> _loadAutoFetchSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _autoFetchEnabled = prefs.getBool('auto_fetch_metadata') ?? false;
      });
    } catch (e) {
      debugPrint('Error loading auto-fetch setting: $e');
    }
  }

  Future<void> _saveAutoFetchSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_fetch_metadata', _autoFetchEnabled);
    } catch (e) {
      debugPrint('Error saving auto-fetch setting: $e');
    }
  }

  Future<void> _loadIgnoredSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ignoredSongsJson =
          prefs.getString('ignored_metadata_songs') ?? '[]';
      final List<dynamic> ignoredList = jsonDecode(ignoredSongsJson);
      setState(() {
        _ignoredSongIds = Set<String>.from(ignoredList);
      });
    } catch (e) {
      debugPrint('Error loading ignored songs: $e');
      setState(() {
        _ignoredSongIds = {};
      });
    }
  }

  Future<void> _saveIgnoredSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'ignored_metadata_songs', jsonEncode(_ignoredSongIds.toList()));
    } catch (e) {
      debugPrint('Error saving ignored songs: $e');
    }
  }

  Future<void> _ignoreSong(Song song) async {
    setState(() {
      _ignoredSongIds.add(song.id);
    });
    await _saveIgnoredSongs();
    await _loadLocalSongs(); // Refresh the list immediately

    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (context.mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('"${song.title}" will be ignored from metadata lookup'),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _unignoreSong(song),
          ),
        ),
      );
    }
  }

  Future<void> _unignoreSong(Song song) async {
    setState(() {
      _ignoredSongIds.remove(song.id);
    });
    await _saveIgnoredSongs();

    // Refresh the local songs list to include the unignored song
    await _loadLocalSongs();

    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (context.mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('"${song.title}" will be included in metadata lookup'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _showIgnoredSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> keys = prefs.getKeys();
      final List<Song> ignoredSongs = [];
      final appDocDir = await getApplicationDocumentsDirectory();
      const String downloadsSubDir = 'ltunes_downloads';

      for (String key in keys) {
        if (key.startsWith('song_')) {
          final String? songJson = prefs.getString(key);
          if (songJson != null) {
            try {
              Map<String, dynamic> songMap =
                  jsonDecode(songJson) as Map<String, dynamic>;
              Song song = Song.fromJson(songMap);

              // Only include ignored songs that are imported and downloaded
              if (song.isImported &&
                  song.isDownloaded &&
                  song.localFilePath != null &&
                  song.localFilePath!.isNotEmpty &&
                  _ignoredSongIds.contains(song.id)) {
                final fullPath = p.join(
                    appDocDir.path, downloadsSubDir, song.localFilePath!);
                if (await File(fullPath).exists()) {
                  ignoredSongs.add(song);
                }
              }
            } catch (e) {
              debugPrint(
                  'Error decoding song from SharedPreferences for key $key: $e');
            }
          }
        }
      }

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Ignored Songs'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: ignoredSongs.isEmpty
                    ? const Center(
                        child: Text(
                          'No ignored songs',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: ignoredSongs.length,
                        itemBuilder: (context, index) {
                          final song = ignoredSongs[index];
                          return ListTile(
                            title: Text(song.title),
                            subtitle: Text(song.artist),
                            trailing: IconButton(
                              icon: const Icon(Icons.restore),
                              onPressed: () {
                                final navigator = Navigator.of(context);
                                navigator.pop();
                                _unignoreSong(song);
                              },
                              tooltip: 'Restore to metadata lookup',
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                if (ignoredSongs.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      navigator.pop();
                      await _clearAllIgnoredSongs();
                    },
                    child: const Text('Clear All'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      debugPrint('Error loading ignored songs: $e');
    }
  }

  Future<void> _clearAllIgnoredSongs() async {
    setState(() {
      _ignoredSongIds.clear();
    });
    await _saveIgnoredSongs();
    await _loadLocalSongs();

    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async
    if (context.mounted) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content:
              Text('All ignored songs have been restored to metadata lookup'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _loadLocalSongs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final Set<String> keys = prefs.getKeys();
      final List<Song> localSongs = [];
      final List<Song> customMetadataSongs = [];
      final appDocDir = await getApplicationDocumentsDirectory();
      const String downloadsSubDir = 'ltunes_downloads';

      for (String key in keys) {
        if (key.startsWith('song_')) {
          final String? songJson = prefs.getString(key);
          if (songJson != null) {
            try {
              Map<String, dynamic> songMap =
                  jsonDecode(songJson) as Map<String, dynamic>;
              Song song = Song.fromJson(songMap);
              // Only include songs that are imported (local files) and not ignored
              if (song.isCustomMetadata == true &&
                  song.isDownloaded &&
                  song.localFilePath != null &&
                  song.localFilePath!.isNotEmpty &&
                  !_ignoredSongIds.contains(song.id)) {
                final fullPath = p.join(
                    appDocDir.path, downloadsSubDir, song.localFilePath!);
                if (await File(fullPath).exists()) {
                  customMetadataSongs.add(song);
                }
              } else if (song.isImported &&
                  song.isDownloaded &&
                  song.localFilePath != null &&
                  song.localFilePath!.isNotEmpty &&
                  !_ignoredSongIds.contains(song.id)) {
                final fullPath = p.join(
                    appDocDir.path, downloadsSubDir, song.localFilePath!);
                if (await File(fullPath).exists()) {
                  localSongs.add(song);
                }
              }
            } catch (e) {
              debugPrint(
                  'Error decoding song from SharedPreferences for key $key: $e');
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _localSongs = localSongs;
          _customMetadataSongs = customMetadataSongs;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading local songs: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // New method to check for exact match (case-insensitive)
  bool _isExactMatch(Song localSong, Song apiSong) {
    return localSong.title.toLowerCase() == apiSong.title.toLowerCase() &&
        localSong.artist.toLowerCase() == apiSong.artist.toLowerCase();
  }

  // Helper to strip (feat., ft., with ...) from title
  String _stripFeaturing(String title) {
    return title
        .replaceAll(
            RegExp(r'\s*\((feat\.|ft\.|with)[^)]*\)', caseSensitive: false), '')
        .trim();
  }

  // Helper to truncate artist at comma
  String _truncateArtistAtComma(String artist) {
    final idx = artist.indexOf(',');
    if (idx == -1) return artist.trim();
    return artist.substring(0, idx).trim();
  }

  Future<void> _fetchMetadataForSong(Song song) async {
    if (_fetchingSongs[song.id] == true) return;

    setState(() {
      _fetchingSongs[song.id] = true;
      _fetchErrors[song.id] = null;
    });

    try {
      // Search for the song using the API with version-aware search
      final searchResults =
          await _apiService.fetchSongsVersionAware(song.artist, song.title);
      Song? bestMatch;
      double bestScore = 0.0;
      for (final result in searchResults) {
        // Use version-aware similarity for better matching
        final titleScore = VersionService.calculateVersionAwareSimilarity(
            song.title, result.title);
        final artistScore = _calculateSimilarity(
            song.artist.toLowerCase(), result.artist.toLowerCase());
        final totalScore = (titleScore + artistScore) / 2.0;
        if (totalScore > bestScore && totalScore > 0.7) {
          bestScore = totalScore;
          bestMatch = result;
        }
      }
      // If not found, retry with stripped title/artist
      if (bestMatch == null) {
        final strippedTitle = _stripFeaturing(song.title);
        final strippedArtist =
            _truncateArtistAtComma(song.artist.replaceAll(',', ''));
        if (strippedTitle != song.title || strippedArtist != song.artist) {
          final retryResults =
              await _apiService.fetchSongs('$strippedTitle $strippedArtist');
          for (final result in retryResults) {
            final titleScore = _calculateSimilarity(
                strippedTitle.toLowerCase(), result.title.toLowerCase());
            final artistScore = _calculateSimilarity(
                strippedArtist.toLowerCase(), result.artist.toLowerCase());
            final totalScore = (titleScore + artistScore) / 2.0;
            if (totalScore > bestScore && totalScore > 0.7) {
              bestScore = totalScore;
              bestMatch = result;
            }
          }
        }
      }
      if (bestMatch != null) {
        await _convertToNativeSong(song, bestMatch);
        final scaffoldMessenger =
            ScaffoldMessenger.of(context); // Capture before async
        if (context.mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content:
                  Text('Successfully fetched metadata for "${song.title}"'),
              backgroundColor: Colors.green,
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => _undoMetadataFetch(song.id),
              ),
            ),
          );
        }
      } else {
        // Show search popup for manual selection
        if (context.mounted) {
          await _showSearchPopup(song, searchResults);
        }
      }
    } catch (e) {
      debugPrint('Error fetching metadata for ${song.title}: $e');
      setState(() {
        _fetchErrors[song.id] = 'Error: ${e.toString()}';
      });
    } finally {
      setState(() {
        _fetchingSongs[song.id] = false;
      });
    }
  }

  // New method for auto-fetching metadata for new imports
  Future<void> _autoFetchMetadataForNewImport(Song song) async {
    if (!_autoFetchEnabled) return;

    try {
      final searchResults =
          await _apiService.fetchSongs('${song.title} ${song.artist}');

      if (searchResults.isNotEmpty) {
        // Look for exact match (case-insensitive)
        Song? exactMatch;
        for (final result in searchResults) {
          if (_isExactMatch(song, result)) {
            exactMatch = result;
            break;
          }
        }

        if (exactMatch != null) {
          // Convert the local song to a native song with fetched metadata
          await _convertToNativeSong(song, exactMatch);
          debugPrint(
              'Auto-fetched metadata for "${song.title}" by ${song.artist}');
        }
      }
    } catch (e) {
      debugPrint('Error auto-fetching metadata for ${song.title}: $e');
    }
  }

  Future<void> _showSearchPopup(
      Song localSong, List<Song> initialResults) async {
    final TextEditingController searchController = TextEditingController(
      text: '${localSong.title} ${localSong.artist}',
    );
    List<Song> searchResults = List.from(initialResults);
    bool isSearching = false;

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
                      'Local: "${localSong.title}" by ${localSong.artist}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: 'Search for song',
                        hintText: 'Enter song title and artist',
                        suffixIcon: isSearching
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: () async {
                                  if (searchController.text.trim().isNotEmpty) {
                                    setState(() {
                                      isSearching = true;
                                    });

                                    try {
                                      final results =
                                          await _apiService.fetchSongs(
                                              searchController.text.trim());
                                      setState(() {
                                        searchResults = results;
                                        isSearching = false;
                                      });
                                    } catch (e) {
                                      setState(() {
                                        isSearching = false;
                                      });
                                      final scaffoldMessenger =
                                          ScaffoldMessenger.of(
                                              context); // Capture before async
                                      if (context.mounted) {
                                        scaffoldMessenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Search error: $e'),
                                            backgroundColor: Colors.red,
                                          ),
                                        );
                                      }
                                    }
                                  }
                                },
                              ),
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (value) async {
                        if (value.trim().isNotEmpty) {
                          setState(() {
                            isSearching = true;
                          });

                          try {
                            final results =
                                await _apiService.fetchSongs(value.trim());
                            setState(() {
                              searchResults = results;
                              isSearching = false;
                            });
                          } catch (e) {
                            setState(() {
                              isSearching = false;
                            });
                            final scaffoldMessenger = ScaffoldMessenger.of(
                                context); // Capture before async
                            if (context.mounted) {
                              scaffoldMessenger.showSnackBar(
                                SnackBar(
                                  content: Text('Search error: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: searchResults.isEmpty
                          ? Center(
                              child: Text(
                                isSearching
                                    ? 'Searching...'
                                    : 'No results found',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: searchResults.length,
                              itemBuilder: (context, index) {
                                final result = searchResults[index];
                                return ListTile(
                                  leading: result.albumArtUrl.isNotEmpty &&
                                          result.albumArtUrl.startsWith('http')
                                      ? CircleAvatar(
                                          backgroundImage:
                                              NetworkImage(result.albumArtUrl),
                                        )
                                      : CircleAvatar(
                                          backgroundColor: Colors.grey[300],
                                          child: const Icon(Icons.music_note,
                                              color: Colors.grey),
                                        ),
                                  title: Text(result.title),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(result.artist),
                                      if (result.album != null)
                                        Text(result.album!),
                                    ],
                                  ),
                                  onTap: () async {
                                    final navigator = Navigator.of(context);
                                    navigator.pop();
                                    final scaffoldMessenger =
                                        ScaffoldMessenger.of(
                                            context); // Capture before async
                                    await _convertToNativeSong(
                                        localSong, result);
                                    if (context.mounted) {
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Successfully converted "${localSong.title}" to "${result.title}"'),
                                          backgroundColor: Colors.green,
                                          action: SnackBarAction(
                                            label: 'Undo',
                                            onPressed: () => _undoMetadataFetch(
                                                localSong.id),
                                          ),
                                        ),
                                      );
                                    }
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
                  onPressed: () {
                    Navigator.of(context).pop();
                    setState(() {
                      _fetchErrors[localSong.id] = 'No song selected';
                    });
                  },
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    // Show custom metadata entry dialog
                    final customSong = await showDialog<Song>(
                      context: context,
                      builder: (context) {
                        final titleController =
                            TextEditingController(text: localSong.title);
                        final artistController =
                            TextEditingController(text: localSong.artist);
                        final albumController = TextEditingController();
                        final releaseDateController = TextEditingController();
                        File? pickedImage;
                        String? pickedImageFileName;
                        return StatefulBuilder(
                          builder: (context, setStateCustom) {
                            return AlertDialog(
                              title: const Text('Custom Metadata'),
                              content: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextField(
                                      controller: titleController,
                                      decoration: const InputDecoration(
                                          labelText: 'Title'),
                                    ),
                                    TextField(
                                      controller: artistController,
                                      decoration: const InputDecoration(
                                          labelText: 'Artist'),
                                    ),
                                    TextField(
                                      controller: albumController,
                                      decoration: const InputDecoration(
                                          labelText: 'Album (optional)'),
                                    ),
                                    TextField(
                                      controller: releaseDateController,
                                      decoration: const InputDecoration(
                                          labelText: 'Release Date (optional)'),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        ElevatedButton.icon(
                                          icon: const Icon(Icons.image),
                                          label: const Text('Import Image'),
                                          onPressed: () async {
                                            final result = await FilePicker
                                                .platform
                                                .pickFiles(
                                                    type: FileType.image);
                                            if (result != null &&
                                                result.files.single.path !=
                                                    null) {
                                              setStateCustom(() {
                                                pickedImage = File(
                                                    result.files.single.path!);
                                                pickedImageFileName =
                                                    result.files.single.name;
                                              });
                                            }
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        if (pickedImage != null)
                                          Flexible(
                                              child: Text(
                                                  pickedImageFileName ?? '',
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                      ],
                                    ),
                                    if (pickedImage != null)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(top: 8.0),
                                        child: Image.file(pickedImage!,
                                            height: 80),
                                      ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    // Save the image to app documents directory if picked
                                    String albumArtUrl = '';
                                    if (pickedImage != null) {
                                      final appDocDir =
                                          await getApplicationDocumentsDirectory();
                                      final fileName =
                                          'custom_art_${const Uuid().v4()}.${pickedImageFileName?.split('.').last ?? 'jpg'}';
                                      final destPath =
                                          p.join(appDocDir.path, fileName);
                                      await pickedImage!.copy(destPath);
                                      albumArtUrl = fileName;
                                    }
                                    final song = Song(
                                      title: titleController.text.trim().isEmpty
                                          ? 'Unknown Title'
                                          : titleController.text.trim(),
                                      id: const Uuid().v4(),
                                      artist:
                                          artistController.text.trim().isEmpty
                                              ? 'Unknown Artist'
                                              : artistController.text.trim(),
                                      artistId: '',
                                      albumArtUrl: albumArtUrl,
                                      album: albumController.text.trim().isEmpty
                                          ? null
                                          : albumController.text.trim(),
                                      releaseDate: releaseDateController.text
                                              .trim()
                                              .isEmpty
                                          ? null
                                          : releaseDateController.text.trim(),
                                      audioUrl: '',
                                      isDownloaded: true,
                                      localFilePath: localSong.localFilePath,
                                      extras: {},
                                      duration: null, // No duration
                                      isImported: true, // Mark as imported
                                      plainLyrics: null, // No lyrics
                                      syncedLyrics: null,
                                      playCount: localSong.playCount,
                                      isCustomMetadata:
                                          true, // Mark as custom metadata
                                    );
                                    Navigator.of(context).pop(song);
                                  },
                                  child: const Text('Save'),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                    if (customSong != null) {
                      Navigator.of(context).pop();
                      final scaffoldMessenger =
                          ScaffoldMessenger.of(context); // Capture before async
                      await _convertToNativeSong(localSong, customSong);
                      if (context.mounted) {
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(
                                'Successfully converted "${localSong.title}" to custom metadata'),
                            backgroundColor: Colors.green,
                            action: SnackBarAction(
                              label: 'Undo',
                              onPressed: () => _undoMetadataFetch(localSong.id),
                            ),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Custom'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  double _calculateSimilarity(String str1, String str2) {
    if (str1 == str2) return 1.0;
    if (str1.isEmpty || str2.isEmpty) return 0.0;

    // Simple similarity calculation using longest common subsequence
    final lcs = _longestCommonSubsequence(str1, str2);
    return (2.0 * lcs.length) / (str1.length + str2.length);
  }

  String _longestCommonSubsequence(String str1, String str2) {
    final m = str1.length;
    final n = str2.length;
    final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));

    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        if (str1[i - 1] == str2[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }

    // Reconstruct the LCS
    final lcs = <String>[];
    int i = m, j = n;
    while (i > 0 && j > 0) {
      if (str1[i - 1] == str2[j - 1]) {
        lcs.insert(0, str1[i - 1]);
        i--;
        j--;
      } else if (dp[i - 1][j] > dp[i][j - 1]) {
        i--;
      } else {
        j--;
      }
    }

    return lcs.join();
  }

  Future<void> _convertToNativeSong(Song localSong, Song apiSong) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final appDocDir = await getApplicationDocumentsDirectory();
      const String downloadsSubDir = 'ltunes_downloads';

      // Save the original local song data for potential undo
      final originalSongData = jsonEncode(localSong.toJson());

      // Create a new native song with the fetched metadata
      final nativeSong = Song(
        id: apiSong.id, // Use the API song's ID
        title: apiSong.title,
        artist: apiSong.artist,
        artistId: apiSong.artistId,
        album: apiSong.album,
        albumArtUrl: apiSong.albumArtUrl,
        releaseDate: apiSong.releaseDate,
        audioUrl: apiSong.audioUrl,
        duration: apiSong.duration,
        isDownloaded:
            true, // Keep it as downloaded since we have the local file
        localFilePath: localSong.localFilePath, // Keep the local file path
        extras: apiSong.extras,
        isImported: apiSong.isCustomMetadata == true
            ? true
            : false, // Mark as imported if custom
        plainLyrics: apiSong.plainLyrics,
        syncedLyrics: apiSong.syncedLyrics,
        playCount: localSong.playCount, // Preserve play count
        isCustomMetadata:
            apiSong.isCustomMetadata == true, // Preserve custom metadata flag
      );

      // Add to history for potential undo
      final historyService = MetadataHistoryService();
      await historyService.addHistoryEntry(MetadataFetchHistory(
        originalSongId: localSong.id,
        originalSongData: originalSongData,
        newSongId: nativeSong.id,
        timestamp: DateTime.now(),
      ));

      // Save the new native song metadata
      await prefs.setString(
          'song_${nativeSong.id}', jsonEncode(nativeSong.toJson()));

      // Remove the old local song metadata
      await prefs.remove('song_${localSong.id}');

      // Update the current song provider if this song is currently playing
      final currentSongProvider =
          Provider.of<CurrentSongProvider>(context, listen: false);
      if (currentSongProvider.currentSong?.id == localSong.id) {
        currentSongProvider.updateSongDetails(nativeSong);
      }

      // Update playlists that contain this song
      final playlistManager = PlaylistManagerService();
      await playlistManager.updateSongInPlaylists(nativeSong);

      // Refresh the list
      await _loadLocalSongs();
      await _loadMetadataHistory(); // Refresh history
    } catch (e) {
      debugPrint('Error converting song to native: $e');
      rethrow;
    }
  }

  // New method to undo metadata fetch
  Future<void> _undoMetadataFetch(String newSongId) async {
    try {
      // Find the history entry
      final historyService = MetadataHistoryService();
      final historyEntries = await historyService.getHistoryEntries();
      final historyEntry = historyEntries.lastWhere(
        (entry) => entry.newSongId == newSongId,
        orElse: () => throw Exception('No history found for this song'),
      );

      final prefs = await SharedPreferences.getInstance();

      // Remove the new song
      await prefs.remove('song_${historyEntry.newSongId}');

      // Restore the original song
      await prefs.setString(
          'song_${historyEntry.originalSongId}', historyEntry.originalSongData);

      // Remove from history
      await historyService.removeHistoryEntry(historyEntry);

      // Update the current song provider if this song is currently playing
      final currentSongProvider =
          Provider.of<CurrentSongProvider>(context, listen: false);
      if (currentSongProvider.currentSong?.id == newSongId) {
        final originalSong =
            Song.fromJson(jsonDecode(historyEntry.originalSongData));
        currentSongProvider.updateSongDetails(originalSong);
      }

      // Update playlists
      final playlistManager = PlaylistManagerService();
      final originalSong =
          Song.fromJson(jsonDecode(historyEntry.originalSongData));
      await playlistManager.updateSongInPlaylists(originalSong);

      // Refresh the list
      await _loadLocalSongs();
      await _loadMetadataHistory(); // Refresh history

      final scaffoldMessenger =
          ScaffoldMessenger.of(context); // Capture before async
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Metadata fetch undone'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error undoing metadata fetch: $e');
      final scaffoldMessenger =
          ScaffoldMessenger.of(context); // Capture before async
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error undoing: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _loadMetadataHistory() async {
    final historyService = MetadataHistoryService();
    final history = await historyService.getHistoryEntries();
    if (mounted) {
      setState(() {
        _metadataHistory = history.reversed.toList(); // Most recent first
      });
    }
  }

  Future<void> _fetchAllMetadata() async {
    if (_isBatchFetching || _isLoading) return;
    setState(() {
      _isBatchFetching = true;
    });
    for (final song in _localSongs) {
      // Skip if already fetching this song or if song is ignored
      if (_fetchingSongs[song.id] == true ||
          _ignoredSongIds.contains(song.id)) {
        continue;
      }
      setState(() {
        _fetchingSongs[song.id] = true;
      });
      try {
        final searchResults =
            await _apiService.fetchSongsVersionAware(song.artist, song.title);
        Song? bestMatch;
        double bestScore = 0.0;
        for (final result in searchResults) {
          // Use version-aware similarity for better matching
          final titleScore = VersionService.calculateVersionAwareSimilarity(
              song.title, result.title);
          final artistScore = _calculateSimilarity(
              song.artist.toLowerCase(), result.artist.toLowerCase());
          final totalScore = (titleScore + artistScore) / 2.0;
          if (totalScore > bestScore && totalScore > 0.7) {
            bestScore = totalScore;
            bestMatch = result;
          }
        }
        // If not found, retry with stripped title/artist
        if (bestMatch == null) {
          final strippedTitle = _stripFeaturing(song.title);
          final strippedArtist =
              _truncateArtistAtComma(song.artist.replaceAll(',', ''));
          if (strippedTitle != song.title || strippedArtist != song.artist) {
            final retryResults =
                await _apiService.fetchSongs('$strippedTitle $strippedArtist');
            for (final result in retryResults) {
              final titleScore = _calculateSimilarity(
                  strippedTitle.toLowerCase(), result.title.toLowerCase());
              final artistScore = _calculateSimilarity(
                  strippedArtist.toLowerCase(), result.artist.toLowerCase());
              final totalScore = (titleScore + artistScore) / 2.0;
              if (totalScore > bestScore && totalScore > 0.7) {
                bestScore = totalScore;
                bestMatch = result;
              }
            }
          }
        }
        if (bestMatch != null) {
          await _convertToNativeSong(song, bestMatch);
        } else {
          // Show popup for manual selection
          if (context.mounted) {
            await _showSearchPopup(song, searchResults);
          }
        }
      } catch (e) {
        setState(() {
          _fetchErrors[song.id] = 'Error: ${e.toString()}';
        });
      } finally {
        setState(() {
          _fetchingSongs[song.id] = false;
        });
      }
    }
    setState(() {
      _isBatchFetching = false;
    });
    await _loadLocalSongs();
  }

  // Reusable dialog for editing/creating custom metadata
  Future<Song?> _showCustomMetadataDialog({required Song baseSong}) async {
    final titleController = TextEditingController(text: baseSong.title);
    final artistController = TextEditingController(text: baseSong.artist);
    final albumController = TextEditingController(text: baseSong.album ?? '');
    final releaseDateController =
        TextEditingController(text: baseSong.releaseDate ?? '');
    File? pickedImage;
    String? pickedImageFileName;
    String? initialAlbumArt = baseSong.albumArtUrl;
    return showDialog<Song>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateCustom) {
            Widget albumArtWidget = const SizedBox.shrink();
            if (pickedImage != null) {
              albumArtWidget = Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Image.file(pickedImage!, height: 80),
              );
            } else if (initialAlbumArt.isNotEmpty) {
              if (initialAlbumArt.startsWith('http')) {
                albumArtWidget = Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Image.network(initialAlbumArt, height: 80),
                );
              } else {
                albumArtWidget = FutureBuilder<Directory>(
                  future: getApplicationDocumentsDirectory(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    final file =
                        File(p.join(snapshot.data!.path, initialAlbumArt));
                    if (!file.existsSync()) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Image.file(file, height: 80),
                    );
                  },
                );
              }
            }
            return AlertDialog(
              title: const Text('Edit Custom Metadata'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    TextField(
                      controller: artistController,
                      decoration: const InputDecoration(labelText: 'Artist'),
                    ),
                    TextField(
                      controller: albumController,
                      decoration:
                          const InputDecoration(labelText: 'Album (optional)'),
                    ),
                    TextField(
                      controller: releaseDateController,
                      decoration: const InputDecoration(
                          labelText: 'Release Date (optional)'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.image),
                          label: const Text('Import Image'),
                          onPressed: () async {
                            final result = await FilePicker.platform
                                .pickFiles(type: FileType.image);
                            if (result != null &&
                                result.files.single.path != null) {
                              setStateCustom(() {
                                pickedImage = File(result.files.single.path!);
                                pickedImageFileName = result.files.single.name;
                              });
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        if (pickedImage != null)
                          Flexible(
                              child: Text(pickedImageFileName ?? '',
                                  overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                    albumArtWidget,
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    String albumArtUrl = baseSong.albumArtUrl;
                    if (pickedImage != null) {
                      final appDocDir =
                          await getApplicationDocumentsDirectory();
                      final fileName =
                          'custom_art_${const Uuid().v4()}.${pickedImageFileName?.split('.').last ?? 'jpg'}';
                      final destPath = p.join(appDocDir.path, fileName);
                      await pickedImage!.copy(destPath);
                      albumArtUrl = fileName;
                    }
                    final song = Song(
                      title: titleController.text.trim().isEmpty
                          ? 'Unknown Title'
                          : titleController.text.trim(),
                      id: baseSong.id, // Keep the same ID for editing
                      artist: artistController.text.trim().isEmpty
                          ? 'Unknown Artist'
                          : artistController.text.trim(),
                      artistId: '',
                      albumArtUrl: albumArtUrl,
                      album: albumController.text.trim().isEmpty
                          ? null
                          : albumController.text.trim(),
                      releaseDate: releaseDateController.text.trim().isEmpty
                          ? null
                          : releaseDateController.text.trim(),
                      audioUrl: '',
                      isDownloaded: true,
                      localFilePath: baseSong.localFilePath,
                      extras: {},
                      duration: null, // No duration
                      isImported: true, // Mark as imported
                      plainLyrics: null, // No lyrics
                      syncedLyrics: null,
                      playCount: baseSong.playCount,
                      isCustomMetadata: true, // Mark as custom metadata
                    );
                    Navigator.of(context).pop(song);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Song Metadata'),
        centerTitle: true,
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.block),
                onPressed: _showIgnoredSongs,
                tooltip: 'View Ignored Songs',
              ),
              if (_ignoredSongIds.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '${_ignoredSongIds.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLocalSongs,
            tooltip: 'Refresh',
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                  top: 0,
                  left: 0,
                  right: 0,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.auto_awesome),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Auto-fetch Metadata for New Imports',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Automatically fetch metadata for imported songs with exact title/artist matches',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: _autoFetchEnabled,
                                  onChanged: (bool value) async {
                                    setState(() {
                                      _autoFetchEnabled = value;
                                    });
                                    await _saveAutoFetchSetting();
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.playlist_add_check),
                            label: Text(_isBatchFetching
                                ? 'Fetching All...'
                                : 'Fetch All'),
                            onPressed:
                                _isBatchFetching ? null : _fetchAllMetadata,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Local Songs',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• Auto: Automatically find the best match from the API\n• Manual: Search and select the correct song manually\n• Ignore: Exclude this song from metadata lookup',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.7),
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_metadataHistory.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Card(
                        child: ExpansionTile(
                          title: const Text('Metadata Fetch History',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          initiallyExpanded: false,
                          children: _metadataHistory.map((entry) {
                            final original = Song.fromJson(
                                jsonDecode(entry.originalSongData));
                            return ListTile(
                              title: Text(
                                  '"${original.title}" by ${original.artist}'),
                              subtitle: Text(
                                  'Converted at: ${entry.timestamp.toLocal()}'),
                              trailing: TextButton(
                                onPressed: () =>
                                    _undoMetadataFetch(entry.newSongId),
                                child: const Text('Undo'),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  if (_localSongs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 32.0),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.music_note,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No local songs found',
                              style:
                                  TextStyle(fontSize: 18, color: Colors.grey),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Import songs first to see them here',
                              style:
                                  TextStyle(fontSize: 14, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _localSongs.length,
                        itemBuilder: (context, index) {
                          final song = _localSongs[index];
                          final isFetching = _fetchingSongs[song.id] ?? false;
                          final error = _fetchErrors[song.id];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16.0, vertical: 4.0),
                            child: ListTile(
                              title: Text(
                                song.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    song.artist.isNotEmpty
                                        ? song.artist
                                        : 'Unknown Artist',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.7),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (song.album != null) ...[
                                    const SizedBox(height: 2),
                                    Text(song.album!),
                                  ],
                                  if (error != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      error,
                                      style: const TextStyle(
                                          color: Colors.red, fontSize: 12),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  if (!isFetching)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ElevatedButton(
                                          onPressed: () =>
                                              _fetchMetadataForSong(song),
                                          child: const Text('Auto'),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton(
                                          onPressed: () =>
                                              _showSearchPopup(song, []),
                                          child: const Text('Manual'),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton.icon(
                                          onPressed: () => _ignoreSong(song),
                                          icon:
                                              const Icon(Icons.block, size: 16),
                                          label: const Text('Ignore'),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.orange,
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                              trailing: isFetching
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                  if (_customMetadataSongs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Card(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer
                            .withValues(alpha: 0.2),
                        child: ExpansionTile(
                          title: const Text('Edited Metadata Songs',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          initiallyExpanded: false,
                          children: _customMetadataSongs.map((song) {
                            return ListTile(
                              title: Text(song.title),
                              subtitle: Text(song.artist),
                              trailing: IconButton(
                                icon: const Icon(Icons.edit),
                                color: Theme.of(context).colorScheme.primary,
                                onPressed: () async {
                                  final editedSong =
                                      await _showCustomMetadataDialog(
                                          baseSong: song);
                                  if (editedSong != null) {
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setString(
                                        'song_${editedSong.id}',
                                        jsonEncode(editedSong.toJson()));
                                    await _loadLocalSongs();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content:
                                              Text('Custom metadata updated'),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
