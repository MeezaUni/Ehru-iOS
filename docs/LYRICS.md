# Lyrics source failover

Automatic lookup prefers real word-synced lyrics, then line-synced lyrics. Matching still checks
title, artist, recording version and duration; there is no automatic choose-a-result screen.
The Ye/Kanye West alias is used for matching and healthy empty exact/search lookups without
rewriting local tags. Timing is classified from actual timestamps, never just an API field name.

On a provider failure, immediately try the other available sources. LRCLIB gateway responses
(5xx, including 502) get no automatic retry or retry-delay sleep. A gateway Retry-After header is
not a 429. If present it only suppresses further requests to that unavailable provider internally;
it never creates a user-facing wait. Real 429 limits are also respected by skipping that provider
and continuing failover. Healthy requests keep their existing courtesy spacing.

The player gets the failure reason as soon as failover starts, including for coalesced lookups.
Request-generation and pending-state checks prevent a late progress event from overwriting a
new song, a manual selection or completed lyrics. File lyrics can appear immediately after the
failure even while the alternate request is still pending. There is no countdown or paused-
lyrics screen. Normal network response time is still required when no local result exists.

Real saved synchronization stays ahead of plain text. If only plain text is available from a
file, saved result or another provider, it is shown with the source and **not synced** label,
plus the original reason near the Lyrics heading, such as **LRCLIB unavailable (HTTP 502)**.
This is temporary failover, not a claim that synchronized lyrics do not exist. Actual fallback
content may be cached, but the transient outage reason is not persisted as a permanent status.
Errors never become seven-day missing-lyrics cache entries. Plain caches are rechecked for
synchronization on later lookups, and old missing entries are rechecked under the current policy.

**Search online** loads alternatives as soon as it opens, with real synced options first. It also
keeps a source-failure notice when another service provides options. **Search the web** is a
separate browser action. The plain source is [lyrics.ovh's documented API](https://github.com/NTag/lyrics.ovh#api),
which supplies real catalog metadata/IDs and returned text. It does not provide synchronization,
and Erhu never fabricates timestamps. This service may itself use LRCLIB and other sources, so
availability is not guaranteed. Only search/track metadata is sent, never audio files.

Tests cover gateway-versus-429 classification, one-request gateway failure, immediate provider
switching, a pending alternate with already-visible local lyrics/reason, saved sync, plain-source
labelling, cache recovery, aliases, version matching and stale asynchronous results. The native
iOS workflow builds and tests both variants. Live provider hosts have been blocked by the
development proxy (CONNECT 403); this does not establish their availability on a phone.
