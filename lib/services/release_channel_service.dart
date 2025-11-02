import 'package:shared_preferences/shared_preferences.dart';
import '../models/release_channel.dart';

/// Service to manage release channel preferences and logic
class ReleaseChannelService {
  static const String _channelKey = 'selected_release_channel';

  static final ReleaseChannelService _instance =
      ReleaseChannelService._internal();

  factory ReleaseChannelService() {
    return _instance;
  }

  ReleaseChannelService._internal();

  /// Get the currently selected release channel
  Future<ReleaseChannel> getSelectedChannel() async {
    final prefs = await SharedPreferences.getInstance();
    final channelString = prefs.getString(_channelKey);
    return ReleaseChannel.fromString(channelString ?? 'stable');
  }

  /// Set the selected release channel
  Future<void> setSelectedChannel(ReleaseChannel channel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_channelKey, channel.value);
  }

  /// Get the update URL for the specified channel
  String getUpdateUrlForChannel(ReleaseChannel channel) {
    const baseUrl = 'https://ltn-api.vercel.app/updates/';

    switch (channel) {
      case ReleaseChannel.dev:
        return '${baseUrl}dev.json';
      case ReleaseChannel.beta:
        return '${baseUrl}beta.json';
      case ReleaseChannel.stable:
        return '${baseUrl}update.json';
    }
  }

  /// Get the update URL for the currently selected channel
  Future<String> getCurrentUpdateUrl() async {
    final channel = await getSelectedChannel();
    return getUpdateUrlForChannel(channel);
  }

  /// Check if a channel is more advanced than the current one
  /// Returns true if the given channel gets updates before the current channel
  Future<bool> isChannelMoreAdvanced(ReleaseChannel channel) async {
    final currentChannel = await getSelectedChannel();

    // Priority order: dev > beta > stable
    final channelPriority = {
      ReleaseChannel.dev: 3,
      ReleaseChannel.beta: 2,
      ReleaseChannel.stable: 1,
    };

    return channelPriority[channel]! > channelPriority[currentChannel]!;
  }

  /// Get all available channels for UI display
  List<ReleaseChannel> getAvailableChannels() {
    return ReleaseChannel.values;
  }
}
