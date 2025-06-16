class UpdateInfo {
  final String version;
  final String message;
  final String url;

  UpdateInfo({
    required this.version,
    required this.message,
    required this.url,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String,
      message: json['message'] as String,
      url: json['url'] as String,
    );
  }
}
