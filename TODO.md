# TODO

## Search
- Redo the search to show albums and artists in the search itself 
- Add radio stations into this new search system (without need for a different tab to search for them)

## Features
- Show if a song is explicit, add explicit filter
- Add search bars to library (universal one on modern library screen (maybe) and then individual ones for songs, album, playlists page.)
- make playbar show up in more places
- when viewing the album or lyrics from the albums details page have them preloaded for faster load times
- Also preload the artist page
- Add more details to artist page (maybe using Spotify api?)
- allow batch changes to songs (add a select box to select multiple songs to change, delete, add to a playlist, add to queue, etc.)
- add ways to display errors (like failed to fetch error with bad connection or something)
- add where the radio isn’t loading have a popup saying radio failed to load or something
- if possible add an auto installer on android (it fetches and then installs the apk file for you)
- when you pause a radio for longer than 10 seconds have it skip to live instead of pickup where you left off (disable-able in settings)
- make the swipe down animation for playbar/fullscreen player more interactive
- test adding the heart and download buttons next to the title/artist of the song
- Add a setting to allow auto downloading liked songs

## Bug Fixes
- 

## Performance
- try anything for making song playing faster
- more performance tweaks

## Potential Future Features
- try adding podcast support
- add shareplay support?

[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: Looking up a deactivated widget's ancestor is unsafe.
At this point the state of the widget's element tree is no longer stable.
To safely refer to a widget's ancestor in its dispose() method, save a reference to the ancestor by calling dependOnInheritedWidgetOfExactType() in the widget's didChangeDependencies() method.
#0      Element._debugCheckStateIsActiveForAncestorLookup.<anonymous closure> (package:flutter/src/widgets/framework.dart:4945:9)
#1      Element._debugCheckStateIsActiveForAncestorLookup (package:flutter/src/widgets/framework.dart:4959:6)
#2      Element.findAncestorWidgetOfExactType (package:flutter/src/widgets/framework.dart:5020:12)
#3      debugCheckHasScaffoldMessenger.<anonymous closure> (package:flutter/src/material/debug.dart:181:17)
#4      debugCheckHasScaffoldMessenger (package:flutter/src/material/debug.dart:195:4)
#5      ScaffoldMessenger.of (package:flutter/src/material/scaffold.dart:156:12)
#6      _AlbumsListScreenState._addAlbumToPlaylist (package:LTunes/screens/albums_list_screen.dart:155:25)
<asynchronous suspension>
#7      _AlbumsListScreenState._showAlbumOptions.<anonymous closure>.<anonymous closure> (package:LTunes/screens/albums_list_screen.dart:115:17)
<asynchronous suspension>

