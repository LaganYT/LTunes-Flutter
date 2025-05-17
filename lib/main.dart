import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import './screens/home_screen.dart';
import 'screens/library_screen.dart';
import './screens/settings_screen.dart';
import 'widgets/playbar.dart';
import 'package:audioplayers/audioplayers.dart';
import './models/song.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => CurrentSongProvider()),
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


class CurrentSongProvider extends ChangeNotifier {
  Song? currentSong;
  bool isPlaying = false;
  final AudioPlayer audioPlayer = AudioPlayer();

  void setSong(Song song) {
    currentSong = song;
    notifyListeners();
  }

  Future<void> playSong(Song song) async {
    if (currentSong != song) {
      currentSong = song;
    }
    try {
      if (song.isDownloaded && song.localFilePath != null) {
        await audioPlayer.play(DeviceFileSource(song.localFilePath!));
      } else {
        if (song.audioUrl != null) {
          await audioPlayer.play(UrlSource(song.audioUrl!));
        } else {
          // Handle case where audio URL is not available
          print('Audio URL not available');
          return;
        }
      }
      isPlaying = true;
      notifyListeners();
    } catch (e) {
      print('Error playing song: $e');
    }
  }

  Future<void> pauseSong() async {
    await audioPlayer.pause();
    isPlaying = false;
    notifyListeners();
  }

  Future<void> resumeSong() async {
    await audioPlayer.resume();
    isPlaying = true;
    notifyListeners();
  }

  void stopSong() async {
    await audioPlayer.stop();
    isPlaying = false;
    notifyListeners();
  }
}
