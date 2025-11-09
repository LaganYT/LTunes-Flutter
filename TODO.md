# TODO

- Podcasts
- Audiobooks
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics
- Before the artist name on a song show an explicit marker and a downloaded marker on the song lists
- Allow users to export playlists
- Allow users to export settings
- Allow users to export all data
- Let users change their default tab
- let users re-arange their tabs
- When you scroll a certain amount past the current lyric have it not auto scroll the current lyric into view unless you scroll back into that range


When scrolling down the song list, fix the icons flickering

When a new song is added to a downloaded playlist have that song auto download - rework how downloaded playlists are handled to achieve this

When you click on an online song and you don’t have signal skip to the next song in context automatically

Fix it so when the device is offline it’ll still play a playlist with a song that isn’t downloaded just skip that song when it comes up

Add touch haptics (disable-able)

Fix bug: LTunes refuses to play a playlist if 1 song is not found, also make sure it doesn’t wait for any online songs to load before loading the current song of a playlist

Redesign the sleep timer system, make it more integrated and show the countdown in the full screen player on the appbar section

When clicking on a song in the songs list it takes forever to start playing, to fix this make sure that the song can play while the rest of the queue  is still loading, have the queue load in segments that way it doesn’t await for the full queue to load

Experiment with the queue just having song ids and the rest of the info loading dynamically

Redo the listening stats to be a full page with more info


Go through the entire codebase focusing on the audio handler and current song provider components. Identify and remove all custom audio-related code that duplicates functionality already provided by the audio, audio_service, or audio_session Flutter packages. Refactor the code to rely solely on these packages for audio playback, session management, and song state handling. Remove any unnecessary custom event listeners, state management, or helper functions related to audio that these packages can handle internally. Adjust the UI and providers to directly use the APIs and reactive streams from these packages without extra abstraction or duplication. The goal is to simplify the audio logic by leveraging the standard, well-supported Flutter audio ecosystem fully.