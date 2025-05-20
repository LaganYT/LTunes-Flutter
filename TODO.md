# TODO

- Save song metadata to the song when downloaded to avoid fetching it later.

- Add loading animation.
- Add the song thumbnail next to the downloaded song

- Change the downloads icon to a library icon
- Have it so when you play downloaded songs it sitll plays in the playbar
- have a playlist called like songs that exists by default, have a heart button that adds songs to liked songs

- when adding a song to a playlist, check that the song isn't already in the playlist, preventing duplicates
- allow you to click on the playbar to have it become fullscreen with more controls
- add shuffle and loop

- do not fetch song info on downloaded tracks, they should have the song info as metadata
- Add an updater, the api to fetch update details is at: https://ltn-api.vercel.app/updates/update.json


- Integrate iOS/Android lock screen and notification media controls (audio_session, media_notification, etc.)
    - Set up audio_session for background audio and interruption handling.
    - Implement MediaMetadata retrieval and updates for display on lock screen/notifications.
    - Handle play/pause/next/previous commands from media controls.
    - Ensure media controls work seamlessly with streaming audio URLs without requiring local file encoding.