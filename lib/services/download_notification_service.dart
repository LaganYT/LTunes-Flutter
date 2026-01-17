import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/song.dart';

class DownloadNotificationService {
  static final DownloadNotificationService _instance = DownloadNotificationService._internal();
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._internal();

  // Callback for handling notification actions
  Function(String)? _onNotificationAction;
  
  // AudioHandler instance for handling custom actions
  dynamic _audioHandler;

  static const int _downloadNotificationId = 1001;
  static const String _downloadChannelId = 'com.LTunes.channel.downloads';
  static const String _downloadChannelName = 'LTunes Downloads';
  static const String _downloadChannelDescription = 'Download progress and queue management';

  FlutterLocalNotificationsPlugin? _notifications;
  bool _isInitialized = false;
  
  // Add throttling for notification updates
  DateTime? _lastNotificationUpdate;
  static const Duration _updateThrottle = Duration(seconds: 5); // Update every 5 seconds instead of every second

  Future<void> initialize() async {
    if (_isInitialized) return;

    _notifications = FlutterLocalNotificationsPlugin();

    // Initialize settings for Android
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('mipmap/ic_launcher');

    // Initialize settings for iOS
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _notifications!.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel for Android
    await _createNotificationChannel();

    // Request permissions for both platforms
    await _requestPermissions();

    _isInitialized = true;
    debugPrint('DownloadNotificationService initialized');
  }

  Future<void> _createNotificationChannel() async {
    if (_notifications == null) return;

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _downloadChannelId,
      _downloadChannelName,
      description: _downloadChannelDescription,
      importance: Importance.none,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    await _notifications!.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
  }

  Future<void> _requestPermissions() async {
    if (_notifications == null) return;

    // Request permissions for Android 13+
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _notifications!.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      final bool? granted = await androidImplementation.requestNotificationsPermission();
      debugPrint('Android notification permission granted: $granted');
    }

    // Request permissions for iOS
    final IOSFlutterLocalNotificationsPlugin? iOSImplementation =
        _notifications!.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();

    if (iOSImplementation != null) {
      final bool? granted = await iOSImplementation.requestPermissions(
        alert: true,
        badge: true,
        sound: false,
        critical: false,
      );
      debugPrint('iOS notification permission granted: $granted');
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Download notification tapped: ${response.payload}, action: ${response.actionId}');
    
    if (response.actionId != null) {
      // Handle notification action
      debugPrint('Handling notification action: ${response.actionId}');
      if (_onNotificationAction != null) {
        try {
          _onNotificationAction!.call(response.actionId!);
          debugPrint('Notification action callback executed successfully');
        } catch (e) {
          debugPrint('Error executing notification action callback: $e');
        }
      } else {
        debugPrint('Warning: No notification action callback set');
      }
    } else {
      // Handle notification tap - send custom action to audio handler
      debugPrint('Notification tapped (no action), opening download queue');
      if (_audioHandler != null) {
        try {
          _audioHandler.customAction('openDownloadQueue', {});
          debugPrint('AudioHandler custom action executed successfully');
        } catch (e) {
          debugPrint('Error executing AudioHandler custom action: $e');
        }
      } else {
        debugPrint('Warning: No AudioHandler set for notification service');
      }
    }
  }

  void setNotificationActionCallback(Function(String) callback) {
    _onNotificationAction = callback;
    debugPrint('Download notification action callback set');
  }

  void setAudioHandler(dynamic audioHandler) {
    _audioHandler = audioHandler;
    debugPrint('AudioHandler set for download notification service');
  }

  Future<void> showDownloadNotification({
    required Map<String, Song> activeDownloads,
    required List<Song> queuedSongs,
    required Map<String, double> downloadProgress,
  }) async {
    if (!_isInitialized || _notifications == null) {
      await initialize();
    }

    // Throttle notification updates to reduce frequency
    final now = DateTime.now();
    if (_lastNotificationUpdate != null && 
        now.difference(_lastNotificationUpdate!) < _updateThrottle) {
      return; // Skip update if not enough time has passed
    }
    _lastNotificationUpdate = now;

    final int totalDownloads = activeDownloads.length + queuedSongs.length;
    
    if (totalDownloads == 0) {
      await hideDownloadNotification();
      return;
    }

    final int activeCount = activeDownloads.length;
    final int queuedCount = queuedSongs.length;

    String title;
    String body;

    if (activeCount > 0) {
      // Show active download status without progress percentage
      // BUG FIX: Check if activeDownloads is not empty before accessing .first
      if (activeDownloads.isNotEmpty) {
        final activeSong = activeDownloads.values.first;
        
        title = 'Downloading: ${activeSong.title}';
        body = 'Download in progress';
        if (queuedCount > 0) {
          body += ' • $queuedCount queued';
        }
      } else {
        // Fallback if somehow activeCount > 0 but map is empty
        title = 'Downloading';
        body = 'Download in progress';
        if (queuedCount > 0) {
          body += ' • $queuedCount queued';
        }
      }
    } else {
      // Show queued status
      title = 'Download Queue';
      body = '$queuedCount song(s) queued for download';
    }

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _downloadChannelId,
      _downloadChannelName,
      channelDescription: _downloadChannelDescription,
      importance: Importance.none,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      enableLights: false,
      playSound: false,
      enableVibration: false,
      category: AndroidNotificationCategory.progress,
      actions: [
        AndroidNotificationAction(
          'cancel_all', 
          'Cancel All', 
          showsUserInterface: false,
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          'view_queue', 
          'View Queue', 
          showsUserInterface: true,
          cancelNotification: false,
        ),
      ],
      // Remove progress support since we're not showing progress percentage
      showProgress: false,
      indeterminate: false,
    );

    const DarwinNotificationDetails iOSDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
      categoryIdentifier: 'download_progress',
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    try {
      await _notifications!.show(
        _downloadNotificationId,
        title,
        body,
        details,
        payload: 'download_queue',
      );
      debugPrint('Download notification shown: $title - $body');
    } catch (e) {
      debugPrint('Error showing download notification: $e');
    }
  }

  Future<void> hideDownloadNotification() async {
    if (!_isInitialized || _notifications == null) return;

    try {
      await _notifications!.cancel(_downloadNotificationId);
      debugPrint('Download notification hidden');
    } catch (e) {
      debugPrint('Error hiding download notification: $e');
    }
  }

  Future<void> updateDownloadProgress({
    required Map<String, Song> activeDownloads,
    required List<Song> queuedSongs,
    required Map<String, double> downloadProgress,
  }) async {
    // This method now respects the throttling in showDownloadNotification
    await showDownloadNotification(
      activeDownloads: activeDownloads,
      queuedSongs: queuedSongs,
      downloadProgress: downloadProgress,
    );
  }

  void dispose() {
    _isInitialized = false;
  }

  // Check if notifications are enabled
  Future<bool> areNotificationsEnabled() async {
    if (!_isInitialized || _notifications == null) {
      await initialize();
    }

    // Check Android permissions
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _notifications!.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      final bool? androidEnabled = await androidImplementation.areNotificationsEnabled();
      if (androidEnabled != null) {
        return androidEnabled;
      }
    }

    // For iOS, we'll assume notifications are enabled after initialization
    // since we request permissions during initialization
    return true;
  }

  // Test method to verify notification action handling
  Future<void> testNotificationAction() async {
    debugPrint('Testing notification action handling...');
    if (_onNotificationAction != null) {
      try {
        _onNotificationAction!.call('cancel_all');
        debugPrint('Test notification action executed successfully');
      } catch (e) {
        debugPrint('Test notification action failed: $e');
      }
    } else {
      debugPrint('No notification action callback set for testing');
    }
  }

  // Force update notification (bypasses throttling) for important state changes
  Future<void> forceUpdateNotification({
    required Map<String, Song> activeDownloads,
    required List<Song> queuedSongs,
    required Map<String, double> downloadProgress,
  }) async {
    if (!_isInitialized || _notifications == null) {
      await initialize();
    }

    // Temporarily reset the last update time to force an update
    _lastNotificationUpdate = null;
    
    await showDownloadNotification(
      activeDownloads: activeDownloads,
      queuedSongs: queuedSongs,
      downloadProgress: downloadProgress,
    );
  }
}