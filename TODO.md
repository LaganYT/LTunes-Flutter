# TODO

## Search & Filtering
- Redo the search to show albums and artists in the search itself
- Add radio stations into this new search system (without need for a different tab to search for them)
- Offline Search & Filtering
  - Advanced search and filtering by any metadata (genre, year, composer, etc.).
  - Search across lyrics if available.
- Add better search bars

## Library & Song Management
- Add new sorting methods to the songs list page
- Song Ratings
  - Allow users to rate songs and sort/filter by rating.
- Add: a setting to only show your saved songs on your saved albums with an option to show full album
- Add: a downloaded indicator for specific songs (playlists, albums, artists, etc)
- Album Art Management
  - Let users change or add album art for their local music files.
- File Management Tools
  - Enable renaming, moving, or deleting music files from within the app.
  - Batch edit metadata (title, artist, album, etc.).
- Export/Import Settings & Playlists
  - Allow users to export/import their playlists, tags, and app settings as files.

## Audio & Playback Features
- Try adding podcast support
- Audiobooks?
- Audio Effects
  - Add a built-in equalizer or simple audio effects (bass boost, reverb, etc.).
- Lyrics Support
  - Allow users to add/edit lyrics for their local songs and display them during playback.
- Bookmarking
  - Let users bookmark positions in long tracks (e.g., audiobooks, podcasts).

## Artist & Album Features
- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library’s saved artists have it load the artist page with an option to show “saved songs by -artist name-“
- Fix: in the artists page for the library screen have the artists shown only be artists that are in the library, if it cant find any songs from that artist then dont show the artist
- Fix album arts not showing up on library page when offline (local files issue most likely)
- Have the artist page (opened from the song page) pre-loaded and pre-caches

## Download & Notification Handling
- Fix the download album/liked songs buttons (show the all songs are downloaded button when all songs they are already downloaded)
- Fix: when calculating if a song can be downloaded have it check if it’s a local song, if it is then exclude it from the is downloaded part of the is playlist downloaded function 
- Replace: the all downloaded button with remove downloads (which makes the songs from offline to online - deleting the song files) from playlist button

## UI/UX Improvements
- Add: explicit thing in more places, as well as an explicit filter 

## Connectivity & Caching
- Fix: When you leave a car and the bluetooth disconnects then get back in the car and reconnect bluetooth it will end the audio session: requiring you to reopen the app from the background to re-start the audio session - MAYBE FIXED
- Have it cache the current recently played stations icons so they show up when offline, it should delete the icon if the station is no longer on the recently played list

## Bug Fixes & Miscellaneous
- Add: Discord intergration?