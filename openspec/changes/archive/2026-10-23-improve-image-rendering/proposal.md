# Proposal

## Why

Image artwork currently throws away most of what the source image carries. Every sample is averaged
in sRGB bytes, so gradients and edges darken; transparency is thresholded at 128 and never blended,
so logos carry hard halos and shadows vanish; and every image is quantised to the same 4×4×4 colour
cube, so a sunset collapses onto two or three oranges. The encoding itself tops out at two colours
per cell, and the default `quads` grid is 2×2 — coarser vertically than the cell's own 1:2 geometry
allows.

The braille encoding is the one high-resolution grid available without a font change: U+2800–U+28FF
is present in every monospace font on this machine, gives a 2×4 square sub-cell grid, and needs one
ink colour per cell. What is missing is a colour pipeline good enough to feed it, and a default that
uses it.

## What Changes

- **Braille encoding**. A fourth encoding, `braille`, drawing each cell as U+2800 + bits: 2×4 square
  sub-cells, one foreground colour for the lit dots, the terminal background for the rest. It
  becomes what `auto` selects when `'termguicolors'` is on; `quads`, `blocks`, `ascii` and `off`
  remain selectable, and `quads` is unchanged in output.
- **Linear-light downsampling**. The area average is taken in linear light rather than on sRGB
  bytes, so downscaled photographs keep their brightness and edges keep their contrast.
- **Alpha compositing**. Source alpha is averaged with the colour and composited against a
  configurable background — the terminal's (today's behaviour), the theme's, or a hex colour —
  instead of being thresholded at 128. Semi-transparent pixels blend; fully transparent ones still
  leave the cell to the terminal.
- **Adaptive palettes**. Colours are quantised to a palette cut from the image itself (median cut
  in CIELAB), not to one fixed cube for every image and document. The palette has the same size
  bound as today, so the style count stays bounded.
- **A true-colour mode**. `image_palette = 'full'` emits the averaged colour exactly, subject to a
  per-document cap on distinct image styles; past the cap, colours snap to the adaptive palette.
- **Ordered dithering**. Bayer 4×4 offsets applied to quantisation and to the braille threshold, so
  a reduced palette produces gradients rather than bands. On by default where it helps (braille,
  ASCII, adaptive palettes) and off where it would speckle two-colour cells (`quads`, `blocks`,
  `full`).
- **Small-image enlargement and sharpening**. `image_min_rows` lets an image whose natural height is
  below a threshold be enlarged by an integer nearest-neighbour factor; `image_sharpen` applies an
  unsharp mask after a downscale. Both are off by default, preserving "never larger than natural".
- **New options**, documented in `README.md` and `config.lua`: `image_palette`, `image_background`,
  `image_dither`, `image_min_rows`, `image_sharpen`, plus the new `braille` value of `image_mode`.
- The wire format, the cache key, the page bounds, the animation work and the preview popup are
  unchanged. The preview popup inherits the same encoding and palette options because it renders
  through the engine.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `nvim/render-engine`: the encoding requirement gains `braille` and changes its default; the
  palette requirement is inverted from "one fixed palette, never per image" to adaptive and
  true-colour palettes with a cap; the scaling requirement gains linear-light averaging, alpha
  compositing against a configured background, dithering, and optional enlargement and sharpening.
- `nvim/render-mode`: `image_mode` gains `braille` and `auto` resolves to it; the plugin gains
  `image_palette`, `image_background`, `image_dither`, `image_min_rows` and `image_sharpen`, passed
  with every render and included in the render cache key.

## Impact

- `engine/src/image_art.rs`: the sample, quantise and encode pipeline; a new braille encoder; a
  median-cut palette builder; Bayer tables; an alpha/beta compositing path.
- `engine/src/main.rs`: five new flags, one new encoding value.
- `engine/src/wire.rs`: no structural change; a per-document image-style counter for the cap.
- `lua/md-render/config.lua`, `lua/md-render/engine.lua`, `lua/md-render/state.lua`: new options,
  their defaults, the arguments they produce, and the cache key they join.
- `lua/md-render/preview.lua`: no code change expected; the popup picks the options up through the
  shared argument builder.
- `README.md`, `docs/md-render-format.md` (if the encoding list is stated there), tests.
- Default output changes for every image (braille, adaptive palette), so the change is
  user-visible and should be called out in the README.
