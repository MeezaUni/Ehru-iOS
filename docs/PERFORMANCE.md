# Performance checks

The iOS workflow runs `LibraryPerformanceTests` alongside the regression suite and uploads
`Ehru-test-results` (an `.xcresult` bundle). Open the bundle in Xcode to inspect wall-clock
and CPU measurements for building a synthetic library of 10,000 tracks. Compare runs with
the same Xcode, simulator and runner class. These measurements are not device temperature
or battery measurements, and there is no established performance baseline yet.

On a Mac, generate the project with `xcodegen generate`, select an installed iPhone simulator
with `xcrun simctl list devices available`, then run:

```sh
xcodebuild test -project Ehru.xcodeproj -scheme Ehru \
  -destination 'id=<simulator-UUID>' \
  -only-testing:EhruTests/LibraryPerformanceTests \
  -resultBundlePath /tmp/Ehru-performance.xcresult CODE_SIGNING_ALLOWED=NO
```

Use a fresh result bundle path for each run. Linux syntax parsing does not compile or execute
these tests.

## Physical-device follow-up

Use a Release build and Instruments Time Profiler / Energy Log with the same library and audio
route for both revisions. Record the device model, iOS version, track count, route and initial
thermal state. Check these scenarios separately:

- Ten minutes of playback with the screen locked.
- Pause for two minutes: the position must stay fixed and the audio engine must stop rendering.
  Resume should continue from that position; lock-screen controls should show the paused state.
- Scroll a large library and change an existing album cover. Check both the library and Now Playing;
  reopening the app should retain the embedded image. An unsupported or failed save must show an error.
- Open VYBE once to finish indexing, then play and pause without changing tags. Listening statistics
  and waveform cache writes must not start another indexing pass.

The regression suite exercises pause/resume with a real AVAudioEngine, cover replacement at an
unchanged URL, and database notification filtering. It does not replace these device checks.

## Scrolling and animation work

The floating controls follow consumed vertical scrolling over 120 points, then settle into one
row (current section, mini player, Search). The small chrome view owns the changing fraction;
library pages do not read it. Their bottom inset stays fixed so collapsing the controls cannot
change the scroll position and feed another collapse/expand cycle. Section changes, navigation
and Search expand the controls again. Horizontal shelves do not drive the vertical chrome.
The section capsule previews a drag locally and selects a section only on release.
On iOS 26+, the three glass surfaces share a `GlassEffectContainer` rather than rendering as
independent glass groups.

Synced lyrics use lazy rows and stop their refresh timeline while paused, backgrounded, hidden,
or during player movement. Line-only lyrics update at 4 Hz; word-timed lyrics use 10 Hz when the
device's energy budget allows. Motion covers release their decoder when scrolled out of view,
backgrounded, in Low Power Mode, or at serious/critical thermal state. Pause/resume retains the
visible decoder so it does not repeatedly reopen the file. The visualizer releases its audio-tap
reader in the background and reduces its frame rate under power/thermal restrictions. Its tap
uses a non-blocking lock on the audio callback; a diagnostic sample may be skipped under contention.
Decorative still-cover animation also stops when backgrounded or power/thermal restricted.
These changes preserve audio processing and the higher-resolution downloaded clips.

Keeping all four tab stacks mounted must not start every tab's work. VYBE first starts its model
and index when selected, and Home first starts its mix observer when shown. Mix/radio lookups
return immediately when there is no saved VYBE index; they do not instantiate an embedding model
just to discover that no vectors exist. A saved index's model identity is cached for later mix
rebuilds. `VybeStartupTests` checks model-factory calls for both cases.

Phone checks: scroll Home, Albums, Library and a long album in both directions; test the top/bottom
rubber band, horizontal shelves, tab taps and drags, opening Search, expanding the compact section
button, and opening the player from either layout. Check VoiceOver and Reduce Motion. For energy,
compare ten minutes of library scrolling and ten minutes of Now Playing with lyrics, using the
same animated cover on both builds. Unit/simulator checks cannot establish device heat reduction.
