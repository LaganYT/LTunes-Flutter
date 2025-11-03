import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import './screens/search_screen.dart'; // Import the new SearchScreen
import 'screens/library_screen.dart'; // Import the ModernLibraryScreen
import './screens/settings_screen.dart'; // Import for ThemeProvider
import 'widgets/playbar.dart';
import 'providers/current_song_provider.dart';
import 'services/api_service.dart'; // Import ApiService
import 'services/error_handler_service.dart'; // Import ErrorHandlerService
import 'models/update_info.dart'; // Import UpdateInfo
import 'package:url_launcher/url_launcher.dart'; // Import url_launcher
import 'package:package_info_plus/package_info_plus.dart'; // Import package_info_plus
import 'package:audio_service/audio_service.dart'; // Import audio_service
import 'services/audio_handler.dart'; // Import your AudioPlayerHandler
import 'services/album_manager_service.dart'; // Import AlbumManagerService
import 'services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'services/download_notification_service.dart'; // Import DownloadNotificationService
import 'services/metadata_history_service.dart'; // Import MetadataHistoryService
import 'services/animation_service.dart'; // Import AnimationService
import 'services/bug_report_service.dart'; // Import BugReportService
import 'services/artwork_service.dart'; // Import ArtworkService
import 'services/liked_songs_service.dart'; // Import LikedSongsService
import 'dart:io'; // Import for Platform
import 'dart:async'; // Import for Timer
import 'package:shared_preferences/shared_preferences.dart'; // Import for SharedPreferences
import 'package:flutter/services.dart'; // For MethodChannel

// Global instance of the AudioPlayerHandler
late AudioHandler _audioHandler;

// Global navigator key for navigation from notifications
final GlobalKey<NavigatorState> globalNavigatorKey =
    GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Required for audio_service

  // Initialize download notification service
  await DownloadNotificationService().initialize();

  // Initialize bug report service
  await BugReportService().initialize();

  _audioHandler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.LTunes.channel.audio',
      androidNotificationChannelName: 'LTunes Audio Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
      // Enhanced iOS specific configuration for background playback
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationClickStartsActivity: true,
      artDownscaleWidth: 300,
      artDownscaleHeight: 300,
      // Enhanced iOS background audio configuration
      androidNotificationChannelDescription: 'LTunes audio playback controls',
      notificationColor: Color(0xFF2196F3),
    ),
  );

  // Add Bluetooth event MethodChannel listener
  const bluetoothChannel = MethodChannel('bluetooth_events');
  bluetoothChannel.setMethodCallHandler((call) async {
    if (call.method == 'bluetooth_connected') {
      // Re-activate audio session on Bluetooth reconnect
      await _audioHandler.customAction('forceSessionActivation', {});
    } else if (call.method == 'bluetooth_disconnected') {
      // Optionally handle disconnect
      debugPrint('Bluetooth disconnected');
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        // Provide the _audioHandler instance to CurrentSongProvider
        ChangeNotifierProvider(
          create: (context) => CurrentSongProvider(_audioHandler),
        ),
        ChangeNotifierProvider(
            create: (context) =>
                PlaylistManagerService()), // Assuming this was already here or needed
        ChangeNotifierProvider(
            create: (context) =>
                AlbumManagerService()), // Add AlbumManagerService
        ChangeNotifierProvider(
            create: (context) =>
                AnimationService.instance), // Add AnimationService
        ChangeNotifierProvider(
            create: (context) => LikedSongsService()), // Add LikedSongsService
      ],
      child: const LTunesApp(),
    ),
  );
}

class LTunesApp extends StatelessWidget {
  const LTunesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return Consumer<AnimationService>(
          builder: (context, animationService, child) {
            return MaterialApp(
              title: 'LTunes',
              theme: themeProvider.lightTheme,
              darkTheme: themeProvider.darkTheme,
              themeMode: themeProvider.themeMode,
              navigatorKey: globalNavigatorKey,
              home: const TabView(),
            );
          },
        );
      },
    );
  }
}

class TabView extends StatefulWidget {
  const TabView({super.key});

  @override
  State<TabView> createState() => _TabViewState();
}

class _TabViewState extends State<TabView> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  Timer? _backgroundContinuityTimer;
  Timer? _intensiveBackgroundTimer;
  int _backgroundContinuityCount = 0;
  Timer? _sessionRestorationTimer;

  // Widget list is now built dynamically in the build method
  // static final List<Widget> _widgetOptions = <Widget>[
  //   const SearchScreen(),
  //   const LibraryScreen(),
  //   const SettingsScreen(),
  // ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeVersionAndCheckForUpdates();

    // Ensure audio session is initialized when app opens
    _audioHandler.customAction('ensureAudioSessionInitialized', {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopBackgroundContinuityTimer();

    // Perform memory cleanup when TabView is disposed
    _performMemoryCleanup();
    super.dispose();
  }

  void _startBackgroundContinuityTimer() {
    if (!Platform.isIOS) return;

    // Cancel existing timers if any
    _backgroundContinuityTimer?.cancel();
    _intensiveBackgroundTimer?.cancel();
    _sessionRestorationTimer?.cancel();
    _backgroundContinuityCount = 0;

    // Single consolidated timer for all background operations
    // Start with moderate frequency and gradually reduce
    _backgroundContinuityTimer =
        Timer.periodic(const Duration(seconds: 60), (timer) {
      // Add error handling to prevent crashes
      try {
        // Check if widget is still mounted before proceeding
        if (!mounted) {
          timer.cancel();
          return;
        }

        _backgroundContinuityCount++;

        // Perform continuity check
        _audioHandler.customAction('ensureBackgroundPlaybackContinuity', {});

        // Every 10 minutes, also check session restoration (every 10th iteration)
        if (_backgroundContinuityCount % 10 == 0) {
          _audioHandler.customAction('restoreAudioSession', {});
        }

        // After 30 minutes, reduce frequency to every 5 minutes
        if (_backgroundContinuityCount >= 30) {
          timer.cancel();
          _backgroundContinuityCount = 0; // Reset counter for new timer
          _backgroundContinuityTimer =
              Timer.periodic(const Duration(minutes: 5), (regularTimer) {
            try {
              // Check if widget is still mounted before proceeding
              if (!mounted) {
                regularTimer.cancel();
                return;
              }

              _backgroundContinuityCount++;

              _audioHandler
                  .customAction('ensureBackgroundPlaybackContinuity', {});
              // Check session every other time (every 10 minutes)
              if (_backgroundContinuityCount % 2 == 0) {
                _audioHandler.customAction('restoreAudioSession', {});
              }
            } catch (e) {
              debugPrint(
                  "Main: Error in background continuity timer (5min): $e");
            }
          });
          debugPrint(
              "Main: Reduced background continuity timer to 5 minute intervals");
        }
      } catch (e) {
        debugPrint("Main: Error in background continuity timer (60s): $e");
      }
    });

    debugPrint(
        "Main: Started optimized background continuity timer (60s intervals)");
  }

  void _stopBackgroundContinuityTimer() {
    _backgroundContinuityTimer?.cancel();
    _backgroundContinuityTimer = null;
    _backgroundContinuityCount = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Enhanced app lifecycle handling for iOS background playback
    switch (state) {
      case AppLifecycleState.resumed:
        // App is coming back to foreground - handle audio first, then provider
        _audioHandler.customAction('handleAppForeground', {}).then((_) {
          // Then sync position and check for stuck loading states in the CurrentSongProvider
          Provider.of<CurrentSongProvider>(context, listen: false)
              .handleAppForeground()
              .then((_) {
            debugPrint("Main: App resumed - audio handler and provider synced");
          });
        });
        _stopBackgroundContinuityTimer();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App is going to background, ensure audio session stays active
        _audioHandler.customAction('handleAppBackground', {});
        // Save current state before going to background
        Provider.of<CurrentSongProvider>(context, listen: false)
            .saveStateToStorage();
        _startBackgroundContinuityTimer();

        // Perform light memory cleanup when going to background
        artworkService.clearCacheForLowMemory();
        break;
      case AppLifecycleState.detached:
        // App is being terminated, ensure background playback is configured
        _audioHandler.customAction('ensureBackgroundPlayback', {});
        // Save current state before app termination
        Provider.of<CurrentSongProvider>(context, listen: false)
            .saveStateToStorage();
        _stopBackgroundContinuityTimer();

        // Memory cleanup on app termination
        _performMemoryCleanup();
        // MetadataHistoryService().clearHistory(); // Removed: never clear metadata history
        break;
      case AppLifecycleState.hidden:
        // App is hidden (iOS specific), ensure background playback
        _audioHandler.customAction('handleAppBackground', {});
        // Save current state before going to background
        Provider.of<CurrentSongProvider>(context, listen: false)
            .saveStateToStorage();
        _startBackgroundContinuityTimer();
        break;
    }

    debugPrint("App lifecycle state changed to: $state");

    // Additional iOS-specific handling for background playback
    if (Platform.isIOS) {
      switch (state) {
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
          // For iOS, ensure background playback is immediately configured
          // The background continuity timer handles ongoing session management
          _audioHandler.customAction('ensureBackgroundPlayback', {});
          break;
        default:
          break;
      }
    }

    // Set global background/foreground state for download notifications
    switch (state) {
      case AppLifecycleState.resumed:
        CurrentSongProvider.isAppInBackground = false;
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        CurrentSongProvider.isAppInBackground = true;
        break;
    }
  }

  Future<void> _initializeVersionAndCheckForUpdates() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String version = packageInfo.version;

    if (mounted) {
      _checkForUpdates(version);
    }
  }

  Future<void> _checkForUpdates(String currentAppVersion) async {
    final apiService = ApiService();
    final errorHandler = ErrorHandlerService();

    try {
      final updateInfo = await apiService.checkForUpdate(currentAppVersion);
      if (updateInfo != null && mounted) {
        // Always show mandatory updates regardless of auto-check setting
        if (updateInfo.mandatory) {
          _showMandatoryUpdateDialog(updateInfo);
        } else {
          // For non-mandatory updates, check if auto update checking is enabled
          final prefs = await SharedPreferences.getInstance();
          final autoCheckForUpdates =
              prefs.getBool('autoCheckForUpdates') ?? true;

          // If auto check is disabled, don't proceed for non-mandatory updates
          if (autoCheckForUpdates) {
            _showUpdateDialog(updateInfo);
          }
        }
      }
    } catch (e) {
      errorHandler.logError(e, context: 'checkForUpdates');
      // Don't show error to user for update checks as they're not critical
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo updateInfo) async {
    if (!mounted) return;
    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async gap
    showDialog(
      context: context,
      barrierDismissible: false, // User must interact with the dialog
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Update Available'),
          content: Text(updateInfo.message),
          actions: <Widget>[
            TextButton(
              child: const Text('Later'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Update Now'),
              onPressed: () async {
                Navigator.of(context).pop();
                final Uri url = Uri.parse(updateInfo.url);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } else {
                  // Use captured scaffoldMessenger instead of context after async
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                        content: Text('Could not launch ${updateInfo.url}')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showMandatoryUpdateDialog(UpdateInfo updateInfo) async {
    if (!mounted) return;
    final scaffoldMessenger =
        ScaffoldMessenger.of(context); // Capture before async gap

    // Show a non-dismissible dialog for mandatory updates
    showDialog(
      context: context,
      barrierDismissible: false, // Cannot be dismissed by tapping outside
      builder: (BuildContext context) {
        return PopScope(
          canPop: false, // Prevent back button from closing dialog
          child: Dialog(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.9,
                maxHeight: MediaQuery.of(context).size.height * 0.8,
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title with warning icon
                  Row(
                    children: [
                      Icon(Icons.warning, color: Colors.orange, size: 24),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mandatory Update Required',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  // Content
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'A critical update is required to continue using the app.',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 12),
                          Text(
                            updateInfo.message,
                            style: TextStyle(fontSize: 14),
                          ),
                          SizedBox(height: 12),
                          Text(
                            'You must update the app to continue.',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 20),
                  // Action button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text(
                        'Update Now',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () async {
                        final Uri url = Uri.parse(updateInfo.url);
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url,
                              mode: LaunchMode.externalApplication);
                        } else {
                          // Use captured scaffoldMessenger instead of context after async
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                                content:
                                    Text('Could not launch ${updateInfo.url}')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _performMemoryCleanup() {
    try {
      // Clear artwork caches to free memory
      artworkService.clearCacheForLowMemory();

      // Cancel any pending timers
      _backgroundContinuityTimer?.cancel();
      _intensiveBackgroundTimer?.cancel();
      _sessionRestorationTimer?.cancel();

      debugPrint("Main: Performed memory cleanup on app termination");
    } catch (e) {
      debugPrint("Main: Error during memory cleanup: $e");
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> widgetOptions = <Widget>[
      const SearchScreen(),
      const ModernLibraryScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: Center(
        child: widgetOptions.elementAt(_selectedIndex),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Playbar(),
          ),
          BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            items: const <BottomNavigationBarItem>[
              BottomNavigationBarItem(
                icon: Icon(Icons.search, size: 28),
                label: '',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.library_music, size: 28),
                label: '',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings, size: 28),
                label: '',
              ),
            ],
            currentIndex: _selectedIndex,
            selectedItemColor: Theme.of(context)
                .colorScheme
                .primary, // Use theme's primary color
            unselectedItemColor:
                Colors.grey, // Add unselected color for better contrast
            onTap: _onItemTapped,
            showUnselectedLabels: false,
            selectedFontSize: 0,
            unselectedFontSize: 0,
          ),
        ],
      ),
    );
  }
}
