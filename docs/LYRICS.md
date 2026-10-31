# Online lyrics and service failures

File lyrics and previously saved online lyrics work without another download. When a lookup is
needed, Erhu asks LRCLIB first. Its exact lookup and search still prefer genuine word/line timing
and enforce the existing title, artist, recording-version and duration match checks.

LRCLIB gateway responses (502/503/504) get at most one automatic retry. Lyrics requests bypass
URLSession's local response cache, so Retry does not reuse a stored gateway response. Rate limits
retain their Retry-After backoff. An explicit server wait is never immediately retried.

If LRCLIB is unavailable or has no confident result, automatic lookup and manual search can use
[lyrics.ovh's documented public API](https://github.com/NTag/lyrics.ovh#api). Its suggestions supply
actual catalog IDs and metadata; up to three matching records are checked for returned text.
Only that text is shown: this provider does not supply timing, and Erhu does not estimate it.
Uncertain artist/title matches are offered for the listener to choose. The source and timing are
shown with each result. The public service may itself rely on LRCLIB and other sources; a second
endpoint is not a guarantee that lyrics will be available during every outage.

Both services receive only search/track metadata. Music files are never uploaded. Saved results
keep their actual source and remain keyed to the song's metadata. A partially failed lookup is
not cached as a seven-day missing result. Starting another manual search or closing it cancels
its pending work; a late response cannot overwrite newer results.

**Search the web** is a separate, explicit browser action, available on the search sheet even
while an in-app search is pending. It opens a Google query; Erhu does not scrape the browser or
claim that a web result was downloaded or synced.

Tests cover transient/persistent gateways, Retry-After, automatic/manual failover, cache recovery,
real fallback metadata and plain text, different recording versions, URL component escaping,
empty responses and overlapping manual searches. Live calls to both provider hosts are blocked
by this development environment's outbound proxy (CONNECT 403); that does not establish their
availability on a phone. Native builds/tests run in the iOS workflow.
