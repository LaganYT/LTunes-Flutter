import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import '../models/song.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/playlist_manager_service.dart';
import '../models/update_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../providers/current_song_provider.dart';
import 'library_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';
import 'local_metadata_screen.dart';
import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import '../services/sleep_timer_service.dart';
import '../services/album_manager_service.dart';
import 'delete_downloads_screen.dart';
import 'playlists_list_screen.dart' show robustArtwork;
import 'audio_effects_screen.dart';
import '../services/audio_effects_service.dart';
import '../screens/settings_screen.dart'; // Import for ThemeProvider

class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key});

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  final ValueNotifier<int> _refreshNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool?> usRadioOnlyNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> showRadioTabNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> autoDownloadLikedSongsNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<List<double>> customSpeedPresetsNotifier = ValueNotifier<List<double>>([]);
  final ValueNotifier<bool> listeningStatsEnabledNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool?> autoCheckForUpdatesNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<String> currentAppVersionNotifier = ValueNotifier<String>('Loading...');
  final ValueNotifier<String> latestKnownVersionNotifier = ValueNotifier<String>('N/A');
  final ValueNotifier<bool?> showOnlySavedSongsInAlbumsNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<int> maxConcurrentDownloadsNotifier = ValueNotifier<int>(1);
  final ValueNotifier<int> maxConcurrentPlaylistMatchesNotifier = ValueNotifier<int>(5);
  final SleepTimerService _sleepTimerService = SleepTimerService();
  CurrentSongProvider? _currentSongProvider;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadAppVersion();
    _loadListeningStatsEnabled();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    if (!_sleepTimerService.isInitialized) {
      _sleepTimerService.initialize(_currentSongProvider!);
    }
    
    _sleepTimerService.isTimerValid();
    
    _sleepTimerService.setCallbacks(
      onTimerUpdate: () {
        if (mounted) setState(() {});
      },
      onTimerExpired: () {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sleep timer expired. Playback stopped.')),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _sleepTimerService.clearCallbacks();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      currentAppVersionNotifier.value = packageInfo.version;
    } catch (e) {
      currentAppVersionNotifier.value = 'Unknown';
    }
  }

  Future<void> _loadListeningStatsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    listeningStatsEnabledNotifier.value = prefs.getBool('listeningStatsEnabled') ?? true;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    usRadioOnlyNotifier.value = prefs.getBool('usRadioOnly');
    showRadioTabNotifier.value = prefs.getBool('showRadioTab');
    autoDownloadLikedSongsNotifier.value = prefs.getBool('autoDownloadLikedSongs');
    showOnlySavedSongsInAlbumsNotifier.value = prefs.getBool('showOnlySavedSongsInAlbums');
    maxConcurrentDownloadsNotifier.value = prefs.getInt('maxConcurrentDownloads') ?? 1;
    maxConcurrentPlaylistMatchesNotifier.value = prefs.getInt('maxConcurrentPlaylistMatches') ?? 5;
    
    final customSpeedPresetsJson = prefs.getString('customSpeedPresets');
    if (customSpeedPresetsJson != null) {
      try {
        final List<dynamic> presets = jsonDecode(customSpeedPresetsJson);
        customSpeedPresetsNotifier.value = presets.map<double>((e) => e.toDouble()).toList();
      } catch (e) {
        customSpeedPresetsNotifier.value = [];
      }
    }
    
    autoCheckForUpdatesNotifier.value = prefs.getBool('autoCheckForUpdates');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Settings',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            
            // Settings sections
            _buildGeneralSettings(),
            const SizedBox(height: 32),
            _buildPlaybackSettings(),
            const SizedBox(height: 32),
            _buildDownloadSettings(),
            const SizedBox(height: 32),
            _buildAppInfo(),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneralSettings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'General',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            
            // Theme settings
            Consumer<ThemeProvider>(
              builder: (context, themeProvider, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Theme',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('Light'),
                          selected: themeProvider.themeMode == ThemeMode.light,
                          onSelected: (selected) {
                            if (selected) themeProvider.toggleTheme();
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Dark'),
                          selected: themeProvider.themeMode == ThemeMode.dark,
                          onSelected: (selected) {
                            if (selected) themeProvider.toggleTheme();
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('System'),
                          selected: themeProvider.themeMode == ThemeMode.system,
                          onSelected: (selected) {
                            if (selected) themeProvider.toggleTheme();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Accent color
                    Text(
                      'Accent Color',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ThemeProvider.accentColorOptions.entries.map((entry) {
                        return GestureDetector(
                          onTap: () => themeProvider.setAccentColor(entry.value),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: entry.value,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: themeProvider.accentColor == entry.value
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackSettings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Playback',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            
            // Sleep timer
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sleep Timer',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _sleepTimerService.isTimerActive
                            ? 'Timer active'
                            : 'Not active',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    _showSleepTimerDialog();
                  },
                  child: Text(_sleepTimerService.isTimerActive ? 'Change' : 'Set Timer'),
                ),
                if (_sleepTimerService.isTimerActive) ...[
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      _sleepTimerService.cancelTimer();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadSettings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Downloads',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            
            // Max concurrent downloads
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Max Concurrent Downloads',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${maxConcurrentDownloadsNotifier.value}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Slider(
                    value: maxConcurrentDownloadsNotifier.value.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    onChanged: (value) async {
                      maxConcurrentDownloadsNotifier.value = value.toInt();
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setInt('maxConcurrentDownloads', value.toInt());
                    },
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Download queue button
            ElevatedButton.icon(
              onPressed: () {
                // TODO: Implement download queue navigation
              },
              icon: const Icon(Icons.download),
              label: const Text('Download Queue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'App Information',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            
            // Version info
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Version',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ValueListenableBuilder<String>(
                        valueListenable: currentAppVersionNotifier,
                        builder: (context, version, child) {
                          return Text(
                            version,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    // TODO: Implement check for updates
                  },
                  child: const Text('Check for Updates'),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Links
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const PrivacyPolicyScreen(),
                      ),
                    );
                  },
                  child: const Text('Privacy Policy'),
                ),
                const SizedBox(width: 16),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const TermsOfServiceScreen(),
                      ),
                    );
                  },
                  child: const Text('Terms of Service'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        int selectedMinutes = 15;
        return AlertDialog(
          title: const Text('Set Sleep Timer'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('How long before stopping playback?'),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                value: selectedMinutes,
                items: [15, 30, 45, 60, 90, 120].map((minutes) {
                  return DropdownMenuItem(
                    value: minutes,
                    child: Text('$minutes minutes'),
                  );
                }).toList(),
                onChanged: (value) {
                  selectedMinutes = value ?? 15;
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _sleepTimerService.startTimer(selectedMinutes);
                Navigator.of(context).pop();
              },
              child: const Text('Set Timer'),
            ),
          ],
        );
      },
    );
  }
} 