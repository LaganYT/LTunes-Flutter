import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import './screens/search_screen.dart'; // Import the new SearchScreen
import 'screens/library_screen.dart'; // Import the ModernLibraryScreen
import './screens/settings_screen.dart'; // Import for ThemeProvider
import 'widgets/playbar.dart';
import 'widgets/desktop_playbar.dart';
import 'screens/desktop_library_screen.dart';
import 'screens/desktop_search_screen.dart';
import 'screens/desktop_liked_songs_screen.dart';
import 'providers/current_song_provider.dart';
import 'services/api_service.dart'; // Import ApiService
import 'services/error_handler_service.dart'; // Import ErrorHandlerService
import 'models/update_info.dart';   // Import UpdateInfo
import 'package:url_launcher/url_launcher.dart'; // Import url_launcher
import 'package:package_info_plus/package_info_plus.dart'; // Import package_info_plus
import 'package:audio_service/audio_service.dart'; // Import audio_service
import 'services/audio_handler.dart'; // Import your AudioPlayerHandler
import 'services/album_manager_service.dart'; // Import AlbumManagerService
import 'services/playlist_manager_service.dart'; // Import PlaylistManagerService
import 'services/download_notification_service.dart'; // Import DownloadNotificationService
import 'services/metadata_history_service.dart'; // Import MetadataHistoryService
import 'dart:io'; // Import for Platform
import 'dart:async'; // Import for Timer
import 'package:shared_preferences/shared_preferences.dart'; // Import for SharedPreferences
import 'package:flutter/services.dart'; // For MethodChannel
import 'package:flutter/foundation.dart'; // For kIsWeb and defaultTargetPlatform

// Global instance of the AudioPlayerHandler
late AudioHandler _audioHandler;

// Global navigator key for navigation from notifications
final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

// Check if running on desktop
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

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
        ChangeNotifierProvider(create: (context) => PlaylistManagerService()), // Assuming this was already here or needed
        ChangeNotifierProvider(create: (context) => AlbumManagerService()), // Add AlbumManagerService
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
        return MaterialApp(
          title: 'LTunes',
          theme: isDesktop ? themeProvider.desktopLightTheme : themeProvider.lightTheme,
          darkTheme: isDesktop ? themeProvider.desktopDarkTheme : themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          navigatorKey: globalNavigatorKey,
          home: isDesktop ? const DesktopTabView() : const TabView(),
        );
      },
    );
  }
}

// Mobile layout (original TabView)
class TabView extends StatefulWidget {
  const TabView({super.key});

  @override
  State<TabView> createState() => _TabViewState();
}

class _TabViewState extends State<TabView> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  Timer? _backgroundContinuityTimer;

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
    _backgroundContinuityTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _audioHandler.customAction('ensureBackgroundPlaybackContinuity', {});
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
        // App is coming back to foreground, ensure audio session is active
        _audioHandler.customAction('handleAppForeground', {});
        // Also check for stuck loading states in the CurrentSongProvider
        Provider.of<CurrentSongProvider>(context, listen: false).handleAppForeground();
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
          
          // Add background playback continuity check after 30 seconds
          Future.delayed(const Duration(seconds: 30), () {
            _audioHandler.customAction('ensureBackgroundPlaybackContinuity', {});
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
    // Check if auto update checking is enabled
    final prefs = await SharedPreferences.getInstance();
    final autoCheckForUpdates = prefs.getBool('autoCheckForUpdates') ?? true;
    
    // If auto check is disabled, don't proceed
    if (!autoCheckForUpdates) {
      return;
    }
    
    final apiService = ApiService();
    final errorHandler = ErrorHandlerService();
    try {
      final updateInfo = await apiService.checkForUpdate(currentAppVersion);
      if (updateInfo != null && mounted) {
        _showUpdateDialog(updateInfo);
      }
    } catch (e) {
      errorHandler.logError(e, context: 'checkForUpdates');
      // Don't show error to user for update checks as they're not critical
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo updateInfo) async {
    if (!mounted) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async gap
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
                    SnackBar(content: Text('Could not launch ${updateInfo.url}')),
                  );
                }
              },
            ),
          ],
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
      const SearchScreen(), // Use existing search screen for now
      const DesktopLibraryScreen(), // Use desktop library screen
      const SettingsScreen(), // Use desktop settings screen
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
            type: BottomNavigationBarType.fixed, // Ensure icons and labels align properly
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
                icon: Icon(Icons.settings, size: 28), // Keep settings at the end
                label: 'Settings',
              ),
            ],
            currentIndex: _selectedIndex,
            selectedItemColor: Theme.of(context).colorScheme.primary, // Use theme's primary color
            unselectedItemColor: Colors.grey, // Add unselected color for better contrast
            onTap: _onItemTapped,
            showUnselectedLabels: true, // Ensure labels are visible for all items
          ),
        ],
      ),
    );
  }
}

// Desktop-specific layout with Spotify-like sidebar navigation
class DesktopTabView extends StatefulWidget {
  const DesktopTabView({super.key});

  @override
  State<DesktopTabView> createState() => _DesktopTabViewState();
}

class _DesktopTabViewState extends State<DesktopTabView> {
  int _selectedIndex = 0;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  final List<Widget> _pages = [
    const DesktopLibraryScreen(),
    const DesktopSearchScreen(),
    const DesktopLikedSongsScreen(),
    const SettingsScreen(),
  ];

  final List<String> _pageTitles = [
    'Your Library',
    'Search',
    'Liked Songs',
    'Settings',
  ];

  final List<IconData> _pageIcons = [
    Icons.library_music,
    Icons.search,
    Icons.favorite,
    Icons.settings,
  ];

  Widget _buildNavItem(IconData icon, String label, int index, {bool isSelected = false}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        leading: Icon(
          icon,
          color: isSelected ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurfaceVariant,
          size: 24,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFFF9800) : Theme.of(context).colorScheme.onSurface,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 16,
          ),
        ),
        selected: isSelected,
        selectedTileColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        onTap: () {
          setState(() {
            _selectedIndex = index;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Row(
        children: [
          // Spotify-like Sidebar
          Container(
            width: 280,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                right: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                  width: 1,
                ),
              ),
            ),
            child: Column(
              children: [
                // App Logo/Header
                Container(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9800),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'LTunes',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 24,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Navigation Items
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      _buildNavItem(Icons.library_music, 'Your Library', 0, isSelected: _selectedIndex == 0),
                      _buildNavItem(Icons.search, 'Search', 1, isSelected: _selectedIndex == 1),
                      _buildNavItem(Icons.favorite, 'Liked Songs', 2, isSelected: _selectedIndex == 2),
                      const Divider(height: 32),
                      _buildNavItem(Icons.settings, 'Settings', 3, isSelected: _selectedIndex == 3),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Main Content Area
          Expanded(
            child: Column(
              children: [
                // Content Header with gradient background
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context).colorScheme.surface,
                        Theme.of(context).colorScheme.surface.withOpacity(0.8),
                      ],
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _pageIcons[_selectedIndex],
                        color: const Color(0xFFFF9800),
                        size: 32,
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _pageTitles[_selectedIndex],
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 32,
                        ),
                      ),
                    ],
                  ),
                ),
                // Page Content
                Expanded(
                  child: _pages[_selectedIndex],
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const DesktopPlaybar(),
    );
  }
}

