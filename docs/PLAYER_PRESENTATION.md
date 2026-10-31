# Cover-led player presentation

Only the current artwork scales and translates from its expanded rectangle to the mini-player
artwork rectangle. The header, controls and lyrics stay in place and fade; they never shrink
or travel with the cover. Both expanded and compact navigation layouts supply the
real destination frame. Drag progress follows the finger; opening, dismissal and a cancelled
pull settle with the same geometry. The stationary backdrop, header, controls,
neighbours and metadata fade with a smoothstep over the first 90 points of a downward pull.
The library is revealed progressively, rather than appearing on the first touch; beyond that
short fade only the cover travels. A cancelled or interrupted pull picks up both the displayed
cover position and chrome opacity. The mini artwork becomes
visible when the expanded presentation finishes. The expanded view stays mounted until the
animation completion, so dismissal cannot strand a header at the bottom.

Expanded artwork is measured using an untransformed placeholder in a named player coordinate
space. The painted cover is an overlay with its own local-to-destination transform.
Measuring its transformed frame would feed motion back into the next frame and cause jitter.
Each opening waits for a fresh measured source frame, with the mini cover visible until ready.
A generation token prevents an interrupted animation completion from removing a reopened player.
The flight is a persistent overlay above the ScrollView, with discrete visibility and an
animated progress transform. The inline cover hides only while the overlay owns presentation.
The overlay is already mounted before opening starts, so it can interpolate from the mini frame
instead of appearing at its final size. It is outside both scroll clipping and card projection.
There is no second video decoder or per-frame image decode.
Existing decorative-motion suspension remains in effect. Lightweight modifiers observe progress;
the library, waveform seek position and carousel layout do not drive the presentation animation.
Reduce Motion uses a fade without flying the artwork.

CI checks destination geometry for both chrome layouts, interpolation, invalid/empty frames,
cancelled pulls and interrupted opening/dismissal state. Verify touch feel, rapid open/close,
header and cover pulls, rotation, text sizes and animated covers on a device. These checks do
not establish a device frame-rate or thermal measurement.

## Animated covers and interrupted swipes

Motion video lives in an ordinary UIKit container with an AVPlayerLayer sublayer; layout disables
implicit layer resizing. Gesture start pauses the existing decoder. Its native paused layer follows
the cover transform, without copying pixels, constructing a bitmap, or fading into a first-frame
poster. The mini-player, flight overlay and current card reparent that same surface. Player item,
readiness, frame and layer identity survive each handoff; stale host teardown cannot detach or
pause a newly rebound host. A transient readiness change never exposes the poster after a real
frame has been presented. Static fallback remains available for initial loading, Low Power Mode,
thermal restrictions, Reduce Motion and missing/disabled artwork.

The carousel keeps up to three occurrence-owned sessions: current and two paused, prerolled
neighbours. The approaching cover resumes before it reaches centre. Departing neighbours are
recycled when the next card uses the same album, without reopening its video. Closing releases
neighbours and keeps the current movie for the mini-player. Reopening adopts that same movie
before entrance completes, even when its previous coordinate is now a repeat neighbour.
Cold native decoder construction waits until after presentation and active card motion.

The album header retains its own mounted video when covered by the player, scrolled away, or
backgrounded. These visibility changes pause it; revealing the album resumes the same frame.
Decorative video is independent of whether music is playing. Power/accessibility restrictions
may remove the video layer and show the static cover instead.

The strip uses stable page ordinals and entry-occurrence keys instead of rebasing by a page on
a later main-loop turn. Shared cards keep their loaded artwork and identity when the queue moves.
Departing cards are retained through settlement and then pruned, with at most seven nearby
occurrences even during repeatedly interrupted swipes. A compositor meter lets a rapid
new touch pick up the visible interpolated position. Generation tokens discard stale completions.
Cover Flow spacing leaves a previous/next preview at both edges. The depth deck uses real
opaque neighbouring covers and a mirrored perspective turn. The incoming cover rises from
behind while the outgoing cover turns away; their projected edges clear before layer order
changes. The animatable layer stack updates pose, shading and depth together, retaining the
same card/video hosts. Its passive interpolation sample supports retouch without publishing
state from rendering. Card contents are built outside that per-frame layer stack. Reduce Motion
uses the simpler fade. Expanded artwork geometry is not republished on every horizontal frame.

Playback opens up to two adjacent file headers at user-initiated priority off the main thread.
Each prepared AVAudioFile reader is consumed once and checked against file size/mtime, so decks
never share an active reader and replaced/deleted files cannot reuse stale data. Warming does not
predecode audio, change skip behavior, alter paused state, or replace the real audio engine clock.

A released swipe commits the real queue immediately, then settles on that returned selection.
Title, queue index, duration and audio refer to the same entry; playback never waits for the
animation completion. Generation guards cancel stale visual completions. Drag travel is bounded
to one available page plus a small, asymptotically limited edge resistance, so a long drag cannot
leave every card outside the screen. Two-entry repeat honours the requested direction.

Skips do not reactivate an already-running audio session. The idle audio deck is prepared while
the outgoing deck is still sounding, with a 20 ms linear handoff scheduled on the render clock.
The old deck fades to silence before being released. Paused skips remain paused. Album-history
writes happen on the database's background queue; duplicate MediaPlayer publications coalesce.
In-app visual motion defers those publications for at most 350 ms, with immediate publication
when the app resigns active and no animation delay for lock-screen transport.

Embedded artwork can paint a cached size on its first frame before its task runs, then refine to
the requested resolution. Adjacent covers are warmed at 600 px for Now Playing fallback. Animated
lock-screen assets keep a bounded four-source cache keyed by path/size/mtime, retaining immutable
file leases and preview frames. Returning to a cached album needs no video-frame extraction;
replaced downloads invalidate the cache and get a new artwork identity.

CI checks continuous page identities across forward/reverse/repeat changes, visible side previews
and interpolated depth order, cover-only geometry with stationary controls,
rendered preview visibility and cursor height, artwork escaping a clipped viewport, first-frame
cache painting, interrupted focus, implicit-layer-resize suppression, mounted-frame retention through occlusion, Low Power Mode
fallback, mini-to-carousel reuse, same-asset session reuse, stale-host teardown, and bounded single-use file preparation/invalidation.
Device video compositing and frame pacing still require verification on an iPhone.

## Finite motion and decoder lifetime

CarouselMotion owns one finite animation for position and layout: 280 ms for spread mode and
400 ms for depth mode, shortened according to remaining travel and release velocity. A stacked
drag retains its depth layout. The rear preview is actual neighbouring artwork, and the cards
keep their titles while exchanging positions. Mid-slide retouch reads both presented values;
gesture direction comes from finger travel, independently of the previous destination.
Generation guards prevent an interrupted completion from pruning the active scene or clearing
its movement flag. Mode toggles retarget the same motion owner.

Opening uses a finite 400 ms cubic curve; dismissal duration follows its remaining travel and
finger velocity. Generation-guarded monotonic tasks release chrome/input and prune settled pages
at the declared duration, independently of SwiftUI render-completion callbacks. They do not drive
frame positions or the audio playhead. This prevents an offscreen or interrupted render transaction
from leaving the player busy. Native video resources are lazy: constructing a SwiftUI cover does
not construct a decoder, and non-animated covers never create a native player.

CI hosts the actual motion state in a UIWindow and checks intermediate frames, prompt completion,
mode changes, interrupted gestures and reopening. It also verifies lazy native allocation and
Custom activation from inherited/off settings, including undo and preservation of EQ/filter/cues.
These checks do not establish a physical-device frame rate.

The strip mounts two neighbours in each direction, so a second quick swipe reuses an already
positioned cover instead of inserting a new card directly at its destination mid-animation.
Playback-order helpers supply these neighbours, including repeat wraparound. Retention remains
bounded to seven occurrences; side covers request 600 px and the current cover refines to 1200 px.

The passive presentation sample is recorded in the visible layer stack's animatable-data setter, which
receives interpolated values. Target/layout calls to effectValue do not overwrite it. The collapse
opacity has a separate passive sample so a retouch during restoration does not jump its fade.
