# Design

## Context

See `proposal.md` — Why. The current collector in `engine/src/image_art.rs` walks the decoder's
frame iterator, draws each frame, and stops with `TooLarge` as soon as the frame count passes 256
or the cumulative pixel count passes 64 MP. Both refusals are all-or-nothing: the collected frames
are discarded and the document carries `animations_limited` for the reference. The frame iterator
streams, so the total frame count is not known before the last frame is decoded.

Constraints that shape the approach:

- Peak memory is one decoded frame: frames are sampled and encoded to lines as they arrive.
- Rendering is deterministic; the engine's output must be byte-identical for the same input and
  bounds, on every run.
- The plugin's wire contract needs no new field: it steps over whatever frames the document
  carries, and `animations_limited` already distinguishes a refusal from a still image.

## Goals / Non-Goals

**Goals:**

- An animation that only exceeds the frame count still animates, with a bounded payload.
- The bounds still cap decode work, so a resize-triggered re-render cannot be made arbitrarily
  expensive by one file.
- The loop's duration is preserved when frames are dropped.

**Non-Goals:**

- Making arbitrarily large animations play. The decoded-pixel budget and the decoded-frame ceiling
  still refuse them.
- Changing playback timing rules in the popup, the wire format, or `animations_limited`'s meaning
  beyond what the spec delta states.
- A user-facing option for the frame budget. The values are engine constants until a real case
  argues otherwise.

## Decisions

### D1 — Streaming downsample instead of a second pass

The collector keeps every frame while the buffer is within the 256-frame budget. When a 257th
frame would enter, it halves the buffer by dropping every second kept frame and doubling the
keep stride; from then on it keeps every stride-th decoded frame. Dropped frames' delays are added
to the kept frame that precedes them, including a trailing carry on the last kept frame. The
subset therefore starts at the image's first frame, stays in file order, never exceeds 256 entries,
and its delays sum to the original total.

*Alternatives:* decoding twice, once to count and once to sample (doubles decode CPU, the exact
cost the bounds exist to cap); reservoir sampling with randomness (breaks the determinism
guarantee); buffering every frame before choosing a stride (breaks the one-frame peak-memory
guarantee and can hold thousands of encoded line sets). Halving on overflow is deterministic and
needs no knowledge of the final count.

*Trade-off:* the kept set is evenly spaced only within each stride epoch, so a 257-frame animation
keeps about 129 frames rather than exactly 256. That is still a smooth animation and a bounded
payload; the alternative would require knowing the count in advance.

### D2 — Two hard bounds: decoded pixels and decoded frames

Sampling bounds the payload, not the work: a GIF's later frames are decoded as deltas, so every
frame must still be decoded to reach the ones that are kept. The cumulative pixel budget stays as
the bound on large-frame animations, raised from 64 to 128 MP because a real 640 × 360 GIF of 533
frames (122.8 MP, about 3.5 seconds to decode) was refused at 64 MP although sampling could carry
it. A decoded-frame ceiling of 4,096 covers the hole it leaves for tiny frames — 100,000 two-by-two
frames cost 400,000 pixels and would otherwise be decoded in full.

*Alternatives:* only the pixel budget (unbounded frame count for tiny images); a wall-clock budget
(non-deterministic); deriving the ceiling from the kept budget (256 would refuse the very
animations this change exists to admit).

### D3 — Delay folding

A kept frame's delay is its own delay plus the delays of the frames it stands for. The loop's total
duration is therefore unchanged; the popup's existing floor for sub-20 ms delays is unaffected,
because folded delays only get longer.

*Alternatives:* keeping each frame's recorded delay and accepting a faster loop (changes what the
image looks like); scaling delays proportionally at the end (needs the omitted frames' delays,
which the streaming pass has already dropped).

### D4 — No wire or plugin change

The subset is emitted through the existing `animations` entry: the same `start`, `rows` and
per-frame `delay` and `lines`. Frame indices are the subset's indices, so the plugin's stepping and
looping code is unchanged. A sampled animation is not listed in `animations_limited`; only the
two hard bounds refuse.

*Alternatives:* a `sampled` flag or a stride on the wire (no reader behavior would change); moving
the sampling into the plugin (the plugin does not have the pixels or the delays).

### D5 — Fixtures

`image_257.gif` currently exists to exercise the refusal. It now animates, so the refusal test
moves to a 4,097-frame fixture, which exceeds the decoded-frame ceiling while staying a few
hundred kilobytes. A 513-frame fixture with distinct delays exercises sampling and delay folding;
`image_256.gif` keeps the inclusive-budget case. Fixtures are generated with Pillow and checked
in, as the existing ones are.

## Risks / Trade-offs

- **A 257-frame animation loses about half its frames** → It animates instead of being refused. If
  a specific animation looks choppy, its creator can reduce the source frame count; the alternative
  is showing one frame with a warning.
- **A long animation still costs its full decode on every resize** → The pixel budget and the
  4,096-frame ceiling bound that cost. Measure the worst allowed case (4,096 tiny frames) before
  accepting the ceiling; it is a constant, so lowering it is a one-line change.
- **Folded delays make some frames sit still for a long time** → Only for animations whose frames
  are far over the budget; total duration is what the reader perceives, and playing every frame is
  impossible at that count anyway.
- **Sampling must not depend on a clock or hash order** → The schedule is a function of decode
  order and frame count only; a determinism test renders the same fixture twice.

## Migration Plan

1. Engine: add the kept-frame budget and the decoded-frame ceiling, replace the frame-count refusal
   with sampling, and keep `animation_within_bounds` as the hard-bound check.
2. Fixtures: generate `image_4097.gif` and `image_513.gif`; repoint `too-large-animation.md`.
3. Documentation: `docs/md-render-format.md` and `README.md` describe sampling, the two limits and
   what a refusal still means.
4. Rollback: reverting the engine change restores the old refusal; no wire or plugin change is
   involved, so an older plugin and a newer engine remain compatible in both directions.
