# Proposal

## Why

A markdown document's `![alt](path)` is currently rendered as its alt text and nothing else. The
image itself is invisible in the reading view, which is the one content type the reader has to
leave the editor to see. Every other block — prose, code, tables, diagrams, formulas — is already
drawn in the buffer.

Windows Terminal supports no terminal graphics protocol (no Kitty, no Sixel, no iTerm2), so a real
bitmap cannot be placed in a buffer there. What it does support is truecolor and arbitrary text, and
a terminal cell can carry a picture the same way `chafa` and `mcat` do it: one character per cell,
colored from the pixels it covers. That is the only route that keeps the image inside the buffer,
where scrolling, searching and yanking already work.

The engine is already the right place for it: it produces styled spans with a foreground and a
background color, which is exactly what a half-block cell needs, and the plugin's `render.apply`
needs no new code path.

## What Changes

- The engine takes an optional base directory (`--base <dir>`). Content arrives on standard input,
  so the engine otherwise has no way to resolve a relative image path against the document holding
  it.
- A supported image reference is rendered as a block of character-cell artwork:
  - a quadrant encoding draws four sub-cells per character from the block elements (`▘▝▖▗`, `▚`,
    `▀` …), two colors per cell, for twice the horizontal detail of half-blocks;
  - a half-block encoding — `▀` with the upper pixel as the foreground color and the lower pixel as
    the background color — is the engine's default and the fallback for fonts without quadrants;
  - an ASCII encoding maps each cell's luminance to a character from a fixed ramp, for terminals
    without truecolor.
- The image is scaled with an area average to at most the requested width, correcting for the
  terminal cell's 2:1 height-to-width ratio. Transparent pixels leave the terminal's background
  showing rather than being painted.
- The image follows the page. The plugin passes the window's text height alongside its text width,
  so a tall image is fitted to the visible page instead of running for hundreds of rows, and a
  resize in either direction re-renders it to the new page. Both bounds preserve the aspect ratio,
  and neither enlarges the image past its natural size.
- Image colors are reduced to a fixed 64-colour palette. A block cell carries a foreground and a
  background, so 64 colours bound the artwork at 4,096 distinct styles per session, and every image
  in every document reuses the same groups. This is not cosmetic: the plugin defines one highlight
  group per distinct style and each definition redraws the editor — 5,000 groups measured at 913 ms,
  which one unquantized screenshot would cost on every resize.
- Supported formats are PNG, JPEG, GIF (first frame), WebP, BMP, TIFF and ICO. They are all served
  by pure-Rust decoders, so nothing new is needed at build or cross-compile time. SVG, AVIF, HEIC
  and anything else fall back to the alt text.
- Decoding is capped: a file over a size limit, or an image over a pixel limit, falls back rather
  than being decoded.
- Anything that cannot be rendered — missing file, undecodable data, unsupported format, an `http`
  URL, a `data:` URI — becomes the alt text. One bad image never fails the document.
- The plugin gains `image_mode`: `auto` (default; quadrants when `termguicolors` is on, ASCII when
  it is off), `quads`, `blocks`, `ascii`, or `off`. `off` is today's behaviour, alt text only.
- Image artwork obeys the existing width contract and source mapping: every line fits the requested
  width, the block's display lines all map back to the source line holding the image reference, and
  rendering stays deterministic.

## Capabilities

### New Capabilities

None. Image rendering is an extension of what the engine already promises to render, not a
capability of its own.

### Modified Capabilities

- `nvim/render-engine`: rendering input gains an optional base directory, and an image reference is
  rendered as character-cell artwork under new requirements for encoding, scaling, size limits and
  fallback. The width-bounded and deterministic guarantees extend to images explicitly.
- `nvim/render-mode`: the plugin exposes `image_mode` and passes it to the engine; with `off`, an
  image renders as its alt text exactly as it does today.

## Impact

- `engine/src/main.rs`: a `--base` argument.
- `engine/src/renderer.rs`: `Tag::Image` becomes an image block instead of falling into the
  catch-all tag arm; the alt text is kept as the fallback.
- `engine/src/document.rs`: image blocks are laid out to a bounded cell grid.
- New engine module for decoding, scaling and encoding; the `image` crate with the `png`, `jpeg`,
  `gif`, `webp`, `bmp`, `tiff` and `ico` features enabled and the rest off.
- `lua/md-render/engine.lua`: pass `--base`, computed from the source buffer's file name, and
  `--image-max-height`, computed from the window's text height.
- `lua/md-render/state.lua`: the render cache key includes the height bound, so a resize in height
  alone is not answered from a stale render.
- `lua/md-render/config.lua`, `README.md`: the `image_mode` option.
- `engine/tests/` and `tests/headless/`: a small fixture image, width and fallback checks, and a
  deterministic-output check.

Not part of this change: Kitty, Sixel or iTerm2 output and any capability detection for them;
animated GIFs or video; remote URLs and data URIs; zooming an image in the preview popup.
