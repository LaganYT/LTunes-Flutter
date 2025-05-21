import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Initialize with null to represent loading state
  final ValueNotifier<bool?> usRadioOnlyNotifier = ValueNotifier<bool?>(null);

  @override
  void initState() {
    super.initState();
    _loadUSRadioOnlySetting();
  }

  Future<void> _loadUSRadioOnlySetting() async {
    final prefs = await SharedPreferences.getInstance();
    // Default to true if not set, as per original logic
    usRadioOnlyNotifier.value = prefs.getBool('usRadioOnly') ?? true;
  }

  Future<void> _saveUSRadioOnlySetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('usRadioOnly', value);
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
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    usRadioOnlyNotifier.dispose();
    super.dispose();
  }
}

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark; // Default to dark mode
  MaterialColor _accentColor = Colors.orange; // Default accent color

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
        orElse: () => ThemeMode.dark, // Default to dark mode
      );
    } else {
      _themeMode = ThemeMode.dark; // Explicitly set default if null
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
    MaterialColor newAccentColor = Colors.orange; // Default
    
    if (colorValue != null) {
      newAccentColor = accentColorOptions.values.firstWhere(
        (c) => c.value == colorValue,
        orElse: () => Colors.orange, // Fallback to default if saved color not in options
      );
    }

    if (_accentColor.value != newAccentColor.value) {
      _accentColor = newAccentColor;
      notifyListeners();
    } else {
      // Ensure _accentColor is set even if it's the same as the initial default,
      // especially for the very first load.
      _accentColor = newAccentColor;
    }
  }
}
