import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io'; // Required for File operations
import 'dart:convert'; // Required for jsonDecode
import 'dart:math'; // Required for log and pow
import '../models/song.dart'; // Required for Song.fromJson
import 'package:package_info_plus/package_info_plus.dart'; // Import package_info_plus
import 'package:url_launcher/url_launcher.dart'; // Import url_launcher
import '../services/api_service.dart'; // Import ApiService
import '../services/playlist_manager_service.dart'; // Import PlaylistManagerService
import '../models/update_info.dart';   // Import UpdateInfo
import 'package:path_provider/path_provider.dart'; // For getApplicationDocumentsDirectory
import 'package:path/path.dart' as p; // For path joining
import '../providers/current_song_provider.dart'; // Import CurrentSongProvider
import 'library_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';
import 'local_metadata_screen.dart';
import 'dart:async'; // Required for Timer
import 'package:fl_chart/fl_chart.dart'; // For charts
import '../services/sleep_timer_service.dart'; // Import SleepTimerService
import '../services/album_manager_service.dart'; // Import AlbumManagerService
import 'delete_downloads_screen.dart'; // Import DeleteDownloadsScreen
import '../screens/playlists_list_screen.dart' show robustArtwork;
import 'audio_effects_screen.dart'; // Import AudioEffectsScreen
import '../services/audio_effects_service.dart'; // Import AudioEffectsService


class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ValueNotifier<int> _refreshNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool?> usRadioOnlyNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> showRadioTabNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<bool?> autoDownloadLikedSongsNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<List<double>> customSpeedPresetsNotifier = ValueNotifier<List<double>>([]);
  final ValueNotifier<bool> listeningStatsEnabledNotifier = ValueNotifier<bool>(true); // <-- move here
  final ValueNotifier<bool?> autoCheckForUpdatesNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<String> currentAppVersionNotifier = ValueNotifier<String>('Loading...');
  final ValueNotifier<String> latestKnownVersionNotifier = ValueNotifier<String>('N/A');
  final ValueNotifier<bool?> showOnlySavedSongsInAlbumsNotifier = ValueNotifier<bool?>(null); // NEW
  final ValueNotifier<int> maxConcurrentDownloadsNotifier = ValueNotifier<int>(1); // NEW
  final ValueNotifier<int> maxConcurrentPlaylistMatchesNotifier = ValueNotifier<int>(5); // NEW
  final SleepTimerService _sleepTimerService = SleepTimerService();
  CurrentSongProvider? _currentSongProvider; // Store reference to provider

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
    // Get the provider reference when dependencies change
    _currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
    
    // Initialize sleep timer service only if not already initialized
    if (!_sleepTimerService.isInitialized) {
      _sleepTimerService.initialize(_currentSongProvider!);
    }
    
    // Check if the timer is still valid (not expired)
    _sleepTimerService.isTimerValid();
    
    // Set callbacks for this instance
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
    // Don't dispose the sleep timer service - it should persist across screen navigation
    // Just remove the callbacks for this instance
    _sleepTimerService.clearCallbacks();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      if (mounted && context.mounted) {
        currentAppVersionNotifier.value = packageInfo.version;
        latestKnownVersionNotifier.value = packageInfo.version; // Initially set to current version
      }
    } catch (e) {
      debugPrint('Error loading app version: $e');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load US Radio Only setting
    final usRadioOnly = prefs.getBool('usRadioOnly') ?? true;
    usRadioOnlyNotifier.value = usRadioOnly;
    
    // Load Show Radio Tab setting
    final showRadioTab = prefs.getBool('showRadioTab') ?? true;
    showRadioTabNotifier.value = showRadioTab;
    
    // Load Auto Download Liked Songs setting
    final autoDownloadLikedSongs = prefs.getBool('autoDownloadLikedSongs') ?? false;
    autoDownloadLikedSongsNotifier.value = autoDownloadLikedSongs;
    
    // Load Auto Check for Updates setting
    final autoCheckForUpdates = prefs.getBool('autoCheckForUpdates') ?? true;
    autoCheckForUpdatesNotifier.value = autoCheckForUpdates;
    
    // Load Custom Speed Presets (disabled on iOS)
    if (!Platform.isIOS) {
      final customSpeedPresetsJson = prefs.getStringList('customSpeedPresets') ?? [];
      final customSpeedPresets = customSpeedPresetsJson
          .map((e) => double.tryParse(e) ?? 1.0)
          .where((e) => e >= 0.25 && e <= 3.0)
          .toList();
      customSpeedPresetsNotifier.value = customSpeedPresets;
    }
    
    // Load Only Show Saved Songs in Albums setting
    final showOnlySavedSongs = prefs.getBool('showOnlySavedSongsInAlbums') ?? false;
    showOnlySavedSongsInAlbumsNotifier.value = showOnlySavedSongs;

    // Load Max Concurrent Downloads setting
    final maxConcurrentDownloads = prefs.getInt('maxConcurrentDownloads') ?? 1;
    maxConcurrentDownloadsNotifier.value = maxConcurrentDownloads;

    // Load Max Concurrent Playlist Matches setting
    final maxConcurrentPlaylistMatches = prefs.getInt('maxConcurrentPlaylistMatches') ?? 5;
    maxConcurrentPlaylistMatchesNotifier.value = maxConcurrentPlaylistMatches;

  }

  Future<void> _saveUSRadioOnlySetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('usRadioOnly', value);
  }

  Future<void> _saveShowRadioTabSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showRadioTab', value);
  }

  Future<void> _saveAutoDownloadLikedSongsSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoDownloadLikedSongs', value);
  }

  Future<void> _saveAutoCheckForUpdatesSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoCheckForUpdates', value);
  }

  Future<void> _saveShowOnlySavedSongsInAlbumsSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showOnlySavedSongsInAlbums', value);
  }

  Future<void> _saveMaxConcurrentDownloadsSetting(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('maxConcurrentDownloads', value);
    
    // Reinitialize the download manager with the new setting
    if (_currentSongProvider != null) {
      await _currentSongProvider!.reinitializeDownloadManager();
    }
  }

  Future<void> _saveMaxConcurrentPlaylistMatchesSetting(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('maxConcurrentPlaylistMatches', value);
  }


  Future<void> _saveCustomSpeedPresets(List<double> presets) async {
    // Disable on iOS
    if (Platform.isIOS) return;
    
    final prefs = await SharedPreferences.getInstance();
    final presetsJson = presets.map((e) => e.toString()).toList();
    await prefs.setStringList('customSpeedPresets', presetsJson);
  }

  Future<int> _getDownloadedSongsCount() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    int count = 0;

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              final appDocDir = await getApplicationDocumentsDirectory();
              const String downloadsSubDir = 'ltunes_downloads';
              final fullPath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
              final file = File(fullPath);
              if (await file.exists()) {
                count++;
              }
            }
          } catch (e) {
            debugPrint("Error processing song $key for count: $e");
          }
        }
      }
    }
    return count;
  }

  Future<int> _getDownloadedSongsStorageBytes() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    int totalBytes = 0;
    final appDocDir = await getApplicationDocumentsDirectory();
    const String downloadsSubDir = 'ltunes_downloads';

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              final fullPath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
              final file = File(fullPath);
              if (await file.exists()) {
                totalBytes += await file.length();
              }
            }
          } catch (e) {
            debugPrint("Error processing song $key for storage calculation: $e");
          }
        }
      }
    }
    return totalBytes;
  }

  Future<void> _deleteAllDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    int deletedFilesCount = 0;
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once
    const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager
    
    List<Song> songsToUpdateInProvider = [];

    List<String> keysToUpdateInPrefs = [];
    List<String> updatedJsonStringsForPrefs = [];

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            Map<String, dynamic> songMap = jsonDecode(songJson) as Map<String, dynamic>;
            Song currentSongState = Song.fromJson(songMap);

            if (currentSongState.isDownloaded && currentSongState.localFilePath != null && currentSongState.localFilePath!.isNotEmpty) {
              final String fileName = currentSongState.localFilePath!;
              // Correct path for deletion, including the subdirectory
              final fullPath = p.join(appDocDir.path, downloadsSubDir, fileName);
              final file = File(fullPath);
              if (await file.exists()) {
                await file.delete();
                deletedFilesCount++;
              }
            }
            // Unconditionally update song metadata to mark as not downloaded
            // for all songs processed by this function.
            Song updatedSong = currentSongState.copyWith(isDownloaded: false, localFilePath: null);
            songsToUpdateInProvider.add(updatedSong);
            keysToUpdateInPrefs.add(key);
            updatedJsonStringsForPrefs.add(jsonEncode(updatedSong.toJson()));

          } catch (e) {
            debugPrint("Error processing song $key for deletion: $e");
          }
        }
      }
    }

    // Perform SharedPreferences updates
    for (int i = 0; i < keysToUpdateInPrefs.length; i++) {
      await prefs.setString(keysToUpdateInPrefs[i], updatedJsonStringsForPrefs[i]);
    }
    
    // Notify CurrentSongProvider and PlaylistManagerService for each updated song
    if (mounted) {
      final currentSongProvider = Provider.of<CurrentSongProvider>(context, listen: false);
      final playlistManager = PlaylistManagerService();
      for (final song in songsToUpdateInProvider) {
        currentSongProvider.updateSongDetails(song); // Notifies and saves state
        playlistManager.updateSongInPlaylists(song);
        await AlbumManagerService().updateSongInAlbums(song); // Update album download status
      }
    }


    if (mounted && context.mounted) { // Check if the widget is still in the tree
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$deletedFilesCount downloaded song(s) deleted.')),
      );
      _refreshNotifier.value++; // Trigger refresh
    }
  }

  Future<void> _resetSettings() async {
    // Show confirmation dialog first
    bool? confirmReset = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reset Settings?'),
          content: const Text('Are you sure you want to reset all settings to their default values? This action cannot be undone.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
            TextButton(
              child: Text('Reset', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
          ],
        );
      },
    );

    // Only proceed if user confirmed
    if (confirmReset != true) {
      return;
    }

    // Reset US Radio Only
    usRadioOnlyNotifier.value = true; // Default value
    await _saveUSRadioOnlySetting(true);

    // Reset Show Radio Tab
    showRadioTabNotifier.value = true; // Default value
    await _saveShowRadioTabSetting(true);

    // Reset Auto Download Liked Songs
    autoDownloadLikedSongsNotifier.value = false; // Default value
    await _saveAutoDownloadLikedSongsSetting(false);

    // Reset Auto Check for Updates
    autoCheckForUpdatesNotifier.value = true; // Default value
    await _saveAutoCheckForUpdatesSetting(true);

    // Reset Custom Speed Presets
    customSpeedPresetsNotifier.value = [];
    await _saveCustomSpeedPresets([]);

    // Reset Show Only Saved Songs in Albums
    showOnlySavedSongsInAlbumsNotifier.value = false;
    await _saveShowOnlySavedSongsInAlbumsSetting(false);

    // Reset ThemeProvider settings
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    await themeProvider.resetToDefaults(); 

    // Reset Audio Effects settings
    final audioEffectsService = AudioEffectsService();
    audioEffectsService.resetToDefaults();

    if (mounted && context.mounted) { // Ensure mounted check before showing SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings have been reset to default.')),
      );
    }
  }

  void _showPrivacyPolicy(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PrivacyPolicyScreen(),
      ),
    );
  }

  void _showTermsOfService(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const TermsOfServiceScreen(),
      ),
    );
  }

  void _showCustomSpeedPresetsDialog(BuildContext context) {
    // Disable on iOS
    if (Platform.isIOS) return;
    
    final currentPresets = List<double>.from(customSpeedPresetsNotifier.value);
    final TextEditingController speedController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Custom Speed Presets'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Add custom playback speed presets (0.25x - 3.0x)',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: speedController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Speed (e.g., 0.9)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final speed = double.tryParse(speedController.text);
                          if (speed != null && speed >= 0.25 && speed <= 3.0) {
                            if (!currentPresets.contains(speed)) {
                              currentPresets.add(speed);
                              currentPresets.sort();
                              setState(() {});
                              speedController.clear();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Speed preset already exists')),
                              );
                            }
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Please enter a valid speed between 0.25 and 3.0')),
                            );
                          }
                        },
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (currentPresets.isNotEmpty) ...[
                    const Text('Current Presets:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: currentPresets.map((speed) {
                        return Chip(
                          label: Text('${speed.toStringAsFixed(2)}x'),
                          onDeleted: () {
                            currentPresets.remove(speed);
                            setState(() {});
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    customSpeedPresetsNotifier.value = List<double>.from(currentPresets);
                    await _saveCustomSpeedPresets(currentPresets);
                    Navigator.of(context).pop();
                    if (mounted && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Custom speed presets saved')),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showMaxConcurrentDownloadsDialog(BuildContext context, int currentValue) {
    int selectedValue = currentValue;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Max Concurrent Downloads'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Choose how many songs to download simultaneously',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: selectedValue.toDouble(),
                    min: 1,
                    max: 20,
                    divisions: 19,
                    label: selectedValue.toString(),
                    onChanged: (value) {
                      setState(() {
                        selectedValue = value.round();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Download up to $selectedValue song${selectedValue == 1 ? '' : 's'} simultaneously',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    maxConcurrentDownloadsNotifier.value = selectedValue;
                    await _saveMaxConcurrentDownloadsSetting(selectedValue);
                    Navigator.of(context).pop();
                    if (mounted && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Max concurrent downloads set to $selectedValue')),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showMaxConcurrentPlaylistMatchesDialog(BuildContext context, int currentValue) {
    int selectedValue = currentValue;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Max Concurrent Playlist Matches'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Choose how many songs to search and match simultaneously during playlist import',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: selectedValue.toDouble(),
                    min: 1,
                    max: 35,
                    divisions: 34,
                    label: selectedValue.toString(),
                    onChanged: (value) {
                      setState(() {
                        selectedValue = value.round();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Search up to $selectedValue song${selectedValue == 1 ? '' : 's'} simultaneously',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    maxConcurrentPlaylistMatchesNotifier.value = selectedValue;
                    await _saveMaxConcurrentPlaylistMatchesSetting(selectedValue);
                    Navigator.of(context).pop();
                    if (mounted && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Max concurrent playlist matches set to $selectedValue')),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSleepTimerDialog(BuildContext context) {
    final List<int> presetMinutes = [15, 30, 60];
    int? selectedMinutes = _sleepTimerService.sleepTimerMinutes;
    final TextEditingController customController = TextEditingController();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Set Sleep Timer'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...presetMinutes.map((m) => RadioListTile<int>(
                        title: Text('$m minutes'),
                        value: m,
                        groupValue: selectedMinutes,
                        onChanged: (val) {
                          setState(() {
                            selectedMinutes = val;
                            customController.clear();
                          });
                        },
                      )),
                  RadioListTile<int>(
                    title: Row(
                      children: [
                        const Text('Custom: '),
                        SizedBox(
                          width: 60,
                          child: TextField(
                            controller: customController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: 'min'),
                            onChanged: (val) {
                              final parsed = int.tryParse(val);
                              setState(() {
                                selectedMinutes = parsed;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    value: selectedMinutes != null && !presetMinutes.contains(selectedMinutes!) ? selectedMinutes! : -1,
                    groupValue: selectedMinutes != null && !presetMinutes.contains(selectedMinutes!) ? selectedMinutes! : -1,
                    onChanged: (_) {},
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: (selectedMinutes != null && selectedMinutes! > 0)
                      ? () {
                          _startSleepTimer(selectedMinutes!);
                          Navigator.of(context).pop();
                        }
                      : null,
                  child: const Text('Start'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _startSleepTimer(int minutes) {
    _sleepTimerService.startTimer(minutes);
  }

  void _cancelSleepTimer() {
    _sleepTimerService.cancelTimer();
  }
  Future<void> _loadListeningStatsEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool('listeningStatsEnabled') ?? true;
  listeningStatsEnabledNotifier.value = enabled;
}

  Future<void> _setListeningStatsEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('listeningStatsEnabled', enabled);
  listeningStatsEnabledNotifier.value = enabled;
  if (mounted) setState(() {}); // Use setState from State class
}

  double _calculateMaxY(Iterable<int> values) {
    if (values.isEmpty) return 1.0;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    if (maxValue == 0) return 1.0;
    if (maxValue <= 3) return 3.0;
    if (maxValue <= 6) return 6.0;
    if (maxValue <= 10) return 10.0;
    if (maxValue <= 20) return 20.0;
    if (maxValue <= 50) return 50.0;
    // For larger values, round up to the nearest multiple of 10
    return ((maxValue / 10).ceil() * 10).toDouble();
  }

  double _calculateGridInterval(Iterable<int> values) {
    if (values.isEmpty) return 1.0;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    if (maxValue <= 3) return 1.0;
    if (maxValue <= 6) return 1.0;
    if (maxValue <= 10) return 2.0;
    if (maxValue <= 20) return 5.0;
    if (maxValue <= 50) return 10.0;
    return (maxValue / 10).ceil().toDouble();
  }

  double _calculateYAxisInterval(Iterable<int> values) {
    if (values.isEmpty) return 1.0;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    if (maxValue == 0) return 1.0;
    if (maxValue <= 3) return 1.0;
    if (maxValue <= 6) return 1.0;
    if (maxValue <= 10) return 2.0;
    if (maxValue <= 20) return 5.0;
    if (maxValue <= 50) return 10.0;
    return (maxValue / 10).ceil().toDouble();
  }

  Future<void> _showUpdateDialog(UpdateInfo updateInfo) async {
    if (!mounted) return;
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
                  if (mounted && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not launch ${updateInfo.url}')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _performUpdateCheck() async {
    if (!mounted) return;
    if (mounted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Checking for updates...')),
      );
    }

    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentAppVersion = packageInfo.version;
      final apiService = ApiService();
      final updateInfo = await apiService.checkForUpdate(currentAppVersion);

      if (!mounted) return;

      if (updateInfo != null) {
        _showUpdateDialog(updateInfo);
        latestKnownVersionNotifier.value = updateInfo.version; // Only update the notifier
      } else {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('App is up to date.')),
          );
        }
        latestKnownVersionNotifier.value = currentAppVersion; // Only update the notifier
      }
    } catch (e) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking for updates: $e')),
        );
      }
      debugPrint("Error performing update check: $e");
      // Optionally, reset _latestKnownVersion or indicate error
      latestKnownVersionNotifier.value = 'Error';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        key: const PageStorageKey('settings_list'),
        physics: const ClampingScrollPhysics(),
        children: [
          _buildSectionTitle(context, 'Content & Discovery'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: Column(
              children: [
                ValueListenableBuilder<bool?>(
                  valueListenable: usRadioOnlyNotifier,
                  builder: (context, usRadioOnly, _) {
                    if (usRadioOnly == null) {
                      return const ListTile(
                        leading: Icon(Icons.radio),
                        title: Text('US Radio Only'),
                        subtitle: Text('Show only US radio stations'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.radio),
                      title: const Text('US Radio Only'),
                      subtitle: const Text('Show only US radio stations'),
                      trailing: Switch(
                        value: usRadioOnly,
                        onChanged: (bool value) async {
                          usRadioOnlyNotifier.value = value;
                          await _saveUSRadioOnlySetting(value);
                        },
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<bool?>(
                  valueListenable: showRadioTabNotifier,
                  builder: (context, showRadioTab, _) {
                    if (showRadioTab == null) {
                      return const ListTile(
                        leading: Icon(Icons.tab),
                        title: Text('Show Radio Tab'),
                        subtitle: Text('Display radio tab in navigation'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.tab),
                      title: const Text('Show Radio Tab'),
                      subtitle: const Text('Display radio tab in navigation'),
                      trailing: Switch(
                        value: showRadioTab,
                        onChanged: (bool value) async {
                          showRadioTabNotifier.value = value;
                          await _saveShowRadioTabSetting(value);
                        },
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<bool?>(
                  valueListenable: showOnlySavedSongsInAlbumsNotifier,
                  builder: (context, showOnlySaved, _) {
                    if (showOnlySaved == null) {
                      return const ListTile(
                        leading: Icon(Icons.filter_alt),
                        title: Text('Show Only Saved Songs in Albums'),
                        subtitle: Text('Only show your downloaded/saved songs in saved albums'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.filter_alt),
                      title: const Text('Show Only Saved Songs in Albums'),
                      subtitle: const Text('Only show your downloaded/saved songs in saved albums'),
                      trailing: Switch(
                        value: showOnlySaved,
                        onChanged: (bool value) async {
                          showOnlySavedSongsInAlbumsNotifier.value = value;
                          await _saveShowOnlySavedSongsInAlbumsSetting(value);
                        },
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _buildSectionTitle(context, 'Downloads & Storage'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: Column(
              children: [
                ValueListenableBuilder<bool?>(
                  valueListenable: autoDownloadLikedSongsNotifier,
                  builder: (context, autoDownloadLikedSongs, _) {
                    if (autoDownloadLikedSongs == null) {
                      return const ListTile(
                        leading: Icon(Icons.favorite),
                        title: Text('Auto Download Liked Songs'),
                        subtitle: Text('Automatically download songs when liked'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.favorite),
                      title: const Text('Auto Download Liked Songs'),
                      subtitle: const Text('Automatically download songs when liked'),
                      trailing: Switch(
                        value: autoDownloadLikedSongs,
                        onChanged: (bool value) async {
                          autoDownloadLikedSongsNotifier.value = value;
                          await _saveAutoDownloadLikedSongsSetting(value);
                        },
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<int>(
                  valueListenable: maxConcurrentDownloadsNotifier,
                  builder: (context, maxConcurrentDownloads, _) {
                    return ListTile(
                      leading: const Icon(Icons.download),
                      title: const Text('Max Concurrent Downloads'),
                      subtitle: Text('Download up to $maxConcurrentDownloads song${maxConcurrentDownloads == 1 ? '' : 's'} simultaneously'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () => _showMaxConcurrentDownloadsDialog(context, maxConcurrentDownloads),
                    );
                  },
                ),
                ValueListenableBuilder<int>(
                  valueListenable: maxConcurrentPlaylistMatchesNotifier,
                  builder: (context, maxConcurrentPlaylistMatches, _) {
                    return ListTile(
                      leading: const Icon(Icons.playlist_add),
                      title: const Text('Max Concurrent Playlist Matches'),
                      subtitle: Text('Search up to $maxConcurrentPlaylistMatches song${maxConcurrentPlaylistMatches == 1 ? '' : 's'} simultaneously during import'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () => _showMaxConcurrentPlaylistMatchesDialog(context, maxConcurrentPlaylistMatches),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: const Text('Fetch Metadata for Local Songs'),
                  subtitle: const Text('Convert imported songs to native songs with full metadata.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const LocalMetadataScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _buildSectionTitle(context, 'Playback'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: Column(
              children: [
                // Custom Speed Presets (disabled on iOS)
                if (!Platform.isIOS)
                  ValueListenableBuilder<List<double>>(
                    valueListenable: customSpeedPresetsNotifier,
                    builder: (context, customPresets, _) {
                      return ListTile(
                        leading: const Icon(Icons.speed),
                        title: const Text('Custom Speed Presets'),
                        subtitle: Text(
                          customPresets.isEmpty 
                              ? 'No custom presets added'
                              : '${customPresets.length} custom preset${customPresets.length == 1 ? '' : 's'}'
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                        onTap: () => _showCustomSpeedPresetsDialog(context),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.graphic_eq),
                  title: const Text('Audio Effects'),
                  subtitle: const Text('Equalizer, bass boost, and reverb settings'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const AudioEffectsScreen(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: const Text('Sleep Timer'),
                  subtitle: _sleepTimerService.sleepTimerEndTime != null
                      ? Text('Timer set: ends at ${_sleepTimerService.getEndTimeString()}')
                      : const Text('No timer set'),
                  trailing: _sleepTimerService.sleepTimerEndTime != null
                      ? IconButton(
                          icon: const Icon(Icons.cancel),
                          tooltip: 'Cancel Timer',
                          onPressed: _cancelSleepTimer,
                        )
                      : const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: _sleepTimerService.sleepTimerEndTime == null ? () => _showSleepTimerDialog(context) : null,
                ),
              ],
            ),
          ),
          _buildSectionTitle(context, 'Theme'),
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, child) {
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24.0),
                ),
                elevation: 2,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.brightness_6_outlined),
                      title: const Text('Dark Mode'),
                      subtitle: Text(themeProvider.isDarkMode ? 'Dark' : 'Light'),
                      trailing: Switch(
                        value: themeProvider.isDarkMode,
                        onChanged: (bool value) {
                          themeProvider.toggleTheme();
                        },
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.color_lens_outlined),
                      title: const Text('Accent Color'),
                      trailing: DropdownButton<MaterialColor>(
                        value: themeProvider.accentColor,
                        items: ThemeProvider.accentColorOptions.entries.map((entry) {
                          String colorName = entry.key;
                          MaterialColor colorValue = entry.value;
                          return DropdownMenuItem<MaterialColor>(
                            value: colorValue,
                            child: Row(
                              children: [
                                Container(
                                  width: 20,
                                  height: 20,
                                  color: colorValue,
                                  margin: const EdgeInsets.only(right: 8.0),
                                ),
                                Text(colorName),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (MaterialColor? newValue) {
                          if (newValue != null) {
                            themeProvider.setAccentColor(newValue);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          _buildSectionTitle(context, 'Storage Management'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloaded Songs and Storage Used',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.music_note, size: 20),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<int>(
                            valueListenable: _refreshNotifier,
                            builder: (context, _, child) {
                              return FutureBuilder<int>(
                                future: _getDownloadedSongsCount(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState == ConnectionState.waiting) {
                                    return const SizedBox(
                                      height: 18, width: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    );
                                  } else if (snapshot.hasError) {
                                    return Text('Error', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 15));
                                  } else if (snapshot.hasData) {
                                    return Text(
                                      '${snapshot.data} Songs',
                                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 15),
                                    );
                                  }
                                  return const Text('N/A', style: TextStyle(fontSize: 15));
                                },
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.sd_storage, size: 20),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<int>(
                            valueListenable: _refreshNotifier,
                            builder: (context, _, child) {
                              return FutureBuilder<int>(
                                future: _getDownloadedSongsStorageBytes(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState == ConnectionState.waiting) {
                                    return const SizedBox(
                                      height: 18, width: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    );
                                  } else if (snapshot.hasError) {
                                    return Text('Error', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 15));
                                  } else if (snapshot.hasData) {
                                    return Text(
                                      '${_formatBytes(snapshot.data ?? 0)} used',
                                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 15),
                                    );
                                  }
                                  return const Text('N/A', style: TextStyle(fontSize: 15));
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.delete_sweep_outlined, color: Theme.of(context).colorScheme.error),
                  title: Text(
                    'Delete All Downloaded Songs',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  subtitle: const Text('Remove local files but keep songs in library'),
                  onTap: () async {
                    bool? confirmDelete = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: const Text('Delete All Downloads?'),
                          content: const Text('Are you sure you want to delete all downloaded songs? This action will remove local files but keep them in your library. This action cannot be undone.'),
                          actions: <Widget>[
                            TextButton(
                              child: const Text('Cancel'),
                              onPressed: () {
                                Navigator.of(context).pop(false);
                              },
                            ),
                            TextButton(
                              child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                              onPressed: () {
                                Navigator.of(context).pop(true);
                              },
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmDelete == true) {
                      await _deleteAllDownloads();
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.refresh_outlined, color: Theme.of(context).colorScheme.primary),
                  title: const Text('Validate & Fix Downloaded Files'),
                  subtitle: const Text('Check all downloaded songs, redownload corrupted ones, and unmark missing files'),
                  onTap: () async {
                    bool? confirmValidate = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: const Text('Validate Downloads?'),
                          content: const Text('This will check all downloaded songs for corruption and missing files. Corrupted files will be redownloaded, and missing files will be unmarked as downloaded. This may take some time.'),
                          actions: <Widget>[
                            TextButton(
                              child: const Text('Cancel'),
                              onPressed: () {
                                Navigator.of(context).pop(false);
                              },
                            ),
                            TextButton(
                              child: Text('Validate', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                              onPressed: () {
                                Navigator.of(context).pop(true);
                              },
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmValidate == true && _currentSongProvider != null) {
                      // Show loading dialog
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (BuildContext context) {
                          return const AlertDialog(
                            content: Row(
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(width: 16),
                                Text('Validating downloads...'),
                              ],
                            ),
                          );
                        },
                      );
                      
                      try {
                        final validationResult = await _currentSongProvider!.validateAllDownloadedSongs();
                        Navigator.of(context).pop(); // Close loading dialog
                        
                        if (mounted) {
                          String message;
                          if (validationResult.totalIssues == 0) {
                            message = 'All downloads validated successfully!';
                          } else {
                            final parts = <String>[];
                            if (validationResult.corruptedSongs.isNotEmpty) {
                              parts.add('${validationResult.corruptedSongs.length} corrupted files');
                            }
                            if (validationResult.unmarkedSongs.isNotEmpty) {
                              parts.add('${validationResult.unmarkedSongs.length} missing files unmarked');
                            }
                            message = 'Found ${parts.join(' and ')}. ${validationResult.corruptedSongs.isNotEmpty ? 'Redownloading...' : ''}';
                          }
                          
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(message),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      } catch (e) {
                        Navigator.of(context).pop(); // Close loading dialog
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error validating downloads: $e'),
                              backgroundColor: Theme.of(context).colorScheme.error,
                            ),
                          );
                        }
                      }
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.clear_all_outlined, color: Theme.of(context).colorScheme.secondary),
                  title: const Text('Clear Recently Played Stations'),
                  subtitle: const Text('Remove recently played radio stations from history'),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext dialogContext) {
                        return AlertDialog(
                          title: const Text('Clear Recent Stations?'),
                          content: const Text(
                              'This will clear the list of recently played radio stations. This action cannot be undone.'),
                          actions: <Widget>[
                            TextButton(
                              child: const Text('Cancel'),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                            ),
                            TextButton(
                              child: Text('Clear', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmed == true) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove('recent_radio_stations');
                      // Notify the radio recents manager to update its state
                      radioRecentsManager.clearRecentStations();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Recently played stations cleared.')),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
          ),


          _buildSectionTitle(context, 'Listening Stats'),
          ValueListenableBuilder<bool>(
            valueListenable: listeningStatsEnabledNotifier,
            builder: (context, enabled, _) {
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24.0),
                ),
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bar_chart, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            'Your Listening Stats',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Switch(
                            value: enabled,
                            onChanged: (val) async {
                              await _setListeningStatsEnabled(val);
                            },
                          ),
                        ],
                      ),
                      if (!enabled)
                        const Padding(
                          padding: EdgeInsets.only(top: 16.0),
                          child: Text('Listening stats are disabled.', style: TextStyle(color: Colors.grey)),
                        ),
                      if (enabled)
                        FutureBuilder<Map<String, dynamic>>(
                          future: _getListeningStats(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator());
                            } else if (snapshot.hasError) {
                              return Text('Error loading stats', style: TextStyle(color: Theme.of(context).colorScheme.error));
                            } else if (!snapshot.hasData) {
                              return const Text('No stats available');
                            }
                            final stats = snapshot.data!;
                            final List<Song> topSongs = stats['topSongs'] as List<Song>;
                            final List<Map<String, dynamic>> topAlbums = stats['topAlbums'] as List<Map<String, dynamic>>;
                            final List<MapEntry<String, int>> topArtists = stats['topArtists'] as List<MapEntry<String, int>>;
                            final Map<String, int> dailyCounts = stats['dailyCounts'] as Map<String, int>? ?? {};
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 16),
                                if (dailyCounts.isNotEmpty && dailyCounts.values.any((count) => count > 0)) ...[
                                  Text('Daily Listening (last 7 days):', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 200,
                                    child: BarChart(
                                      BarChartData(
                                        alignment: BarChartAlignment.spaceAround,
                                        maxY: _calculateMaxY(dailyCounts.values),
                                        minY: 0,
                                        barTouchData: BarTouchData(
                                          enabled: true,
                                          touchTooltipData: BarTouchTooltipData(
                                            tooltipBorder: BorderSide(color: Theme.of(context).colorScheme.outline),
                                            getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                              final keys = dailyCounts.keys.toList();
                                              final date = keys[group.x];
                                              final count = rod.toY.toInt();
                                              return BarTooltipItem(
                                                '$date\n$count plays',
                                                TextStyle(
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        titlesData: FlTitlesData(
                                          leftTitles: AxisTitles(
                                            sideTitles: SideTitles(
                                              showTitles: true,
                                              reservedSize: 40,
                                              interval: _calculateYAxisInterval(dailyCounts.values),
                                              getTitlesWidget: (double value, TitleMeta meta) {
                                                return Text(
                                                  value.toInt().toString(),
                                                  style: TextStyle(
                                                    color: Theme.of(context).colorScheme.onSurface,
                                                    fontSize: 12,
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          bottomTitles: AxisTitles(
                                            sideTitles: SideTitles(
                                              showTitles: true,
                                              getTitlesWidget: (double value, TitleMeta meta) {
                                                final keys = dailyCounts.keys.toList();
                                                if (value.toInt() < 0 || value.toInt() >= keys.length) return const SizedBox();
                                                final dateStr = keys[value.toInt()];
                                                // Format date as MM/DD
                                                final parts = dateStr.split('-');
                                                if (parts.length >= 3) {
                                                  return Padding(
                                                    padding: const EdgeInsets.only(top: 8.0),
                                                    child: Text(
                                                      '${parts[1]}/${parts[2]}',
                                                      style: TextStyle(
                                                        color: Theme.of(context).colorScheme.onSurface,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  );
                                                }
                                                return const SizedBox();
                                              },
                                              reservedSize: 40,
                                            ),
                                          ),
                                          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                        ),
                                        borderData: FlBorderData(
                                          show: true,
                                          border: Border(
                                            bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
                                            left: BorderSide(color: Theme.of(context).colorScheme.outline),
                                          ),
                                        ),
                                        gridData: FlGridData(
                                          show: true,
                                          horizontalInterval: _calculateGridInterval(dailyCounts.values),
                                          getDrawingHorizontalLine: (value) {
                                            return FlLine(
                                              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                                              strokeWidth: 1,
                                            );
                                          },
                                          drawVerticalLine: false,
                                        ),
                                        barGroups: [
                                          for (int i = 0; i < dailyCounts.length; i++)
                                            BarChartGroupData(
                                              x: i,
                                              barRods: [
                                                BarChartRodData(
                                                  toY: dailyCounts.values.elementAt(i).toDouble(),
                                                  color: Theme.of(context).colorScheme.primary,
                                                  width: 20,
                                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                                )
                                              ],
                                            )
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                if (dailyCounts.isEmpty || !dailyCounts.values.any((count) => count > 0))
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                                    child: Text(
                                      'No listening data available for the last 7 days.',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                                Text('Most Played Songs:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                                ...topSongs.map((song) => ListTile(
                                  leading: robustArtwork(
                                    song.albumArtUrl,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                  ),
                                  title: Text(song.title),
                                  subtitle: Text(song.artist),
                                  trailing: Text('${song.playCount} plays'),
                                  dense: true,
                                )),
                                const SizedBox(height: 12),
                                Text('Most Played Artists:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                                ...topArtists.map((entry) => ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.person)),
                                  title: Text(entry.key),
                                  trailing: Text('${entry.value} plays'),
                                  dense: true,
                                )),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          _buildSectionTitle(context, 'Advanced Settings'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: ExpansionTile(
              key: const PageStorageKey<String>('advanced_settings_expansion_tile'),
              leading: Icon(Icons.settings_applications_outlined, color: Theme.of(context).colorScheme.secondary),
              title: const Text('Advanced Settings'),
              subtitle: const Text('Danger zone: advanced file management'),
              children: [
                ListTile(
                  leading: Icon(Icons.folder_delete_outlined, color: Theme.of(context).colorScheme.error),
                  title: const Text('Manage Downloaded Files'),
                  subtitle: const Text('Delete individual files from the downloads folder'),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const DeleteDownloadsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          _buildSectionTitle(context, 'App'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24.0),
            ),
            elevation: 2,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info),
                  title: const Text('Version'),
                  subtitle: ValueListenableBuilder<String>(
                    valueListenable: currentAppVersionNotifier,
                    builder: (context, currentVersion, _) {
                      return ValueListenableBuilder<String>(
                        valueListenable: latestKnownVersionNotifier,
                        builder: (context, latestVersion, __) {
                          return Text('Current: $currentVersion\nLatest: $latestVersion');
                        },
                      );
                    },
                  ),
                  trailing: ValueListenableBuilder<String>(
                    valueListenable: latestKnownVersionNotifier,
                    builder: (context, latestVersion, _) {
                      if (latestVersion != currentAppVersionNotifier.value) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Update Available',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      } else {
                        return const SizedBox.shrink();
                      }
                    },
                  ),
                  onTap: () async {
                    try {
                      final apiService = ApiService();
                      final updateInfo = await apiService.checkForUpdate(currentAppVersionNotifier.value);

                      if (!mounted) return;

                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: const Text('App Version'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Current Version: ${currentAppVersionNotifier.value}'),
                                ValueListenableBuilder<String>(
                                  valueListenable: latestKnownVersionNotifier,
                                  builder: (context, latestVersion, _) {
                                    return Text('Latest Version: $latestVersion');
                                  },
                                ),
                                if (updateInfo != null) ...[
                                  const SizedBox(height: 8),
                                  Text('What\'s New: ${updateInfo.message}'),
                                ],
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Close'),
                              ),
                            ],
                          );
                        },
                      );
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error fetching update info: $e')),
                        );
                      }
                    }
                  },
                ),
                ValueListenableBuilder<bool?>(
                  valueListenable: autoCheckForUpdatesNotifier,
                  builder: (context, autoCheckForUpdates, _) {
                    if (autoCheckForUpdates == null) {
                      return const ListTile(
                        leading: Icon(Icons.system_update),
                        title: Text('Auto Check for Updates'),
                        subtitle: Text('Automatically check for updates on app open'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.system_update),
                      title: const Text('Auto Check for Updates'),
                      subtitle: const Text('Automatically check for updates on app open'),
                      trailing: Switch(
                        value: autoCheckForUpdates,
                        onChanged: (bool value) async {
                          autoCheckForUpdatesNotifier.value = value;
                          await _saveAutoCheckForUpdatesSetting(value);
                        },
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update),
                  title: const Text('Check for Updates'),
                  subtitle: const Text('Check for app updates'),
                  onTap: _performUpdateCheck,
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('Reset Settings'),
                  subtitle: const Text('Reset all settings to default'),
                  onTap: _resetSettings,
                ),
                ListTile(
                  leading: const Icon(Icons.privacy_tip),
                  title: const Text('Privacy Policy'),
                  subtitle: const Text('View privacy policy'),
                  onTap: () => _showPrivacyPolicy(context),
                ),
                ListTile(
                  leading: const Icon(Icons.description),
                  title: const Text('Terms of Service'),
                  subtitle: const Text('View terms of service'),
                  onTap: () => _showTermsOfService(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class ThemeProvider extends ChangeNotifier {
  static const ThemeMode _defaultThemeMode = ThemeMode.dark;
  static final MaterialColor _defaultAccentColor = Colors.orange;

  ThemeMode _themeMode = _defaultThemeMode;
  MaterialColor _accentColor = _defaultAccentColor;

  static final Map<String, MaterialColor> accentColorOptions = {
    'Orange': Colors.orange,
    'Blue': Colors.blue,
    'Green': Colors.green,
    'Red': Colors.red,
    'Purple': Colors.purple,
    'Teal': Colors.teal,
    'Pink': Colors.pink,
    'Indigo': Colors.indigo,
  };

  ThemeMode get themeMode => _themeMode;
  bool get isDarkMode => _themeMode == ThemeMode.dark;
  MaterialColor get accentColor => _accentColor;

  ThemeData get lightTheme => ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accentColor,
          brightness: Brightness.light,
        ),
      );

  ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accentColor,
          brightness: Brightness.dark,
        ),
      );

  ThemeProvider() {
    _loadThemeMode();
    _loadAccentColor();
  }

  Future<void> toggleTheme() async {
    _themeMode = isDarkMode ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('themeMode', _themeMode.toString());
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeString = prefs.getString('themeMode');
    if (themeString != null) {
      _themeMode = ThemeMode.values.firstWhere(
        (element) => element.toString() == themeString,
        orElse: () => _defaultThemeMode, // Default to dark mode
      );
    } else {
      _themeMode = _defaultThemeMode; // Explicitly set default if null
    }
    notifyListeners();
  }

  Future<void> setAccentColor(MaterialColor color) async {
    if (_accentColor.toARGB32() != color.toARGB32()) {
      _accentColor = color;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('accentColor', color.toARGB32());
    }
  }

  Future<void> _loadAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt('accentColor');
    MaterialColor newAccentColor = _defaultAccentColor; 
    
    if (colorValue != null) {
      newAccentColor = accentColorOptions.values.firstWhere(
        (c) => c.toARGB32() == colorValue,
        orElse: () => _defaultAccentColor, // Fallback to default if saved color not in options
      );
    }

    if (_accentColor.toARGB32() != newAccentColor.toARGB32()) {
      _accentColor = newAccentColor;
      // notifyListeners(); // Notifying here might cause issues if called during build.
                          // ThemeProvider constructor calls this, so it should be fine.
    } else {
      _accentColor = newAccentColor;
    }
    // It's generally safer to call notifyListeners() once after all initial loading in constructor,
    // or ensure it's not called in a way that violates Flutter's build lifecycle.
    // For now, the existing structure calls notifyListeners() at the end of _loadThemeMode and _loadAccentColor.
    // Let's ensure notifyListeners() is called if the color is actually set.
    // The original code had notifyListeners() inside the if block, which is fine.
    // If it's the same as the initial default, it might not notify, but the value is set.
    // This means if it loads the default and it was already the default, it won't notify.
    // This is usually fine. Let's stick to the original conditional notify.
    if (_accentColor.toARGB32() != newAccentColor.toARGB32()) {
       _accentColor = newAccentColor;
       notifyListeners();
    } else {
       // Ensure _accentColor is set even if it's the same as the initial default,
       // especially for the very first load.
       _accentColor = newAccentColor;
       // No notifyListeners() here if it's the same, to avoid unnecessary rebuilds.
    }
    // The original code had a final notifyListeners() in the constructor implicitly by calling it in _loadThemeMode and _loadAccentColor.
    // The current structure is okay.
  }

  Future<void> resetToDefaults() async {
    _themeMode = _defaultThemeMode;
    _accentColor = _defaultAccentColor;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', _themeMode.toString());
    await prefs.setInt('accentColor', _accentColor.toARGB32());
    
    notifyListeners();
  }
}



  // Add this method to _SettingsScreenState:
  Future<Map<String, dynamic>> _getListeningStats() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    // Songs
    final List<Song> allSongs = [];
    final now = DateTime.now();
    for (final key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            allSongs.add(song);
          } catch (_) {}
        }
      }
    }
    allSongs.sort((a, b) => b.playCount.compareTo(a.playCount));
    final topSongs = allSongs.take(3).toList();
    // Albums
    final List<Map<String, dynamic>> allAlbums = [];
    for (final key in keys) {
      if (key.startsWith('album_')) {
        final albumJson = prefs.getString(key);
        if (albumJson != null) {
          try {
            final albumMap = jsonDecode(albumJson) as Map<String, dynamic>;
            allAlbums.add(albumMap);
          } catch (_) {}
        }
      }
    }
    allAlbums.sort((a, b) => (b['playCount'] as int? ?? 0).compareTo(a['playCount'] as int? ?? 0));
    final topAlbums = allAlbums.take(3).toList();
    // Artists
    final artistPlayCountsJson = prefs.getString('artist_play_counts');
    Map<String, int> artistPlayCounts = {};
    if (artistPlayCountsJson != null) {
      try {
        artistPlayCounts = Map<String, int>.from(jsonDecode(artistPlayCountsJson));
      } catch (_) {}
    }
    final topArtists = artistPlayCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // Daily play counts (actual)
    final dailyPlayCountsJson = prefs.getString('daily_play_counts');
    Map<String, int> dailyCounts = {};
    if (dailyPlayCountsJson != null) {
      try {
        dailyCounts = Map<String, int>.from(jsonDecode(dailyPlayCountsJson));
      } catch (_) {}
    }
    // Only keep last 7 days, sorted
    final last7Days = [for (int i = 6; i >= 0; i--) now.subtract(Duration(days: i))];
    final Map<String, int> last7DailyCounts = {};
    
    for (final day in last7Days) {
      final dateKey = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      last7DailyCounts[dateKey] = dailyCounts[dateKey] ?? 0;
    }
    return {
      'topSongs': topSongs,
      'topAlbums': topAlbums,
      'topArtists': topArtists.take(3).toList(),
      'dailyCounts': last7DailyCounts,
    };
  }