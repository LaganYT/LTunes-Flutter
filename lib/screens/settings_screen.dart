import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool usRadioOnly = false;

  @override
  void initState() {
    super.initState();
    _loadUSRadioOnlySetting();
  }

  Future<void> _loadUSRadioOnlySetting() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      usRadioOnly = prefs.getBool('usRadioOnly') ?? false; // Default to false
    });
  }

  Future<void> _saveUSRadioOnlySetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('usRadioOnly', value);
  }

  Future<void> toggleUSRadio() async {
    setState(() {
      usRadioOnly = !usRadioOnly; // Toggle the value
    });
    await _saveUSRadioOnlySetting(usRadioOnly); // Save the updated value
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
            ListTile(
              title: const Text('United States Radio Only'),
              trailing: Switch(
                value: usRadioOnly,
                onChanged: (bool value) async {
                  setState(() {
                    usRadioOnly = value; // Directly update the state
                  });
                  await _saveUSRadioOnlySetting(value); // Save the updated value
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
}

class ThemeProvider extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.light;

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
        orElse: () => ThemeMode.light,
      );
      notifyListeners();
    }
  }
}
