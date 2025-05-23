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


## Bug Fixes
- When a radio station is playing disable the skip, previous, shuffle, loop, queue, download, and add to playlist buttons.
- When downloading from the song detail screen, make sure it downloads in background
- Don't autoplay songs on re-launch
- Make sure to check if a song is downloaded when playing from search, if it is then play the downloaded version

## Add background playback
- Add background playback using the #fetch https://pub.dev/packages/audio_service package, documentation to implement it with the AudioPlayers package: #fetch https://denis-korovitskii.medium.com/flutter-demo-audioplayers-on-background-via-audio-service-c95d65c90ae1 #codebase