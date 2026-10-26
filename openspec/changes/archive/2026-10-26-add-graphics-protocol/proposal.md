# Proposal

## Why

Image artwork is drawn as terminal cells, so a picture is shown at the resolution of the
character grid: braille gives 2 x 4 dots per cell, which makes a 640 x 360 GIF about 240 x 120
dots wide in a 120-column window — a fraction of the pixels the file holds. Animation is no
better: every frame is decoded, sampled and re-encoded as character lines, and a Lua timer swaps
them into the popup.

A terminal that implements the iTerm2 inline-image protocol draws the file itself with
`ESC ] 1337 ; File=...`, composited by the GPU at native resolution, and plays an animated GIF's
own frames without the editor doing anything per frame. This was measured, not assumed: WezTerm
on Windows animates a ten-frame GIF sent this way, in the popup position, with no per-frame work
from Neovim. The preview is a floating window rather than a region of the rendered buffer, so
none of R mode's buffer model — extmarks, source mapping, motions, search — has to change.

The Kitty graphics protocol, the other candidate, is **not** usable here: its APC sequences do
not reach the terminal through Windows ConPTY, which is WezTerm's default pseudo-console on
Windows. The same test that failed for APC succeeded for OSC 1337, so the transport is the one
that works in the environment this plugin is developed and used in.

## What Changes

- A new plugin module owns terminal identification, the file's transport and placement over the
  preview popup, and the record of what is currently on screen.
- A new `graphics` option (`'auto'` by default, `'off'`) decides whether the plugin uses it.
- Two transports, chosen by the terminal the environment names, so each gets the best that
  transport can do:
  - **OSC 1337** on WezTerm (every platform it runs on) and iTerm2. The file crosses the pty in
    one sequence and the terminal plays an animated GIF/APNG/WebP itself.
  - **Kitty APC** on kitty and Ghostty. The terminal reads the file from its path, so nothing
    crosses the pty but the path; the protocol has no file playback, so an animated image keeps
    its character-art animation and only still images are drawn natively.
- With either transport available, the popup shows the image over its interior: the popup window,
  its size and its position are unchanged, and the terminal scales the file to it.
- With neither available, off, or the file unreadable, the popup is exactly what it is today —
  the text artwork, with the existing pause and frame-step keys.
- **Not breaking**: no existing option changes meaning, no command or key is removed, and the
  engine and its wire format are untouched.

## Capabilities

### New Capabilities

- `nvim/graphics`: how the plugin identifies a terminal that can draw images, picks the transport
  it speaks, sends an image to it, places it over the preview popup, keeps it on screen across a
  resize, removes it when the popup goes, and decides when not to try.

### Modified Capabilities

- `nvim/block-preview`: an image's popup may show the image file rather than its artwork; the
  popup's content-is-buffer requirement is stated against the artwork that remains underneath,
  and the animation requirement allows the terminal to own playback.

## Impact

- `lua/md-render/graphics.lua` (new), `preview.lua`, `init.lua`, `config.lua`, `health.lua`.
- `tests/headless/run.lua`: the identification, the sequence construction, the payload cap and
  every fallback are testable there, with the sender replaced; the bytes reaching a terminal are
  not, and are verified by hand in WezTerm.
- `doc/md-render.txt`, `doc/tags`, `README.md`, `CLAUDE.md` (the module table).
- No engine change, no wire change, no new crate, no change to the width contract.

## Out of Scope

- Sixel, and OSC 1337 under `tmux`/`screen` passthrough. The module is shaped so a transport can
  be added as a tier without touching the popup.
- Animated playback through Kitty APC, which would mean the engine emitting per-frame files. On
  that transport an animated image keeps the artwork animation instead (see `design.md` D7).
- Inline images in R. The artwork stays in the buffer, and every motion, search, yank and source
  map stays as it is.
