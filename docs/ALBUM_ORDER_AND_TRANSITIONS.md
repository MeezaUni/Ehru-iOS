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
and FLAC. Valid existing total counts and unrelated metadata/audio are preserved (a total smaller
than the repaired position is cleared rather than inventing a total); backups and Revert
still apply. A scan after successful repairs updates album ordering and adjacent transition pairs.

The pair editor displays short decoded PCM windows around the outgoing/incoming cues, with
absolute per-channel peak and RMS envelopes. These are source audio, not a predicted processed
waveform, spectrum, beat grid, or loudness-normalized decorative shape. Opposite-phase stereo
does not cancel the measurement. Missing/truncated/unsupported audio is marked unavailable.

The timing comes directly from `TransitionPlanner`, including effective duration limits and cues.
Blue volume curves sample `TransitionAutomation`, also used by the engine. The inspection slider
shows source times, volume dB, 200 Hz bass-shelf dB and filter cutoff targets at millisecond
precision. Source peak/RMS measurements are dBFS over each loaded audio window before processing
(its exact range is listed beside the measurements, independently of the visible zoom);
filter values are automation targets rather than measured output spectra. BPM is explicitly a
file tag; there is no fabricated key, tempo estimate, beatmatching, effect or looping display.

Cue sliders and ±100 ms controls edit the actual outgoing-end/incoming-start settings, with undo,
reset, Save and Cancel. Each waveform also accepts a horizontal drag: the upper lane shifts only
the outgoing cue and the lower lane only the incoming cue. Each drag captures its initial lane,
cue and time scale, updates locally under the finger, then commits one undoable edit on release.
Cancellation leaves the draft alone. Vertical gestures away from automation remain available
for scrolling; touches on a curve can adjust it vertically.

Fit fills most of the plot with the overlap. Fit/2×/4×/8× menu choices and anchored pinch zoom control
the time scale; a separate overview strip moves the view without changing either cue. A ruler
and source-time labels show the actual scale. Auto/1×/4×/16× height controls amplify the drawing
with an explicit display-gain label. Both lanes share the same display gain, frozen during a cue
drag, and silence stays silent. These controls never change audio volume or raw peak/RMS values.
Dimmed source samples are outside the playback interval; missing source data is left empty.

The pair workspace puts the outgoing track above the waveforms and incoming track below.
Move audio shifts each lane independently; touching any active automation line immediately
selects its editor and reveals its handles, without requiring the Edit curves tool first.
A zero-delay touch observer selects the line without blocking pan, tap, scroll or pinch gestures. Handles use the same time/gain geometry as the drawn engine curves. Dragging a
handle preserves its initial finger offset, keeps the other lane and both cues intact, and
commits one undoable edit on release; cancellation discards the transient edit. Tapping a lane
adds a point on its current curve; selecting an interior point allows removal. Fixed endpoint
levels and point-order limits still apply. Dragging a volume segment without a nearby handle
inserts a point on the actual curve before moving it. Touching yellow EQ selects its handover
handle, whose horizontal movement adjusts the real 200 Hz/-24 dB bass swap timing. Touching
pink selects a filter knee: horizontal movement adjusts its time, vertical movement its cutoff
on the same logarithmic frequency scale as the plot. Both source endpoints retain the filter's
original cutoff; exponential sweeps connect them through the edited knee. Optional saved knee
fields preserve old presets exactly when absent. Picking a named filter resets its knee edits.
All direct edits are transient until release and form one undo step. The play/stop row below the waveforms auditions the draft;
technical measurements and source ranges remain in an expandable analysis section.

Preview schedules bounded source segments on two decks with the same
transition DSP and current equalizer as playback. The incoming start uses the render clock.
The existing queue and seek position are retained; music pauses for the preview and resumes when
it finishes/stops. Backgrounding, interruptions and route changes stop preview without automatic
resumption; changing the queued song or resuming normal playback also stops preview.

Analysis buffers up to four seconds on either side of the overlap (at most 20 seconds per track)
off the main thread after a 250 ms debounce. Fine-grained bins retain detail while zooming. Cue
drags reuse the real buffered samples; zoom/height/view navigation do not start decoding. A cue
commit loads its new context. At most two screen columns per point are drawn as batched paths.
Cancellation stops obsolete work; an eight-window cache uses path, file size, mtime and resolution.
No continuous FFT, whole-library analysis, background animation, or full-track PCM allocation is
needed. Automatic beat/key analysis is not implemented.

CI checks album ordering, all-fields migration, provider positions, safe numbering plans, disc
tag round-trips, real PCM window measurements, opposite-phase channels, planner/automation parity,
bounded preview scheduling, zoom anchors, independent cue dragging, limits, undo and view gain.
On a phone, verify pinch zoom, both drag directions, lane locking, cancelled drags, vertical scroll,
preview sound, independent source formats,
headphone/route changes, Save/Cancel/Undo, rapid cue changes, unavailable files, large text, and
normal playback resumption. Device heat and touch feel still require a physical device.

## Compact pair workspace and preview cursor

Individual pairs now use one waveform workspace with compact track rows, a horizontally
scrolling preset strip, and Volume/EQ/Filter menus. The full-screen duplicate automation graph,
permanent duration card and in-page diagnostics are removed from this pair flow. Collection
and global editors retain their shared automation controls. Overlap duration opens a popover
with existing presets, a slider and exact requested milliseconds in 100 ms steps. EQ handover
has a popover with the actual swap time, 200 Hz shelf, -24 dB attenuation and ramp duration.

Selecting a volume handle opens a menu for precise time/gain editing, removal or deselection.
Numeric edits convert dB to linear amplitude, preserve fixed endpoints and neighbouring times,
and use one undo step. Silence is exactly zero; the dB field supports -96 through 0 dB.
Unchanged numeric edits do not convert a built-in curve to an approximated custom one.

Tools holds time zoom, waveform display height, overlay switches, precise source cues, and
Analysis & automation. The latter retains decoded sample rate/channels, raw source peak/RMS,
exact source windows and live automation target inspection during preview. Active bass shelf
curves show their actual linear gain; filter curves show target cutoff on a logarithmic
20–18000 Hz scale. These are explicitly control targets, not processed spectra or multi-band
waveforms. BPM remains a file tag. Unsupported beat/key/effect features are not offered as
working controls, and durations are seconds rather than unverified musical bars.

Off/Auto-with-no-default now shows actual end/start audio without inventing an overlap, trim,
volume fade, bass or filter automation. Its bounded preview schedules a real back-to-back cut
with both transition stages bypassed. Choosing a preset or a duration enables an actual fade.

The full-height green audition playhead is drawn as one explicit path through both waveforms.
Its playback control and current-time readout sit below the plot, keeping the curves unobstructed.
The cursor reads each AVAudioPlayerNode's rendered sample time; positive samples remain usable
on routes without a host-time flag. Zero without a host timestamp does not invent a start. Before the
incoming scheduled host time the outgoing deck supplies progress; afterward incoming samples
take over and continue through the tail even when the outgoing deck is released. The current
output-route latency is captured at preview start and subtracted for approximate audible sync.
No Date-based progress or timer starts audio. Missing render time leaves the cursor absent.
Stop, interruptions, backgrounding, route changes and edits retain the existing preview cleanup.

Only the thin playhead refreshes at 30 Hz while playing, with a separate 10 Hz readout; the
waveform Canvas and source decoding are not tied to those ticks. Closed diagnostics do no
periodic work. Fit includes the entire lead-in/overlap/tail, so the line is visible throughout;
zoomed views show an edge direction marker if playback leaves the visible interval.

CI covers no-clock/no-progress, deck handover, route latency, bounds, cut timing and bypassed
stages, render-clock availability/cleanup, full-preview fit, and exact dB/time point edits.
Verify audible alignment on wired, Bluetooth and speaker routes and touch feel on a device.

Tapping anywhere inside the pair plot activates Custom and reveals its curve handles, including
when Auto resolves to no crossfade or the pair is Off. It uses the same idempotent draft action
as the retained Custom button, starts from inherited settings, and preserves duration, EQ, filter
and source cues. Activation is one undo step; repeated activation does not resample an already
custom curve or add undo entries. A tap that first enters editing selects the lane without
inserting an arbitrary point. Vertical scrolling alone does not change the transition choice.
