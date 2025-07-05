import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';

class DownloadNotificationService {
  static final DownloadNotificationService _instance = DownloadNotificationService._internal();
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._internal();

  // Callback for handling notification actions
  Function(String)? _onNotificationAction;

  static const int _downloadNotificationId = 1001;
  static const String _downloadChannelId = 'com.LTunes.channel.downloads';
  static const String _downloadChannelName = 'LTunes Downloads';
  static const String _downloadChannelDescription = 'Download progress and queue management';

  FlutterLocalNotificationsPlugin? _notifications;
  bool _isInitialized = false;

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

    // Request permissions for Android 13+
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
      importance: Importance.low,
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
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Download notification tapped: ${response.payload}, action: ${response.actionId}');
    
    if (response.actionId != null) {
      // Handle notification action
      _onNotificationAction?.call(response.actionId!);
    } else {
      // Handle notification tap - send custom action to audio handler
      AudioService.customAction('openDownloadQueue', {});
    }
  }

  void setNotificationActionCallback(Function(String) callback) {
    _onNotificationAction = callback;
    debugPrint('Download notification action callback set');
  }

  Future<void> showDownloadNotification({
    required Map<String, Song> activeDownloads,
    required List<Song> queuedSongs,
    required Map<String, double> downloadProgress,
  }) async {
    if (!_isInitialized || _notifications == null) {
      await initialize();
    }

    final int totalDownloads = activeDownloads.length + queuedSongs.length;
    
    if (totalDownloads == 0) {
      await hideDownloadNotification();
      return;
    }

    final int activeCount = activeDownloads.length;
    final int queuedCount = queuedSongs.length;

    String title;
    String body;
    double? progress;

    if (activeCount > 0) {
      // Show active download progress
      final activeSong = activeDownloads.values.first;
      final songProgress = downloadProgress[activeSong.id] ?? 0.0;
      
      title = 'Downloading: ${activeSong.title}';
      body = '${(songProgress * 100).toStringAsFixed(0)}% complete';
      if (queuedCount > 0) {
        body += ' • $queuedCount queued';
      }
      progress = songProgress;
    } else {
      // Show queued status
      title = 'Download Queue';
      body = '$queuedCount song(s) queued for download';
      progress = null;
    }

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _downloadChannelId,
      _downloadChannelName,
      channelDescription: _downloadChannelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      enableLights: false,
      playSound: false,
      enableVibration: false,
      category: AndroidNotificationCategory.progress,
      actions: [
        AndroidNotificationAction('cancel_all', 'Cancel All', showsUserInterface: false),
        AndroidNotificationAction('view_queue', 'View Queue', showsUserInterface: true),
      ],
      // Add progress support
      showProgress: progress != null,
      maxProgress: 100,
      progress: progress != null ? (progress * 100).round() : 0,
      indeterminate: progress == null,
    );

    const DarwinNotificationDetails iOSDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    await _notifications!.show(
      _downloadNotificationId,
      title,
      body,
      details,
      payload: 'download_queue',
    );

    debugPrint('Download notification shown: $title - $body');
  }

  Future<void> hideDownloadNotification() async {
    if (!_isInitialized || _notifications == null) return;

    await _notifications!.cancel(_downloadNotificationId);
    debugPrint('Download notification hidden');
  }

  Future<void> updateDownloadProgress({
    required Map<String, Song> activeDownloads,
    required List<Song> queuedSongs,
    required Map<String, double> downloadProgress,
  }) async {
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

    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _notifications!.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      return await androidImplementation.areNotificationsEnabled() ?? false;
    }

    return false;
  }
}