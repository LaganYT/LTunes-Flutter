import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class BugReportService {
  static final BugReportService _instance = BugReportService._internal();
  factory BugReportService() => _instance;
  BugReportService._internal();

  // Discord webhook URL - this should be configured in your Discord server
  static const String _discordWebhookUrl =
      'https://discord.com/api/webhooks/1414386505605976125/ChE6IohRZHle7SvcaUwmReV6CB2WbZwKcJqWXD2maA_UDxzSfpsz5LtPWIPAS8gEbnk5';

  // Log file settings
  static const String _logFileName = 'app_logs.txt';
  static const int _maxLogSize = 100000; // 100KB max log size
  static const int _maxLogEntries = 1000; // Max number of log entries

  final List<LogEntry> _logEntries = [];
  File? _logFile;

  /// Initialize the logging system
  Future<void> initialize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _logFile = File(p.join(directory.path, _logFileName));

      // Load existing logs if file exists
      if (await _logFile!.exists()) {
        await _loadExistingLogs();
      }

      debugPrint('BugReportService: Initialized successfully');
    } catch (e) {
      debugPrint('BugReportService: Failed to initialize: $e');
    }
  }

  /// Log a message with timestamp and level
  void log(String message, {LogLevel level = LogLevel.info, String? context}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      context: context,
    );

    _logEntries.add(entry);

    // Keep only the most recent entries
    if (_logEntries.length > _maxLogEntries) {
      _logEntries.removeAt(0);
    }

    // Write to file asynchronously
    _writeToFile(entry);

    // Also print to debug console
    debugPrint(
        '${entry.level.name.toUpperCase()}: ${entry.context != null ? '[${entry.context}] ' : ''}${entry.message}');
  }

  /// Log an error with stack trace
  void logError(dynamic error, {String? context, StackTrace? stackTrace}) {
    final errorMessage = error.toString();
    final stackTraceString =
        stackTrace?.toString() ?? 'No stack trace available';

    log('ERROR: $errorMessage', level: LogLevel.error, context: context);
    log('STACK TRACE: $stackTraceString',
        level: LogLevel.error, context: context);
  }

  /// Log app lifecycle events
  void logAppLifecycle(String event) {
    log('App lifecycle: $event', level: LogLevel.info, context: 'Lifecycle');
  }

  /// Log user actions
  void logUserAction(String action, {Map<String, dynamic>? data}) {
    final dataString = data != null ? ' | Data: ${jsonEncode(data)}' : '';
    log('User action: $action$dataString',
        level: LogLevel.info, context: 'UserAction');
  }

  /// Log network requests
  void logNetworkRequest(String method, String url,
      {int? statusCode, String? error}) {
    final statusString = statusCode != null ? ' | Status: $statusCode' : '';
    final errorString = error != null ? ' | Error: $error' : '';
    log('Network: $method $url$statusString$errorString',
        level: LogLevel.info, context: 'Network');
  }

  /// Log audio events
  void logAudioEvent(String event, {Map<String, dynamic>? data}) {
    final dataString = data != null ? ' | Data: ${jsonEncode(data)}' : '';
    log('Audio: $event$dataString', level: LogLevel.info, context: 'Audio');
  }

  /// Get current log entries
  List<LogEntry> getLogEntries() {
    return List.unmodifiable(_logEntries);
  }

  /// Get logs as formatted string
  String getLogsAsString({int? maxEntries}) {
    final entries = maxEntries != null
        ? _logEntries.length > maxEntries
            ? _logEntries.skip(_logEntries.length - maxEntries).toList()
            : _logEntries
        : _logEntries;

    return entries.map((entry) => entry.toString()).join('\n');
  }

  /// Clear all logs
  Future<void> clearLogs() async {
    _logEntries.clear();
    if (_logFile != null && await _logFile!.exists()) {
      await _logFile!.delete();
    }
    log('Logs cleared', level: LogLevel.info, context: 'BugReport');
  }

  /// Test Discord webhook connection
  Future<bool> testWebhook() async {
    try {
      final testPayload = {
        'content': '🧪 LTunes Bug Report System Test - Webhook is working!',
        'username': 'LTunes Bug Reporter',
      };

      final response = await http.post(
        Uri.parse(_discordWebhookUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(testPayload),
      );

      if (response.statusCode == 204) {
        log('Webhook test successful',
            level: LogLevel.info, context: 'BugReport');
        return true;
      } else {
        log('Webhook test failed: ${response.statusCode} - ${response.body}',
            level: LogLevel.error, context: 'BugReport');
        return false;
      }
    } catch (e, stackTrace) {
      logError(e, context: 'BugReport', stackTrace: stackTrace);
      return false;
    }
  }

  /// Send bug report to Discord webhook
  Future<bool> sendBugReport({
    required String userDescription,
    String? userEmail,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      // Get app information
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceInfo = await _getDeviceInfo();

      // Get recent logs (last 50 entries or last 24 hours, whichever is smaller)
      final recentLogs = _getRecentLogs();

      // Create logs file for attachment
      final logsFile = await _createLogsFile(recentLogs);

      // Create simple message payload (embeds don't work well with file attachments)
      final message = '''🐛 **Bug Report - LTunes**

${userDescription.trim().isNotEmpty ? '**User Description:**\n$userDescription\n' : ''}**App Information:**
Version: ${packageInfo.version}
Build: ${packageInfo.buildNumber}
Package: ${packageInfo.packageName}
Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}

**Device Information:**
$deviceInfo

${userEmail != null ? '**Contact Email:** $userEmail\n' : ''}${additionalData != null ? '**Additional Data:** ${jsonEncode(additionalData)}\n' : ''}**Recent Logs:**
${recentLogs.isEmpty ? 'No recent logs available' : 'Logs attached as file (${recentLogs.split('\n').length} entries)'}

---
Reported at: ${DateTime.now().toIso8601String()}''';

      // Create Discord webhook payload
      final payload = {
        'content': message,
        'username': 'LTunes Bug Reporter',
      };

      // Validate payload before sending
      final payloadJson = jsonEncode(payload);
      if (payloadJson.length > 2000) {
        log('Payload too large (${payloadJson.length} chars), truncating message',
            level: LogLevel.warning, context: 'BugReport');

        // Truncate the message content
        final truncatedMessage = message.length > 1900
            ? '${message.substring(0, 1900)}...\n\n*Message truncated due to size limits*'
            : message;
        payload['content'] = truncatedMessage;
      }

      // Send to Discord webhook with file attachment (using fallback method directly)
      return await _sendFallbackBugReport(
        userDescription: userDescription,
        userEmail: userEmail,
        packageInfo: packageInfo,
        deviceInfo: deviceInfo,
        recentLogs: recentLogs,
        additionalData: additionalData,
        logsFile: logsFile,
      );
    } catch (e, stackTrace) {
      logError(e, context: 'BugReport', stackTrace: stackTrace);
      return false;
    }
  }

  /// Fallback method to send bug report as simple message
  Future<bool> _sendFallbackBugReport({
    required String userDescription,
    String? userEmail,
    required PackageInfo packageInfo,
    required String deviceInfo,
    required String recentLogs,
    Map<String, dynamic>? additionalData,
    File? logsFile,
  }) async {
    try {
      final message = '''🐛 **Bug Report - LTunes**

${userDescription.trim().isNotEmpty ? '**User Description:**\n$userDescription\n' : ''}**App Information:**
Version: ${packageInfo.version}
Build: ${packageInfo.buildNumber}
Package: ${packageInfo.packageName}
Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}

**Device Information:**
$deviceInfo

${userEmail != null ? '**Contact Email:** $userEmail\n' : ''}${additionalData != null ? '**Additional Data:** ${jsonEncode(additionalData)}\n' : ''}**Recent Logs:**
${recentLogs.isEmpty ? 'No recent logs available' : 'Logs attached as file (${recentLogs.split('\n').length} entries)'}

---
Reported at: ${DateTime.now().toIso8601String()}''';

      final payload = {
        'content': message.length > 2000
            ? '${message.substring(0, 1997)}...'
            : message,
        'username': 'LTunes Bug Reporter',
      };

      // Send Discord webhook with file attachment
      final request =
          http.MultipartRequest('POST', Uri.parse(_discordWebhookUrl));

      // Add the payload as a form field
      request.fields['payload_json'] = jsonEncode(payload);

      // Add logs file if available
      if (logsFile != null && await logsFile.exists()) {
        final fileStream = http.ByteStream(logsFile.openRead());
        final fileLength = await logsFile.length();
        final multipartFile = http.MultipartFile(
          'file',
          fileStream,
          fileLength,
          filename: 'ltunes_logs.txt',
        );
        request.files.add(multipartFile);
      }

      // Send the request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      // Log the response for debugging
      log('Discord webhook response: ${response.statusCode} - ${response.body}',
          level: LogLevel.info, context: 'BugReport');

      // Clean up the temporary file
      if (logsFile != null && await logsFile.exists()) {
        await logsFile.delete();
      }

      if (response.statusCode == 200 || response.statusCode == 204) {
        log('Bug report sent successfully',
            level: LogLevel.info, context: 'BugReport');
        return true;
      } else {
        log('Failed to send bug report: ${response.statusCode} - ${response.body}',
            level: LogLevel.error, context: 'BugReport');
        return false;
      }
    } catch (e, stackTrace) {
      logError(e, context: 'BugReport', stackTrace: stackTrace);
      return false;
    }
  }

  /// Get device information
  Future<String> _getDeviceInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();

      return '''
**OS:** ${Platform.operatingSystem} ${Platform.operatingSystemVersion}
**Dart Version:** ${Platform.version}
**Locale:** ${Platform.localeName}
**Number of Processes:** ${Platform.numberOfProcessors}
**SharedPreferences Keys:** ${keys.length} keys stored
      ''';
    } catch (e) {
      return 'Error getting device info: $e';
    }
  }

  /// Get recent logs (last 24 hours or last 50 entries)
  String _getRecentLogs() {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(hours: 24));

    final recentEntries = _logEntries
        .where((entry) => entry.timestamp.isAfter(yesterday))
        .take(50)
        .toList();

    if (recentEntries.isEmpty) {
      return 'No recent logs available';
    }

    return recentEntries.map((entry) => entry.toString()).join('\n');
  }

  /// Load existing logs from file
  Future<void> _loadExistingLogs() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return;

      final content = await _logFile!.readAsString();
      final lines = content.split('\n').where((line) => line.isNotEmpty);

      for (final line in lines) {
        try {
          final entry = LogEntry.fromString(line);
          _logEntries.add(entry);
        } catch (e) {
          // Skip malformed log entries
          continue;
        }
      }

      // Keep only the most recent entries
      if (_logEntries.length > _maxLogEntries) {
        _logEntries.removeRange(0, _logEntries.length - _maxLogEntries);
      }
    } catch (e) {
      debugPrint('BugReportService: Failed to load existing logs: $e');
    }
  }

  /// Write log entry to file
  Future<void> _writeToFile(LogEntry entry) async {
    try {
      if (_logFile == null) return;

      final logLine = '${entry.toString()}\n';
      await _logFile!.writeAsString(logLine, mode: FileMode.append);

      // Check file size and trim if necessary
      final fileSize = await _logFile!.length();
      if (fileSize > _maxLogSize) {
        await _trimLogFile();
      }
    } catch (e) {
      debugPrint('BugReportService: Failed to write to log file: $e');
    }
  }

  /// Trim log file to keep it under size limit
  Future<void> _trimLogFile() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return;

      final content = await _logFile!.readAsString();
      final lines = content.split('\n');

      // Keep only the last 70% of lines
      final keepLines = (lines.length * 0.7).round();
      final trimmedLines = lines.skip(lines.length - keepLines).toList();

      await _logFile!.writeAsString(trimmedLines.join('\n'));
    } catch (e) {
      debugPrint('BugReportService: Failed to trim log file: $e');
    }
  }

  /// Create a temporary logs file for attachment
  Future<File?> _createLogsFile(String logs) async {
    try {
      if (logs.isEmpty) return null;

      final directory = await getTemporaryDirectory();
      final logsFile = File(p.join(directory.path,
          'ltunes_logs_${DateTime.now().millisecondsSinceEpoch}.txt'));

      await logsFile.writeAsString(logs);
      return logsFile;
    } catch (e) {
      logError(e, context: 'BugReport');
      return null;
    }
  }
}

/// Log entry model
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? context;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.context,
  });

  @override
  String toString() {
    final contextStr = context != null ? '[$context] ' : '';
    return '${timestamp.toIso8601String()} [${level.name.toUpperCase()}] $contextStr$message';
  }

  /// Create LogEntry from string representation
  factory LogEntry.fromString(String logLine) {
    try {
      // Parse format: "2024-01-01T12:00:00.000Z [INFO] [Context] Message"
      final parts = logLine.split('] ');
      if (parts.length < 2) throw FormatException('Invalid log format');

      final timestampStr = parts[0].substring(0, parts[0].indexOf(' ['));
      final timestamp = DateTime.parse(timestampStr);

      final levelStr = parts[0].substring(parts[0].indexOf('[') + 1);
      final level = LogLevel.values.firstWhere(
        (l) => l.name.toUpperCase() == levelStr,
        orElse: () => LogLevel.info,
      );

      String message;
      String? context;

      if (parts.length == 2) {
        // No context
        message = parts[1];
      } else {
        // Has context
        final contextStr =
            parts[1].substring(1, parts[1].length - 1); // Remove brackets
        context = contextStr;
        message = parts[2];
      }

      return LogEntry(
        timestamp: timestamp,
        level: level,
        message: message,
        context: context,
      );
    } catch (e) {
      throw FormatException('Failed to parse log entry: $e');
    }
  }
}

/// Log levels
enum LogLevel {
  debug,
  info,
  warning,
  error,
}
