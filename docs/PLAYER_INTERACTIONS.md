# Player and song interactions

The seek bar uses a UIKit pan recognizer that rejects vertical gestures before recognition.
Vertical scrolling can therefore start over the seek bar, including either endpoint. A horizontal
drag previews a position and seeks once on release; cancellation clears the preview without
seeking. A tap still seeks directly. The waveform seek bar uses the same interaction. VoiceOver
keeps its ten-second adjustable seek action.

Song rows support a deliberate swipe of at least 72 points: right appends the song to the queue;
left adds it to Liked Songs. Repeating the like action does not unlike the song. Vertical gestures
and short swipes do neither. Existing play, heart, context-menu and ellipsis actions remain.
The ellipsis uses a plain 44-point control rather than the system's filled menu-button style.

The centered player header shows its playback source as ordinary text. Tapping it closes the
player and opens the source. Album/playlist sources come from the collection actually started,
including playlists containing repeated songs. Artist, smart-mix, favorite and VYBE playback also
record their context. Queueing a song from a collection records that navigation context without
adding a transition origin to an individually queued song. Sources follow queue entries through
shuffle/removal and persist across launches. Older snapshots recover album/playlist sources from
their existing transition origins and use Library for otherwise unattributed entries.

The Transition editor has a separate header with Cancel, More and Save; a wrapping preset grid;
glass panels for duration, curves and settings; plain menu rows; and a clear inactive state.
Duration reads the transition currently displayed, including inherited settings. Graph legends
sit outside the curves. Dragging a curve requires starting near a control point; dragging blank
graph space can scroll. The bass-swap lane only accepts horizontal movement. Draft, undo, Save,
Cancel and transition audio semantics remain the same. Preview playback and waveform cue lanes
are still separate unfinished features.

## Checks

`GestureIntentTests` checks horizontal/vertical classification and swipe commitment thresholds.
`PlaybackSourceTests` checks source inference, duplicate/deleted-song restoration, old JSON
compatibility and source navigation. Native compilation and the regression suite run in GitHub CI.

On a phone, scroll vertically starting at the left/middle/right of the seek bar: playback time
must not jump. Check a genuine tap and horizontal scrub, cancelled scrubs and VoiceOver seeking.
Swipe song rows both ways, repeat liking an already-liked song, and verify normal vertical
scrolling, song taps and menu actions. Start an album and a mixed-album playlist, shuffle/skip,
restart, and tap the source header. Check editor Save/Cancel/Undo, inherited duration, all preset
buttons, large text and scrolling from empty graph areas. Unit tests do not verify touch feel
or visual appearance on a physical device.
