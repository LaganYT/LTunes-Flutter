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
  ThemeMode themeMode = ThemeMode.dark; // Default to dark mode

  bool get isDarkMode => themeMode == ThemeMode.dark;

  ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: Colors.blue,
  );

  ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: Colors.amber,
  );

  ThemeProvider() {
    _loadThemeMode();
  }

  Future<void> toggleTheme() async {
    themeMode = isDarkMode ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('themeMode', themeMode.toString());
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeString = prefs.getString('themeMode');
    if (themeString != null) {
      themeMode = ThemeMode.values.firstWhere(
        (element) => element.toString() == themeString,
        orElse: () => ThemeMode.dark, // Default to dark mode
      );
      notifyListeners();
    }
  }
}
