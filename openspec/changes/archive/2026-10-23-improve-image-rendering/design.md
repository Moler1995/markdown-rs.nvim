# Design

## Context

See `proposal.md` — Why. The current pipeline is `resolve → load → cell_grid → sample (box filter on
sRGB bytes) → nearest of 64 fixed colours → encode`, with a 128 alpha threshold and no dithering
(`engine/src/image_art.rs`). Styles reach the plugin as hex colours and become one Neovim highlight
group per distinct style, cached for the session; the module notes that 5,000 new groups cost
913 ms, which is why the colour work below is bounded rather than free-form.

Constraints that shape the approach:

- The engine's determinism guarantee (byte-identical output for the same input, width, theme and
  encoding) extends to every new algorithm; no randomness, no hash-order iteration.
- A cell has at most two colours in every encoding, so resolution and colour fidelity are
  independent levers.
- The braille glyph range is present in Cascadia Mono and Segoe UI Symbol on this machine and
  `strdisplaywidth` reports 1 column for every code point in U+2800–U+28FF. The sextant and octant
  ranges (U+1FB00, U+1CD00) are absent from all 359 installed fonts, so they stay out of scope.

## Goals / Non-Goals

**Goals:**

- Make braille the default when the editor supports colour, with `quads` and the other encodings
  still selectable and unchanged.
- Remove the three largest sources of error in the existing pipeline: sRGB averaging, alpha
  thresholding, and a palette that ignores the image.
- Keep the style count bounded and the render deterministic.
- Keep the cost of a full-page image in the same order of magnitude as today.

**Non-Goals:**

- Terminal graphics protocols (Kitty, Sixel, iTerm2). They bypass buffer text and conflict with the
  reading view's line model.
- New fonts or font configuration; sextant/octant encodings.
- Per-document colour-profile handling (ICC) or HDR.
- Changing the preview popup's geometry, the animation path or the wire format.

## Decisions

### D1 — Braille geometry and sampling

The braille encoding uses a 2×4 sub-cell grid, so its sub-cells are square in both source and
display space: a cell covers one source pixel across and two down at natural size, and a braille
dot covers half a pixel each way. Sampling supersamples the source at 2× horizontally and 2×
vertically relative to the natural grid, and every sub-cell is an area average of the pixels under
it.

*Alternatives:* octants (2×4, two colours) would give the same geometry with two colours per cell,
but no installed font covers them, so the artwork would be tofu. Braille was chosen because it is
the only 2×4 grid that renders everywhere today.

### D2 — How a braille dot is decided

A dot is lit when its sub-cell lies away from the page the artwork is drawn on — lighter than a
dark page, darker than a light page — with an ordered dither offset moving the threshold from the
page towards the far end of the range. Distance is per channel (the largest channel difference), so
a saturated red or blue stays visible on a dark page where its luminance alone would drop it into
the page. The cell's single colour is the average of the lit sub-cells.

*Alternatives:* a luminance threshold against the cell's own average (the first cut) lights about
half the dots of every cell that has any contrast, which is a uniform texture rather than a
picture; on a dark page it inks only the shadows, so a white screenshot of a document rendered as
almost nothing and the manual review in 7.3 rejected it. A fixed threshold of 128 has the same
polarity problem for one of the two kinds of terminal. The page comes from the resolved
`image_background` when the caller named one; otherwise the plugin reports the editor's `Normal`
background, which is the only place that colour is known. A transparent sub-cell is never lit.

*Trade-off:* dark regions of a photograph become the page on a dark terminal, and a text screenshot
at a normal window width is below the resolution of the dot grid — braille cannot make it legible.
Both are properties of one bit per dot, not of the decision rule.

### D3 — Linear-light area average

Every source pixel is converted once through a 256-entry sRGB→linear lookup, summed in linear
light, divided, and converted back to sRGB per sample. The inverse conversion is a `powf` on the
sample value; samples number in the thousands, not the millions, so no inverse LUT is needed.

*Alternatives:* averaging in sRGB (today) darkens gradients and edges. A full float pipeline
without a LUT costs a `powf` per source pixel and was rejected for the 16 MP worst case.

### D4 — Alpha handling

Alpha is averaged alongside the colour, and the colour average is alpha-weighted, so transparent
pixels do not pull a cell's colour toward black. Then:

- `terminal` (default): no compositing; a cell whose averaged alpha is below the existing 128
  threshold is still left to the terminal, exactly as today.
- a named background (theme or `#rrggbb`): the averaged colour is composited against it with the
  averaged alpha, and the cell is opaque. This is what removes halos around logos and restores
  drop shadows.

*Alternatives:* always compositing would require knowing the terminal's background, which the
engine does not. Thresholding every pixel (today) leaves hard edges wherever alpha crosses 128.

### D5 — Adaptive palette by median cut in CIELAB

The palette is built from the downscaled samples: stride to at most 4,096 samples, convert to
CIELAB, split the box with the largest weighted extent along its widest channel until there are 64
boxes, and take each box's weighted mean, converted back to sRGB. Ties are broken by box index, so
the result is deterministic. The same nearest-colour search (64 entries, CIELAB) then serves every
sample as it does today, so the per-cell cost is unchanged.

*Alternatives:* k-means (better on some photographs, but slower and sensitive to initialisation),
octree quantisation (coarser on gradients, and its split order is less stable), the fixed cube
(today's mode, kept as `theme`).

### D6 — Full colour and the style bound

`full` emits the sampled colour without quantisation. Because every distinct fg/bg pair becomes a
highlight group in the plugin, the engine counts distinct image styles per document and stops at
4,096: once the bound is reached, subsequent samples are quantised to the image's adaptive palette
instead. Colours already emitted are never changed, and the document stays deterministic because
the cap is reached in document order.

The cap is enforced in the style table, so it covers text styles only insofar as they share the
table; image styles are counted separately.

*Alternatives:* no cap (a full-page photograph can produce thousands of groups and spend hundreds
of milliseconds in `nvim_set_hl`); a much larger cap (4096 already matches the worst case the
existing palette can produce, so the plugin's cost profile does not change).

### D7 — Ordered dithering

A Bayer 4×4 matrix is indexed by sample coordinates. For palette quantisation the sample is offset
by up to half a palette step before the nearest-colour search; for braille it offsets the
comparison against the cell average. Both offsets are deterministic and depend only on position.

In `auto`, dithering is on for braille (the dot decision always has a threshold) and for ASCII when
the palette is reduced; it is off for half-block and quadrant, where a two-colour cell would
speckle, and off for the full palette, where there is no quantisation to dither.

### D8 — Enlargement and sharpening

`image_min_rows` enlarges by the smallest whole factor (2, 3 or 4) that reaches the requested row
count, using nearest-neighbour sampling, and never beyond the page bounds. `image_sharpen` applies
a fixed 3×3 unsharp mask after the area average and before quantisation, only when the image was
reduced.

*Alternatives:* bilinear enlargement (blurs pixel art, which is the main case for enlargement);
sharpening always on (changes the look of every downscaled photograph).

### D9 — Options, flags and cache key

The engine gains `--image-palette`, `--image-background`, `--image-dither`, `--image-min-rows`,
`--image-sharpen` and `--image-paper`, and `--image-encoding` gains `braille`. The plugin adds the
five user-facing options to `config.defaults` and passes them from the one argument builder used by
both the inline render and the preview popup; `--image-paper` is not a user option but the page
`Normal`'s background supplies when `image_background` is `terminal`. Everything the builder sends
joins the render cache key in `state.lua`, since each changes the artwork — a colourscheme change
therefore re-renders, which is what keeps braille inked the right way round.

`image_mode = 'auto'` resolves to `braille` with `'termguicolors'` and `ascii` without.
`image_palette = 'auto'` resolves to `full` for braille/ASCII and `adaptive` otherwise.

## Risks / Trade-offs

- **The default output changes for every image** → Called out in the README; `image_mode = 'quads'`
  and `image_palette = 'theme'` restore the previous look, and the change is a single commit that
  can be reverted.
- **Braille is monochrome per cell** → It is a dot-density reproduction, not a colour photograph;
  the full palette still colours each cell, and `quads` remains one option away. The proposal
  accepts this trade for 8× the sub-cell resolution.
- **Full palette can explode the highlight-group count** → The 4,096-style cap, plus the existing
  session cache in `style.lua`; a headless test counts groups for a large image.
- **Median cut adds work per image** → Bounded by the 4,096-sample stride; measured against the
  existing 500 ms target for an animated render.
- **Dithering looks like noise on flat areas** → Off by default for the two-colour encodings, and
  the amplitude is half a palette step, not full-scale.
- **Linear-light averaging changes every colour slightly** → Intended; the existing golden tests
  will need regenerated expectations for images, which the task list calls out.

## Migration Plan

1. Engine first, with the new flags defaulting to today's behaviour where they can (`theme` palette,
   `terminal` background, dithering off, no enlargement, no sharpening), so the plugin is not
   affected until it starts passing flags.
2. Plugin options and defaults, including the `auto` resolution; the cache key gains the new values
   so stale renders cannot survive.
3. README and format docs updated with the new defaults and how to restore the previous output.
4. Rollback: set `image_mode = 'quads'`, `image_palette = 'theme'`, `image_dither = false`,
   `image_min_rows = 0`, `image_sharpen = false`; the engine's own defaults are already those, so
   an older plugin against the new binary keeps the old look.
