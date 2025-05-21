import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/library_screen.dart';
import './screens/settings_screen.dart';
import './screens/radio_screen.dart'; // Import the new RadioScreen
import './screens/search_screen.dart'; // Import the new SearchScreen
import 'widgets/playbar.dart';
import 'providers/current_song_provider.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => CurrentSongProvider()), // Ensure this is initialized
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
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          home: const TabView(),
        );
      },
    );
  }
}

class TabView extends StatefulWidget {
  const TabView({super.key});

  @override
  _TabViewState createState() => _TabViewState();
}

class _TabViewState extends State<TabView> {
  int _selectedIndex = 0;

  static final List<Widget> _widgetOptions = <Widget>[
    const RadioScreen(), // Radio next
    const SearchScreen(), // Search in the middle
    const LibraryScreen(), // Library to the right of Search
    const SettingsScreen(), // Settings remains at the end
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _widgetOptions.elementAt(_selectedIndex),
            ),
          ),
          const Playbar(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed, // Ensure icons and labels align properly
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.radio, size: 28), // Move radio to the second position
            label: 'Radio',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search, size: 28), // Place search in the middle
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music, size: 28), // Place library to the right of search
            label: 'Library',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings, size: 28), // Keep settings at the end
            label: 'Settings',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey, // Add unselected color for better contrast
        onTap: _onItemTapped,
        showUnselectedLabels: true, // Ensure labels are visible for all items
      ),
    );
  }
}
