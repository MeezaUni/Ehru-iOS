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
There is one live cover throughout the morph: no screenshot, second video or per-frame decode.
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
Cover Flow spacing leaves a visible previous/next preview at both edges. The nearest card
always draws in front: depth is computed from the interpolated presentation distance, so a
departing card cannot jump in front of the newly centered card. Stack mode gathers neighbours
only at rest. Expanded artwork geometry is not republished on every horizontal frame.

Playback opens up to two adjacent file headers at user-initiated priority off the main thread.
Each prepared AVAudioFile reader is consumed once and checked against file size/mtime, so decks
never share an active reader and replaced/deleted files cannot reuse stale data. Warming does not
predecode audio, change skip behavior, alter paused state, or replace the real audio engine clock.

A released swipe finishes its visual slide before invoking transport and lock-screen updates.
Audio continues during that slide. A generation guard cancels superseded skip requests; a
rejected switch settles back to the actual queue item. A two-entry repeat honours the requested
previous/next occurrence even when both neighbours refer to the same queue entry.

CI checks continuous page identities across forward/reverse/repeat changes, visible side previews
and interpolated depth order, cover-only geometry with stationary controls,
interrupted focus, implicit-layer-resize suppression, real-pixel frame freezing and cancellation,
same-asset session reuse, stale-host teardown, and bounded single-use file preparation/invalidation.
Device video compositing and frame pacing still require verification on an iPhone.
