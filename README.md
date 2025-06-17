# LTunes

A Flutter-based music app for streaming, downloading, and organizing songs, albums, playlists, and radio stations—all in one place.

## Features

- **Search**  
  • Music search by title/artist  
  • US-only or global radio station search  
  • Instant refresh and caching  
- **Streaming**  
  • Play songs and radio streams using a background audio service  
  • Full-screen player with album art, shuffle, loop modes, and position control  
- **Library**  
  • Manage your downloaded songs  
  • Import local audio files with metadata extraction  
  • Sort and search downloads  
  • Delete individual or all downloads  
- **Playlists**  
  • Create, rename, reorder, and delete playlists  
  • Add/remove songs with drag-and-drop support  
  • Play or shuffle entire playlists  
- **Albums & Artists**  
  • Save albums to your library  
  • View album details and track listings  
  • Download or play whole albums  
  • Browse artist pages with popular tracks  
- **Lyrics & Art**  
  • Fetch and display synced or plain lyrics  
  • Toggle between lyrics view and full-screen album art  
- **Settings**  
  • Toggle dark/light themes and accent colors  
  • Enable US-only radio by default  
  • Check for app updates  
  • View app version, storage usage, and clear cached data  
- **Download Queue**  
  • Background download manager with resume, progress, and cancellation  
  • Queue multiple downloads concurrently  

## Installation

1. Ensure you have Flutter SDK ≥ 3.0 installed  
2. Clone this repository:
   ```bash
   git clone https://github.com/LaganYT/LTunes-Flutter.git
   cd "LTunes Flutter"
   ```
3. Get dependencies:
   ```bash
   flutter pub get
   ```
4. Run on simulator or device:
   ```bash
   flutter run
   ```

## Usage

- **Search**: Use the bottom navigation to select “Search,” enter a query, and tap a song or station to play.  
- **Library**: View, play, import, and delete downloaded songs or manage playlists and albums.  
- **Settings**: Customize themes, radio region, and clear storage or check for updates.

## Screenshots

### Search Page

| Light Mode | Dark Mode |
| ---------- | --------- |
| <img src="assets/screenshots/light-mode/readme.png" alt="Light mode" width="200"/> | <img src="assets/screenshots/dark-mode/readme.png" alt="Dark mode" width="200"/> |

## Contributing

1. Fork the repo  
2. Create a new branch (`git checkout -b feature/YourFeature`)  
3. Commit your changes and push (`git push origin feature/YourFeature`)  
4. Open a Pull Request

## License

The Unlicense © Logan Latham / LaganDevs
