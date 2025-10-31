import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Centralized service for handling artwork across the app
/// This ensures consistent behavior for both local and network artwork
class ArtworkService {
  static final ArtworkService _instance = ArtworkService._internal();
  factory ArtworkService() => _instance;
  ArtworkService._internal();

  // Cache for local art paths to prevent repeated file system calls
  final Map<String, String> _localArtPathCache = {};
  
  // Cache for artwork providers to prevent recreation
  final Map<String, ImageProvider> _artworkProviderCache = {};

  /// Get a robust artwork provider that handles both local and network artwork
  Future<ImageProvider> getArtworkProvider(String artUrl) async {
    if (artUrl.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    // Check cache first
    if (_artworkProviderCache.containsKey(artUrl)) {
      return _artworkProviderCache[artUrl]!;
    }

    ImageProvider provider;

    if (artUrl.startsWith('http')) {
      // Network artwork with memory optimization
      provider = CachedNetworkImageProvider(
        artUrl,
        maxHeight: 300, // Limit image size for memory efficiency
        maxWidth: 300,
      );
    } else {
      // Local artwork - resolve the full path
      final fullPath = await resolveLocalArtPath(artUrl);
      if (fullPath.isNotEmpty && await File(fullPath).exists()) {
        provider = FileImage(File(fullPath));
      } else {
        // Fallback to placeholder if local file doesn't exist
        provider = const AssetImage('assets/placeholder.png');
      }
    }

    // Cache the provider
    _artworkProviderCache[artUrl] = provider;
    return provider;
  }

  /// Pre-load artwork providers for a list of URLs to reduce FutureBuilder usage
  Future<void> preloadArtworkProviders(List<String> artUrls) async {
    final futures = <Future>[];

    for (final artUrl in artUrls) {
      if (artUrl.isNotEmpty && !_artworkProviderCache.containsKey(artUrl)) {
        futures.add(getArtworkProvider(artUrl));
      }
    }

    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  /// Get artwork provider synchronously if available, otherwise return placeholder
  ImageProvider getArtworkProviderSync(String artUrl) {
    if (artUrl.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    // Check cache first
    if (_artworkProviderCache.containsKey(artUrl)) {
      return _artworkProviderCache[artUrl]!;
    }

    // Return placeholder and trigger async loading
    getArtworkProvider(artUrl); // This will cache it for future use
    return const AssetImage('assets/placeholder.png');
  }

  /// Get a thumbnail-sized artwork provider (optimized for lists)
  Future<ImageProvider> getThumbnailArtworkProvider(String artUrl) async {
    if (artUrl.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    final thumbnailKey = '${artUrl}_thumbnail';

    // Check cache first
    if (_artworkProviderCache.containsKey(thumbnailKey)) {
      return _artworkProviderCache[thumbnailKey]!;
    }

    ImageProvider provider;

    if (artUrl.startsWith('http')) {
      // Network artwork with smaller dimensions for thumbnails
      provider = CachedNetworkImageProvider(
        artUrl,
        maxHeight: 150, // Smaller for thumbnails
        maxWidth: 150,
      );
    } else {
      // Local artwork - resolve the full path
      final fullPath = await resolveLocalArtPath(artUrl);
      if (fullPath.isNotEmpty && await File(fullPath).exists()) {
        provider = FileImage(File(fullPath));
      } else {
        provider = const AssetImage('assets/placeholder.png');
      }
    }

    // Cache with thumbnail key
    _artworkProviderCache[thumbnailKey] = provider;
    return provider;
  }

  /// Get a high-quality artwork provider (for full-screen player)
  Future<ImageProvider> getHighQualityArtworkProvider(String artUrl) async {
    if (artUrl.isEmpty) {
      return const AssetImage('assets/placeholder.png');
    }

    final hqKey = '${artUrl}_hq';

    // Check cache first
    if (_artworkProviderCache.containsKey(hqKey)) {
      return _artworkProviderCache[hqKey]!;
    }

    ImageProvider provider;

    if (artUrl.startsWith('http')) {
      // Network artwork with higher quality
      provider = CachedNetworkImageProvider(
        artUrl,
        maxHeight: 600, // Higher quality for full-screen
        maxWidth: 600,
      );
    } else {
      // Local artwork - resolve the full path
      final fullPath = await resolveLocalArtPath(artUrl);
      if (fullPath.isNotEmpty && await File(fullPath).exists()) {
        provider = FileImage(File(fullPath));
      } else {
        provider = const AssetImage('assets/placeholder.png');
      }
    }

    // Cache with HQ key
    _artworkProviderCache[hqKey] = provider;
    return provider;
  }

  /// Resolve a local artwork filename to its full path
  Future<String> resolveLocalArtPath(String fileName) async {
    if (fileName.isEmpty || fileName.startsWith('http')) {
      return '';
    }

    // Check cache first
    if (_localArtPathCache.containsKey(fileName)) {
      return _localArtPathCache[fileName]!;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final fullPath = p.join(directory.path, fileName);
      
      if (await File(fullPath).exists()) {
        _localArtPathCache[fileName] = fullPath;
        return fullPath;
      }
    } catch (e) {
      debugPrint('Error resolving local art path: $e');
    }

    return '';
  }

  /// Get a widget that displays artwork with proper error handling
  Widget getArtworkWidget(
    String artUrl, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
    Widget? placeholder,
    Widget? errorWidget,
  }) {
    if (artUrl.isEmpty) {
      return _buildPlaceholder(width, height, placeholder);
    }

    // Try to get provider synchronously first
    final cachedProvider = getArtworkProviderSync(artUrl);
    if (_artworkProviderCache.containsKey(artUrl)) {
      // Provider is cached, use it directly
      return Image(
        image: cachedProvider,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return _buildErrorWidget(width, height, errorWidget);
        },
      );
    }

    // Provider not cached yet, use FutureBuilder but only once
    return FutureBuilder<ImageProvider>(
      future: getArtworkProvider(artUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          return Image(
            image: snapshot.data!,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (context, error, stackTrace) {
              return _buildErrorWidget(width, height, errorWidget);
            },
          );
        }

        // Loading state
        return _buildPlaceholder(width, height, placeholder);
      },
    );
  }

  /// Clear the cache (useful for memory management)
  void clearCache() {
    _localArtPathCache.clear();
    _artworkProviderCache.clear();
  }

  /// Remove specific artwork from cache
  void removeFromCache(String artUrl) {
    _localArtPathCache.remove(artUrl);
    _artworkProviderCache.remove(artUrl);
    // Also remove thumbnail and HQ variants
    _artworkProviderCache.remove('${artUrl}_thumbnail');
    _artworkProviderCache.remove('${artUrl}_hq');
  }

  /// Clear cache for low memory situations
  void clearCacheForLowMemory() {
    // Keep only essential cached items, clear others to free memory
    final essentialKeys = <String>{};

    // Keep thumbnail variants as they're smaller
    _artworkProviderCache.removeWhere((key, value) {
      if (key.contains('_thumbnail') || key.contains('_hq')) {
        return false; // Keep thumbnails and HQ
      }
      return !essentialKeys.contains(key);
    });

    // Clear some local path cache but keep recent ones
    if (_localArtPathCache.length > 50) {
      final keysToKeep = _localArtPathCache.keys.take(25).toSet();
      _localArtPathCache.removeWhere((key, value) => !keysToKeep.contains(key));
    }

    debugPrint('ArtworkService: Cleared cache for low memory situation');
  }

  /// Get cache statistics for monitoring
  Map<String, int> getCacheStats() {
    return {
      'localArtPaths': _localArtPathCache.length,
      'artworkProviders': _artworkProviderCache.length,
    };
  }

  /// Check if artwork is available locally
  Future<bool> isArtworkAvailableLocally(String fileName) async {
    if (fileName.isEmpty || fileName.startsWith('http')) {
      return false;
    }
    
    final fullPath = await resolveLocalArtPath(fileName);
    return fullPath.isNotEmpty && await File(fullPath).exists();
  }

  /// Get the full local path for artwork if it exists
  Future<String?> getLocalArtworkPath(String fileName) async {
    if (fileName.isEmpty || fileName.startsWith('http')) {
      return null;
    }
    
    final fullPath = await resolveLocalArtPath(fileName);
    if (fullPath.isNotEmpty && await File(fullPath).exists()) {
      return fullPath;
    }
    return null;
  }

  Widget _buildPlaceholder(double? width, double? height, Widget? placeholder) {
    if (placeholder != null) {
      return SizedBox(
        width: width,
        height: height,
        child: placeholder,
      );
    }
    
    return Container(
      width: width,
      height: height,
      color: Colors.grey[700],
      child: Icon(
        Icons.music_note,
        size: (width ?? 48) * 0.6,
        color: Colors.white70,
      ),
    );
  }

  Widget _buildErrorWidget(double? width, double? height, Widget? errorWidget) {
    if (errorWidget != null) {
      return SizedBox(
        width: width,
        height: height,
        child: errorWidget,
      );
    }
    
    return Container(
      width: width,
      height: height,
      color: Colors.grey[700],
      child: Icon(
        Icons.music_note,
        size: (width ?? 48) * 0.6,
        color: Colors.white70,
      ),
    );
  }
}

// Global instance for easy access
final artworkService = ArtworkService();
