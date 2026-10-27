# Animated covers (personal branch)

Open **Menu → Animated covers**, find an album, and tap **Find & download**. Matching uses the
library's album and artist, searches the local/US catalog, and checks Apple motion artwork across
several storefronts. Explicit editions are preferred among matching results. An album with no
motion artwork keeps its embedded still image. No Apple Music account or subscription is used.

Downloads are local videos in Application Support, with a persisted index. They do not alter
music files or tags. Use **Remove** to delete a clip, or turn off **Play downloaded motion covers**
to retain the files while using still covers. Downloads require a network connection; playback
of a saved clip does not. Only unencrypted fragmented MP4 clips are supported. The downloader
chooses an SDR rendition up to a 720-pixel short edge where available, limits saved clips to
64 MB, checks playability, and removes partial files on failure or cancellation. Single-track
fragment decode times are rebased to zero, preserving video bytes and relative timing.

The current Now Playing card and the visible album header loop muted video. The library grid and
carousel neighbours remain still. Video releases its player when the view is hidden, music is
paused (Now Playing), the app backgrounds, Low Power Mode activates, or Reduce Motion is enabled.
The existing cover remains underneath until the first video frame is ready, and remains visible
if video playback fails. Saved video does not replace lock-screen artwork, which iOS expects as
a still image.

## Lookup implementation

Adapted from `MeezaUni/empee3` at `f291c7dc41d5725efcdf646677c048f282f78a4b`:
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
boxes. The standard iOS GitHub Actions workflow builds the app and runs these tests.

On a phone, download a known album that Apple currently supplies motion artwork for. Verify
that it loops without sound in Now Playing and on the album page; test pause/resume, tab switches,
backgrounding, Low Power Mode and Reduce Motion. Enable airplane mode after download to verify
offline playback. Test removal, cancellation, an album without motion artwork, and failure with
no connection. Compare device energy usage with animated covers enabled and disabled.
