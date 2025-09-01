# TODO

## Audio & Playback Features

- Podcasts
- Audiobooks
- Work on perfecting the api so that the song choices are always accurate

## Lyrics Features

- Allow users to add/edit lyrics for their local songs and display them during playback.
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics

## Artist & Album Features

- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library's saved artists have it load the artist page with an option to show "saved songs by -artist name-"
- Create a new api endpoint for the artist profile api and update the app to use this new api, this should use Spotify for the profile? (Not decided)

## UI & Display Features

- Before the artist name on a song show an explicit marker and a downloaded marker on the song lists

## Onboarding & Updates

- Add an onboarding screen (happens only the first time you open the app)

## Development & Infrastructure

- Put a clone of the api in the same folder as the flutter project and let cursor edit both to be as compatible at possible

Edit the display logic to allow (acoustic, live versions) also edit the audio fetching to allow the same.
Add a button by updates called “Known issues” that displays the issues i have logged in issues.json at the same url as updates.json
When you are on a song make sure its showing the right lyrics (full screen player)
Fix the download system on the full screen player so it doesn’t need the download button to be pressed for it to know if the song is downloaded
Fix the lyric service only finding plain lyrics