class LyricsData {
  final String? plainLyrics;
  final String? syncedLyrics;
  final String? source;
  final Map<String, dynamic>? trackInfo;
  final Map<String, dynamic>? retrievedLrcEntry;

  LyricsData({
    this.plainLyrics,
    this.syncedLyrics,
    this.source,
    this.trackInfo,
    this.retrievedLrcEntry,
  });

  /// Returns syncedLyrics if non‐empty, otherwise plainLyrics or empty string.
  String get displayLyrics {
    if (syncedLyrics != null && syncedLyrics!.isNotEmpty) {
      return syncedLyrics!;
    }
    return plainLyrics ?? '';
  }

  /// Factory constructor to parse API v2 lyrics response
  factory LyricsData.fromApiV2Response(Map<String, dynamic> json) {
    final lyricsData = json['lyrics'] as Map<String, dynamic>? ?? {};

    return LyricsData(
      plainLyrics: lyricsData['plainLyrics'] as String?,
      syncedLyrics: lyricsData['syncedLyrics'] as String?,
      source: json['source'] as String?,
      trackInfo: json['trackInfo'] as Map<String, dynamic>?,
      retrievedLrcEntry: json['retrievedLrcEntry'] as Map<String, dynamic>?,
    );
  }

  /// Factory constructor for original API (fallback) lyrics response
  factory LyricsData.fromOriginalApiResponse(Map<String, dynamic> json) {
    // Original API returns lyrics in a nested structure
    final lyricsData = json['lyrics'] as Map<String, dynamic>? ?? {};

    return LyricsData(
      plainLyrics: lyricsData['plainLyrics'] as String?,
      syncedLyrics: lyricsData['syncedLyrics'] as String?,
      source: 'original_api', // Mark as coming from original API
      trackInfo: null, // Original API doesn't provide track info
      retrievedLrcEntry: null, // Original API doesn't provide LRC entry
    );
  }

  /// Factory constructor for backward compatibility with simple format
  factory LyricsData.fromSimpleResponse(Map<String, dynamic> json) {
    return LyricsData(
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
      source: 'simple_format',
    );
  }

  /// Universal factory constructor that tries to detect the API format
  factory LyricsData.fromAnyResponse(Map<String, dynamic> json) {
    // Check if it's API v2 format (has trackInfo or retrievedLrcEntry)
    if (json.containsKey('trackInfo') ||
        json.containsKey('retrievedLrcEntry')) {
      return LyricsData.fromApiV2Response(json);
    }

    // Check if it's original API format (has nested lyrics structure)
    if (json.containsKey('lyrics') && json['lyrics'] is Map<String, dynamic>) {
      return LyricsData.fromOriginalApiResponse(json);
    }

    // Fallback to simple format
    return LyricsData.fromSimpleResponse(json);
  }

  Map<String, dynamic> toJson() => {
        'plainLyrics': plainLyrics,
        'syncedLyrics': syncedLyrics,
        'source': source,
        'trackInfo': trackInfo,
        'retrievedLrcEntry': retrievedLrcEntry,
      };
}
