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
import 'modern_library_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';


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
  final ValueNotifier<bool?> playerActionsInAppBarNotifier = ValueNotifier<bool?>(null);
  final ValueNotifier<List<double>> customSpeedPresetsNotifier = ValueNotifier<List<double>>([]);
  String _currentAppVersion = 'Loading...';
  String _latestKnownVersion = 'N/A';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _currentAppVersion = packageInfo.version;
          _latestKnownVersion = packageInfo.version; // Initially set to current version
        });
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
    
    // Load Player Actions in App Bar setting
    final playerActionsInAppBar = prefs.getBool('playerActionsInAppBar') ?? false;
    playerActionsInAppBarNotifier.value = playerActionsInAppBar;
    
    // Load Custom Speed Presets
    final customSpeedPresetsJson = prefs.getStringList('customSpeedPresets') ?? [];
    final customSpeedPresets = customSpeedPresetsJson
        .map((e) => double.tryParse(e) ?? 1.0)
        .where((e) => e >= 0.25 && e <= 3.0)
        .toList();
    customSpeedPresetsNotifier.value = customSpeedPresets;
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

  Future<void> _savePlayerActionsInAppBarSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('playerActionsInAppBar', value);
  }

  Future<void> _saveCustomSpeedPresets(List<double> presets) async {
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
      }
    }


    if (mounted) { // Check if the widget is still in the tree
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

    // Reset Player Actions in App Bar
    playerActionsInAppBarNotifier.value = false; // Default value
    await _savePlayerActionsInAppBarSetting(false);

    // Reset Custom Speed Presets
    customSpeedPresetsNotifier.value = [];
    await _saveCustomSpeedPresets([]);

    // Reset ThemeProvider settings
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    await themeProvider.resetToDefaults(); 

    if (mounted) { // Ensure mounted check before showing SnackBar
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
                    if (mounted) {
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
                  if (mounted) {
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Checking for updates...')),
    );

    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentAppVersion = packageInfo.version;
      final apiService = ApiService();
      final updateInfo = await apiService.checkForUpdate(currentAppVersion);

      if (!mounted) return;

      if (updateInfo != null) {
        _showUpdateDialog(updateInfo);
        setState(() {
          // Assuming UpdateInfo has a 'version' field for the new version string
          _latestKnownVersion = updateInfo.version; 
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('App is up to date.')),
        );
        setState(() {
          _latestKnownVersion = _currentAppVersion; // App is up to date
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking for updates: $e')),
        );
      }
      debugPrint("Error performing update check: $e");
      // Optionally, reset _latestKnownVersion or indicate error
      setState(() {
        _latestKnownVersion = 'Error';
      });
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
        children: [
          _buildSectionTitle(context, 'Content'),
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
                ValueListenableBuilder<bool?>(
                  valueListenable: playerActionsInAppBarNotifier,
                  builder: (context, playerActionsInAppBar, _) {
                    if (playerActionsInAppBar == null) {
                      return const ListTile(
                        leading: Icon(Icons.play_arrow),
                        title: Text('Player Actions in App Bar'),
                        subtitle: Text('Show play controls in app bar'),
                        trailing: SizedBox(
                          width: 50,
                          height: 30,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.play_arrow),
                      title: const Text('Player Actions in App Bar'),
                      subtitle: const Text('Show play controls in app bar'),
                      trailing: Switch(
                        value: playerActionsInAppBar,
                        onChanged: (bool value) async {
                          playerActionsInAppBarNotifier.value = value;
                          await _savePlayerActionsInAppBarSetting(value);
                        },
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
          _buildSectionTitle(context, 'Storage'),
          Card(
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
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Delete All Downloaded Songs'),
              onPressed: () async {
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
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                minimumSize: const Size(double.infinity, 48), // Make button wider
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.clear_all_outlined),
              label: const Text('Clear Recently Played Stations'),
              onPressed: () async {
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
                  await prefs.remove('recentStations');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Recently played stations cleared.')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                minimumSize: const Size(double.infinity, 48),
              ),
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
                  subtitle: Text('Current: $_currentAppVersion'),
                  trailing: _latestKnownVersion != _currentAppVersion
                      ? Container(
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
                        )
                      : null,
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
    if (_accentColor.value != color.value) {
      _accentColor = color;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('accentColor', color.value);
    }
  }

  Future<void> _loadAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt('accentColor');
    MaterialColor newAccentColor = _defaultAccentColor; 
    
    if (colorValue != null) {
      newAccentColor = accentColorOptions.values.firstWhere(
        (c) => c.value == colorValue,
        orElse: () => _defaultAccentColor, // Fallback to default if saved color not in options
      );
    }

    if (_accentColor.value != newAccentColor.value) {
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
    // The current logic is: if (_accentColor.value != newAccentColor.value) { _accentColor = newAccentColor; notifyListeners(); }
    // else { _accentColor = newAccentColor; }
    // This means if it loads the default and it was already the default, it won't notify.
    // This is usually fine. Let's stick to the original conditional notify.
    if (_accentColor.value != newAccentColor.value) {
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
    await prefs.setInt('accentColor', _accentColor.value);
    
    notifyListeners();
  }
}