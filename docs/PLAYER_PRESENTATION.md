# Cover-led player presentation

This branch uses static album artwork. Only the current cover scales and translates between
its expanded rectangle and the actual mini-player artwork rectangle. Controls, metadata,
lyrics, carousel neighbours and backdrop fade smoothly over the first 90 points of a downward
pull, revealing the library progressively. Beyond that fade only the cover travels. A cancelled
pull restores the stationary player; retouching its animation picks up both the displayed cover
position and opacity.
Opening uses a finite 400 ms curve, with the chrome joining through a smooth fade.
Reduce Motion uses a fade without flying the artwork.

Expanded artwork is measured with an untransformed placeholder in the named player coordinate
space. A persistent overlay outside the ScrollView and card projection paints the flying cover.
Measuring its transformed frame would feed motion back into layout and cause jitter. The mini
cover stays visible until a fresh source frame is ready, then hides until the flight completes.
Generation guards prevent interrupted completions from removing a reopened player.

## Finger tracking and card turnover

Stable page ordinals and entry-occurrence keys retain loaded artwork through selection changes.
The strip mounts two neighbours in each direction, retains departing cards through settlement,
and prunes back to a bounded scene afterward. At most seven occurrences survive interrupted
swipes. Playback-order helpers supply repeat-aware neighbours and preserve requested direction.

The card artwork and metadata are equatable, while transforms and distance shading update
separately during finger movement. Spread-mode layer order stays fixed through the drag and settlement. Side-by-side mode
uses projected card extents to maintain a visible gap and previews at both edges.

Stacked mode uses actual smaller, raised neighbouring covers behind the current card. Both
covers stay opaque during a mirrored perspective turn: the incoming cover rises from behind
on the chosen side while the outgoing cover turns away. Their projected edges separate before
layer order changes, preventing a final-frame swap. Titles stay attached to their covers.
The layer stack interpolates pose, shading and depth around prebuilt card contents. Reduce
Motion uses the simpler fade, without rotation.

A compositor meter records interpolated focus and stack values in the probe's animatable-data
setter on the visible layer stack. Target/layout evaluations never overwrite that sample. Interrupted touches therefore
pick up the displayed position. The probe does not publish view state or drive audio time.
Drag travel is bounded to one page plus limited edge resistance.

Buttons use a 280 ms cubic settlement in spread mode and 400 ms in depth mode. Finger release uses actual gesture velocity and remaining
travel to choose a bounded duration and initial curve slope. Generation-guarded monotonic tasks
perform cleanup without depending on render-completion callbacks; they do not drive frame
positions. Mode toggles retarget the same motion owner.

## Audio and static artwork

A released swipe commits the real queue immediately before settling. Audio, title, duration
and queue index refer to the same entry. Playback never waits for a visual completion.
Adjacent audio files are opened off the main thread, checked against size/mtime, primed with
at most 4096 PCM frames, rewound and consumed once. Priming discards its samples, leaving
scheduled playback at the requested source position.

Skips do not reactivate an already-running audio session. Playing skips prepare the idle deck
while the outgoing deck is still sounding, with a 20 ms handoff scheduled on the render clock.
Paused skips stay paused and reuse an appropriately connected deck. Album-history writes run on
a background queue. Duplicate MediaPlayer publications coalesce; in-app visual motion may defer
them for at most 350 ms. Resigning active flushes metadata immediately for Lock Screen transport.

Embedded artwork can paint a cached size on its first frame, then refine to the requested
resolution. Adjacent covers are warmed at 600 px; current artwork refines to 1200 px. The
Lock Screen receives ordinary MPMediaItemArtwork. This branch has no animated-cover store,
video surfaces, movie snapshots, decorative animation timer or animated artwork provider.

## Validation

CI builds an unsigned IPA and runs the retained native tests, including scene identity,
projected spacing, rendered previews, directional depth turnover, velocity-aware settlement,
interrupted gestures, cover-only dismissal, live-window interpolation, cached first-frame
artwork and bounded audio-file preparation. Transition editor and playback tests are retained.
Physical-device touch feel, frame pacing and thermal behavior still need verification on an iPhone.
