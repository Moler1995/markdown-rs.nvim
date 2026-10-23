# Proposal

## Why

Image artwork is drawn as terminal cells, so a picture is shown at the resolution of the
character grid: braille gives 2 x 4 dots per cell, which makes a 640 x 360 GIF about 240 x 120
dots wide in a 120-column window — a fraction of the pixels the file holds. Animation is no
better: every frame is decoded, sampled and re-encoded as character lines, and a Lua timer swaps
them into the popup.

Terminals that implement the Kitty graphics protocol — WezTerm, which the author uses, among
them — draw the file itself, composited by the GPU at native resolution, and play an animated
GIF's own frames without the editor doing anything per frame. The plugin already knows which
block the reader asked to see, and the preview is a floating window rather than a region of the
rendered buffer, so none of R mode's buffer model — extmarks, source mapping, motions, search —
has to change to use it.

## What Changes

- The engine reports, for every image reference it drew, the reference's source line and the
  resolved local path, so a reader can display the file the artwork came from.
- A new plugin module owns terminal detection, the Kitty graphics transport and placement, and
  the record of what is currently on screen.
- A new `graphics` option (`'auto'` by default, `'off'`) decides whether the plugin uses it.
- With graphics available, an image's preview popup shows the image file instead of its
  artwork: the popup window is unchanged, the file is placed over the popup's interior, and the
  terminal scales it and plays it if it animates.
- With graphics unavailable, off, or the engine unable to report a path for the image, the popup
  is exactly what it is today — the text artwork, with the existing pause and frame-step keys.
- **Not breaking**: no existing option changes meaning, no command or key is removed, and the
  wire format gains an optional field that a reader may ignore.

## Capabilities

### New Capabilities

- `nvim/graphics`: how the plugin detects a terminal that can draw images, sends an image to it,
  places it over the preview popup, removes it, and decides when not to try.

### Modified Capabilities

- `nvim/render-engine`: the engine reports each drawn image's source line and resolved local
  path; a reference it could not draw reports nothing.
- `nvim/block-preview`: an image's popup may show the image file rather than its artwork; the
  popup's content-is-buffer requirement is stated against the artwork that remains underneath,
  and the animation requirement allows the terminal to own playback.

## Impact

- `engine/src/wire.rs` and `engine/src/document.rs`: an `images` array on the document and the
  path each drawn reference resolved to; `engine/src/image_art.rs` exposes that path.
- `docs/md-render-format.md` and `engine/tests/wire_format_doc.rs`: the new field, documented
  and checked field for field.
- `lua/md-render/graphics.lua` (new), `preview.lua`, `config.lua`, `health.lua`.
- `doc/md-render.txt`, `doc/tags`, `README.md`.
- `tests/headless/run.lua`: the sequence construction and the fallbacks are testable there; the
  bytes reaching a terminal are not, and are verified by hand in WezTerm.
- No new crate. No change to the engine's dependency set or to the width contract.
