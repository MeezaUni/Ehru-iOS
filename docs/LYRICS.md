# Synced-first lyrics

Automatic lookup chooses a confident word-synced match, then a line-synced match. It never
interrupts playback with a choose-a-result screen. Artist/title, recording-version and duration
checks still apply. The known Ye/Kanye West identity is used for matching and, after a healthy
empty response, an alternative LRCLIB lookup; local file tags are never changed.

Embedded synchronized lyrics and saved synchronized results can be used immediately and offline.
Embedded plain lyrics no longer bypass the online sync check. Old plain caches and legacy missing
entries are rechecked; valid saved synchronization is retained. Real timestamps are parsed to
classify timing, so an untimed string in a field named syncedLyrics is still plain text.

Plain text is used automatically only after synchronized sources successfully answered without
an appropriate synced match. LRCLIB returning 502, a timeout, an offline error or rate limiting
means availability could not be checked. It does not establish that synchronization is missing.
In this situation the player shows the service-unavailable message and keeps any genuine saved
sync; it does not automatically substitute newly fetched or cached plain text.

**Search online** is the separate place for available alternatives. Synced choices appear first.
If LRCLIB fails but a plain source returns options, the list states that synchronized availability
could not be checked, and labels the actual source/timing of each option. Picking an option there
is an explicit action, unlike automatic lookup. **Search the web** still opens a browser query.

LRCLIB retains its bounded retry and Retry-After behavior. Lyrics requests bypass the local HTTP
response cache. The optional plain source is [lyrics.ovh's documented API](https://github.com/NTag/lyrics.ovh#api),
using real catalog metadata/IDs and returned text. It does not supply timing; Erhu never estimates
it. This service may itself use LRCLIB and other sources, so it cannot guarantee availability.
Only search/track metadata is sent; music files are never uploaded.

Tests cover synced-over-plain priority, embedded plain lyrics, old caches, partial outages,
continued use of saved sync, explicit manual alternatives, artist aliases and recording-version
rejection, actual timestamp classification, gateway recovery, backoff and stale search responses.
Live provider calls remain blocked by this development environment's outbound proxy (CONNECT
403); that does not establish the service's availability on a phone. The user's desktop 502 and
third-party degraded-status screenshot are consistent with the API failing while its website
still loads; they do not expose the provider's internal cause.
