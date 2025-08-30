import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/album.dart'; // Add import for Album model
import '../models/lyrics_data.dart'; // Add import for Lyrics model
import '../services/playlist_manager_service.dart';
import '../services/album_manager_service.dart'; // Add import for AlbumManagerService
import '../services/error_handler_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import '../services/api_service.dart';
import '../services/lyrics_service.dart';
import 'album_screen.dart';
import 'lyrics_screen.dart';
import 'artist_screen.dart'; // Import artist screen
import '../widgets/playbar.dart'; // Add import for Playbar

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

class SongDetailScreen extends StatefulWidget {
  final Song song;

  const SongDetailScreen({super.key, required this.song});

  @override
  SongDetailScreenState createState() => SongDetailScreenState();
}

class SongDetailScreenState extends State<SongDetailScreen> {
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  bool _isLoadingAlbum = false; // For View Album button
  bool _isLoadingLyrics = false;
  String? _lyrics;

  // Add preloading variables
  Album? _preloadedAlbum;
  LyricsData? _preloadedLyrics;
  Map<String, dynamic>? _preloadedArtistInfo;
  List<Song>? _preloadedArtistTracks;
  List<Album>? _preloadedArtistAlbums;
  bool _isPreloadingAlbum = false;
  bool _isPreloadingLyrics = false;
  bool _isPreloadingArtist = false;
  String? _cachedAlbumId;

  Set<String> _likedSongIds = {};

  ImageProvider? _currentArtProvider;
  String? _currentArtKey;
  bool _artLoading = false;

  // Helper function to safely create TextStyle with valid fontSize
  TextStyle _safeTextStyle(
    TextStyle? baseStyle, {
    Color? color,
    FontWeight? fontWeight,
    double? fallbackFontSize,
  }) {
    // Check if base style has valid fontSize
    if (baseStyle != null &&
        baseStyle.fontSize != null &&
        baseStyle.fontSize!.isFinite) {
      return baseStyle.copyWith(
        color: color,
        fontWeight: fontWeight,
      );
    }

    // Use fallback with safe fontSize
    return TextStyle(
      color: color,
      fontWeight: fontWeight,
      fontSize: fallbackFontSize ?? 16.0,
    );
  }

  @override
  void initState() {
    super.initState();
    // Listen to download progress changes for the specific song
    Provider.of<CurrentSongProvider>(context, listen: false).addListener(() {
      final currentSong =
          Provider.of<CurrentSongProvider>(context, listen: false).currentSong;
      // Check if the current song in the provider is the same as the one in this widget
      if (currentSong?.id == widget.song.id && mounted) {
        setState(() {
          _isDownloading = currentSong?.isDownloading ?? false;
          _downloadProgress = currentSong?.downloadProgress ?? 0.0;
        });
      }
    });

    _updateArtProvider(widget.song.albumArtUrl);

    // Start preloading data
    _preloadAlbumData();
    _preloadLyricsData();
    _preloadArtistData();
    _loadLikedSongIds();
  }

  Future<void> _updateArtProvider(String artUrl) async {
    if (mounted) {
      setState(() {
        _artLoading = true;
      });
    }

    if (artUrl.startsWith('http')) {
      _currentArtProvider = CachedNetworkImageProvider(artUrl);
    } else if (artUrl.isNotEmpty) {
      // Handle local file paths like the library screen does
      try {
        final directory = await getApplicationDocumentsDirectory();
        final fileName = p.basename(artUrl);
        final fullPath = p.join(directory.path, fileName);

        if (await File(fullPath).exists()) {
          _currentArtProvider = FileImage(File(fullPath));
          debugPrint('Song detail: Found local album art: $fullPath');
        } else {
          debugPrint('Song detail: Local album art not found: $fullPath');
          _currentArtProvider = null;
        }
      } catch (e) {
        debugPrint('Song detail: Error loading local art: $e');
        _currentArtProvider = null;
      }
    } else {
      _currentArtProvider = null;
    }

    _currentArtKey = artUrl;
    if (mounted)
      setState(() {
        _artLoading = false;
      });
  }

  @override
  void didUpdateWidget(covariant SongDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.albumArtUrl != widget.song.albumArtUrl) {
      _updateArtProvider(widget.song.albumArtUrl);
    }
  }

  @override
  void dispose() {
    // Remove listener on dispose
    Provider.of<CurrentSongProvider>(context, listen: false)
        .removeListener(() {});
    super.dispose();
  }

  // ignore: unused_element
  void _onDownloadProgress(String songId, double progress) {
    if (songId == widget.song.id && mounted) {
      setState(() {
        _downloadProgress = progress;
        _isDownloading = progress < 1.0; // Still downloading if progress < 1
        if (progress == 1.0) {
          // Optionally refresh song data from provider or prefs to get updated localFilePath
        }
      });
    }
  }

  void _downloadSong() {
    // No longer async, just triggers the provider's background download
    Provider.of<CurrentSongProvider>(context, listen: false)
        .queueSongForDownload(widget.song);
    // Optionally, show a snackbar that download has started
    // scaffoldMessengerKey.currentState?.showSnackBar(
    //   SnackBar(content: Text('Starting download for ${widget.song.title}...')),
    // );
  }

  // ignore: unused_element
  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('An Error Occurred'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('Okay'),
              onPressed: () {
                Navigator.of(context).pop();
                // Save state and exit the app
                // SystemNavigator.pop(); // Exit the app
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteSong() async {
    // Capture context and song for use in async operations, checking mounted status.
    if (!mounted) return;
    final currentContext = context; // Capture context
    final songToDelete =
        widget.song; // Use a local variable for the song being deleted.

    try {
      if (songToDelete.localFilePath != null &&
          songToDelete.localFilePath!.isNotEmpty) {
        final directory = await getApplicationDocumentsDirectory();
        final fullPath = p.join(directory.path, songToDelete.localFilePath!);
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
          debugPrint("Deleted file: $fullPath");
        } else {
          debugPrint("File not found for deletion: $fullPath");
        }
      }

      // Create the updated song object reflecting its new state.
      final updatedSong =
          songToDelete.copyWith(isDownloaded: false, localFilePath: null);

      // Persist the updated metadata.
      await _saveSongMetadata(updatedSong);

      // Notify services if the widget is still mounted.
      if (mounted) {
        // Notify PlaylistManagerService
        PlaylistManagerService().updateSongInPlaylists(updatedSong);

        // Notify AlbumManagerService to update album download status
        await AlbumManagerService().updateSongInAlbums(updatedSong);

        // Notify CurrentSongProvider
        Provider.of<CurrentSongProvider>(currentContext, listen: false)
            .updateSongDetails(updatedSong);

        // Update local state if the widget is still mounted.
        if (mounted && currentContext.mounted) {
          setState(() {
            // Reflect that the song is no longer downloaded.
            // This assumes widget.song is not directly mutated,
            // but rather the UI relies on a fresh build or provider state.
            // For immediate feedback, you might update a local copy or rely on provider.
          });
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
                content:
                    Text('"${updatedSong.title}" deleted from downloads.')),
          );
        }
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'deleteSong');
      if (mounted && currentContext.mounted) {
        _errorHandler.showErrorSnackBar(currentContext, e,
            errorContext: 'deleting song');
      }
    }
  }

  Future<void> _saveSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    // Ensure all relevant fields are in toJson() and saved
    final songData = jsonEncode(song.toJson());
    await prefs.setString(
        'song_${song.id}', songData); // Use song.id for unique key
  }

  Future<void> _preloadAlbumData() async {
    if (widget.song.album == null ||
        widget.song.album!.isEmpty ||
        widget.song.artist.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _isPreloadingAlbum = true;
      });
    }

    try {
      final apiService = ApiService();
      final albumDetails =
          await apiService.getAlbum(widget.song.album!, widget.song.artist);

      if (mounted && albumDetails != null) {
        setState(() {
          _preloadedAlbum = albumDetails;
          _cachedAlbumId = albumDetails.id; // Cache the album ID
        });
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'preloadAlbumData');
    } finally {
      if (mounted) {
        setState(() {
          _isPreloadingAlbum = false;
        });
      }
    }
  }

  Future<void> _preloadLyricsData() async {
    if (widget.song.id.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _isPreloadingLyrics = true;
      });
    }

    try {
      final lyricsService = LyricsService();
      final provider = Provider.of<CurrentSongProvider>(context, listen: false);
      final lyricsData =
          await lyricsService.fetchLyricsIfNeeded(widget.song, provider);

      if (mounted && lyricsData != null) {
        setState(() {
          _preloadedLyrics = lyricsData;
          _lyrics = lyricsData.displayLyrics;
        });
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'preloadLyricsData');
    } finally {
      if (mounted) {
        setState(() {
          _isPreloadingLyrics = false;
        });
      }
    }
  }

  Future<void> _preloadArtistData() async {
    if (widget.song.artist.isEmpty) return;

    if (mounted)
      setState(() {
        _isPreloadingArtist = true;
      });

    try {
      final apiService = ApiService();
      final artistData = await apiService.getArtistById(widget.song.artist);

      if (mounted) {
        final artistInfo = artistData['info'] as Map<String, dynamic>;
        final tracks = (artistData['tracks'] as List).map((raw) {
          return Song.fromAlbumTrackJson(
            raw as Map<String, dynamic>,
            raw['ALB_TITLE']?.toString() ?? '',
            raw['ALB_PICTURE']?.toString() ?? '',
            '',
            artistInfo['ART_NAME']?.toString() ?? '',
          );
        }).toList();

        // Get artist albums using the actual artist ID
        final actualArtistId =
            artistInfo['ART_ID']?.toString() ?? widget.song.artistId;
        List<Album>? albums;
        try {
          albums = await apiService.getArtistAlbums(actualArtistId);
        } catch (e) {
          // Albums loading failed, continue without them
          albums = [];
        }

        if (mounted) {
          setState(() {
            _preloadedArtistInfo = artistInfo;
            _preloadedArtistTracks = tracks;
            _preloadedArtistAlbums = albums;
          });
        }
      }
    } catch (e) {
      _errorHandler.logError(e, context: 'preloadArtistData');
    } finally {
      if (mounted) {
        setState(() {
          _isPreloadingArtist = false;
        });
      }
    }
  }

  Future<void> _viewAlbum(BuildContext context) async {
    if (widget.song.album == null ||
        widget.song.album!.isEmpty ||
        widget.song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Album information is not available for this song.')),
      );
      return;
    }

    // Use preloaded data if available
    if (_preloadedAlbum != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AlbumScreen(album: _preloadedAlbum!),
        ),
      );
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingAlbum = true;
      });
    }

    try {
      final apiService = ApiService();
      final albumDetails =
          await apiService.getAlbum(widget.song.album!, widget.song.artist);

      if (mounted) {
        if (albumDetails != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AlbumScreen(album: albumDetails),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Could not find details for album: "${widget.song.album}".')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching album details: $e')),
        );
      }
      debugPrint('Error fetching album details: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingAlbum = false;
        });
      }
    }
  }

  Future<void> _fetchAndShowLyrics(BuildContext context) async {
    if (widget.song.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Song ID is missing, cannot fetch lyrics.')),
      );
      return;
    }

    // Use preloaded data if available
    if (_preloadedLyrics != null && _lyrics != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => LyricsScreen(
            songTitle: widget.song.title,
            lyrics: _lyrics!,
            albumArtUrl: widget.song.albumArtUrl,
            songId: widget.song.id, // Pass the current song ID as lyric ID
          ),
        ),
      );
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingLyrics = true;
        _lyrics = null;
      });
    }

    try {
      final apiService = ApiService();
      final lyricsData =
          await apiService.fetchLyrics(widget.song.artist, widget.song.title);

      if (mounted) {
        if (lyricsData != null &&
            lyricsData.plainLyrics != null &&
            lyricsData.plainLyrics!.isNotEmpty) {
          _lyrics = lyricsData.plainLyrics;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => LyricsScreen(
                songTitle: widget.song.title,
                lyrics: _lyrics!,
                albumArtUrl: widget.song.albumArtUrl,
                songId: widget.song.id, // Pass the current song ID as lyric ID
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lyrics not found for this song.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching lyrics: $e')),
        );
      }
      debugPrint('Error fetching lyrics: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingLyrics = false;
        });
      }
    }
  }

  Future<void> _loadLikedSongIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('liked_songs') ?? [];
    final ids = raw
        .map((s) {
          try {
            return (jsonDecode(s) as Map<String, dynamic>)['id'] as String;
          } catch (_) {
            return null;
          }
        })
        .whereType<String>()
        .toSet();
    if (mounted) {
      setState(() {
        _likedSongIds = ids;
      });
    }
  }

  Future<void> _toggleLike(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('liked_songs') ?? [];
    final isLiked = _likedSongIds.contains(song.id);

    if (isLiked) {
      // unlike, remove from list
      raw.removeWhere((s) {
        try {
          return (jsonDecode(s) as Map<String, dynamic>)['id'] == song.id;
        } catch (_) {
          return false;
        }
      });
      _likedSongIds.remove(song.id);
    } else {
      // like and queue if auto-download enabled
      raw.add(jsonEncode(song.toJson()));
      _likedSongIds.add(song.id);
      final bool autoDL = prefs.getBool('autoDownloadLikedSongs') ?? false;
      if (autoDL) {
        final provider =
            Provider.of<CurrentSongProvider>(context, listen: false);
        provider.queueSongForDownload(song);
      }
    }

    await prefs.setStringList('liked_songs', raw);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _saveAlbum() async {
    if (_preloadedAlbum == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album data not available')),
      );
      return;
    }

    try {
      final albumManager = AlbumManagerService();
      await albumManager.addSavedAlbum(_preloadedAlbum!);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Album "${_preloadedAlbum!.title}" saved to library')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving album: $e')),
      );
    }
  }

  Future<void> _viewArtist(BuildContext context) async {
    if (widget.song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Artist information is not available for this song.')),
      );
      return;
    }

    // Use preloaded data if available
    if (_preloadedArtistInfo != null &&
        _preloadedArtistTracks != null &&
        _preloadedArtistAlbums != null) {
      final actualArtistId =
          _preloadedArtistInfo!['ART_ID']?.toString() ?? widget.song.artistId;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ArtistScreen(
            artistId: actualArtistId,
            artistName: widget.song.artist,
            preloadedArtistInfo: _preloadedArtistInfo,
            preloadedArtistTracks: _preloadedArtistTracks,
            preloadedArtistAlbums: _preloadedArtistAlbums,
          ),
        ),
      );
      return;
    }

    try {
      // Use artistId if available, otherwise use artist name
      final artistQuery = widget.song.artistId.isNotEmpty
          ? widget.song.artistId
          : widget.song.artist;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ArtistScreen(
            artistId: artistQuery,
            artistName: widget.song.artist,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening artist page: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSongProvider =
        Provider.of<CurrentSongProvider>(context); // Listen to changes
    final bool isCurrentSongInProvider =
        currentSongProvider.currentSong?.id == widget.song.id;
    final bool isPlayingThisSong =
        isCurrentSongInProvider && currentSongProvider.isPlaying;
    final bool isLoadingThisSong =
        isCurrentSongInProvider && currentSongProvider.isLoadingAudio;
    final bool isRadioPlayingGlobal =
        currentSongProvider.isCurrentlyPlayingRadio;

    // ignore: unused_local_variable
    final Song songForDisplay; // Use a different variable for clarity
    if (isCurrentSongInProvider && currentSongProvider.currentSong != null) {
      songForDisplay = currentSongProvider.currentSong!;
    } else {
      songForDisplay = widget.song;
    }

    // Determine the song instance whose download status should be displayed.
    // Prioritize the one from CurrentSongProvider if it's the same song.
    final Song songForDownloadStatus;
    if (isCurrentSongInProvider && currentSongProvider.currentSong != null) {
      songForDownloadStatus = currentSongProvider.currentSong!;
    } else {
      songForDownloadStatus = widget.song;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return ScaffoldMessenger(
      key: scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.song.album ?? 'Song Details'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: _likedSongIds.contains(widget.song.id)
                  ? Icon(Icons.favorite,
                      color: Theme.of(context).colorScheme.secondary)
                  : const Icon(Icons.favorite_border),
              onPressed: () => _toggleLike(widget.song),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _currentArtProvider != null
                      ? Image(
                          key: ValueKey(_currentArtKey),
                          image: _currentArtProvider!,
                          width: 300,
                          height: 300,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            debugPrint('Song detail: Image error: $error');
                            return Container(
                              width: 300,
                              height: 300,
                              color: Colors.grey[700],
                              child: const Icon(Icons.music_note,
                                  size: 150, color: Colors.white70),
                            );
                          },
                        )
                      : Container(
                          width: 300,
                          height: 300,
                          color: Colors.grey[700],
                          child: const Icon(Icons.music_note,
                              size: 150, color: Colors.white70),
                          key: ValueKey('song_detail_art_none'),
                        ),
                ),
              ),
              const SizedBox(height: 24),

              // Song Title and Artist Name
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          widget.song.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _viewArtist(context),
                    child: Text(
                      widget.song.artist,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context).colorScheme.secondary,
                            decoration: TextDecoration.underline,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Play/Pause and Download/Delete Buttons (moved above info sections)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      height: 56, // Fixed height for consistency
                      child: ElevatedButton.icon(
                        icon: isLoadingThisSong
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      colorScheme.onPrimary),
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                isPlayingThisSong
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 28,
                                color: colorScheme.onPrimary,
                              ),
                        label: Text(isPlayingThisSong ? 'Pause' : 'Play',
                            style: _safeTextStyle(textTheme.labelLarge,
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                                fallbackFontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: isLoadingThisSong
                            ? null
                            : () async {
                                if (isPlayingThisSong) {
                                  currentSongProvider.pauseSong();
                                } else {
                                  if (isCurrentSongInProvider) {
                                    currentSongProvider.resumeSong();
                                  } else {
                                    await currentSongProvider
                                        .smartPlayWithContext(
                                            [widget.song], widget.song);
                                  }
                                }
                              },
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Download/Delete Button
                  Expanded(
                    child: Column(
                      children: [
                        if (currentSongProvider.isDownloadingSong &&
                            currentSongProvider.downloadProgress
                                .containsKey(songForDownloadStatus.id) &&
                            (currentSongProvider.downloadProgress[
                                        songForDownloadStatus.id] ??
                                    0.0) <
                                1.0) ...[
                          SizedBox(
                            height: 56, // Fixed height for consistency
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                LinearProgressIndicator(
                                    value: currentSongProvider.downloadProgress[
                                        songForDownloadStatus.id],
                                    color: colorScheme.secondary),
                                const SizedBox(height: 4),
                                Text(
                                  'Downloading... ${((currentSongProvider.downloadProgress[songForDownloadStatus.id] ?? 0.0) * 100).toStringAsFixed(0)}%',
                                  style: textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ] else if ((songForDownloadStatus.isDownloaded &&
                                songForDownloadStatus.localFilePath != null) ||
                            (currentSongProvider.downloadProgress[
                                    songForDownloadStatus.id] ==
                                1.0)) ...[
                          SizedBox(
                            width: double.infinity,
                            height: 56, // Fixed height for consistency
                            child: FilledButton.tonalIcon(
                              icon: Icon(Icons.delete_outline_rounded,
                                  color: colorScheme.onErrorContainer),
                              label: Text('Delete',
                                  style: _safeTextStyle(textTheme.labelLarge,
                                      color: colorScheme.onErrorContainer,
                                      fallbackFontSize: 16)),
                              style: FilledButton.styleFrom(
                                backgroundColor: colorScheme.errorContainer,
                                foregroundColor: colorScheme.onErrorContainer,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: _deleteSong,
                            ),
                          ),
                        ] else ...[
                          SizedBox(
                            width: double.infinity,
                            height: 56, // Fixed height for consistency
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.download_rounded),
                              label: Text('Download',
                                  style: textTheme.labelLarge
                                      ?.copyWith(fontSize: 16)),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed:
                                  isRadioPlayingGlobal ? null : _downloadSong,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Action Row: Add to Playlist & Add to Queue
              Row(
                children: [
                  // Add to Playlist Button
                  Expanded(
                    child: SizedBox(
                      height: 56, // Fixed height for consistency
                      child: ElevatedButton.icon(
                        icon: Icon(
                          Icons.playlist_add_rounded,
                          color: isRadioPlayingGlobal
                              ? colorScheme.onSurface.withValues(alpha: 0.38)
                              : colorScheme.onSecondary,
                        ),
                        label: Text(
                          'Add to Playlist',
                          style: TextStyle(
                            color: isRadioPlayingGlobal
                                ? colorScheme.onSurface.withValues(alpha: 0.38)
                                : colorScheme.onSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        onPressed: isRadioPlayingGlobal
                            ? null
                            : () =>
                                _showAddToPlaylistDialog(context, widget.song),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.secondary,
                          foregroundColor: colorScheme.onSecondary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Add to Queue Button
                  Expanded(
                    child: SizedBox(
                      height: 56, // Fixed height for consistency
                      child: ElevatedButton.icon(
                        icon: Icon(
                          Icons.queue_music,
                          color: isRadioPlayingGlobal
                              ? colorScheme.onSurface.withValues(alpha: 0.38)
                              : colorScheme.onTertiary,
                        ),
                        label: Text(
                          'Add to Queue',
                          style: TextStyle(
                            color: isRadioPlayingGlobal
                                ? colorScheme.onSurface.withValues(alpha: 0.38)
                                : colorScheme.onTertiary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        onPressed: isRadioPlayingGlobal
                            ? null
                            : () {
                                final currentSongProvider =
                                    Provider.of<CurrentSongProvider>(context,
                                        listen: false);
                                currentSongProvider.addToQueue(widget.song);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          '${widget.song.title} added to queue')),
                                );
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.tertiary,
                          foregroundColor: colorScheme.onTertiary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Enhanced Song Information Section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: colorScheme.outline.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Song Information',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Album Information
                    if (widget.song.album != null &&
                        widget.song.album!.isNotEmpty) ...[
                      _buildInfoRow('Album', widget.song.album!),
                      const SizedBox(height: 8),
                    ],

                    // Release Date
                    if (widget.song.releaseDate != null &&
                        widget.song.releaseDate!.isNotEmpty) ...[
                      _buildInfoRow('Released', widget.song.releaseDate!),
                      const SizedBox(height: 8),
                    ],

                    // Duration
                    if (widget.song.duration != null) ...[
                      _buildInfoRow(
                          'Duration', _formatDuration(widget.song.duration!)),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Lyrics Preview Section (if available)
              if (_preloadedLyrics != null &&
                  _preloadedLyrics!.plainLyrics != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: colorScheme.outline.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lyrics, color: colorScheme.tertiary),
                          const SizedBox(width: 8),
                          Text(
                            'Lyrics Preview',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.tertiary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _preloadedLyrics!.plainLyrics!.length > 200
                            ? '${_preloadedLyrics!.plainLyrics!.substring(0, 200)}...'
                            : _preloadedLyrics!.plainLyrics!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      if (_preloadedLyrics!.plainLyrics!.length > 200) ...[
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () => _fetchAndShowLyrics(context),
                          child: Text(
                            'View Full Lyrics',
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.tertiary,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Album Details Section (if preloaded)
              if (_preloadedAlbum != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        colorScheme.secondaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: colorScheme.outline.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.album, color: colorScheme.secondary),
                          const SizedBox(width: 8),
                          Text(
                            'Album Details',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.secondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_preloadedAlbum!.tracks.isNotEmpty) ...[
                        Text(
                          '${_preloadedAlbum!.tracks.length} tracks',
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Show first few tracks
                        ...(_preloadedAlbum!.tracks.take(3).map(
                              (track) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.music_note,
                                      size: 16,
                                      color: track.title == widget.song.title
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        track.title,
                                        style: textTheme.bodySmall?.copyWith(
                                          color: track.title ==
                                                  widget.song.title
                                              ? colorScheme.primary
                                              : colorScheme.onSurfaceVariant,
                                          fontWeight:
                                              track.title == widget.song.title
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )),

                        if (_preloadedAlbum!.tracks.length > 3) ...[
                          const SizedBox(height: 4),
                          Text(
                            '... and ${_preloadedAlbum!.tracks.length - 3} more tracks',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],

                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () => _viewAlbum(context),
                          child: Text(
                            'View Album',
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.secondary,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Artist Information Section (if preloaded)
              if (_preloadedArtistInfo != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: colorScheme.outline.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'Artist Information',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Artist stats
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildArtistStatItem(
                            context,
                            'Fans',
                            _formatNumber(
                                _preloadedArtistInfo!['NB_FAN'] as int? ?? 0),
                            Icons.favorite,
                            colorScheme,
                          ),
                          _buildArtistStatItem(
                            context,
                            'Albums',
                            (_preloadedArtistAlbums?.length ??
                                    _preloadedArtistInfo!['NB_ALBUM'] as int? ??
                                    0)
                                .toString(),
                            Icons.album,
                            colorScheme,
                          ),
                          _buildArtistStatItem(
                            context,
                            'Tracks',
                            (_preloadedArtistTracks?.length ?? 0).toString(),
                            Icons.music_note,
                            colorScheme,
                          ),
                        ],
                      ),

                      if (_preloadedArtistTracks != null &&
                          _preloadedArtistTracks!.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Popular Tracks',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Show first few tracks
                        ...(_preloadedArtistTracks!.take(3).map(
                              (track) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.music_note,
                                      size: 16,
                                      color: track.title == widget.song.title
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        track.title,
                                        style: textTheme.bodySmall?.copyWith(
                                          color: track.title ==
                                                  widget.song.title
                                              ? colorScheme.primary
                                              : colorScheme.onSurfaceVariant,
                                          fontWeight:
                                              track.title == widget.song.title
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )),

                        if (_preloadedArtistTracks!.length > 3) ...[
                          const SizedBox(height: 4),
                          Text(
                            '... and ${_preloadedArtistTracks!.length - 3} more tracks',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],

                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () => _viewArtist(context),
                          child: Text(
                            'View Artist',
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.primary,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              const SizedBox(height: 24),
            ],
          ),
        ),
        bottomNavigationBar: Container(
          padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 32.0),
          child: const Hero(
            tag: 'global-playbar-hero',
            child: Playbar(),
          ),
        ),
      ),
    );
  }

  // Helper method to build info rows
  Widget _buildInfoRow(String label, String value,
      {IconData? icon, Color? iconColor}) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: 16,
            color: iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
        ],
        Text(
          '$label: ',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // Helper method to format duration
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  // Helper method to format numbers (e.g., 1000000 -> 1.0M)
  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  // Helper method to build artist stat items
  Widget _buildArtistStatItem(BuildContext context, String label, String value,
      IconData icon, ColorScheme colorScheme) {
    return Column(
      children: [
        Icon(
          icon,
          size: 24,
          color: colorScheme.primary,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AddToPlaylistDialog(song: song);
      },
    );
  }
}

class AddToPlaylistDialog extends StatefulWidget {
  final Song song;

  const AddToPlaylistDialog({super.key, required this.song});

  @override
  AddToPlaylistDialogState createState() => AddToPlaylistDialogState();
}

class AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  List<Playlist> _allPlaylists = [];
  List<Playlist> _filteredPlaylists = [];
  final PlaylistManagerService _playlistManagerService =
      PlaylistManagerService();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAndPreparePlaylists();
    _searchController.addListener(_filterAndSortPlaylists);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAndPreparePlaylists() async {
    await _playlistManagerService
        .ensurePlaylistsLoaded(); // Ensure playlists are loaded
    if (mounted) {
      // Check mounted after await
      setState(() {
        _allPlaylists = List<Playlist>.from(_playlistManagerService.playlists);
        _filteredPlaylists = List<Playlist>.from(_allPlaylists);
        // _sortPlaylists(); // Initial sort // Removed
      });
    }
  }

  void _filterAndSortPlaylists() {
    final searchQuery = _searchController.text.toLowerCase();
    setState(() {
      _filteredPlaylists = _allPlaylists.where((playlist) {
        return playlist.name.toLowerCase().contains(searchQuery);
      }).toList();
      // _sortPlaylists(); // Removed
    });
  }

  Future<String> _resolveLocalArtPathForDialog(String? fileName) async {
    if (fileName == null || fileName.isEmpty || fileName.startsWith('http')) {
      return '';
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        return fullPath;
      }
    } catch (e) {
      debugPrint("Error resolving local art path for dialog: $e");
    }
    return '';
  }

  Widget _buildPlaylistArt(Playlist playlist, BuildContext context) {
    String? artUrl =
        playlist.songs.isNotEmpty ? playlist.songs.first.albumArtUrl : null;
    Widget placeholder = Icon(Icons.music_note,
        size: 24, color: Theme.of(context).colorScheme.onSurfaceVariant);

    if (artUrl != null && artUrl.isNotEmpty) {
      if (artUrl.startsWith('http')) {
        return Image.network(
          artUrl,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder,
        );
      } else {
        return FutureBuilder<String>(
          future: _resolveLocalArtPathForDialog(artUrl),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData &&
                snapshot.data!.isNotEmpty) {
              return Image.file(
                File(snapshot.data!),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
              );
            }
            return placeholder;
          },
        );
      }
    }
    return placeholder;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Center(child: Text('Add to playlist')),
      contentPadding:
          const EdgeInsets.fromLTRB(16.0, 20.0, 16.0, 0), // Adjust padding
      content: SizedBox(
        width:
            double.maxFinite, // Make dialog content take full available width
        height: MediaQuery.of(context).size.height *
            0.6, // Set a max height for the content
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24.0),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  // Navigator.of(context).pop(); // Don't close AddToPlaylistDialog
                  _showCreatePlaylistDialog(
                      context); // Show create playlist dialog directly
                },
                child: const Text('New playlist',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Find playlist',
                        prefixIcon: Icon(Icons.search,
                            color: Theme.of(context)
                                .iconTheme
                                .color
                                ?.withValues(alpha: 0.7)),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24.0),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 0, horizontal: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _filteredPlaylists.isEmpty
                  ? Center(
                      child: Text(
                        _searchController.text.isNotEmpty
                            ? 'No playlists found.'
                            : 'No playlists available.',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filteredPlaylists.length,
                      itemBuilder: (BuildContext context, int index) {
                        final playlist = _filteredPlaylists[index];
                        return ListTile(
                          leading: SizedBox(
                            width: 48,
                            height: 48,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4.0),
                              child: _buildPlaylistArt(playlist, context),
                            ),
                          ),
                          title: Text(playlist.name),
                          subtitle: Text('${playlist.songs.length} songs'),
                          onTap: () {
                            if (!playlist.songs
                                .any((s) => s.id == widget.song.id)) {
                              _playlistManagerService.addSongToPlaylist(
                                  playlist, widget.song);
                              // _playlistManagerService.savePlaylists(); // savePlaylists is called within addSongToPlaylist
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text('Added to ${playlist.name}')),
                              );
                            } else {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Song already in playlist')),
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
          child: const Text('Cancel'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        // Renamed inner context for clarity
        final TextEditingController playlistNameController =
            TextEditingController();
        return AlertDialog(
          title: const Text('Create Playlist'),
          content: TextField(
            controller: playlistNameController,
            decoration: const InputDecoration(hintText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop(); // Use dialogContext
              },
            ),
            TextButton(
              child: const Text('Create'),
              onPressed: () {
                final playlistName = playlistNameController.text.trim();
                if (playlistName.isNotEmpty) {
                  final newPlaylist = Playlist(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: playlistName,
                      songs: []);
                  _playlistManagerService.addPlaylist(newPlaylist);
                  if (mounted) {
                    setState(() {
                      _allPlaylists = List<Playlist>.from(
                          _playlistManagerService
                              .playlists); // Refresh the master list
                      // Re-apply filter based on the new _allPlaylists and existing search term
                      final searchQuery = _searchController.text.toLowerCase();
                      _filteredPlaylists = _allPlaylists.where((playlist) {
                        return playlist.name
                            .toLowerCase()
                            .contains(searchQuery);
                      }).toList();
                      // No need to re-sort as sorting is removed
                    });
                  }
                }
                Navigator.of(dialogContext)
                    .pop(); // Use dialogContext to pop CreatePlaylistDialog
              },
            ),
          ],
        );
      },
    );
  }
}
