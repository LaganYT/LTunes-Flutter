# TODO

## Audio & Playback Features
- Try adding podcast support
- Audiobooks
- Work on ios audio session configuration, its still a little broken
- When you click on the same song in a different playlist/album have it "switch context" which keeps the current song the same and same place and everything but the queue updates as if you were playing that song from that playlist/album

## Lyrics Features
- Lyrics Support
  - Allow users to add/edit lyrics for their local songs and display them during playback.
- remove the decreased opacity on previous lyric for synced lyrics
- Fix the lyric functionality for how it fetches to be more optimized and consistent 
- Add those dots from better lyrics on Spotify whenever there is a break in lyrics
- Have lyrics be formatted in a way so when they get resized as they are set to the current lyric that they don't shift positions at all
- Copy Spotify's lyric sharing feature where it makes an image with the selected lyrics
- When you close the lyric menu (and show album art again) have it auto scroll to the current lyric when it's opened again
- For the no lyrics found thing for a song in the full screen player add a subtext saying "Want to add lyrics to our database? Click here" with a Hyperlink to LRCLIB-frontend (maybe add a find song lyrics button to lrclib that fetches a specific song's lyrics from genius, or something. )

## Artist & Album Features
- Add: allow following an artist to save them to your library, this should replace the old artists page in the library, when clicking an artist from your library's saved artists have it load the artist page with an option to show "saved songs by -artist name-"
- Create a new api endpoint for the artist profile api and update the app to use this new api, this should use Spotify for the profile? (Not decided)

## Full Screen Player & UI
- For the opening of full screen player animation have it use the icon from the playbar and make the transition smoother by not having it wait for the icon to load before finishing the animation, currently it doesn't feel smooth it feels like you get half of the animation wait a few milliseconds then continue 

## Downloads & File Management
- From the manage downloaded files in settings allow users to export any file (audio or album art) 

## Onboarding
- Add an onboarding screen (happens only the first time you open the app)