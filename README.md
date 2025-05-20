# TODO

## Features to Implement
- Add loading animation that persists until the song starts playing.
- Implement slide-to-queue feature on the search and downloads screens.
- Add the song thumbnail next to the downloaded song.
- Have it so when you play downloaded songs, it still plays in the playbar.
- Create a default playlist called "Liked Songs" with a heart button to add songs to it.
- Prevent duplicate songs when adding to a playlist.
- Allow clicking on the playbar to make it fullscreen with more controls.
- Add shuffle and loop functionality.
- Add listening history.
- Add color themes (default: orange).
- Add lyrics (save lyrics when downloading the song too).
- Add explicit content filter.
- Add Equalizer (EQ) presets (e.g., Bass Boost, Classical, Jazz, Custom).
- Add crossfade duration (smooth transition between songs).
- Add volume normalization (level all songs to similar volume).
- Add sleep timer (stop playback after a set time).
- Add an option to clear listening history.
- Add support to connect to smart speakers (AirPlay, Chromecast, etc.).
- Add confirmation prompts for deleting songs or removing songs from playlists.
- Add gapless playback (no pause between tracks).

## UI/UX Improvements
- Change "Home" to "Search" and "Downloads" to "Library" in the navigation bar.
- Update the icons on the navigation bar.
- Cache search results to avoid reloading when switching pages.
- Ensure the full-screen player still shows the navigation bar at the bottom.

## Metadata and Downloads
- Save song metadata (e.g., icon, artist name) as a JSON file when downloading songs.
- Do not fetch song info for downloaded tracks; use the saved metadata instead.

## Lock Screen and Notifications
- Integrate iOS/Android lock screen and notification media controls:
  - Set up `audio_session` for background audio and interruption handling.
  - Implement `MediaMetadata` retrieval and updates for lock screen/notifications.
  - Handle play/pause/next/previous commands from media controls.
  - Ensure media controls work seamlessly with streaming audio URLs.

## Updates
- Add an updater. API to fetch update details: [https://ltn-api.vercel.app/updates/update.json](https://ltn-api.vercel.app/updates/update.json).

## Miscellaneous
- Fix the app name from "Ltunes Flutter" to "LTunes".