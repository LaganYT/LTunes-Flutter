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
- Allow users to export playlists
- Allow users to export settings
- Allow users to export all data
- Let users change their default tab
- let users re-arange their tabs

## Development & Infrastructure

- Have the most accurate match for everything be shown first, instead of showing in order of how they are returned from the api

- Go through the audio handler and current song provider and make sure it is as compatiable as possible, I have issues with background audio playback on my ios device sometimes, fix this

Fix songs not always switching when clicking on them
Fix music in the background randomly stopping playing after a few songs
Maybe try replacing audio session/audio service with just audio background (compare them first)
Fix versions of songs not being downloaded nor being counted as different songs (ex. Song about you and Song about you - acoustic)
When you scroll a certain amount past the current lyric have it not auto scroll the current lyric into view unless you scroll back into that range
Make the liked songs section of the library only show up if at least 1 song is liked
Add dev, beta, and stable release channels, let the user choose which to use.
When you click on a song it should change the playbar but not open the full screen player
Fix the queue stuck loading when a queue is too long