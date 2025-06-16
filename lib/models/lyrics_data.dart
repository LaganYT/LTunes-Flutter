class LyricsData {
  final String? plainLyrics;
  final String? syncedLyrics;

  LyricsData({this.plainLyrics, this.syncedLyrics});

  /// Returns syncedLyrics if non‐empty, otherwise plainLyrics or empty string.
  String get displayLyrics {
    if (syncedLyrics != null && syncedLyrics!.isNotEmpty) {
      return syncedLyrics!;
    }
    return plainLyrics ?? '';
  }
}
