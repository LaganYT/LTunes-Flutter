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
      // Network artwork
      provider = CachedNetworkImageProvider(artUrl);
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
