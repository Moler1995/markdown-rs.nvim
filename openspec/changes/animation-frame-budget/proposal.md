# Proposal

## Why

The animation caps treat a frame count of 257 as all-or-nothing: the whole animation is discarded,
the reader loses `<C-n>`, `<Space>` and playback, and the plugin reports "too large to animate" —
even for a 2×2-pixel, 10 KB file that costs almost nothing to decode. The single count conflates
three unrelated costs (wire size, decode CPU and style budget), so it refuses animations that are
cheap and does not proportionally protect against the ones that are expensive.

## What Changes

- Replace the frame-count refusal with a **kept-frame budget**: an animation of at most 256 frames
  is carried unchanged; one with more is reduced to an evenly spaced subset anchored at the first
  frame, with the delays of skipped frames folded into the frame before them so the loop's total
  duration is preserved.
- Keep the cumulative decoded-pixel budget as a hard refusal, because GIF and WebP frames are
  decoded as deltas and sampling cannot reduce decode work, but raise it from 64 to 128
  megapixels: a real 640 × 360 GIF of 533 frames (122.8 MP) was refused at 64 MP even though frame
  sampling could carry it, and its first step costs about 3.5 seconds.
- Add a **decoded-frame ceiling** (4,096 frames) as a hard refusal, so sampling cannot turn a
  pathological many-tiny-frames file into unbounded decode work.
- A refused animation stays distinguishable on the wire (`animations_limited`); a sampled one is
  not refused and carries no warning.
- Update the format documentation, README and animation fixtures; the 257-frame fixture now
  animates, and new fixtures cover sampling and the decoded-frame ceiling.
- No wire-format change, no plugin Lua change: the plugin already renders whatever frames it is
  given.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `nvim/render-engine`: "Animation frames on request" — how many frames are carried, how an
  over-budget frame count is reduced rather than refused, and which bounds still refuse an
  animation outright.

## Impact

- `engine/src/image_art.rs`: `collect_animation`, the frame constants, and the public
  `animation_within_bounds` check.
- `engine/src/document.rs` and `engine/src/image_art.rs` tests, plus new GIF fixtures under
  `engine/tests/fixtures/images/`.
- `tests/fixtures/too-large-animation.md` must point at an animation that is genuinely refused
  under the new bounds, so the headless refusal checks keep testing refusal.
- `docs/md-render-format.md` and `README.md` animation sections.
- Not affected: the wire format, the plugin's Lua modules, the preview popup, and the frame-step
  key's behavior for animations the engine still refuses.
