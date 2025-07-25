# TODO

## Search & Filtering
- Redo the search to show albums and artists in the search itself
- Add radio stations into this new search system (without need for a different tab to search for them)
- Offline Search & Filtering
  - Advanced search and filtering by any metadata (genre, year, composer, etc.).
  - Search across lyrics if available.
- Add more complex search bars to the library (search by metadata and not specific song names)

## Library & Song Management
- Add new sorting methods to the songs list page
- Song Ratings
  - Allow users to rate songs and sort/filter by rating.
- Add: a downloaded indicator for songs (playlists, albums, artists, etc)

## Audio & Playback Features
- Try adding podcast support
- Audiobooks?
- Audio Effects
  - Add a built-in equalizer or simple audio effects (bass boost, reverb, etc.).
- Lyrics Support
  - Allow users to add/edit lyrics for their local songs and display them during playback.

## Artist & Album Features
- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library’s saved artists have it load the artist page with an option to show “saved songs by -artist name-“

## Bug Fixes & Miscellaneous
- Migrate the full playlist import logic to a service that can run without the screen being open. I want the ui to not change at all, just move the logic to a service.
- the album icon on the playbar flickers when transitioning between parts of a screen (ex. albums list to a specific album or artist lists page to a specific artist's songs) i like the way everything is handled now but would like the flicker to stop

- Improve: the download system by allowing syncernous downloading
- Improve: the playlist import system by searching and matching multiple songs at the same time

- Fix: the broken download system:

flutter: Submitting download for Paralyzed (base filename: 5DHQKZCOZhGNTbYBCekWx0_Paralyzed) to DownloadManager.
flutter: [DownloadManager:info] [DownloadManager] Download already active or queued: https://ltn-api.vercel.app/api/track/97096574.mp3
flutter: Error in downloadSong: Exception: DownloadManager.getFile completed but file is null or does not exist.

Add handling for this (redownload and overwrite original files)