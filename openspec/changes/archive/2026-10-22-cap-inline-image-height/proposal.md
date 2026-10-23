# Proposal

## Why

Inline images are drawn as large as the window allows: the width bound is the window's text width
and the height bound is its text height, so any picture wider than the window fills 100% of the
text column. In a reading view that makes a single figure dominate the page, and there is no option
to make it smaller — the reader can only shrink the whole window. A cap on the artwork's height
scales the picture (both axes, keeping the aspect ratio) without touching the document's width.

## What Changes

- Add an `image_max_height` option: the most display rows an inline image may occupy, defaulting
  to `20`. `false` restores the previous behaviour (bounded only by the window's text height).
- The inline render passes `min(window text height, image_max_height)` to the engine as
  `--image-max-height`. Because the engine scales both axes by one factor, capping the height also
  narrows the artwork; a 640×360 image in a 126-column window goes from 126×35 to 71×20.
- The preview popup is deliberately unaffected: it keeps its own geometry, so the preview key still
  shows the image larger than the page does.
- No engine or wire-format change: `--image-max-height` already exists and does what is needed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `nvim/render-mode`: the height bound for image artwork changes from the window's text height to
  the smaller of that and the configured `image_max_height`.

## Impact

- `lua/md-render/config.lua` — new option and its documentation.
- `lua/md-render/init.lua` — `request` computes the height bound.
- `README.md` — describe the option and the default.
- `tests/headless/run.lua` — the request's height argument is asserted, for R and for the popup.
- No change to `engine/`, `docs/md-render-format.md`, or the render cache key's shape.
