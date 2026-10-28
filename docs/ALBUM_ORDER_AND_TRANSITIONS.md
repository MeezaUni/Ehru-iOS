# Album ordering and individual transitions

Album pages and Transition Studio share `songsOfAlbum`: disc number first, then numeric track
number. Missing disc numbers are treated as disc 1. Unnumbered tracks follow numbered tracks
on that disc; title, path and id give a stable fallback. Playlist order is left as explicitly saved.
The scanner reads the file's own track/disc metadata and does not truncate large track numbers.

Auto Fix Tags offers Track number and Disc number. An existing all-fields selection gains these
options once; custom selections stay intact. All-fields mode preserves valid local numbering.
An explicit numbering selection can replace it. Positions must belong to the destination album,
including its edition words, and the destination disc. Conflicting equally confident positions,
unknown positions, or repeated MusicBrainz recordings are left unchanged and explained.

iTunes search supplies real track/disc fields; MusicBrainz supplies the chosen release's actual
media/tracklist (cached and rate limited); Deezer track detail supplies positions only if its
track and album identities match. Search rank and filename order are never used as track numbers.
Selected repairs write verified TRCK/TPOS, trkn/disk, or TRACKNUMBER/DISCNUMBER tags for MP3, MP4/M4A
and FLAC. Existing total counts and unrelated metadata/audio are preserved; backups and Revert
still apply. A scan after successful repairs updates album ordering and adjacent transition pairs.

The pair editor displays short decoded PCM windows around the outgoing/incoming cues, with
absolute per-channel peak and RMS envelopes. These are source audio, not a predicted processed
waveform, spectrum, beat grid, or loudness-normalized decorative shape. Opposite-phase stereo
does not cancel the measurement. Missing/truncated/unsupported audio is marked unavailable.

The timing comes directly from `TransitionPlanner`, including effective duration limits and cues.
White volume curves sample `TransitionAutomation`, also used by the engine. The inspection slider
shows source times, volume dB, 200 Hz bass-shelf dB and filter cutoff targets at millisecond
precision. Source peak/RMS measurements are dBFS over each displayed window before processing;
filter values are automation targets rather than measured output spectra. BPM is explicitly a
file tag; there is no fabricated key, tempo estimate, beatmatching, effect or looping display.

Cue sliders and ±100 ms controls edit the actual outgoing-end/incoming-start settings, with undo,
reset, Save and Cancel. Preview schedules bounded source segments on two decks with the same
transition DSP and current equalizer as playback. The incoming start uses the render clock.
The existing queue and seek position are retained; music pauses for the preview and resumes when
it finishes/stops. Backgrounding, interruptions and route changes stop preview without automatic
resumption; changing the queued song or resuming normal playback also stops preview.

Analysis decodes at most 13.5 seconds per track on demand, off the main thread, after a 250 ms
debounce. Cancellation stops obsolete work; an eight-window cache uses path, file size and mtime.
No continuous FFT, whole-library analysis, background animation, or full-track PCM allocation is
needed. Native waveform dragging and automatic beat/key analysis are not implemented.

CI checks album ordering, all-fields migration, provider positions, safe numbering plans, disc
tag round-trips, real PCM window measurements, opposite-phase channels, planner/automation parity,
and bounded preview scheduling. On a phone, verify preview sound, independent source formats,
headphone/route changes, Save/Cancel/Undo, rapid cue changes, unavailable files, large text, and
normal playback resumption. Device heat and touch feel still require a physical device.
