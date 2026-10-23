# Design

## Context

See `proposal.md` — Why. The pieces this design builds on, as they are today:

- `lua/md-render/preview.lua` already renders an image's popup from the reference alone, sizes the
  float to its content, and owns image playback with a one-shot timer per frame. It never opens a
  window it did not size from a document.
- The engine already resolves every reference to a local path (`image_art::resolve`) and decodes
  it, but the wire carries no path: `WireDoc` has `animations` and `animations_limited` and nothing
  else about images (`engine/src/wire.rs`).
- The plugin is written against Neovim 0.10+ and its suites run headless, with no terminal to
  observe.

Constraints that shape the approach:

- The engine knows nothing about Neovim and the plugin knows nothing about markdown. Anything that
  parses a destination or decides what is a local file stays in Rust.
- The width contract and R mode's buffer model are untouched by this change: the popup is a float
  over R, not a region of it.
- No new crate; `engine/tests/dependencies.rs` still passes unchanged.
- Rendering stays deterministic and byte-identical for the same input.

## Goals / Non-Goals

**Goals:**

- An image the reader asked to see is shown from its own file, at the terminal's resolution.
- An animated file is played by the terminal, with the file's own delays.
- Everything the plugin cannot do here degrades to exactly today's popup.

**Non-Goals:**

- Inline images in R. The artwork stays in the buffer, and every motion, search, yank and source
  map stays as it is; a later change may overlay the rendered rows.
- Sixel. The transport is the Kitty graphics protocol only, and the detection names clients known
  to implement it.
- Zooming or scrolling a graphic; re-placing it when the terminal or the popup changes.
- Native pixel dimensions on the wire: the popup's cell box is what the graphic is fitted to, and
  the terminal preserves the image's aspect ratio within it.

## Decisions

### D1 — The engine reports paths, unconditionally

`WireDoc` gains `images: [WireImage]`, each `{source, path}`, emitted for every reference the engine
drew as artwork, in source-line order, omitted when empty. `document.rs::push_image` is the only
writer: it already holds the resolved destination and knows whether it fell back to alt text.

*Alternatives:* a `--image-metadata` flag (a new plugin would send an argument an older engine
rejects, so the plugin would need a retry path and a skew story for a field that costs five
fields of JSON); letting the plugin re-resolve the destination itself (it would have to reimplement
the scheme refusals and the base-directory rule, which is the boundary the repository draws).
A document without images is byte-identical, and the wire version stays 1 because the field is
optional in both directions: an old reader ignores it, and an old engine's absence of it means the
plugin shows artwork.

### D2 — Placement is cursor-relative, not pixel-absolute

The Kitty protocol anchors a placement at the terminal cursor unless absolute pixels are given. The
plugin writes, in one `nvim_ui_send` call: a cursor-position sequence to the popup's first interior
cell — computed from `nvim_win_get_position` plus the border — followed by
`ESC_Gi=<id>,a=T,f=100,c=<inner>,r=<height>,C=1,q=2,t=f;<absolute path>ESC\`.

`c`/`r` size the image in cells, which is exactly the popup's interior, and the terminal fits the
image inside that box preserving aspect ratio. `C=1` leaves the cursor where it was, `q=2` keeps the
terminal from answering on the wire, and `i=<id>` is what makes removal possible later.

*Alternatives:* absolute `x`/`y` placement (needs the cell's pixel size and the window's pixel
origin, which the TUI does not expose; the `CSI 14 t` reply would add a second asynchronous round
trip for no gain); moving the float's position instead (the popup's position is the reader's
layout, not the plugin's to alter).

### D3 — Transmit by path, fall back to inline bytes

`t=f` has the terminal read the file the engine already resolved: one short sequence, no copy, no
memory held by the plugin or the editor. Where the path is not ASCII — a Windows path in a
non-ASCII directory is the plausible case, and the protocol payload is not guaranteed to carry it —
the plugin reads the file with `vim.uv.fs_read` and sends `t=d` in base64 chunks of at most 4096
bytes with `m=1` continuations.

*Alternatives:* always `t=d` (4/3 bytes through the pty and thousands of writes for a multi-megabyte
GIF); `t=t` (the temporary-file medium) with a plugin-made copy (a copy to create, and a lifetime to
manage for no benefit).

### D4 — The terminal owns animation

Where the popup is drawn with graphics, the plugin starts no timer and binds no pause or step keys.
A GIF sent with `t=f` reaches WezTerm's frame decoder, which plays its frames with the file's own
delays.

*Alternatives:* the plugin stepping frames (it cannot extract frame N of a GIF; what the engine
emits is character art per frame, not pixels); transporting decoded RGBA frames as `a=f`/`a=a` and
composing them in the terminal (WezTerm stores `AnimRgba8` and would play them, but a 640 x 360
frame is 921 KB uncompressed, so a 134-frame animation would cost some 120 MB over the wire —
versus 3.9 MB for the file).

### D5 — Detection: a positive identification or nothing

Graphics is used only when `nvim_ui_send` exists (Neovim 0.12+), `graphics` is not `'off'`, and the
terminal is identified. `TERM_PROGRAM` answers immediately where it names a known client; otherwise
`setup` sends `ESC[>q` and caches the reply from the `TermResponse` autocmd. Nothing blocks: a popup
opened before the answer arrives is the artwork, and the next one is not.

*Alternatives:* assuming a modern terminal (`nvim_ui_send` writes to whatever is there, and an
unrecognized APC is normally swallowed — but "normally" is not a guarantee, and a mis-sent image is
garbage on screen); requiring an explicit `graphics = 'kitty'` (correct but unfriendly: the default
would do nothing for every reader who does not read the help).

### D6 — The failure paths are the old paths

"Graphics unavailable" is not an error state: the popup is still built from the engine's document,
sized by the artwork, and painted as today; the placement is skipped. An image the engine could not
draw carries no `images` entry, so nothing is attempted and no warning is emitted.

`health.probe()` gains one entry naming the decision: in use, or off because of the option, the
editor's API, or the terminal's identity.

### D7 — Tests stop at the terminal boundary

`graphics.lua` exposes the sequence builder and the decision as pure functions over injected inputs,
and its sender is a module-level function a test can replace. Headless tests then assert: the exact
bytes for a given path and box; the placement skipped for `graphics = 'off'`, for a missing
`nvim_ui_send`, and for a document with no `images` entry; removal naming the assigned id; and that
a graphics-off popup is byte-for-byte today's popup. What a terminal does with the bytes is checked
by hand, in WezTerm, as an explicit task.

## Risks / Trade-offs

- **`nvim_ui_send` may not reach the terminal under Windows ConPTY** → the first task is a spike:
  a hand-run sequence in WezTerm before any module is written. If it fails, the change stops there
  and the proposal is withdrawn rather than shipped behind a check that never passes.
- **The popup's cursor moves for an instant** while the placement sequence runs → the cursor is
  placed at the cell the graphic starts at, which the reader is looking at, and the following
  Neovim redraw restores it. If it is visible in practice, the fallback is absolute placement once
  the cell pixel size is known.
- **A graphic covers the artwork that search and yank act on** → the buffer is unchanged and
  `graphics = 'off'` shows the text again; the popup is a reading surface for one image, not a
  place to read text.
- **A non-ASCII path may not survive the protocol payload** → `t=d` inline transmission carries the
  bytes instead of the path.
- **WezTerm may pause frames for an unfocused window** → accepted; the reader's attention is what
  playback is for.
- **The README's Neovim floor is 0.10 while this needs 0.12** → the feature is gated on the API,
  never required, and the floor is not raised.
- **Letterboxing where the image's aspect ratio differs from the popup's** → the popup was sized
  from artwork produced at the same box, so the mismatch is the cell grid's, not a new one.

## Migration Plan

1. Spike `nvim_ui_send` in WezTerm; stop if it does not work.
2. Engine: emit `images` and update the wire doc and its field-for-field test.
3. Plugin: `graphics.lua`, the option, the popup integration, health.
4. Documentation and headless tests.

Rollback: `graphics = 'off'` restores today's behavior without touching the engine, and reverting
the plugin alone does the same for existing configurations; the engine's field is additive, so an
older plugin and a newer engine remain compatible.
