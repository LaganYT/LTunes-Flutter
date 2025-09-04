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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopBackgroundContinuityTimer();
    super.dispose();
  }

  void _startBackgroundContinuityTimer() {
    if (!Platform.isIOS) return;

    // Cancel existing timer if any
    _backgroundContinuityTimer?.cancel();

    // Start a timer that periodically ensures background playback continuity
    _backgroundContinuityTimer =
        Timer.periodic(const Duration(seconds: 15), (timer) {
      _audioHandler.customAction('ensureBackgroundPlaybackContinuity', {});
    });

    // Also add a timer for audio session restoration
    Timer.periodic(const Duration(seconds: 30), (timer) {
      _audioHandler.customAction('restoreAudioSession', {});
    });
  }

  void _stopBackgroundContinuityTimer() {
    _backgroundContinuityTimer?.cancel();
    _backgroundContinuityTimer = null;
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
        _startBackgroundContinuityTimer();
        break;
      case AppLifecycleState.detached:
        // App is being terminated, ensure background playback is configured
        _audioHandler.customAction('ensureBackgroundPlayback', {});
        _stopBackgroundContinuityTimer();
        // MetadataHistoryService().clearHistory(); // Removed: never clear metadata history
        break;
      case AppLifecycleState.hidden:
        // App is hidden (iOS specific), ensure background playback
        _audioHandler.customAction('handleAppBackground', {});
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
          // This helps prevent audio session from being deactivated
          _audioHandler.customAction('ensureBackgroundPlayback', {});

          // Add a single session activation check after 5 seconds
          Future.delayed(const Duration(seconds: 5), () {
            _audioHandler.customAction('forceSessionActivation', {});
          });

          // Add audio session restoration check after 15 seconds
          Future.delayed(const Duration(seconds: 15), () {
            _audioHandler.customAction('restoreAudioSession', {});
          });

          // Add background playback continuity check after 30 seconds
          Future.delayed(const Duration(seconds: 30), () {
            _audioHandler
                .customAction('ensureBackgroundPlaybackContinuity', {});
          });

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
            type: BottomNavigationBarType
                .fixed, // Ensure icons and labels align properly
            items: const <BottomNavigationBarItem>[
              BottomNavigationBarItem(
                icon: Icon(Icons.search, size: 28),
                label: 'Search',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.library_music, size: 28),
                label: 'Library',
              ),
              BottomNavigationBarItem(
                icon:
                    Icon(Icons.settings, size: 28), // Keep settings at the end
                label: 'Settings',
              ),
            ],
            currentIndex: _selectedIndex,
            selectedItemColor: Theme.of(context)
                .colorScheme
                .primary, // Use theme's primary color
            unselectedItemColor:
                Colors.grey, // Add unselected color for better contrast
            onTap: _onItemTapped,
            showUnselectedLabels:
                true, // Ensure labels are visible for all items
          ),
        ],
      ),
    );
  }
}
