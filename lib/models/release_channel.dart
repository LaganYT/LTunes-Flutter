/// Enum representing different release channels for app updates
enum ReleaseChannel {
  /// Development channel - gets the latest builds, may be unstable
  dev('dev'),

  /// Beta channel - gets beta releases, more stable than dev but not final
  beta('beta'),

  /// Stable channel - gets only stable, production-ready releases
  stable('stable');

  const ReleaseChannel(this.value);

  /// String representation of the channel
  final String value;

  /// Display name for the UI
  String get displayName {
    switch (this) {
      case ReleaseChannel.dev:
        return 'Development';
      case ReleaseChannel.beta:
        return 'Beta';
      case ReleaseChannel.stable:
        return 'Stable';
    }
  }

  /// Description for the UI
  String get description {
    switch (this) {
      case ReleaseChannel.dev:
        return 'Get the latest features and updates, but may contain bugs';
      case ReleaseChannel.beta:
        return 'Get beta releases that are more stable than development';
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
