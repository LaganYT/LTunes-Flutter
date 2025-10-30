# TODO

## Audio & Playback Features

- Podcasts
- Audiobooks

## Lyrics Features

- Allow users to add/edit lyrics for their local songs and display them during playback.
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics

## UI & Display Features

- Before the artist name on a song show an explicit marker and a downloaded marker on the song lists
- On library screen let the user hold on a song/playlist/album icon to show a menu with related options
- Add an imported songs section under songs area
- Allow users to export playlists
- Allow users to export settings
- Allow users to export all data
- Let users change their default tab
- let users re-arange their tabs

## Development & Infrastructure

- Have the most accurate match for everything be shown first, instead of showing in order of how they are returned from the api

-- Test all audio features on phone -- ✅

When the app opens have it initialize an audio session ✅

Fix the add to playlist dialog not working a lot of the time ✅
Make the height of the navbar shorter and make the navbar everywhere the playbar is ✅

## Bug Fixes Completed

- Fixed memory leak in background continuity timer (session restoration timer not being cancelled)
- Fixed inconsistent mounted checks in full screen player sleep timer callbacks
- Added proper timer management for iOS background playback continuity
