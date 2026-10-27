# Design

## Context

See `proposal.md` — Why. The pieces this design builds on, as they are today:

- An inline image is a `DocBlock::Image`; `document::push_image` asks `image_art::artwork` for
  lines at `Bounds { width, height: image_max_height }`. `cell_grid` turns the picture's pixels
  into a cell box under one assumption — a cell is twice as tall as it is wide — and the encoder
  fills that box with glyphs. The lines are pushed through the same width guarantee as prose and
  every one of them is attributed to the reference's source line.
- `image_art::load` reads a file's dimensions from its header, then refuses more than 16 MiB or
  more than 16 megapixels before decoding pixels. `artwork` returning `None` is what makes
  `push_image` draw the alt text.
- `engine/Cargo.toml` compiles `image` with seven format features; the same features carry the
  encoders, so PNG and JPEG output costs no new dependency.
- `lua/md-render/graphics.lua` (from `add-graphics-protocol`) identifies a terminal from the
  environment and writes one sequence: OSC 1337 with the file's bytes for WezTerm and iTerm2, or
  Kitty APC with the file's path for kitty and Ghostty. Measured there: an OSC placement lives on
  the cells it covers and any repaint of them removes it; a scroll repaints; a terminal resize
  repaints the screen; Kitty APC reaches nothing through Windows ConPTY.
- R is a real buffer: it scrolls, searches and edits, and the plugin renders it again on every
  change, cached by buffer, `changedtick`, width and theme. The headless suite counts engine
  spawns, so every new spawn is a number the tests pin.
- `nvim_win_get_position` reports a float's frame corner while `screenpos` reports the cell a row
  and a column really occupies; the popup's placement had to be inset by its border.
- `config.image_encoding()` answers `braille` or `ascii` for `image_mode = 'auto'` and otherwise
  returns the option as given, including `off`, which the engine already renders as alt text.
- The preview key finds a block under the cursor — a mermaid fence, a table, or an image reference
  — and opens the popup for it. The open-image key already exists: it resolves the reference the
  way the engine does and hands a local file to `vim.ui.open`, reporting a URL, a `data:` URI, a
  missing path and a directory instead of launching anything.

## Goals / Non-Goals

**Goals:**

- An inline image is the picture while the block is on screen and the viewport is at rest.
- What shows when it is not — scrolling, a redraw — is quiet, sized and positioned exactly like
  the picture that would replace it.
- A terminal that can never draw the file shows the quiet thing and nothing else: no dots, and no
  popup built out of them.
- Cost scales with what is on screen, not with the document: one engine request per distinct file
  and box, and a payload small enough to re-send on every settle.

**Non-Goals:**

- Animation inline. The inline view is one still picture; the popup is where motion lives.
- A thumbnail for a PNG on the path-carrying transport: Kitty sends the original path, so the
  terminal scales the file itself. A file of any other format has no path transmission to use —
  that sequence names PNG — so it travels as the engine's PNG encode of the block's box.
- A thumbnail cache on disk, or one shared between editor sessions.
- Changing the document's flow. `image_max_height` stays the only knob over how much room an image
  takes, and this change does not touch it.
- A card in the popup. The popup draws the file, or the artwork when it cannot.
- Changing the preview key on diagrams and tables, or the open-image key anywhere.

## Decisions

### D1 — The card is an engine encoding

`ImageEncoding` gains `card`, `--image-encoding card` selects it, and the plugin's `image_mode`
does not. The encoding set is already the engine's answer to "how is an image drawn", and the card
is one more answer: a box the size of the artwork's, filled with a surface and one caption.

The box is computed by the same `cell_grid` call that braille uses, with the same bounds, so a
document rendered with `card` and one rendered with `braille` hold the same number of rows for the
same image, and the same source attribution. Two engine options, `--image-card-rows` and
`--image-card-min-width`, let the caller give the card a shape of its own instead: three rows on a
terminal that will never paint the picture, and a width at least as wide as the hint the card
carries. The artwork's box remains the default because that is what a card a picture is painted
over must keep.

*Alternatives:* the plugin replacing the block's lines after the render — it would have to move
every following line, rewrite the source mapping and re-implement the width guarantee, and it
would put a rendering decision in Lua; a separate `--image-placeholder` flag — a second switch for
the same decision the encoding already carries.

### D2 — One caption, read from the header

The caption is the file's name and, when the header reports a size, ` · <width>×<height>`. The
header is read even when the pixels are not: this is what lets a picture over the decode limits —
24 megapixels, a 20 MiB scan — still become a card of the right shape instead of a line of alt
text. Images that cannot be identified at all (missing, unreadable, unsupported, remote) keep the
alt text, because a card with no size would claim a picture that is not there.

The card's colours are theme tokens — the raised surface as the background, the muted text colour
for the caption — so a card in a light theme is light, and no palette or dither option applies to
it.

The card a picture is painted over is the one card without a caption. A picture may be
transparent, and what a transparent pixel shows is what is under it: `tests/fixtures/image.md`'s
16×16 RGBA sample, painted over its card, showed the caption as faint letters inside the picture —
seen by hand in WezTerm. The plugin therefore asks the engine for a caption-less card exactly when
it expects a picture over it (`config.card_shape`'s third answer), which is also the case where the
hint is already not drawn. A card with no placement on it keeps its caption, because the caption is
then all the reader gets.

*Alternatives:* a border-drawn frame with the caption below it — two colours and box-drawing
characters for the same information, and the box would have to shrink to keep the frame inside the
width; the alt text everywhere — leaves exactly the case the reader complained about; flattening
the picture's alpha over the card colour instead — the same clean rectangle, but only for what the
engine re-encodes: a file under the threshold is sent unchanged, so the terminal would still draw
its transparency over whatever is underneath, and closing that hole meant refusing that
pass-through for every transparent PNG — the native resolution D3 sells, lost for the format that
is most often transparent.

### D3 — The thumbnail is produced on demand, outside the wire

A `thumbnail` subcommand takes a path, a cell box, an output path and a background colour, and
writes one encoded picture. The plugin calls it only for blocks that are wholly visible and only
for a file it cannot send as it is, keeps the bytes in memory keyed by (absolute path, length,
mtime, columns, rows), and deletes the temporary file it asked for.

A small file is not worth that: `image_inline_original_bytes` (2 MiB by default) is the largest
file sent to the terminal unchanged, so a logo or a screenshot keeps its own resolution instead of
being re-encoded to 640 pixels, and the payload is no bigger than the encode it replaces. The
bytes are cached the same way. Only a still PNG or JPEG qualifies — a GIF, a WebP or an APNG would
play itself inline, which the inline view is not, and every other format is left to the engine,
which decodes more than the terminal does.

The wire is deliberately untouched: a base64 field would be re-produced on every render — every
keystroke in insert mode — and a path field would be environment-dependent, which the wire's
determinism guarantee (same document, width and theme → byte-identical output) does not allow.

*Alternatives:* a `thumbnail` field on the wire — the render's output would carry megabytes it
almost always does not need; the engine writing thumbnails during the render into a cache
directory named by the caller — the wire would still need a way to name them, and the naming would
become part of the format.

### D4 — Thumbnail pixels follow the artwork's cell shape

The thumbnail's pixel box is `cols × k` by `rows × 2k`: the same 2:1 cell assumption `cell_grid`
lays the artwork out under, so a terminal whose cells are near that shape reproduces the picture's
proportions, and one far from it stretches the picture by exactly the error the artwork already
carries. `k` is chosen to make the width about 640 pixels, clamped so that the result stays under
two megapixels — a bound on encode time and on the payload, not a quality setting — and capped at
the source's own pixels per cell, so a picture smaller than its box is written at its own size. The
cap is what keeps a small file looking the same whole and cut: whole, it is sent as itself and the
terminal scales it once; cut, it is the engine's encode, and encoding a 16 × 16 file into 640
pixels resamples every edge in it away — seen by hand as a blurry picture the moment a block touched
the window's edge.

The picture is scaled to fit inside that box and centred, with the remainder filled by the theme's
background, so the placement is a clean rectangle: nothing of the card shows at an edge, and no
dimension is stretched. PNG is written when the picture has transparency, JPEG otherwise; both
encoders come from the `image` features already compiled in.

*Alternatives:* `preserveAspectRatio=0` and the original file — the terminal would stretch the
picture into whatever cell shape it has (the popup's trade); `preserveAspectRatio=1` — the
letterbox band is transparent, and the card would show through around the picture.

### D5 — The box and the position come from the document, the shape from the window

`graphics.lua` already knows how to place a graphic over a window's interior. Inline, it needs a
sub-rectangle: the block's rows. The plugin computes them from the rendered document — the run of
display rows attributed to the reference's source line — and the columns as the widest of those
rows, so the thumbnail covers exactly the cells the artwork was laid out in. The screen origin
comes from `screenpos`, which is where the cell really is; the window's own position is not used,
for the reason the popup's border taught.

*Alternatives:* a wire field naming each image's span — the rows are derivable from the mapping
the wire already carries, and a new field would be a format change for something the plugin can
already compute.

### D6 — Place on settle, over the rows the window shows

A placement is a paint over cells, so it has to be made after the window has painted, and it is
lost to every repaint after it. The popup solved this by not moving; R cannot. The rule is
therefore: place over the block's rows that are inside the window's visible rows, and after the
viewport has stopped moving — one debounce for scrolls, resizes, re-renders and cursor motions.

That debounce is `settle_debounce` (15 ms), not the re-render's `resize_debounce` (100 ms), although
both coalesce bursts of the same events. The two waits cost the reader different things: a
re-render that is late leaves the previous document on screen, while a placement that is late leaves
a card where the picture belongs — a flicker on every scroll stop, measured as the 100 ms the shared
knob used to spend, and visible by hand. One frame is enough to fold a burst into one paint, and a
reader whose terminal struggles with the payloads — or whose scrolling over a cut block asks for a
thumbnail of every slice — raises it again.

Those rows are the window's own answer — `w0` and `w$`, not arithmetic on `topline` — because
`scrolloff` and a partly drawn last line are easy to get wrong. A block the window cuts was
originally left as its card, on the grounds that the protocol scales a picture into the box it is
given and cannot crop it: half a block would show the whole picture squeezed into the visible
half. The fix belongs in the engine, which is the only stage that decodes pixels: the thumbnail
mode takes the visible slice of the box, fits the picture into the whole box first and then cuts
those rows out, so the placement carries the same picture at the same scale, continuing above and
below the window. A file sent unchanged cannot be cut, so a cut block always goes through the
engine; the Kitty transport is handed a path and cannot crop at all, so there a partly visible
block keeps its card.

Cursor motion is in the list of triggers rather than only scrolls: with `cursorline` set, moving
the cursor repaints its row, which erases the placement at that row, and a debounced re-place
after the motion is what puts it back. The cost is one payload per pause, which D4's sizing keeps
small.

"Visible" also means "not covered". A floating window owns the cells under it, and the list of
triggers is not filtered by window — a cursor move inside the preview popup schedules the same
settle — so without this rule opening the popup on an image re-placed every inline picture on top
of it one debounce later: the terminal draws whatever it was told last, and on the OSC transport
there is one image layer for the whole tabpage. Measured by hand in WezTerm. The rule is the same
rectangle comparison `screenpos` already gives, against every float in the tabpage, borders
included; a covered block is treated exactly like a scrolled-out one, which also deletes its Kitty
placement.

A window is also not on screen while another tab page is current, and `screenpos` does not know
it: measured, a hidden window's first row comes back at the same row and column as the current
window's, because the position is computed from the layout rather than from what is displayed. A
settle that ran while another tab was current therefore painted the document's picture over that
tab — `:checkhealth` opens its own tab, and what a hand check saw was its report covered by the
picture of the page left behind. The rule follows the float's: the settle compares tab pages
before placing anything, and `TabEnter` asks for the pictures of the tab being entered, because a
tab that was not showing had no placement to keep.

*Alternatives:* re-place synchronously on every event — a payload per scroll row and per keystroke;
freeze the viewport as the popup does — R is the reading surface and must scroll; keep the artwork
underneath and let the terminal keep its paint — the same thing, with the wipe still visible.

### D7 — The card is what a failed or absent placement costs

Nothing in this design hides a failure: a file that disappears, a block the path-carrying
transport cannot crop, an encode the engine refuses, a terminal that cannot draw,
a `graphics = 'off'` — all of them leave the
card in place, which is the document's own content and needs no paint. That is why the card comes first in the task order:
it is the floor the rest of the change stands on.

### D8 — An explicit `image_mode = 'off'` keeps its alt text

A reader who set `image_mode = 'off'` — the switch that says no picture, just the text — keeps the
alt text under both `auto` and `card`: no card and no placement. `image_inline` decides how a
picture is presented, not whether the reader wants one; letting a card appear over that switch
would make the one option that opts out the one option that got overridden. `art` is the explicit
way to ask for the artwork, and `off` keeps its meaning there too.

### D9 — `auto` ends at the card on every terminal

`auto` used to mean "card on a drawing terminal, artwork elsewhere". This change makes the second
half the same as the first: the card is what an inline image is, and the terminal only decides
whether a picture is painted over it. `card` stays as the way to keep the quiet box and refuse the
paint on a terminal that could provide it, and `art` stays as the way back to character artwork.

*Alternatives:* keep artwork without graphics and only add the card where a picture exists — the
dots are precisely what this change removes, and on a terminal that can never paint them they are
neither a preview nor a placeholder; make `card` the default and drop `auto` — `auto` and `card`
would differ nowhere in what is drawn, but the difference between "paint when you can" and "never
paint" is the one a user needs to state.

### D10 — The preview key routes on the placement predicate

`<CR>` on an image opens the popup only where the same predicate that gates placement holds —
`graphics` usable, a terminal identified, no multiplexer. Elsewhere it calls the existing
open-image path, so the file goes to the system's default application with the resolution and the
reports that already exist for that key: a relative destination against the document's directory,
an absolute one as given, and a URL, `data:` URI, missing path or directory reported rather than
launched. Diagrams and tables are untouched, and `gx` is untouched.

The predicate is the transport's, not `image_inline`'s: `art` on a terminal that cannot draw still
routes to the system viewer, because the rule is about what the terminal can show, and a reader
who wants dots inline still has them in R.

*Alternatives:* open the popup everywhere and let it show the card — the popup exists to show more
than R already shows, and a card in a float is the same card, one keystroke further away; always
open the file externally — it would throw away the whole popup on a terminal that can draw it
natively; gate on `image_inline` — two answers to the same question, and `art` users would get a
popup full of dots on the terminal this change exists to stop drawing them on.

## Risks / Trade-offs

- **A visible wipe on every scroll** → wherever a picture is painted the card underneath is the
  artwork's box, so what shows during the wipe is a quiet surface with the file's name, not a dot
  matrix; the placement returns one debounce after the scroll stops.
- **A document with many images costs a spawn each** → thumbnails are requested lazily, only for
  blocks that become wholly visible and only for files over the threshold, and cached per file and
  box, so a session costs one request per distinct visible picture; the cache is bounded and
  evicts least-recently-used entries.
- **A file under the threshold is re-sent on every settle** → the threshold is a byte count, so
  the payload is bounded by it and the bytes are cached; a reader who would rather have the
  smallest payload sets it to `0` and takes the thumbnail everywhere.
- **A terminal whose cells are far from 2:1** → the picture is stretched by the same error the
  artwork carries, since both are laid out under the same assumption; a cell-metric source, if
  Neovim ever exposes one, changes D4 and nothing else.
- **OSC has no identifier on the cell-attached transport** → a placement cannot be moved or
  removed, only painted over. Nothing has to repaint it deliberately: the card is the buffer's
  content, so the next scroll or redraw restores it, and the placement is made again when the
  viewport settles.
- **`cursorline` erases the picture as the cursor moves** → a debounced re-place on cursor motion;
  a reader who types continuously sees the card.
- **`<CR>` on an image no longer previews in the editor on a non-drawing terminal** → that popup
  could only show the dots this change removes; the file opens in the system viewer instead, which
  is the behaviour the reader asked for, and the open-image key already did it. A reader who wants
  the dots back sets `image_inline = 'art'` and keeps them inline.
- **A float over a block costs it its picture** → the block keeps its card while the float is
  there, which is what the float's own content needs in order to be readable; the settle after
  the float closes paints it again, and the thumbnail came from the cache.
- **Two windows on one document** → each window places its own; a placement is screen-global, so a
  block visible in neither window keeps nothing, and a block visible in both is painted twice at
  different positions, which the protocol allows.

## Migration Plan

1. The engine: `card` in `image_art`, the header-only path for oversized files, the `thumbnail`
   subcommand, fixtures and tests. Nothing in the plugin changes yet, and no existing option
   reaches the new code, so the corpus and the wire are untouched.
2. The plugin: `image_inline`, the card in the render request for every terminal, and the render
   cache key. From here an inline image is a card, on any terminal, with or without graphics.
3. The preview key's routing, which needs only the availability predicate and the existing
   open-image path — it does not depend on a thumbnail existing.
4. The placement — cache, visibility, triggers — in `graphics.lua`, with the headless suite's
   spawn counts extended.
5. Documentation, `:checkhealth`, and the interactive suite for what a scroll does to a placement.

Rollback: `image_inline = 'art'` returns every render to the artwork without touching the engine,
and `graphics = 'off'` removes the placement path and sends the preview key to the system viewer;
reverting the plugin files undoes the key routing too, and leaves the engine's card and thumbnail
mode unused but harmless.
