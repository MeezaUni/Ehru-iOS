# Cover-led player presentation

Only the current artwork scales and translates from its expanded rectangle to the mini-player
artwork rectangle. The header, controls and lyrics stay in place and fade; they never shrink
or travel with the cover. Both expanded and compact navigation layouts supply the
real destination frame. Drag progress follows the finger; opening, dismissal and a cancelled
pull settle with the same geometry. The backdrop fades separately, and header, controls,
neighbours and card metadata fade before the cover reaches the bar. The mini artwork becomes
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
implicit layer resizing. Gesture start pauses the current decoder and copies its current decoded
pixel buffer once, converting a bounded image off the main thread. That flat frozen frame follows
the same cover transform as static artwork, and the video surface fades into the poster used by
the mini-player. Animated-video posters bypass the separate still-art drift/zoom, so their final
crop matches the mini-player exactly. If a decoded buffer is not ready, the paused native frame remains as fallback.
There is no continuous snapshot polling, second video decode, or screen-sized rendering capture.
Cancelled motion restores the existing layer; obsolete snapshot callbacks are ignored.
The session owns the actual video surface, not just the AVQueuePlayer. Lightweight native hosts
reparent that same surface between inline artwork and the root overlay. Readiness, frozen pixels
and AVPlayerLayer identity survive the handoff; stale host teardown cannot detach the new host.

The carousel owns one motion session. An adjacent song from the same album rebinds that session
without recreating its looper or resetting its position. The moving scene retains its original
video host until settlement, and enables the newly current video's host after the slide finishes.
Old-surface teardown checks ownership and cannot pause a newly rebound host. Background, Reduce
Motion, offscreen, low-power and thermal restrictions retain their existing behavior.

The strip uses stable page ordinals and entry-occurrence keys instead of rebasing by a page on
a later main-loop turn. Shared cards keep their loaded artwork and identity when the queue moves.
Departing cards are retained through settlement and then pruned, with at most seven nearby
occurrences even during repeatedly interrupted swipes. A compositor meter lets a rapid
new touch pick up the visible interpolated position. Generation tokens discard stale completions.
Cover Flow spacing leaves a visible previous/next preview at both edges. Z-index is a direct trait on each ZStack child, outside its transform. Finger movement chooses
the nearest card while dragging; a released slide keeps the destination in front. The compositor
probe only records position and stack amount for an interrupted gesture. It never publishes
view state from rendering or interrupts the native animation with a midpoint callback. Stack mode gathers neighbours
only at rest. Expanded artwork geometry is not republished on every horizontal frame.

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
cache painting, interrupted focus, implicit-layer-resize suppression, real-pixel frame freezing and cancellation,
same-asset session reuse, stale-host teardown, and bounded single-use file preparation/invalidation.
Device video compositing and frame pacing still require verification on an iPhone.

## Finite motion and decoder lifetime

CarouselMotion owns one 280 ms cubic animation for both position and stack layout. A stacked
drag unfolds in proportion to the finger; it never switches layouts instantly at touch-down.
Release restores the chosen layout within that same animation. Stacked neighbours are smaller
and slightly raised behind the current card. Mid-slide retouch reads both presented values;
gesture direction comes from finger travel, independently of the previous slide's destination.
Generation guards prevent an interrupted completion from pruning the active scene or clearing
its movement flag. Mode toggles retarget the same motion owner.

Opening/dismissal uses a finite 300 ms cubic curve and logical completion, so chrome and input
are released without waiting for a spring's physical settling tail. The playback controller owns
one lazy MotionVideoSession. Constructing or reconstructing a SwiftUI view does not create an
AVQueuePlayer or AVPlayerLayer. Close/background pauses the existing session and re-opening the
same album reuses it. A cold animated asset is attached after entrance finishes; already-ready
video can accompany the cover flight. Non-animated covers never create a native video player.

CI hosts the actual motion state in a UIWindow and checks intermediate frames, prompt completion,
mode changes, interrupted gestures and reopening. It also verifies lazy native allocation and
Custom activation from inherited/off settings, including undo and preservation of EQ/filter/cues.
These checks do not establish a physical-device frame rate.

The strip mounts two neighbours in each direction, so a second quick swipe reuses an already
positioned cover instead of inserting a new card directly at its destination mid-animation.
Playback-order helpers supply these neighbours, including repeat wraparound. Retention remains
bounded to seven occurrences; side covers request 600 px and the current cover refines to 1200 px.
