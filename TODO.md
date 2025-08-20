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
- When you press view album of a song have it check if that album is already offline in your library first
- Create a new api endpoint for the artist profile api and update the app to use this new api, this should use Spotify for the profile? (Not decided)

## Full Screen Player & UI
- Add a subtle slight quick fade from album art to lyrics
- For the opening of full screen player animation have it use the icon from the playbar and make the transition smoother by not having it wait for the icon to load before finishing the animation, currently it doesn't feel smooth it feels like you get half of the animation wait a few milliseconds then continue 
- Change the slide down animation to be more reactive like Spotify is (full screen player)
- Add a source control (airplay/android equivalent) button to the appbar of full screen player
- Change the full screen player shuffle/repeat icons to be filled not outlined with color

## Audio Effects & Settings
- For the audio effects have it save what eq preset you have on (it currently only saves the slider values and not the name of the preset, if you choose a preset then start editing it then change the name to custom)
- Move the reset audio effects to be a button at the very bottom of the menu

## Downloads & File Management
- From the manage downloaded files in settings allow users to export any file (audio or album art) 
- Have the download notifications open the download queue when clicked

## Social & Sharing Features
- Add SharePlay support via user hosting a hotspot the other person connects to that has a server that is hosted by the original user that the other person opens that syncs with the original user's app

## Onboarding
- Add an onboarding screen (happens only the first time you open the app)


Decrease background color fade time (1500 -> 500?)
make the background more prominent (0.1 more opacity)
give the full screen player a new design for the background of individual elements