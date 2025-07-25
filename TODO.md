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
- Add: a downloaded indicator for specific songs (playlists, albums, artists, etc)

## Audio & Playback Features
- Try adding podcast support
- Audiobooks?
- Audio Effects
  - Add a built-in equalizer or simple audio effects (bass boost, reverb, etc.).
- Lyrics Support
  - Allow users to add/edit lyrics for their local songs and display them during playback.

## Artist & Album Features
- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library’s saved artists have it load the artist page with an option to show “saved songs by -artist name-“

## Download & Notification Handling
- Replace: the all downloaded button with remove downloads (which makes the songs from offline to online - deleting the song files) from playlist button

## UI/UX Improvements
- Add: explicit indicator in more places, as well as an explicit filter in settings 

## Bug Fixes & Miscellaneous
- Migrate the full playlist import logic to a service that can run without the screen being open. I want the ui to not change at all, just move the logic to a service.
- the album icon on the playbar flickers when transitioning between parts of a screen (ex. albums list to a specific album or artist lists page to a specific artist's songs) i like the way everything is handled now but would like the flicker to stop