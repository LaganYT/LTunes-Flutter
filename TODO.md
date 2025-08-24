# TODO

## Audio & Playback Features
- Try adding podcast support
- Audiobooks
- Work on ios audio session configuration, its still a little broken
- When you click on the same song in a different playlist/album have it "switch context" which keeps the current song the same and same place and everything but the queue updates as if you were playing that song from that playlist/album

## Lyrics Features
- Allow users to add/edit lyrics for their local songs and display them during playback.
- Fix the lyric functionality for how it fetches to be more optimized and consistent 
- Add those dots from better lyrics on Spotify whenever there is a break in lyrics
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics
- For the no lyrics found thing for a song in the full screen player add a subtext saying "Want to add lyrics to our database? Click here" with a Hyperlink to LRCLIBPlusPlus (https://lrclibplusplus.vercel.app/publish)

## Artist & Album Features
- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library's saved artists have it load the artist page with an option to show "saved songs by -artist name-"
- Create a new api endpoint for the artist profile api and update the app to use this new api, this should use Spotify for the profile? (Not decided)

## Onboarding
- Add an onboarding screen (happens only the first time you open the app)

- Before the artist name on a song show an explicit marker and a downloaded marker
- For the selected song show the same indicator how the queue does