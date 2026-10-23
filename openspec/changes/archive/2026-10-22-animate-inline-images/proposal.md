# Proposal

## Why

An animated GIF or WebP currently renders as its first frame forever: the reading view is a
snapshot, and there is no way to see the motion or inspect a later frame. The first attempt at
images made that choice deliberately, because decoding every frame on every render (and every
resize) would blow the render budget. But a reader who opened a document to look at an animated
diagram wants to see it move — and wants it to stay still while they read around it.

The same view also cannot hand an image to the operating system. A document may reference a large
screenshot or a format the engine cannot draw (SVG, for example), and the reader's only route to
the real file is to leave the editor and find it by hand.

## What Changes

- **Opt-in frames from the engine.** A new `--image-animation` flag makes the engine emit, in
  addition to the first-frame `lines`, an `animations` table for every animated GIF/WebP image:
  the line range the artwork occupies, and each frame's delay plus its spans. Ordinary renders do
  not pass the flag, so their cost and output are unchanged. Frame count and total decoded pixels
  are capped; an image over the caps stays at its first frame.
- **Paused inline, one key per frame.** In R an image is still drawn paused on its first frame.
  The new `frame_next` key (default `<C-n>`) advances the animated image under the cursor one
  frame, wrapping at the end. It hands the key back to Vim when the cursor is not on an animated
  image, the same way `follow` does.
- **The popup plays.** `<CR>` on image artwork opens that image alone in the existing preview
  popup, the way it already does for a mermaid fence or a table. An animated image there loops
  automatically on its own frame delays; `Space` pauses and resumes, `frame_next` steps one frame
  while paused, and closing the popup stops the timer.
- **Open with the system application.** The new `open_image` key (default `gx`) opens the image
  referenced under the cursor with the operating system's default application, resolving a
  relative destination against the document's own directory. It works for any local image,
  including formats the engine cannot draw; it hands the key back when the cursor is not on one.
- **Config.** `image_animation = true`; `keymaps.frame_next = '<C-n>'`,
  `keymaps.open_image = 'gx'`, and `keymaps.pause = '<Space>'` for the popup.

## Capabilities

### New Capabilities

None. Every behaviour below extends a capability that an earlier change introduces.

### Modified Capabilities

- `nvim/render-engine`: an animated image can additionally carry per-frame artwork and delays when
  the caller asks for animation, under frame and pixel caps.
- `nvim/render-mode`: R keeps an image paused on its first frame, gains a frame-step key, and
  gains a key that opens the image with the system default application.
- `nvim/block-preview`: `<CR>` on an image opens it in the preview popup, where an animated image
  loops automatically and can be paused and stepped.

The capabilities above are introduced by the still-open `render-inline-images` change and
`add-nvim-block-preview`; their deltas here are `ADDED` requirements that layer on top. This change
should be archived after those two, so the requirements land in the order they were written.

## Impact

- Engine: `engine/src/image_art.rs` (animated decode, caps, per-frame sampling and encoding),
  `engine/src/document.rs` and `engine/src/wire.rs` (`animations` in `WireDoc`), `engine/src/main.rs`
  (`--image-animation`).
- Plugin: `lua/md-render/config.lua` (options and keys), `engine.lua` (flag), `state.lua` (cache
  key), `render.lua` (frame replacement), `preview.lua` (image popup, timer), `init.lua` (step and
  open keys), `link.lua` (identifying an image, not just a link, on a line).
- Tests: engine unit tests for animated decode and caps, wire/layout tests for the `animations`
  table, headless tests for stepping, playback and `open_image` (with the opener stubbed).
- Docs: `README.md` (options and keys), `docs/md-render-format.md` (the `animations` field).
- Dependencies: none new; the `image` crate already provides GIF and animated WebP decoding.
