# TODO

## Features
- Listening history (with option to clear).
- Lyrics support (save lyrics when downloading songs).
- Volume normalization (level all songs).
- Sleep timer (stop playback after set time).
- Import playlists from XLSX files.
- Show albums in search results
- Show artists in search results
- Download all songs from album, skipping already downloaded songs.
- Download all songs from playlist, skipping already downloaded songs.
- When downloading from the song detail screen, make sure it downloads in background

## Bug Fixes
- Fix song duration display (showing 00:00 instead of actual duration). - IOS
- When playing from search results, still check if a song is downloaded, if so then play that verison of the song.

## Add background playback
- Add background playback using the #fetch https://pub.dev/packages/audio_service package, documentation to implement it with the AudioPlayers package: #fetch https://denis-korovitskii.medium.com/flutter-demo-audioplayers-on-background-via-audio-service-c95d65c90ae1 #codebase