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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Initialize with null to represent loading state
  final ValueNotifier<bool?> usRadioOnlyNotifier = ValueNotifier<bool?>(null);
  String _currentAppVersion = 'Loading...';
  String _latestKnownVersion = 'N/A';
  // Add a ValueNotifier to trigger refresh for FutureBuilders
  final ValueNotifier<int> _refreshNotifier = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _loadUSRadioOnlySetting();
    _loadCurrentAppVersion();
  }

  Future<void> _loadCurrentAppVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _currentAppVersion = packageInfo.version;
        // Initialize _latestKnownVersion to current until an update check is performed
        _latestKnownVersion = _currentAppVersion; 
      });
    }
  }

  Future<void> _loadUSRadioOnlySetting() async {
    final prefs = await SharedPreferences.getInstance();
    // Default to true if not set, as per original logic
    usRadioOnlyNotifier.value = prefs.getBool('usRadioOnly') ?? true;
    // Notify ValueListenableBuilder to rebuild, if it was waiting for this.
    // This is more for consistency if other parts of the UI depend on this finishing.
    // For the switch itself, its own state management handles the initial value.
  }

  Future<void> _saveUSRadioOnlySetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('usRadioOnly', value);
  }

  // ignore: unused_element
  Future<int> _calculateStorageUsed() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    int totalSizeBytes = 0;
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once
    const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            // Assuming Song.fromJson exists and works correctly
            final song = Song.fromJson(songMap); 
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              // song.localFilePath is now a filename, construct full path with subdirectory
              final fullPath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
              final file = File(fullPath);
              if (await file.exists()) {
                totalSizeBytes += await file.length();
              }
            }
          } catch (e) {
            debugPrint("Error processing song $key for storage calculation: $e");
            // Optionally, handle or log the error more formally
          }
        }
      }
    }
    return totalSizeBytes;
  }

  // ignore: unused_element
  String _formatBytes(int bytes, {int decimals = 2}) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  // ignore: unused_element
  Future<int> _getDownloadedSongsCount() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    int count = 0;
    final appDocDir = await getApplicationDocumentsDirectory(); // Get once
    const String downloadsSubDir = 'ltunes_downloads'; // Subdirectory used by DownloadManager

    for (String key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            if (song.isDownloaded && song.localFilePath != null && song.localFilePath!.isNotEmpty) {
              // Ensure the file actually exists in the subdirectory
              final fullPath = p.join(appDocDir.path, downloadsSubDir, song.localFilePath!);
              if (await File(fullPath).exists()) {
                count++;
              }
            }
          } catch (e) {
            debugPrint("Error processing song $key for count calculation: $e");
          }
        }
      }
    }
    return count;
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
    // Reset US Radio Only
    usRadioOnlyNotifier.value = true; // Default value
    await _saveUSRadioOnlySetting(true);

    // Reset ThemeProvider settings
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    await themeProvider.resetToDefaults();

    if (mounted) { // Ensure mounted check before showing SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings have been reset to default.')),
      );
    }
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

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            ValueListenableBuilder<bool?>( // Listen to nullable bool
              valueListenable: usRadioOnlyNotifier,
              builder: (context, usRadioOnly, _) {
                if (usRadioOnly == null) {
                  // Setting is loading, show a placeholder
                  return const ListTile(
                    title: Text('United States Radio Only'),
                    trailing: SizedBox(
                      width: 50, // Approximate width of a Switch
                      height: 30, // Approximate height of a Switch
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
                    ),
                  );
                }
                // Setting has loaded, show the Switch
                return ListTile(
                  title: const Text('United States Radio Only'),
                  trailing: Switch(
                    value: usRadioOnly, // usRadioOnly is now a non-null bool
                    onChanged: (bool value) async {
                      usRadioOnlyNotifier.value = value; // Update the notifier
                      await _saveUSRadioOnlySetting(value); // Save the updated value
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            ListTile(
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
            const SizedBox(height: 16),
            ListTile(
              title: const Text('Dark Mode'),
              trailing: Switch(
                value: themeProvider.isDarkMode,
                onChanged: (bool value) {
                  themeProvider.toggleTheme();
                },
              ),
            ),
            const Divider(), // Added a divider for better separation
            ListTile(
              title: const Text('Storage Used by Downloads'),
              subtitle: ValueListenableBuilder<int>(
                valueListenable: _refreshNotifier,
                builder: (context, _, child) {
                  return FutureBuilder<int>(
                    future: _calculateStorageUsed(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Text('Calculating...');
                      } else if (snapshot.hasError) {
                        return Text('Error calculating storage', style: TextStyle(color: Theme.of(context).colorScheme.error));
                      } else if (snapshot.hasData) {
                        return Text(_formatBytes(snapshot.data!));
                      }
                      return const Text('N/A');
                    },
                  );
                }
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh Storage Calculation',
                onPressed: () {
                  _refreshNotifier.value++; // Increment to trigger ValueListenableBuilder
                },
              ),
            ),
            ListTile(
              title: const Text('Number of Downloaded Songs'),
              subtitle: ValueListenableBuilder<int>(
                valueListenable: _refreshNotifier,
                builder: (context, _, child) {
                  return FutureBuilder<int>(
                    future: _getDownloadedSongsCount(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Text('Counting...');
                      } else if (snapshot.hasError) {
                        return Text('Error counting songs', style: TextStyle(color: Theme.of(context).colorScheme.error));
                      } else if (snapshot.hasData) {
                        return Text('${snapshot.data} songs');
                      }
                      return const Text('N/A');
                    },
                  );
                }
              ),
              // Optionally, share the refresh button or add another one
              // For simplicity, the existing refresh button will now refresh both.
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: ElevatedButton(
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
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                ),
                child: const Text('Delete All Downloaded Songs'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0), // Adjusted padding for consistency
              child: ElevatedButton(
                onPressed: () async {
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
                  if (confirmReset == true) {
                    await _resetSettings();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                ),
                child: const Text('Reset All Settings to Default'),
              ),
            ),
            const Divider(),
            ListTile(
              title: const Text('Version Information'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current Version: $_currentAppVersion'),
                  Text('Latest Available Version: $_latestKnownVersion'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: ElevatedButton(
                onPressed: () {
                  _performUpdateCheck();
                },
                style: ElevatedButton.styleFrom(
                  // Optional: Use a different color or style for this button
                  // backgroundColor: Theme.of(context).colorScheme.primary,
                  // foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                ),
                child: const Text('Check for Updates'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    usRadioOnlyNotifier.dispose();
    _refreshNotifier.dispose(); // Dispose the new notifier
    super.dispose();
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