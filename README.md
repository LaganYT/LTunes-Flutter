# LTunes

A modern, feature-rich Flutter music app for streaming, downloading, and organizing your music library. Built with performance and user experience in mind.

## ✨ Features

### 🎵 **Music Streaming & Playback**
- **Background Audio Service**: Seamless playback continues when app is minimized
- **Full-Screen Player**: Beautiful player with album art, controls, and lyrics view
- **Smart Queue Management**: Play songs, albums, playlists, or radio stations
- **Audio Controls**: Shuffle, repeat, seek, and volume control
- **Crossfade Support**: Smooth transitions between tracks

### 🔍 **Advanced Search**
- **Global Music Search**: Find songs, albums, and artists instantly
- **Radio Station Search**: Discover US and global radio stations
- **Smart Caching**: Fast results with intelligent cache management
- **Debounced Search**: Optimized performance with search throttling
- **Real-time Results**: Instant search suggestions and filtering

### 📚 **Modern Library Management**
- **Organized Categories**: Songs, Albums, Artists, Playlists, and Liked Songs
- **Smart Collections**: Recently added, recently played, and favorites
- **Import Local Files**: Add your own music with metadata extraction
- **Bulk Operations**: Select multiple items for batch actions
- **Search Within Library**: Find your content quickly

### 📱 **Download Management**
- **Background Downloads**: Download songs while using other apps
- **Progress Tracking**: Real-time download progress with notifications
- **Queue Management**: Organize and prioritize downloads
- **Resume Support**: Continue interrupted downloads
- **Storage Management**: Monitor and clear downloaded content

### 🎼 **Playlist Features**
- **Create & Customize**: Build playlists with drag-and-drop support
- **Smart Playlists**: Auto-generated based on your listening habits
- **Collaborative Features**: Share and import playlists
- **Playlist Art**: Automatic artwork generation from included songs
- **Advanced Sorting**: Sort by name, date, or song count

### 🎨 **Album & Artist Pages**
- **Rich Album Details**: Complete track listings and metadata
- **Artist Profiles**: Biography, popular tracks, and discography
- **Album Artwork**: High-quality cover art with fallback handling
- **Related Content**: Discover similar artists and albums

### 🎤 **Lyrics & Media**
- **Synced Lyrics**: Timed lyrics display during playback
- **Plain Lyrics**: Full lyrics view for reading
- **Lyrics Search**: Find lyrics for any song
- **Album Art Display**: Full-screen artwork viewing
- **Metadata Support**: Complete song information

### ⚙️ **Settings & Customization**
- **Theme Support**: Light, dark, and system themes
- **Accent Colors**: Customize the app's color scheme
- **Radio Preferences**: US-only or global radio stations
- **Update System**: Automatic update notifications
- **Storage Analytics**: Monitor app storage usage
- **Cache Management**: Clear cached data and downloads

### 🔧 **Advanced Features**
- **Error Handling**: Comprehensive error management with retry mechanisms
- **Performance Optimization**: Lazy loading, caching, and request limiting
- **Offline Support**: Full functionality for downloaded content
- **Notification Integration**: System notifications for downloads and playback
- **Accessibility**: Screen reader support and keyboard navigation

## 🚀 Recent Updates (v2.0.1)

- Added auto check for updates preference in settings.
- Added history to local song metadata fetcher.
- Removed player actions in app bar setting, now off permanently.
- Bug fixes.
## 📱 Screenshots

### Light Mode
<img src="assets/screenshots/light-mode/readme.png" alt="Light mode" width="200"/>

### Dark Mode  
<img src="assets/screenshots/dark-mode/readme.png" alt="Dark mode" width="200"/>

## 🛠️ Installation

### Prerequisites
- Flutter SDK ≥ 3.0.0
- Dart SDK ≥ 3.0.0
- Android Studio / VS Code with Flutter extensions

### Setup
1. **Clone the repository**:
   ```bash
   git clone https://github.com/LaganYT/LTunes-Flutter.git
   cd "LTunes Flutter"
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Run the app**:
   ```bash
   flutter run
   ```

### Platform Support
- ✅ **Android**: API 21+ (Android 5.0+)
- ✅ **iOS**: iOS 12.0+

## 🎯 Usage Guide

### Getting Started
1. **Search**: Use the search tab to find music and radio stations
2. **Library**: Access your downloaded content and playlists
3. **Settings**: Customize themes, preferences, and manage storage

### Key Features
- **Download Songs**: Tap the download icon to save songs offline
- **Create Playlists**: Use the library to organize your music
- **Background Playback**: Music continues when switching apps
- **Lyrics View**: Tap the lyrics button in the player for synchronized lyrics

## 🏗️ Architecture

### Core Services
- **ApiService**: Handles all API communication with caching
- **AudioHandler**: Manages background audio playback
- **ErrorHandlerService**: Centralized error management
- **DownloadNotificationService**: System notification management
- **PlaylistManagerService**: Playlist CRUD operations
- **AlbumManagerService**: Album management and metadata

### State Management
- **Provider Pattern**: Clean state management with Provider
- **CurrentSongProvider**: Global audio state management
- **Service Listeners**: Reactive updates across the app

### Performance Features
- **Request Debouncing**: Prevents excessive API calls
- **Lazy Loading**: Loads content as needed
- **Connection Pooling**: Efficient HTTP client management
- **Cache TTL**: Time-based cache expiration
- **Concurrent Request Limiting**: Prevents API overload

## 🔧 Development

### Project Structure
```
lib/
├── main.dart                 # App entry point
├── models/                   # Data models
├── providers/                # State management
├── screens/                  # UI screens
├── services/                 # Business logic
└── widgets/                  # Reusable components
```

### Key Dependencies
- **audio_service**: Background audio playback
- **just_audio**: Audio player implementation
- **provider**: State management
- **http**: API communication
- **shared_preferences**: Local storage
- **path_provider**: File system access

### Error Handling
The app includes a comprehensive error handling system:
- **User-friendly messages**: Clear, actionable error descriptions
- **Retry mechanisms**: Automatic and manual retry options
- **Error logging**: Centralized error tracking for debugging
- **Graceful degradation**: App continues working despite errors

## 🤝 Contributing

We welcome contributions! Please follow these steps:

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/YourFeature`
3. **Make your changes**: Follow the existing code style
4. **Test thoroughly**: Ensure all features work correctly
5. **Commit and push**: `git push origin feature/YourFeature`
6. **Open a Pull Request**: Provide a clear description of changes

### Development Guidelines
- Follow Flutter best practices and conventions
- Add error handling for new features
- Include appropriate tests
- Update documentation for new features
- Ensure cross-platform compatibility

## 📄 License

The Unlicense © Logan Latham / LaganDevs

This project is open source and available under the Unlicense, which means you can use, modify, and distribute it freely.

## 🙏 Acknowledgments

- **Flutter Team**: For the amazing framework
- **Audio Service Package**: For background audio support
- **Just Audio Package**: For reliable audio playback
- **Contributors**: Everyone who has helped improve LTunes

## 📞 Support

- **Issues**: Report bugs and request features on GitHub
- **Discussions**: Join community discussions
- **Documentation**: Check the code comments and error handling guide

---

**LTunes** - Your music, your way. 🎵
