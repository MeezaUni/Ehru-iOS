# Animated covers (personal branch)

Open **Menu → Animated covers**, find an album, and tap **Find & download**. Matching uses the
library's album and artist, searches the local/US catalog, and checks Apple motion artwork across
several storefronts. Explicit editions are preferred among matching results. An album with no
motion artwork keeps its embedded still image. No Apple Music account or subscription is used.

Downloads are local videos in Application Support, with a persisted index. They do not alter
music files or tags. Use **Remove** to delete a clip, or turn off **Play downloaded motion covers**
to retain the files while using still covers. Downloads require a network connection; playback
of a saved clip does not. Only unencrypted fragmented MP4 clips are supported. The downloader
chooses the largest SDR rendition up to a 1080-pixel short edge where available (1080×1080 square,
1080×1440 portrait), preferring higher bitrate at equal resolution. If every rendition exceeds
that target, it uses the smallest available resolution. The downloader limits saved clips to
64 MB, checks playability, and removes partial files on failure or cancellation. Single-track
fragment decode times are rebased to zero, preserving video bytes and relative timing.

The current Now Playing card, mini-player and visible album header loop muted video, including
when music is paused. Library grids remain still. Adjacent carousel covers keep separate paused,
prerolled movies and start moving as they approach the centre. The mini-player, flying cover and
current card share one native video surface rather than switching between static and animated
pictures. A cover pauses on its last decoded frame during presentation gestures; no bitmap
conversion runs at drag start.

Album headers keep their native video mounted when scrolled offscreen, hidden under Now Playing,
or backgrounded. They pause and resume in place as visibility changes. Low Power Mode, serious/
critical thermal state and Reduce Motion may use static artwork. A poster is also used for initial
loading, missing downloads or disabled motion covers; it is not substituted on ordinary occlusion.

## Lock screen and system Now Playing

On iOS 26 and later, a downloaded cover is also published through Apple's
`MPMediaItemAnimatedArtwork` API, under a supported square (1:1) or portrait (3:4) key.
The preview is generated from the video's first frame at up to 1200×1600 pixels without upscaling,
and the video URL is always local. Preview-quality changes use a new artwork ID version so the
system does not reuse the previous low-resolution preview. Use **Download again** to upgrade
older saved videos; their resolution does not change merely by installing a new app build.
New downloads also retain Apple's portrait rendition when available; the publisher supplies both
shapes under their respective supported keys. A failed portrait preparation does not discard a
usable square cover. Existing downloaded clips remain compatible. Use **Download
again** to fetch a portrait rendition for a previously saved square cover. Each rendition has the
same 64 MB limit; the app does not relabel square video as portrait artwork.
iOS owns rendering and decides when animation is displayed; no background AVPlayer is kept
running by the app. Older systems, unsupported shapes/platform keys, missing files and preview
failures retain the existing still artwork. The Animated covers toggle applies to both in-app
and system artwork; removing or replacing a download refreshes Now Playing immediately.

**Menu → Animated covers → Lock Screen** shows preparation errors and whether iOS has requested
the video for the current album. “Ready” means the app published a supported descriptor, not
that iOS displayed it. “Video supplied to iOS” means the video handler was called, not that frames
were rendered. Use **Retry Lock Screen artwork** after a failure; returning to the app retries
failed preparation and rechecks supported shapes. Identical metadata updates reuse prepared
artwork rather than decoding previews repeatedly.

The system may retain its artwork handlers after a metadata refresh. A hard-linked file lease
(or a copy when linking is unavailable) keeps their URLs valid until those handlers are released.
This does not duplicate downloaded video bytes when hard linking is supported.

To check on a phone running iOS 26: download a cover, play its album, lock the phone and expand
Now Playing artwork. Check pause/resume, skipping to another album, replacing/removing the cover,
and toggling animated covers off. Verify the still fallback with no downloaded cover and with
system motion/power restrictions. Simulator/unit checks do not establish lock-screen appearance.

## Lookup implementation

Adapted from `MeezaUni/Erhu` at `f291c7dc41d5725efcdf646677c048f282f78a4b`:
Apple web catalog editorial-video lookup, public web-player token discovery, unencrypted HLS
playlist assembly, and fragmented MP4 timeline rebasing. The web token is kept only in memory,
refreshed after an authorization failure, and is never persisted or printed. Apple can change
its web player or catalog response; lookup failures are reported instead of silently removing
the still cover. A 429 response pauses subsequent lookup attempts.

The public endpoints needed by a device are `itunes.apple.com`, `music.apple.com`,
`amp-api.music.apple.com`, and Apple's video CDN subdomains under `apple.com` / `mzstatic.com`.
The cloud development proxy currently refuses Apple connectivity (HTTP CONNECT 403); live lookup
and video downloads have not been verified from this environment.

## Validation

`MotionArtworkTests` covers catalog resolution through a fake HTTP client, matching, SDR variant
selection, relative URLs, byte ranges, and rejection of encrypted/live/malformed playlists.
`MotionTimelineTests` covers 32/64-bit decode times, idempotence, multiple tracks and malformed
boxes. `LockScreenMotionArtworkTests` generates a real local video to check preview extraction,
recognized aspect ratios, supported-key filtering, missing-file fallback and file lifetime after
removal. The standard iOS GitHub Actions workflow builds the app and runs these tests.

On a phone, download a known album that Apple currently supplies motion artwork for. Verify
that it loops without sound in Now Playing and on the album page; test pause/resume, tab switches,
backgrounding, Low Power Mode and Reduce Motion. Enable airplane mode after download to verify
offline playback. Test removal, cancellation, an album without motion artwork, and failure with
no connection. Compare device energy usage with animated covers enabled and disabled.
