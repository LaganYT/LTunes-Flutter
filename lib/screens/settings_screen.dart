import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
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
