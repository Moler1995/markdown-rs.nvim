# Proposal

## Why

In R, an image is character-cell artwork — braille dots. Now that the same file can be drawn by
the terminal in the popup, those dots are the worst of both worlds: the engine pays a full decode
to draw them, the terminal paints over them, and every scroll wipes the paint and leaves the dots
showing. A reader with a graphics-capable terminal should see the picture where the document
flows.

On a terminal that cannot draw the file at all — Windows Terminal through ConPTY, or any terminal
the plugin does not identify — the dots are not a fallback, they are noise: a few hundred cells of
unreadable texture that no scroll will ever turn into the picture. There the honest inline image
is a labelled place, and the real picture is one key away in the system's image viewer.

## What Changes

- **A card presentation.** The engine gains a fifth image encoding, `card`: it occupies the same
  cell box the artwork would have, and draws a quiet surface with one caption — the file's name,
  and its pixel size when the header says. It is what a native image is drawn over, and the whole
  of an image on a terminal that cannot draw.
- **`image_inline`.** A new plugin option, `'auto'` (default) / `'card'` / `'art'`. `auto` makes an
  image a card everywhere and adds the native picture where the terminal can draw; `card` makes it
  a card and never paints over it; `art` leaves the inline image to `image_mode`, which is how
  character artwork remains available. `image_mode` itself is untouched.
- **Inline thumbnails.** When the terminal can draw, R shows a downscaled copy of the file over
  the card, placed at the block's own cells. The engine produces it — it is the only stage with a
  decoder — at the box's pixel aspect with the theme's background filling the difference, so the
  picture is neither stretched nor fringed by the card. It is cached per file and box, and placed
  only on the cell-attached transport; the path-carrying transport sends the path, as the popup
  already does.
- **Large files stop being a special case.** The payload is the thumbnail, tens of kilobytes
  rather than the original file, so the inline byte cap no longer decides which images can be
  shown.
- **The placement follows the viewport.** A block's thumbnail is drawn when the block is fully
  visible and the viewport has settled, placed again after a scroll, a resize or a re-render, and
  absent while the block is partly off screen. Nothing about the document's lines, its source
  mapping or its keys changes: the card is the box the artwork occupies today.
- **The preview key routes an image by the terminal.** Where the file can be drawn in the editor,
  the preview key opens the popup as it does today. Where it cannot, the key no longer opens a
  popup that could only show dots: it opens the referenced file with the operating system's
  default application, through the same resolution and with the same reports as the open-image
  key. Diagrams and tables keep their popup everywhere, and the open-image key keeps its meaning.

The only visible default change on a terminal that cannot draw is this last pair — a card instead
of dots, and the file's viewer instead of a popup. `image_inline = 'art'` restores the artwork, and
the file is one `gx` away in every case. Nothing about the wire changes, and `image_mode` and
`gx` keep their meanings.

## Capabilities

### New Capabilities

None: the transport this builds on is the capability `add-graphics-protocol` introduces, and that
change owns it.

### Modified Capabilities

- `nvim/render-engine`: the image encodings gain `card`; a reference that exceeds a decoding limit
  but has a readable header is drawn as a card instead of its alt text; a thumbnail output mode is
  added.
- `nvim/render-mode`: R's inline images gain the `image_inline` choice and the card for every
  terminal, and native thumbnail placement with its visibility and settling rules.
- `nvim/block-preview`: the preview key opens an image's popup only where the terminal can draw
  it, and opens the file with the system application where it cannot.

## Impact

- Engine: `engine/src/image_art.rs` (the card and the thumbnail encoder), `engine/src/main.rs` (a
  `thumbnail` subcommand), `engine/src/document.rs` (the card path), plus fixtures and corpus
  coverage for a document rendered with `--image-encoding card`.
- Plugin: `lua/md-render/config.lua` (`image_inline`), `lua/md-render/graphics.lua` (inline
  placement and the thumbnail cache), `lua/md-render/init.lua` (viewport events, the render
  request, the preview key's image branch), `doc/md-render.txt`, `README.md`.
- Tests: engine integration tests for the card box and the thumbnail bytes; headless sections for
  the option, the card's box, the placement rules, the key's routing and the engine-spawn budget;
  the interactive suite for what a scroll does to a placed thumbnail.
- Depends on `add-graphics-protocol`: it ships `graphics.lua`, which this change extends. Archive
  that change first, so the transport is in the main spec this one builds on.
