import 'dart:collection';

/// Service to handle song version detection and formatting
class VersionService {
  // Common version patterns to detect
  static final List<RegExp> _versionPatterns = [
    RegExp(r'\s*\(acoustic\s*version?\s*\)', caseSensitive: false),
    RegExp(r'\s*\(acoustic\)', caseSensitive: false),
    RegExp(r'\s*\(live\s*version?\s*\)', caseSensitive: false),
    RegExp(r'\s*\(live\)', caseSensitive: false),
    RegExp(r'\s*\(radio\s*edit\)', caseSensitive: false),
    RegExp(r'\s*\(remix\)', caseSensitive: false),
    RegExp(r'\s*\(extended\s*version?\s*\)', caseSensitive: false),
    RegExp(r'\s*\(extended\)', caseSensitive: false),
    RegExp(r'\s*\(instrumental\)', caseSensitive: false),
    RegExp(r'\s*\(karaoke\s*version?\s*\)', caseSensitive: false),
    RegExp(r'\s*\(demo\)', caseSensitive: false),
    RegExp(r'\s*\(unplugged\)', caseSensitive: false),
    RegExp(r'\s*\(stripped\)', caseSensitive: false),
    RegExp(r'\s*\(clean\s*version?\s*\)', caseSensitive: false),
    RegExp(r'\s*\(explicit\)', caseSensitive: false),
    RegExp(r'\s*\(remastered\)', caseSensitive: false),
    RegExp(r'\s*\(deluxe\s*version?\s*\)', caseSensitive: false),
  ];

  /// Extract version information from a song title
  /// Returns a map with 'baseTitle' and 'versions' list
  static Map<String, dynamic> extractVersionInfo(String title) {
    String baseTitle = title;
    List<String> versions = [];

    for (final pattern in _versionPatterns) {
      final matches = pattern.allMatches(baseTitle);
      for (final match in matches) {
        String version = match.group(0)!.trim();
        // Clean up the version string - remove parentheses and normalize
        version = version.replaceAll(RegExp(r'[()]'), '').trim();
        if (version.isNotEmpty) {
          versions.add(version);
        }
        // Remove the version from the base title
        baseTitle = baseTitle.replaceAll(pattern, '').trim();
      }
    }

    return {
      'baseTitle': baseTitle,
      'versions': versions,
    };
  }

  /// Get a formatted display title with version information highlighted
  static String getDisplayTitle(String title) {
    final versionInfo = extractVersionInfo(title);
    final baseTitle = versionInfo['baseTitle'] as String;
    final versions = versionInfo['versions'] as List<String>;

    if (versions.isEmpty) {
      return baseTitle;
    }

    // Format versions for display
    final formattedVersions = versions.map((v) => '($v)').join(' ');
    return '$baseTitle $formattedVersions';
  }

  /// Get the base title without version information
  static String getBaseTitle(String title) {
    final versionInfo = extractVersionInfo(title);
    return versionInfo['baseTitle'] as String;
  }

  /// Get all versions from a title
  static List<String> getVersions(String title) {
    final versionInfo = extractVersionInfo(title);
    return List<String>.from(versionInfo['versions'] as List);
  }

  /// Check if a title contains specific version types
  static bool hasAcousticVersion(String title) {
    return getVersions(title).any((v) => v.toLowerCase().contains('acoustic'));
  }

  static bool hasLiveVersion(String title) {
    return getVersions(title).any((v) => v.toLowerCase().contains('live'));
  }

  /// Create a search query that includes version information
  static String createSearchQuery(String artist, String title) {
    // For searching, we want to include the full title with versions
    // as it helps find the exact version the user is looking for
    return '$title $artist'.trim();
  }

  /// Create alternative search queries for better matching
  static List<String> createAlternativeSearchQueries(
      String artist, String title) {
    final queries = <String>[];

    // Primary query with full title
    queries.add(createSearchQuery(artist, title));

    // Query with base title only (in case versions don't match exactly)
    final baseTitle = getBaseTitle(title);
    if (baseTitle != title) {
      queries.add('$baseTitle $artist'.trim());
    }

    // Additional queries with normalized version terms
    final versions = getVersions(title);
    for (final version in versions) {
      if (version.toLowerCase().contains('acoustic')) {
        queries.add('$baseTitle acoustic $artist'.trim());
        queries.add('$baseTitle (acoustic) $artist'.trim());
      }
      if (version.toLowerCase().contains('live')) {
        queries.add('$baseTitle live $artist'.trim());
        queries.add('$baseTitle (live) $artist'.trim());
      }
    }

    // Remove duplicates while preserving order
    final uniqueQueries = LinkedHashSet<String>.from(queries);
    return uniqueQueries.toList();
  }

  /// Normalize version strings for better matching
  static String normalizeVersion(String version) {
    return version
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('version', '')
        .trim();
  }

  /// Calculate similarity score between two titles considering versions
  static double calculateVersionAwareSimilarity(String title1, String title2) {
    final info1 = extractVersionInfo(title1);
    final info2 = extractVersionInfo(title2);

    final baseTitle1 = (info1['baseTitle'] as String).toLowerCase();
    final baseTitle2 = (info2['baseTitle'] as String).toLowerCase();
    final versions1 = (info1['versions'] as List<String>)
        .map((v) => normalizeVersion(v))
        .toList();
    final versions2 = (info2['versions'] as List<String>)
        .map((v) => normalizeVersion(v))
        .toList();

    // Calculate base title similarity
    double titleSimilarity = _stringSimilarity(baseTitle1, baseTitle2);

    // Calculate version similarity
    double versionSimilarity = 0.0;
    if (versions1.isEmpty && versions2.isEmpty) {
      versionSimilarity = 1.0; // Both have no versions
    } else if (versions1.isNotEmpty && versions2.isNotEmpty) {
      // Both have versions, check for overlap
      final commonVersions = versions1
          .where((v1) => versions2.any((v2) => _stringSimilarity(v1, v2) > 0.7))
          .length;
      versionSimilarity = commonVersions /
          (versions1.length + versions2.length - commonVersions);
    } else {
      versionSimilarity = 0.5; // One has versions, one doesn't - partial match
    }

    // Weighted combination: title is more important than version
    return (titleSimilarity * 0.8) + (versionSimilarity * 0.2);
  }

  /// Simple string similarity calculation
  static double _stringSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;

    // Use contains-based similarity for simplicity
    if (s1.contains(s2) || s2.contains(s1)) {
      return 0.8;
    }

    // Check for partial matches
    final words1 = s1.split(' ');
    final words2 = s2.split(' ');
    final commonWords = words1.where((w1) => words2.contains(w1)).length;

    if (commonWords == 0) return 0.0;

    return (commonWords * 2.0) / (words1.length + words2.length);
  }
}
