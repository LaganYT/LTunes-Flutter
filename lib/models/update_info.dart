import 'release_channel.dart';

class UpdateInfo {
  final String version;
  final String message;
  final String url;
  final bool mandatory;
  final ReleaseChannel channel;

  UpdateInfo({
    required this.version,
    required this.message,
    required this.url,
    this.mandatory = false,
    this.channel = ReleaseChannel.stable,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String,
      message: json['message'] as String,
      url: json['url'] as String,
      mandatory: json['mandatory'] as bool? ?? false,
      channel: ReleaseChannel.fromString(json['channel'] as String? ?? 'stable'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'message': message,
      'url': url,
      'mandatory': mandatory,
      'channel': channel.value,
    };
  }
}
