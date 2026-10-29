# Cover-led player presentation

The expanded foreground scales and translates around the actual current artwork rectangle to
the mini-player artwork rectangle. Both expanded and compact navigation layouts supply the
real destination frame. Drag progress follows the finger; opening, dismissal and a cancelled
pull settle with the same geometry. The backdrop fades separately, and header, controls,
neighbours and card metadata fade before the cover reaches the bar. The mini artwork becomes
visible when the expanded presentation finishes. The expanded view stays mounted until the
animation completion, so dismissal cannot strand a header at the bottom.

Expanded artwork is measured in a named coordinate space inside the foreground transform.
Measuring its transformed frame would feed motion back into the next frame and cause jitter.
Each opening waits for a fresh measured source frame, with the mini cover visible until ready.
A generation token prevents an interrupted animation completion from removing a reopened player.
There is one live cover throughout the morph: no screenshot, second video or per-frame decode.
Existing decorative-motion suspension remains in effect. Lightweight modifiers observe progress;
the library, waveform seek position and carousel layout do not drive the presentation animation.
Reduce Motion uses a fade without scaling the player.

CI checks destination geometry for both chrome layouts, interpolation, invalid/empty frames,
cancelled pulls and interrupted opening/dismissal state. Verify touch feel, rapid open/close,
header and cover pulls, rotation, text sizes and animated covers on a device. These checks do
not establish a device frame-rate or thermal measurement.
