# Android → iOS port

What the Android app (lochanpthakke/empee3) does, and where each part stands in this iOS app.
The rules the Android code follows are kept: nothing is made up, music never leaves the phone,
no cloud inference, no microphone, and online lyrics send only title, artist, album and duration.

Legend: ✅ ported · 🟡 partly ported · ⏳ not yet · ➖ not applicable on iOS

## Library and data

| Android | iOS | Notes |
|---|---|---|
| Room database (songs, albums, artists, credits, playlists, play stats, bookmarks, waveforms) | ✅ | SQLite (system library), same tables and ids |
| MediaStore scan, tag reading (JAudioTagger) | ✅ | Scans the app's Documents folder; native ID3v2/v1, MP4, FLAC, WAV, AIFF reader |
| Artist identity, credits, album grouping (library model layers A–D) | ✅ | Same ids and ordering; 94 shared test cases |
| Favorites, playlists, recently played, listening months, Sound Capsule stats | ✅ | |
| Search (accent- and case-insensitive) with recent items | ✅ | |
| Import music | ✅ | Files app (UIFileSharing), document picker, Wi-Fi Transfer |
| Library Builder (move files into Artist/Album folders through SAF) | ⏳ | Held back on purpose: on iOS a song's identity is its file path, so moving files would detach favourites, playlists, play history, bookmarks and transitions. Needs a path-to-id migration first. The Files app can organise the folder meanwhile |
| Custom scan location | ➖ | iOS apps only read their own folder (plus picked files) |

## Playback and sound

| Android | iOS | Notes |
|---|---|---|
| Media3 queue, shuffle, repeat, play next, add to queue, undo removal, history | ✅ | |
| Gapless playback | ✅ | Back-to-back scheduling on AVAudioEngine |
| Transitions (crossfades with curves, EQ moves, bass swap, filters; per album, playlist, pair) | ✅ | Engine, settings and the Transition Studio (per album/playlist and per pair: presets, duration, volume curves with draggable points, bass swap, filters, undo). Individual pairs also show decoded source waveforms, peak/RMS measurements, exact automation inspection, cue sliders and a preview using the real transition DSP. Per-lane waveform dragging, anchored pinch/time zoom and labelled display-height controls are supported. Not yet: automatic beat/key analysis |
| 8-band parametric EQ with presets and the curve editor | ✅ | Custom audio unit, same filter math |
| A–B loop, bookmarks | ✅ | |
| Lock screen / headphone controls, audio focus, resume after restart | ✅ | MPRemoteCommandCenter, AVAudioSession |
| Visualizer | ✅ | Analysis engine and the full-screen visualizer |
| Waveform seek bar | ✅ | Decoded with AVAudioFile into 480 bins, cached in the database |
| Audio details / DSP diagnostics screen | ✅ | Source file read by Core Audio (with provenance), engine formats, processing chain, iOS route, headroom and peak meter, copy/share report without paths or device names |
| Home screen widget | ⏳ | Deferred for now. Needs a WidgetKit extension sharing an App Group, which unsigned / free-account sideloading can't sign reliably. Lock Screen and Control Center controls work (Now Playing) |

## Discovery

| Android | iOS | Notes |
|---|---|---|
| Smart Playlists (rotation, your sound, forgotten, deep cuts, moods, spotlight, throwbacks, …) | ✅ | Same scoring and tie-break hashes; Android's tests ported |
| Smart Radio (song, album, artist; new picks) | ✅ | |
| Generated mix covers and home banners | ✅ | Same seeds and Kotlin random sequence, so covers match |
| Featured Albums | ✅ | |
| VYBE (on-device search by mood, genre, tempo, artist) | ✅ | Same descriptions, routing, boosts and index format. Android runs EmbeddingGemma through MediaPipe, which has no iOS runtime here, so iOS uses Apple's built-in NaturalLanguage embeddings (sentence model when the OS has it, else averaged word vectors). Its "weak result" threshold was set from CI measurements and should be checked on a phone. |

## Lyrics

| Android | iOS | Notes |
|---|---|---|
| Embedded lyrics, LRC / enhanced LRC (word timing) | ✅ | |
| LRCLIB lookups with the matcher, cache, manual search and choice | ✅ | Word-synced Lyricsfiles read with a small YAML reader |
| Lyrics colour palette from artwork | ✅ | Same algorithm and contrast checks; follows the Glass setting |

## Tools

| Android | iOS | Notes |
|---|---|---|
| Wi-Fi Transfer | ✅ | Same page, routes, pairing and checks. Runs only while empee3 is open (iOS suspends apps in the background). Ogg and Opus are refused because iOS cannot play them. |
| Auto Fix Tags / metadata editor (MusicBrainz, iTunes, Deezer, Last.fm, Discogs, Genius, Wikipedia, AcoustID-free matching, tag writing, revert) | ✅ | Matcher, scorer, filename cleaner and field planner ported with their tests; iTunes, MusicBrainz, Deezer and Last.fm searched (Last.fm with the listener's own key from Settings › Online sources); native tag writer for MP3 (ID3v2.4), M4A and FLAC with read-back verification; revert restores the kept original. Not yet: Genius (needs its own token), renaming files (song identity is the path on iOS) |
| Artwork Fetcher (album covers, artist photos, Fanart.tv) | ✅ | iTunes, Cover Art Archive, Deezer, Wikimedia, and Fanart.tv and Discogs when their keys are set in Settings › Online sources; automatic artist photos with the Deezer matcher; covers embedded with the verified writer; playlist covers from Photos. Not ported: Genius / DuckDuckGo scraping |
| Animated album artwork (Apple Music motion covers) | Separate branch | Available on `with-animated-art`; this `without-animated-art` branch uses static artwork only |
| BPM finder | ✅ | AcousticBrainz, then the on-device tempo estimate; only fills a missing BPM |
| Themes, skins, theme import and rollback | 🟡 | Light / dark / system, the glass effect and imported theme packages (colours) are ported; fonts and widget skins aren't used on iOS |
| Update checker (GitHub releases) | ➖ | Sideloaded builds are updated by reinstalling |

## Building and installing

CI (`.github/workflows/ios.yml`) builds an unsigned IPA and runs the unit tests on a simulator on
every push. The IPA is signed on install with a free Apple ID through SideStore or AltStore.

## API keys

Last.fm, Fanart.tv and Discogs keys are the listener's own: they are entered in Settings › Online sources and kept in the iOS Keychain on that device only. None is in this repository or the built IPA; without a key, that source is skipped.
