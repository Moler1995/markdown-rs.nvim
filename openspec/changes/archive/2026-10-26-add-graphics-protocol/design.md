# Design

## Context

See `proposal.md` — Why. The pieces this design builds on, as they are today:

- `lua/md-render/preview.lua` renders an image's popup from the reference alone, sizes the float
  to its content, and owns image playback with a one-shot timer per frame. It never opens a
  window it did not size from a document. A popup's content always fits its window: both the
  width and the height are clamped to what the engine was asked for, so nothing inside a popup
  ever scrolls.
- `lua/md-render/link.lua` already parses image references out of the source, because the engine
  drops link targets. `image_block` throws its parse away and keeps only the reference's source
  text, which is what the popup is rendered from.
- The engine resolves every reference to a local path (`image_art::resolve`), reads it and draws
  it, but the wire carries no path: `WireDoc` has `animations` and `animations_limited` and nothing
  else about images.
- The plugin is written against Neovim 0.10+ and its suites run headless, with no terminal to
  observe.

Measured before this design was written, in WezTerm on Windows with Neovim 0.12.6, by hand:

- Kitty APC (`ESC _ G ... ESC \`) written with `nvim_ui_send` reaches nothing: Windows ConPTY
  does not carry APC. OSC 1337 and CSI do.
- An OSC 1337 `File=` placement with `nvim_ui_send` draws the file over a floating window. A
  ten-frame GIF sent whole plays its own frames, with its own 150 ms delays, with no timer in
  Neovim.
- Placing the image **before** Neovim has flushed its own paint leaves holes: the editor's cell
  writes land after the placement and remove the image from those cells. A `:redraw` before the
  placement removes the problem entirely.
- Closing the popup with `nvim_win_close` repaints the cells the image sat on, and the image is
  gone; no delete sequence exists on this transport.
- A terminal resize repaints the whole screen, and the image is lost with it.
- `nvim_win_get_position` names the popup's *frame*, not its first content cell. Measured with
  `screenpos`: a float opened at `row = 5, col = 10` with `border = 'rounded'` has its first text
  cell at screen row 7, column 12 (1-based), while the position reads `{ 5, 10 }`. A CSI cursor
  move to the position followed by the OSC therefore covers the border's top and left and leaves
  the text area's last column and row showing the artwork — the one-cell strip a hand check
  reported. The placement moves in by the border's thickness; `width` and `height` are the text
  area's already.
- With `preserveAspectRatio=1` and only `width=`, WezTerm derives the height from the file's
  aspect and its true cell size: a 320 x 240 GIF at `width=60` came out 60 cells wide and about
  25.7 rows tall, overflowing a 20-row popup.
- `CSI 16 t` (cell size in pixels) is not surfaced to Neovim: the reply never produced a
  `TermResponse`. The plugin cannot learn the terminal's cell pixel size.

## Goals / Non-Goals

**Goals:**

- An image the reader asked to see is shown from its own file, at the terminal's resolution.
- An animated file is played by the terminal, with the file's own delays.
- Everything the plugin cannot do here degrades to exactly today's popup.

**Non-Goals:**

- Animated playback through Kitty APC: the terminal has no way to play a file, and frames would
  mean the engine emitting one file per frame, which is a change of a different size. An
  animated image on that transport keeps its artwork animation (D7).
- Sixel, and OSC 1337 through `tmux` or `screen`: the passthrough needs DCS wrapping that would be
  sent blind, so a multiplexer is treated as a terminal that cannot draw.
- A pixel-perfect fit: the terminal's cell pixel size is not reachable from Neovim, so the file is
  stretched into the box the engine laid the artwork out in (D4).
- Zooming or scrolling a graphic. An image popup has no zoom rung today, and its content fits its
  window, so neither key reaches a graphic.
- Inline images in R.

## Decisions

### D1 — Two transports, each used for what it does best

**OSC 1337** for WezTerm and iTerm2: one `nvim_ui_send` carrying a cursor move to the popup's
first content cell, then
`ESC ] 1337 ; File=inline=1;width=<cols>;height=<rows>;doNotMoveCursor=1:<base64> ESC \`. The
whole file crosses the pty once, and the terminal plays it if it animates — measured in WezTerm,
which keeps the encoded bytes and drives a frame decoder for GIF, APNG and WebP.

**Kitty APC** for kitty and Ghostty: the same cursor move, then
`ESC _ G i=<id>,a=T,t=f,p=<placement>,c=<cols>,r=<rows>,C=1,q=2;<base64 path> ESC \`. The payload
is the path, so a large file costs almost nothing; the terminal reads and decodes it. The
protocol has no way to play a file, so this transport draws still images only.

Kitty APC is *not* used for WezTerm, even though WezTerm implements it: on Windows, its default
ConPTY drops APC sequences entirely (measured), and OSC 1337 both works there and animates.

*Alternatives:* one transport for every terminal — the two are not interchangeable, and the one
that animates is the one that does not work on this platform; Sixel — a third encoder for clients
neither transport needs.

### D2 — Identification is from the environment; there is no query

Graphics is used only when all of these hold: `nvim_ui_send` exists, a UI is attached,
`graphics` is not `'off'`, the process environment names a client known to implement one of the
two protocols, and no multiplexer is in the way (`TMUX` is unset and `TERM` does not start with
`screen`/`tmux`). The tier is chosen in this order, so WezTerm gets OSC on every platform:

1. `TERM_PROGRAM` is `WezTerm`, or `WEZTERM_PANE` is set → OSC 1337.
2. `TERM_PROGRAM` is `iTerm.app`, or `LC_TERMINAL` is `iTerm2` → OSC 1337.
3. `KITTY_WINDOW_ID` is set, `TERM` is `xterm-kitty` or ends with `-kitty`, `TERM_PROGRAM` is
   `ghostty`, or `TERM` is `xterm-ghostty` → Kitty APC.
4. Anything else → no graphics.

The decision is a pure function of an environment table, so it is testable and needs no timer: a
popup opened on the first keystroke is drawn with graphics if the terminal is identified.

*Alternatives:* a `ESC [ > q` version query — an asynchronous round trip that costs a first popup
of artwork and still names no capability, because a terminal's name is not its protocol support;
probing with a real placement — a failed placement on an unidentified terminal risks garbage on
screen for a feature that has no way to retract it; requiring `graphics = 'wezterm'` — correct but
unfriendly, since the default would do nothing for readers who never read `:help`.

### D3 — The plugin resolves the path itself

The reference is already parsed by `link.lua` for the preview; the popup will keep the parse
instead of discarding it. Resolution repeats `image_art::resolve` exactly: an `http://`,
`https://` or `data:` destination is not a file; an absolute path is used as it is; anything else
is joined to the document's directory (the engine's working directory when the buffer has no
name). The file must stat and be under the size cap (D6), and its contents are read with
`vim.uv.fs_read`.

The duplication is accepted because the boundary this repository draws is about *decisions*, not
about text: the engine decides what a reference means; the plugin already re-reads the destination
for links, and a parse it gets wrong costs a graphic, not a render — the popup still opens, as
artwork.

*Alternatives:* an `images` array on the wire — the owner's earlier design, dropped after this
round: the path would be exact, but it is a wire version bump, a documented field, a field-for-
field test and a corpus snapshot move for a path the plugin can already see, and the engine would
still not report the pixel dimensions the fit cannot use (D4).

### D4 — The file fills the popup's inner box

Both transports are given the same box: the popup's inner width and height in cells. WezTerm
stretches the file to it, but only when it is told to: its parser defaults `preserveAspectRatio`
to true, and with that it ignores the given height and derives it from the width, which left the
image letterboxed and the popup's last rows showing the artwork underneath (measured by hand after
the first implementation — the band the second hand check reported). The sequence therefore carries
`preserveAspectRatio=0` explicitly. kitty scales it inside the box preserving aspect, so on that
transport the difference from the artwork is a letterbox of at most the cell-ratio error, not a
spill.

The box is not arbitrary: the engine sized the popup's content by fitting the image into a cell
grid that assumes cells twice as tall as they are wide, and the float is that content's size. The
terminal's real cell shape is close to that assumption but not equal to it, and the artwork is
already drawn with the difference. Using the same box guarantees two things a one-dimension
placement cannot: the image never spills over the popup's border, and no strip of artwork is left
visible beside it. A one-dimension placement was measured to do both (Context), and the exact
alternative — forward the file's pixel size and the terminal's cell size, then fit by pixels —
needs a reply Neovim does not deliver.

*Alternatives:* `preserveAspectRatio=1` with the width only — the image overflows the popup
whenever the terminal's cells are not exactly 2:1 (measured); the height only — the image is
narrower than the popup and the artwork shows beside it; a cell-pixel query and an image-header
parser in Lua — two new failure modes for a correction the artwork does not make either.

### D5 — Place after a flush, at the popup's content origin, then restore the cursor

`M.open` opens the float as it does today, then, for a graphic popup: `vim.cmd('redraw')` (which
also flushes the repaint of any popup just closed), the cursor move and the OSC in one
`nvim_ui_send`, then `nvim__redraw({ cursor = true, flush = true })` so the terminal cursor returns
to where Neovim's cursor is rather than staying at the image's first cell. The call is guarded:
`nvim__redraw` is private API, and its absence costs a cursor that the next repaint fixes anyway.

The flush is not cosmetic: without it, Neovim's pending paint of the float lands after the
placement and removes the image from the cells it touches (Context: the report of a torn image).

The origin the cursor moves to is not the window's reported position. That position is the corner
of the window's frame, and a bordered float's first text cell is one row and one column in from it
(Context: measured with `screenpos`). Moving in by the border's thickness is what makes the image
cover the artwork's cells exactly; placing at the position itself covered the border's top and
left and left a cell of artwork beside and below the image. The thickness is read from the
window's own `border`: a border with no cell in that corner (`'none'`, `'shadow'`) takes nothing.

*Alternatives:* placing in a `vim.schedule` after the open — a race with the paint as likely as
the flush, and one that depends on event-loop timing rather than on an explicit ordering;
absolute pixel placement — needs the cell pixel size (Context).

### D6 — The payload is per transport: whole file for OSC, path for Kitty

On OSC the file is read once, base64-encoded once, and the encoded string is kept on the popup: a
resize re-places it without touching the disk again. A file over 8 MiB is not sent — the popup
falls back to artwork — because the whole file crosses the pty in a single write and a preview is
not worth an unbounded one. On Kitty the payload is the path, so nothing is read, nothing is
capped, and re-placing costs one short sequence. Either record is dropped with the popup.

*Alternatives:* re-reading the file on every OSC re-place — a disk read and an encode per resize
event; chunked transmission — an iTerm2 volume control for files far below the cap, and a
reassembly path to maintain; a smaller cap — a 1920 x 1080 PNG is routinely 2-4 MiB.

### D7 — The terminal owns playback, and where it cannot play, the artwork keeps it

When a graphic will be placed over an OSC popup, the popup's engine request leaves
`--image-animation` out (`preview.view` gets the plan). The document then carries no frames, so
no timer exists, no pause or frame-step key is bound, and `animations_limited` has nothing to
report. WezTerm plays GIF, APNG and WebP from the OSC payload with the file's own delays
(measured for GIF).

Kitty cannot play a file, so on that transport the frames are still requested and the rule is
inverted: a popup that has an animation to play is not drawn with graphics at all. The check is
the document itself — `doc.animations` non-empty and more than one frame — so no file sniffing is
involved, and an image the engine refused as too large falls through to the still graphic, which
is the best that popup can do either way.

*Alternatives:* requesting the frames on OSC and merely not playing them — decoding every frame of
a multi-megabyte GIF to throw it away, which is exactly the cost this feature exists to avoid;
showing the first frame on Kitty for an animated file — turning motion into a still picture is a
worse trade than character art that moves.

### D8 — Removal differs by transport; a resize re-places

An OSC 1337 placement has no identifier and no delete action: the image lives in the cells it was
drawn on, and anything that rewrites those cells removes it. Closing the popup rewrites them, so
close is removal, and no cleanup call exists to forget (measured).

A Kitty placement carries a placement id, and WezTerm re-attaches it to a cell whenever the cell
is rewritten — which is what keeps it on screen during unrelated repaints, and also why closing
the window would *not* remove it. The popup therefore sends `a=d,d=I,i=<id>` before closing, and
re-placing uses the same ids, which the terminal treats as a move rather than a duplicate.

A terminal resize rewrites the whole screen, which is why the image vanished on resize (measured).
The popup re-places its graphic when `VimResized`/`WinResized` fires, debounced by the same
`resize_debounce` that already coalesces re-renders, at the window's current position. A manual
full redraw (`:redraw!`, `CTRL-L`) still clears an OSC image until the next resize; on Kitty the
placement survives it. The help says so rather than guesses around it.

*Alternatives:* closing the popup on resize — a behaviour change for every popup kind, and the
reader loses the block they were looking at; re-placing from an autocmd without a debounce — one
whole-file write per column during a drag-resize on OSC.

### D9 — A graphic popup does not scroll

The popup is a reading surface and its artwork is its content, so its wheel and vertical scroll
keys normally move the viewport. While a graphic is placed they are bound to a no-op instead.
The reason is the same cell attachment D8 describes: an OSC placement is removed from every cell
the repaint touches, and a scroll repaints the viewport, so a wheel scroll left only the rows above
the scroll region as image and the rest as the artwork underneath (measured by hand, after the
first implementation: a still image's popup lost all but its first rows when the wheel was rolled
over it). The configured sideways scroll keys are frozen with them, for the same reason and after
the same kind of report: `<C-h>`/`<C-l>` scroll to the left or right, that repaints the viewport
too, and the picture turned back into artwork (the third hand check). Nothing is lost by freezing
either axis: the engine fits an image to the popup (`view.width` and `view.height` are the popup's
inner width and height), so its content is exactly as wide and as tall as its window and there is
nothing past an edge to reach.

*Alternatives:* re-placing after every scroll — a whole-file write per wheel notch on OSC, and the
image would visibly flicker while it is re-encoded-in-flight; re-placing after every repaint —
cursor motion repaints too, so the cost would be paid on every `j`.

### D9 — The failure paths are the old paths

"Graphics unavailable" is not an error state: the popup is still built from the engine's document,
sized by the artwork, and painted as today. A destination that is not a file, a file that does not
stat, one over the cap, or bytes the terminal cannot decode all mean "no graphic": the placement
is skipped or does nothing, the artwork or alt text stays visible, and no warning is emitted.

`health.probe()` gains one entry naming the decision: which transport is in use, or off because of
the option, the editor's API, the missing UI, the terminal's identity, or the multiplexer.

### D10 — Tests stop at the terminal boundary

`graphics.lua` exposes identification as a pure function of an environment table, each transport's
sequence builder as a pure function of a position, a box and a payload, and the sender as a
module-level function a test replaces. Headless tests then assert: the exact bytes for both
transports; the cap, and its absence on Kitty; every condition that turns graphics off; that a
graphic popup binds no pause or frame-step key and sends no animation request; that an animated
image on Kitty is left as artwork; that a resize re-places; and that a graphics-off popup is
byte-for-byte today's. What the terminals do with the bytes is checked by hand, in WezTerm, as an
explicit task.

## Risks / Trade-offs

- **The Kitty branch cannot be exercised from this environment** → its sequences are pinned byte
  for byte by tests, an APC a terminal does not understand is ignored rather than printed, and a
  failed placement leaves the artwork visible underneath; the OSC branch, which is the one this
  environment runs, is verified by hand.
- **The stretch in D4 is visible for a terminal far from 2:1 cells** → the artwork carries the
  same error, so the popup is consistent with what it replaced; a cell-metric source, if Neovim
  ever exposes one, turns the stretch into a fit without touching the popup.
- **A terminal that swallows OSC 1337 shows nothing where the image was placed** → the popup is
  still the artwork's window, and identification is limited to two clients known to implement it.
- **Non-ASCII paths** → they are never sent: OSC 1337 carries the file's bytes, not its path.
- **A file that changes on disk after the popup opened** → the popup shows the bytes read at open
  time, which is what a preview is; a second preview shows the new file.
- **A manual full redraw clears the image** → documented; the next resize restores it, and closing
  and reopening the popup is always available.
- **The popup's cursor sits on the image's first cell** → it is where Neovim's cursor is, the
  terminal draws it over the picture, and moving it is harmless because cursor motion rewrites no
  cells.
- **The README's Neovim floor is 0.10 while this needs 0.12's `nvim_ui_send`** → the feature is
  gated on the API, never required, and the floor is not raised.

## Migration Plan

1. `graphics.lua`: identification, the plan, the sequence builder, the injectable sender.
2. The option, the popup integration, the resize re-place, health.
3. Documentation, headless tests, and a hand check in WezTerm.

Rollback: `graphics = 'off'` restores today's behavior without touching anything else; reverting
the plugin files does the same for existing configurations, and the engine never changed.
