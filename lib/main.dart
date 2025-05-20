import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import './screens/home_screen.dart';
import 'screens/library_screen.dart';
import './screens/settings_screen.dart';
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
    const HomeScreen(),
    const LibraryScreen(),
    const SettingsScreen(),
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
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download),
            label: 'Downloads',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.blue,
        onTap: _onItemTapped,
      ),
    );
  }
}
