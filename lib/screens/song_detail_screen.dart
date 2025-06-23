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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../providers/current_song_provider.dart';
import '../services/api_service.dart';
import 'album_screen.dart';
import 'lyrics_screen.dart';
import 'artist_screen.dart'; // Import artist screen

class SongDetailScreen extends StatefulWidget {
  final Song song;

  const SongDetailScreen({super.key, required this.song});

  @override
  _SongDetailScreenState createState() => _SongDetailScreenState();
}

class _SongDetailScreenState extends State<SongDetailScreen> {
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  // ignore: unused_field
  bool _isDownloading = false;
  // ignore: unused_field
  double _downloadProgress = 0.0;
  // ignore: unused_field
  bool _isLoadingAlbum = false; // For View Album button
  bool _isLoadingLyrics = false;
  String? _lyrics;
  
  // Add preloading variables
  Album? _preloadedAlbum;
  LyricsData? _preloadedLyrics;
  bool _isPreloadingAlbum = false;
  bool _isPreloadingLyrics = false;
  // ignore: unused_field
  String? _cachedAlbumId;

  Set<String> _likedSongIds = {};

  @override
  void initState() {
    super.initState();
    // Listen to download progress changes for the specific song
    Provider.of<CurrentSongProvider>(context, listen: false).addListener(() {
      final currentSong = Provider.of<CurrentSongProvider>(context, listen: false).currentSong;
      // Check if the current song in the provider is the same as the one in this widget
      if (currentSong?.id == widget.song.id) {
        setState(() {
          _isDownloading = currentSong?.isDownloading ?? false;
          _downloadProgress = currentSong?.downloadProgress ?? 0.0;
        });
      }
    });

    // Start preloading data
    _preloadAlbumData();
    _preloadLyricsData();
    _loadLikedSongIds();
  }

  @override
  void dispose() {
    // Remove listener on dispose
    Provider.of<CurrentSongProvider>(context, listen: false).removeListener(() {});
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
    Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(widget.song);
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
    final songToDelete = widget.song; // Use a local variable for the song being deleted.

    try {
      if (songToDelete.localFilePath != null && songToDelete.localFilePath!.isNotEmpty) {
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
      final updatedSong = songToDelete.copyWith(isDownloaded: false, localFilePath: null);

      // Persist the updated metadata.
      await _saveSongMetadata(updatedSong);

      // Notify services if the widget is still mounted.
      if (mounted) {
        // Notify PlaylistManagerService
        PlaylistManagerService().updateSongInPlaylists(updatedSong);

        // Notify CurrentSongProvider
        Provider.of<CurrentSongProvider>(currentContext, listen: false).updateSongDetails(updatedSong);

        // Update local state if the widget is still mounted.
        if (mounted) {
          setState(() {
            // Reflect that the song is no longer downloaded.
            // This assumes widget.song is not directly mutated,
            // but rather the UI relies on a fresh build or provider state.
            // For immediate feedback, you might update a local copy or rely on provider.
          });
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text('"${updatedSong.title}" deleted from downloads.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error deleting song: $e');
      if (mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Error deleting song: $e')),
        );
      }
    }
  }

  Future<void> _saveSongMetadata(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    // Ensure all relevant fields are in toJson() and saved
    final songData = jsonEncode(song.toJson()); 
    await prefs.setString('song_${song.id}', songData); // Use song.id for unique key
  }

  Future<void> _preloadAlbumData() async {
    if (widget.song.album == null || widget.song.album!.isEmpty || widget.song.artist.isEmpty) {
      return;
    }

    setState(() {
      _isPreloadingAlbum = true;
    });

    try {
      final apiService = ApiService();
      final albumDetails = await apiService.getAlbum(widget.song.album!, widget.song.artist);
      
      if (mounted && albumDetails != null) {
        setState(() {
          _preloadedAlbum = albumDetails;
          _cachedAlbumId = albumDetails.id; // Cache the album ID
        });
      }
    } catch (e) {
      debugPrint('Error preloading album data: $e');
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

    setState(() {
      _isPreloadingLyrics = true;
    });

    try {
      final apiService = ApiService();
      final lyricsData = await apiService.fetchLyrics(widget.song.artist, widget.song.title);
      
      if (mounted && lyricsData != null) {
        setState(() {
          _preloadedLyrics = lyricsData;
          _lyrics = lyricsData.plainLyrics;
        });
      }
    } catch (e) {
      debugPrint('Error preloading lyrics data: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isPreloadingLyrics = false;
        });
      }
    }
  }

  Future<void> _viewAlbum(BuildContext context) async {
    if (widget.song.album == null || widget.song.album!.isEmpty || widget.song.artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album information is not available for this song.')),
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

    setState(() {
      _isLoadingAlbum = true;
    });

    try {
      final apiService = ApiService();
      final albumDetails = await apiService.getAlbum(widget.song.album!, widget.song.artist);

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
            SnackBar(content: Text('Could not find details for album: "${widget.song.album}".')),
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
        const SnackBar(content: Text('Song ID is missing, cannot fetch lyrics.')),
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

    setState(() {
      _isLoadingLyrics = true;
      _lyrics = null;
    });

    try {
      final apiService = ApiService();
      final lyricsData = await apiService.fetchLyrics(widget.song.artist, widget.song.title);

      if (mounted) {
        if (lyricsData != null) {
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
    final ids = raw.map((s) {
      try {
        return (jsonDecode(s) as Map<String, dynamic>)['id'] as String;
      } catch (_) {
        return null;
      }
    }).whereType<String>().toSet();
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
        Provider.of<CurrentSongProvider>(context, listen: false).queueSongForDownload(song);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Queued "${song.title}" for download.')),
        );
      }
    }

    await prefs.setStringList('liked_songs', raw);
    setState(() {});
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
        SnackBar(content: Text('Album "${_preloadedAlbum!.title}" saved to library')),
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
        const SnackBar(content: Text('Artist information is not available for this song.')),
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
    final currentSongProvider = Provider.of<CurrentSongProvider>(context); // Listen to changes
    final bool isCurrentSongInProvider = currentSongProvider.currentSong?.id == widget.song.id;
    final bool isPlayingThisSong = isCurrentSongInProvider && currentSongProvider.isPlaying;
    final bool isLoadingThisSong = isCurrentSongInProvider && currentSongProvider.isLoadingAudio;
    final bool isRadioPlayingGlobal = currentSongProvider.isCurrentlyPlayingRadio;

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
                  ? Icon(Icons.favorite, color: Theme.of(context).colorScheme.secondary)
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
                child: widget.song.albumArtUrl.isNotEmpty
                    ? (widget.song.albumArtUrl.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: widget.song.albumArtUrl,
                            placeholder: (context, url) => const CircularProgressIndicator(),
                            errorWidget: (context, url, error) => const Icon(Icons.error),
                          )
                        : Image.file(File(widget.song.albumArtUrl)))
                    : const Icon(Icons.album, size: 150),
              ),
              const SizedBox(height: 24),
              
              // Song info section with explicit indicator - CENTERED
              Container(
                width: double.infinity,
                child: Column(
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
                        if (widget.song.isExplicit)
                          Container(
                            margin: const EdgeInsets.only(left: 8.0),
                            padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4.0),
                              border: Border.all(color: Colors.red, width: 1.0),
                            ),
                            child: Text(
                              'E',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
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
              ),
              
              const SizedBox(height: 24),
              
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: isLoadingThisSong
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimary),
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                isPlayingThisSong ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                size: 28,
                                color: colorScheme.onPrimary,
                              ), 
                        label: Text(isPlayingThisSong ? 'Pause' : 'Play', style: textTheme.labelLarge?.copyWith(color: colorScheme.onPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: isLoadingThisSong
                            ? null
                            : () {
                                if (isPlayingThisSong) {
                                  currentSongProvider.pauseSong();
                                } else {
                                  if (isCurrentSongInProvider) {
                                    currentSongProvider.resumeSong();
                                  } else {
                                    currentSongProvider.playSong(widget.song);
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
                        if (currentSongProvider.isDownloadingSong && currentSongProvider.downloadProgress.containsKey(songForDownloadStatus.id)) ...[
                          LinearProgressIndicator(
                            value: currentSongProvider.downloadProgress[songForDownloadStatus.id],
                            color: colorScheme.secondary
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Downloading... ${((currentSongProvider.downloadProgress[songForDownloadStatus.id] ?? 0.0) * 100).toStringAsFixed(0)}%',
                            style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ] else if (songForDownloadStatus.isDownloaded && songForDownloadStatus.localFilePath != null) ...[
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              icon: Icon(Icons.delete_outline_rounded, color: colorScheme.onErrorContainer),
                              label: Text('Delete', style: textTheme.labelLarge?.copyWith(color: colorScheme.onErrorContainer, fontSize: 16)),
                              style: FilledButton.styleFrom(
                                backgroundColor: colorScheme.errorContainer,
                                foregroundColor: colorScheme.onErrorContainer,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: _deleteSong,
                            ),
                          ),
                        ] else ...[
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.download_rounded),
                              label: Text('Download', style: textTheme.labelLarge?.copyWith(fontSize: 16)),
                               style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: isRadioPlayingGlobal ? null : _downloadSong,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Row for View Album and View Lyrics buttons
              Row(
                children: [
                  // View Album button
                  if (widget.song.album != null && widget.song.album!.isNotEmpty)
                    Expanded(
                      child: GestureDetector(
                        onLongPress: () {
                          showModalBottomSheet(
                            context: context,
                            builder: (BuildContext context) {
                              return Container(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.album_outlined),
                                      title: const Text('View Album'),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _viewAlbum(context);
                                      },
                                    ),
                                    ListTile(
                                      leading: const Icon(Icons.bookmark_add),
                                      title: const Text('Save Album'),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _saveAlbum();
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                        child: ElevatedButton.icon(
                          icon: (_isLoadingAlbum || _isPreloadingAlbum)
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.album_outlined),
                          label: const Text('View Album'),
                          onPressed: (_isLoadingAlbum || _isPreloadingAlbum) ? null : () => _viewAlbum(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.secondary,
                            foregroundColor: Theme.of(context).colorScheme.onSecondary,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                  if (widget.song.album != null && widget.song.album!.isNotEmpty)
                    const SizedBox(width: 16),
              
                  // View Lyrics button
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: (_isLoadingLyrics || _isPreloadingLyrics)
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.lyrics_outlined),
                      label: const Text('View Lyrics'),
                      onPressed: (_isLoadingLyrics || _isPreloadingLyrics) ? null : () => _fetchAndShowLyrics(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.tertiaryContainer,
                        foregroundColor: colorScheme.onTertiaryContainer,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Action Row: Add to Playlist & Add to Queue
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: Icon(Icons.playlist_add_rounded, color: isRadioPlayingGlobal ? colorScheme.onSurface.withOpacity(0.38) : colorScheme.secondary),
                    label: Text('Add to Playlist', style: TextStyle(color: isRadioPlayingGlobal ? colorScheme.onSurface.withOpacity(0.38) : colorScheme.secondary)),
                    onPressed: isRadioPlayingGlobal ? null : () => _showAddToPlaylistDialog(context, widget.song),
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.queue_music, color: isRadioPlayingGlobal ? colorScheme.onSurface.withOpacity(0.38) : colorScheme.secondary),
                    label: Text('Add to Queue', style: TextStyle(color: isRadioPlayingGlobal ? colorScheme.onSurface.withOpacity(0.38) : colorScheme.secondary)),
                    onPressed: isRadioPlayingGlobal
                        ? null
                        : () {
                            final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
                            currentSongProvider.addToQueue(widget.song);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('${widget.song.title} added to queue')),
                            );
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Future<String> _getLocalImagePath(String imageFileName) async {
    if (imageFileName.isEmpty || imageFileName.startsWith('http')) return '';
    final directory = await getApplicationDocumentsDirectory();
    final fullPath = p.join(directory.path, imageFileName);
    if (await File(fullPath).exists()) {
      return fullPath;
    }
    return '';
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
  _AddToPlaylistDialogState createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  List<Playlist> _allPlaylists = [];
  List<Playlist> _filteredPlaylists = [];
  final PlaylistManagerService _playlistManagerService = PlaylistManagerService();
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
    await _playlistManagerService.ensurePlaylistsLoaded(); // Ensure playlists are loaded
    if (mounted) { // Check mounted after await
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
    String? artUrl = playlist.songs.isNotEmpty ? playlist.songs.first.albumArtUrl : null;
    Widget placeholder = Icon(Icons.music_note, size: 24, color: Theme.of(context).colorScheme.onSurfaceVariant);

    if (artUrl != null && artUrl.isNotEmpty) {
      if (artUrl.startsWith('http')) {
        return Image.network(
          artUrl,
          width: 48, height: 48, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder,
        );
      } else {
        return FutureBuilder<String>(
          future: _resolveLocalArtPathForDialog(artUrl),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data!.isNotEmpty) {
              return Image.file(
                File(snapshot.data!),
                width: 48, height: 48, fit: BoxFit.cover,
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
      contentPadding: const EdgeInsets.fromLTRB(16.0, 20.0, 16.0, 0), // Adjust padding
      content: SizedBox(
        width: double.maxFinite, // Make dialog content take full available width
        height: MediaQuery.of(context).size.height * 0.6, // Set a max height for the content
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
                  _showCreatePlaylistDialog(context); // Show create playlist dialog directly
                },
                child: const Text('New playlist', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                        prefixIcon: Icon(Icons.search, color: Theme.of(context).iconTheme.color?.withOpacity(0.7)),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24.0),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
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
                        _searchController.text.isNotEmpty ? 'No playlists found.' : 'No playlists available.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                            if (!playlist.songs.any((s) => s.id == widget.song.id)) {
                              _playlistManagerService.addSongToPlaylist(playlist, widget.song);
                              // _playlistManagerService.savePlaylists(); // savePlaylists is called within addSongToPlaylist
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Added to ${playlist.name}')),
                              );
                            } else {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Song already in playlist')),
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
      builder: (BuildContext dialogContext) { // Renamed inner context for clarity
        final TextEditingController playlistNameController = TextEditingController();
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
                  final newPlaylist = Playlist(id: DateTime.now().millisecondsSinceEpoch.toString(), name: playlistName, songs: []);
                  _playlistManagerService.addPlaylist(newPlaylist);
                  setState(() { 
                     _allPlaylists = List<Playlist>.from(_playlistManagerService.playlists); // Refresh the master list
                     // Re-apply filter based on the new _allPlaylists and existing search term
                     final searchQuery = _searchController.text.toLowerCase();
                     _filteredPlaylists = _allPlaylists.where((playlist) {
                       return playlist.name.toLowerCase().contains(searchQuery);
                     }).toList();
                     // No need to re-sort as sorting is removed
                  });
                }
                Navigator.of(dialogContext).pop(); // Use dialogContext to pop CreatePlaylistDialog
              },
            ),
          ],
        );
      },
    );
  }
}