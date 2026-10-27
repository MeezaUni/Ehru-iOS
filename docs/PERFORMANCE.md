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
