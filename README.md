# TODO

## Features

### Playback Features
- Listening history (with option to clear).
- Sleep timer (stop playback after set time).
- Volume normalization (level all songs).

### Search and Library
- Show albums in search results.
- Show artists in search results.
- Import playlists from XLSX files.

### Downloads
- Download all songs from an album, skipping already downloaded songs.

### Lyrics and Visuals
- Lyrics support (save lyrics when downloading songs).

### Settings
- Add an option to disable UI animations (default: enabled).

### Bug fixes
- Fix issue where playback cannot be resumed from notification (audio service) after an audio interruption like playing a video (play button disabled).

## Album Fetching

LTunes can fetch detailed information about albums, including track listings.

### Fetching Album Details

To fetch album details, you can use the `ApiService`. It requires the album name and artist name.

```dart
// Example usage:
// final apiService = ApiService();
// final albumDetails = await apiService.getAlbum("The Maybe Man", "AJR");
// if (albumDetails != null) {
//   print("Album Title: ${albumDetails.title}");
//   print("Artist: ${albumDetails.artistName}");
//   print("Number of tracks: ${albumDetails.tracks.length}");
//   albumDetails.tracks.forEach((track) {
//     print("  Track: ${track.title}");
//   });
// }
```

This will search for the album ID using the provided name and artist, then fetch the complete album data. The `audioUrl` for individual tracks within an album will initially be empty and needs to be fetched separately if playback is desired (e.g., using `ApiService.fetchAudioUrl(artist, title)` or a similar method based on track ID).