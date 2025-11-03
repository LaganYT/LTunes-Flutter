/// Enum representing different release channels for app updates
enum ReleaseChannel {
  /// Stable channel - gets only stable, production-ready releases
  stable('stable'),

  /// Beta channel - gets beta releases, tested but may contain minor bugs
  beta('beta');

  const ReleaseChannel(this.value);

  /// String representation of the channel
  final String value;

  /// Display name for the UI
  String get displayName {
    switch (this) {
      case ReleaseChannel.beta:
        return 'Beta';
      case ReleaseChannel.stable:
        return 'Stable';
    }
  }

  /// Description for the UI
  String get description {
    switch (this) {
      case ReleaseChannel.beta:
        return 'Get beta releases that are tested but may contain minor bugs';
      case ReleaseChannel.stable:
        return 'Get only stable, production-ready releases';
    }
  }

  /// Create from string value
  static ReleaseChannel fromString(String value) {
    return ReleaseChannel.values.firstWhere(
      (channel) => channel.value == value,
      orElse: () => ReleaseChannel.stable, // Default to stable
    );
  }
}
