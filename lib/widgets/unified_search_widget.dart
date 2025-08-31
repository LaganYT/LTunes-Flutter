import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/unified_search_service.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/playlist.dart';
import '../providers/current_song_provider.dart';
import '../screens/song_detail_screen.dart';
import '../screens/album_screen.dart';
import '../screens/playlist_detail_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'package:http/http.dart' as http;

// Create a reusable HTTP client for image downloads
final http.Client _imageHttpClient = http.Client();

// Cache for station icons to prevent flashing
final Map<String, String> _stationIconCache = {};
final Map<String, Future<String>> _stationIconFutures = {};

Future<String> cacheStationIcon(String imageUrl, String stationId) async {
  if (imageUrl.isEmpty || !imageUrl.startsWith('http')) return '';
  
  // Check if we already have a cached result
  if (_stationIconCache.containsKey(stationId)) {
    return _stationIconCache[stationId]!;
  }
  
  // Check if we already have a future for this station
  if (_stationIconFutures.containsKey(stationId)) {
    final result = await _stationIconFutures[stationId]!;
    return result;
  }
  
  // Create a new future for this station
  final future = _cacheStationIconInternal(imageUrl, stationId);
  _stationIconFutures[stationId] = future;
  
  try {
    final result = await future;
    _stationIconCache[stationId] = result;
    _stationIconFutures.remove(stationId);
    return result;
  } catch (e) {
    _stationIconFutures.remove(stationId);
    rethrow;
  }
}

Future<String> _cacheStationIconInternal(String imageUrl, String stationId) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'stationicon_$stationId.jpg';
    final filePath = p.join(directory.path, fileName);
    final file = File(filePath);
    if (await file.exists()) {
      return filePath;
    }
    // Download the image using the reusable HTTP client
    final response = await _imageHttpClient.get(Uri.parse(imageUrl));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      return filePath;
    }
  } catch (e) {
    debugPrint('Error caching station icon: $e');
  }
  return '';
}

// Widget for displaying radio station icons without flashing
class RadioStationIcon extends StatefulWidget {
  final String imageUrl;
  final String stationId;
  final double size;
  final BorderRadius? borderRadius;

  const RadioStationIcon({
    super.key,
    required this.imageUrl,
    required this.stationId,
    required this.size,
    this.borderRadius,
  });

  @override
  State<RadioStationIcon> createState() => _RadioStationIconState();
}

class _RadioStationIconState extends State<RadioStationIcon> {
  String? _cachedPath;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(RadioStationIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl || oldWidget.stationId != widget.stationId) {
      _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    if (widget.imageUrl.isEmpty) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final cachedPath = await cacheStationIcon(widget.imageUrl, widget.stationId);
      if (mounted) {
        setState(() {
          _cachedPath = cachedPath;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.radio,
          size: widget.size * 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    if (_hasError || _cachedPath == null || _cachedPath!.isEmpty) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.radio,
          size: widget.size * 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        child: Image.file(
          File(_cachedPath!),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.radio,
              size: widget.size * 0.6,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

class UnifiedSearchWidget extends StatefulWidget {
  final String searchQuery;
  final VoidCallback? onResultTap;

  const UnifiedSearchWidget({
    super.key,
    required this.searchQuery,
    this.onResultTap,
  });

  @override
  State<UnifiedSearchWidget> createState() => _UnifiedSearchWidgetState();
}

class _UnifiedSearchWidgetState extends State<UnifiedSearchWidget> {
  final UnifiedSearchService _searchService = UnifiedSearchService();
  List<SearchResult> _searchResults = [];
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _performSearch();
  }

  @override
  void didUpdateWidget(UnifiedSearchWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery) {
      _performSearch();
    }
  }

  Future<void> _performSearch() async {
    if (widget.searchQuery.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isLoading = false;
        _errorMessage = '';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final results = await _searchService.search(widget.searchQuery);
      setState(() {
        _searchResults = results;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Search failed: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 8),
              Text(
                _errorMessage,
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 8),
              Text(
                widget.searchQuery.trim().isEmpty 
                    ? 'Enter a search term to find music'
                    : 'No results found for "${widget.searchQuery}"',
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        return _buildSearchResultTile(result);
      },
    );
  }

  Widget _buildSearchResultTile(SearchResult result) {
    switch (result.type) {
      case SearchResultType.song:
        return _buildSongTile(result.item as Song, result.matchedFields);
      case SearchResultType.album:
        return _buildAlbumTile(result.item as Album, result.matchedFields);
      case SearchResultType.playlist:
        return _buildPlaylistTile(result.item as Playlist, result.matchedFields);
      case SearchResultType.radioStation:
        return _buildRadioStationTile(result.item as RadioStation, result.matchedFields);
    }
  }

  Widget _buildSongTile(Song song, List<String> matchedFields) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: song.albumArtUrl.isNotEmpty
            ? (song.albumArtUrl.startsWith('http')
                ? CachedNetworkImage(
                    imageUrl: song.albumArtUrl,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const Icon(Icons.music_note, size: 40),
                    errorWidget: (context, url, error) => const Icon(Icons.music_note, size: 40),
                  )
                : FutureBuilder<String>(
                    future: _resolveLocalArtPath(song.albumArtUrl),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasData &&
                          snapshot.data!.isNotEmpty) {
                        return Image.file(
                          File(snapshot.data!),
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40),
                        );
                      }
                      return const Icon(Icons.music_note, size: 40);
                    },
                  ))
            : const Icon(Icons.music_note, size: 40),
      ),
      title: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: _highlightMatchedText(song.title, matchedFields, 'title'),
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: DefaultTextStyle.of(context).style.copyWith(
                fontSize: 12,
                color: Colors.grey[600],
              ),
              children: _highlightMatchedText(song.artist, matchedFields, 'artist'),
            ),
          ),
          if (song.album != null)
            RichText(
              text: TextSpan(
                style: DefaultTextStyle.of(context).style.copyWith(
                  fontSize: 12,
                  color: Colors.grey[500],
                ),
                children: _highlightMatchedText(song.album!, matchedFields, 'album'),
              ),
            ),
          if (matchedFields.contains('lyrics'))
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Lyrics match',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.blue[700],
                ),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (song.isDownloaded)
            const Icon(Icons.download_done, color: Colors.green, size: 16),
          IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: () async {
              await currentSongProvider.playWithContext([song], song);
              widget.onResultTap?.call();
            },
          ),
        ],
      ),
      onTap: () async {
        await currentSongProvider.playWithContext([song], song);
        widget.onResultTap?.call();
      },
      onLongPress: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SongDetailScreen(song: song),
          ),
        );
      },
    );
  }

  Widget _buildAlbumTile(Album album, List<String> matchedFields) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: album.fullAlbumArtUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: album.fullAlbumArtUrl,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                placeholder: (context, url) => const Icon(Icons.album, size: 40),
                errorWidget: (context, url, error) => const Icon(Icons.album, size: 40),
              )
            : const Icon(Icons.album, size: 40),
      ),
      title: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: _highlightMatchedText(album.title, matchedFields, 'title'),
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: DefaultTextStyle.of(context).style.copyWith(
                fontSize: 12,
                color: Colors.grey[600],
              ),
              children: _highlightMatchedText(album.artistName, matchedFields, 'artist'),
            ),
          ),
          Text(
            '${album.tracks.length} tracks',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[500],
            ),
          ),
          if (matchedFields.contains('tracks'))
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Track match',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.orange[700],
                ),
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AlbumScreen(album: album),
          ),
        );
        widget.onResultTap?.call();
      },
    );
  }

  Widget _buildPlaylistTile(Playlist playlist, List<String> matchedFields) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.purple.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: const Icon(Icons.playlist_play, color: Colors.purple),
      ),
      title: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: _highlightMatchedText(playlist.name, matchedFields, 'name'),
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${playlist.songs.length} songs',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
          if (matchedFields.contains('songs'))
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Song match',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.purple[700],
                ),
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaylistDetailScreen(playlist: playlist),
          ),
        );
        widget.onResultTap?.call();
      },
    );
  }

  Widget _buildRadioStationTile(RadioStation station, List<String> matchedFields) {
    final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: RadioStationIcon(
          imageUrl: station.imageUrl,
          stationId: station.id,
          size: 40,
          borderRadius: BorderRadius.circular(8.0),
        ),
      ),
      title: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: _highlightMatchedText(station.name, matchedFields, 'name'),
        ),
      ),
      subtitle: Text(
        'Radio Station',
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.play_arrow),
        onPressed: () async {
          // Create a radio song object
          final radioSong = Song(
            title: station.name,
            id: station.id,
            artist: 'Radio',
            albumArtUrl: station.imageUrl,
            audioUrl: station.streamUrl,
            extras: {'isRadio': true, 'streamUrl': station.streamUrl},
          );
          await currentSongProvider.playWithContext([radioSong], radioSong);
          widget.onResultTap?.call();
        },
      ),
      onTap: () async {
        final radioSong = Song(
          title: station.name,
          id: station.id,
          artist: 'Radio',
          albumArtUrl: station.imageUrl,
          audioUrl: station.streamUrl,
          extras: {'isRadio': true, 'streamUrl': station.streamUrl},
        );
        await currentSongProvider.playWithContext([radioSong], radioSong);
        widget.onResultTap?.call();
      },
    );
  }

  List<TextSpan> _highlightMatchedText(String text, List<String> matchedFields, String fieldName) {
    if (!matchedFields.contains(fieldName) || widget.searchQuery.trim().isEmpty) {
      return [TextSpan(text: text)];
    }

    final query = widget.searchQuery.toLowerCase();
    final textLower = text.toLowerCase();
    final spans = <TextSpan>[];
    
    int start = 0;
    int index = textLower.indexOf(query);
    
    while (index != -1) {
      // Add text before match
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      
      // Add highlighted match
      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: const TextStyle(
          backgroundColor: Colors.yellow,
          fontWeight: FontWeight.bold,
        ),
      ));
      
      start = index + query.length;
      index = textLower.indexOf(query, start);
    }
    
    // Add remaining text
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    
    return spans;
  }

  Future<String> _resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty) return '';
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      if (await File(fullPath).exists()) {
        return fullPath;
      }
    } catch (e) {
      debugPrint('Error resolving local art path: $e');
    }
    return '';
  }
} 