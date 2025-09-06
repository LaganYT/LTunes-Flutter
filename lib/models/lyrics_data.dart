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

  /// Factory constructor for backward compatibility with simple format
  factory LyricsData.fromSimpleResponse(Map<String, dynamic> json) {
    return LyricsData(
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'plainLyrics': plainLyrics,
        'syncedLyrics': syncedLyrics,
        'source': source,
        'trackInfo': trackInfo,
        'retrievedLrcEntry': retrievedLrcEntry,
      };
}
