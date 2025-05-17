# LTunes

A simple Flutter frontend for a music app that interacts with a REST API.

## Features

- Fetches and displays a list of songs from a remote API
- Shows song details and album art
- Simple and clean UI

## API

This app connects to:  
`https://ltn-live.vercel.app/api/`

The main endpoint used is `/songs`, which should return a list of songs in JSON format.

## Getting Started

1. **Install dependencies:**
   ```
   flutter pub get
   ```

2. **Run the app:**
   ```
   flutter run
   ```

   Or use your IDE's run configuration.

3. **Hot Reload:**
   While running the app, you can make changes to the code and use:
   ```
   r
   ```
   in the terminal or click the "Hot Reload" button in your IDE.

## Development

1. **Clone the repository:**
   ```bash
   git clone
   ```
   flutter run
   ```

3. **Dependencies:**
   - [http](https://pub.dev/packages/http)

   Make sure your `pubspec.yaml` includes:
   ```yaml-
   dependencies:
     flutter:
       sdk: flutter
     http: ^0.14.0
   ```

## Project Structure

- `lib/models/song.dart` - Song model
- `lib/services/api_service.dart` - API service for fetching songs
- `lib/screens/home_screen.dart` - Home screen with song list
- `lib/screens/song_detail_screen.dart` - Song detail view
- `lib/main.dart` - App entry point

## License

MIT
