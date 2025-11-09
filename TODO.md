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

- Add touch haptics (toggleable in settings)
- Automatically download new songs added to downloaded playlists by improving playlist download handling
- Design a fully-featured listening stats page
- Display countdown for the sleep timer in the full screen player app bar; redesign sleep timer integration
- Ensure that when clicking a song in song list, playback starts immediately by loading/playin the song first and queuing the remainder in segments, avoiding queue load delays
- Experiment with queue containing only song IDs and loading song details dynamically as needed
- Reduce icon flickering when scrolling down the song list


Go through the entire codebase focusing on the audio handler and current song provider components. Identify and remove all custom audio-related code that duplicates functionality already provided by the audio, audio_service, or audio_session Flutter packages. Refactor the code to rely solely on these packages for audio playback, session management, and song state handling. Remove any unnecessary custom event listeners, state management, or helper functions related to audio that these packages can handle internally. Adjust the UI and providers to directly use the APIs and reactive streams from these packages without extra abstraction or duplication. The goal is to simplify the audio logic by leveraging the standard, well-supported Flutter audio ecosystem fully.