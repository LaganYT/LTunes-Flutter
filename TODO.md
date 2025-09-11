# TODO

## Audio & Playback Features
- Podcasts
- Audiobooks

## Lyrics Features
- Allow users to add/edit lyrics for their local songs and display them during playback.
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics

## UI & Display Features
- Before the artist name on a song show an explicit marker and a downloaded marker on the song lists

## Development & Infrastructure
- Have the most accurate match for everything be shown first, instead of showing in order of how they are returned from the api


Fix the queue getting stuck loading
Rework how shuffle works: when shuffle is on and you press play all have it skip to a random song in playlist/album and then have the queue shuffled from there, if clicking on a specific song then dont skip to random song just shuffle queue from there, when changing to another context have it shuffle the queue again, when shuffle is on that just means to use a shuffled version of that queue, when off just use the default version (non shuffled) of that queue