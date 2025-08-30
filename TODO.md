# TODO

## Audio & Playback Features

- Podcasts
- Audiobooks
- Work on ios audio session configuration, its still a little broken

## Lyrics Features

- Allow users to add/edit lyrics for their local songs and display them during playback.
- Any time there are breaks (empty lines) in synced lyrics add a break with 3 dots that are like loading dots, each dot should fill up slowly 1 by 1 distributing the time of the gap in the lyrics evenly between each dot
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics
- For unsynced lyrics show the color as the highlighted color

## Artist & Album Features

- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library's saved artists have it load the artist page with an option to show "saved songs by -artist name-"
- Create a new api endpoint for the artist profile api and update the app to use this new api, this should use Spotify for the profile? (Not decided)

## UI & Display Features

- Before the artist name on a song show an explicit marker and a downloaded marker
- For the selected song show the same indicator how the queue does

## Onboarding & Updates

- Add an onboarding screen (happens only the first time you open the app)

## Development & Infrastructure

- Put a clone of the api in the same folder as the flutter project and let cursor edit both to be as compatible at possible
