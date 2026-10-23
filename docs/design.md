# How md-render.nvim is put together

This is the reasoning behind the plugin's structure. The user-facing reference
is `:help md-render`; the wire format is described in
[`md-render-format.md`](md-render-format.md).

## The engine/plugin boundary

Two halves are joined by one data format:

- `engine/` is `md-render`, an editor-agnostic Rust binary. It reads markdown
  and writes a JSON document of styled display lines already laid out for a
  requested column width, plus the mapping between those lines and the source
  lines they came from.
- `lua/md-render/` is the Neovim plugin. It spawns the engine, paints the JSON
  into a read-only buffer, and owns all interaction (toggle, links, preview,
  zoom).

The engine knows nothing about Neovim; the plugin knows nothing about markdown.
Every rendering decision belongs in Rust, and every buffer and window policy
belongs in Lua. That is what makes the engine testable without an editor and
the plugin a consumer rather than a component.

When the engine is missing, the plugin does not render. It leaves the buffer as
source and reports where it looked. A partial render, or a placeholder that is
not the document, would be worse than showing the document.

## The two states

A managed window is always in one of two states, and each state is a buffer:

```text
   R - rendered                          S - source
   +-----------------------------+       +-----------------------------+
   |  # Heading                  |       |  # Heading                  |
   |  ----------                 |       |                             |
   |  prose, laid out to the     |       |  prose, as it is written    |
   |  window's width             |       |                             |
   +-----------------------------+       +-----------------------------+
   | a scratch buffer holding    |       | the file's own buffer       |
   | what the engine produced    |       |                             |
   | buftype=acwrite             |       | editable, as usual          |
   | bufhidden=wipe              |       |                             |
   | modifiable=false            |       |                             |
   | buflisted=false             |       |                             |
   +-----------------------------+       +-----------------------------+
```

R is a view, not a second document. Its buffer is named after the source so
that a write can be routed back, unlisted so it stays out of `:ls` and
`:bnext`, unmodifiable so that an edit command cannot corrupt what is on
screen, and wiped when hidden so that returning to S leaves nothing behind.
The source buffer is untouched throughout — it is simply not the buffer in the
window.

R is a real buffer rather than conceal or virtual text, which is why every
normal-mode motion, search and yank works in it, and why an edit command cannot
reach the source through it.

The state is per window, not per buffer. Two windows on one file each get their
own rendered buffer, so one window returning to S cannot disturb the other.

The six insert-entry keys (`i`, `a`, `I`, `A`, `o`, `O`) are how R gets out of
the way. Each puts the source back in the window with the cursor on the source
line the display line came from, and then hands the key to Vim, so that `A` in
R inserts at the end of that source line exactly as `A` does in any other
buffer. They are fixed rather than configurable because they are the mode's
escape hatch, not a convenience. `Esc` is deliberately not one of them: leaving
insert mode is Vim's business, and a view that came back on `Esc` would be a
view you could not edit in.

## Staying in step

R is remade when the window's width changes and when the source buffer changes,
and it is remade from the buffer rather than from the file — so an edit made in
S and not yet written is what the next render shows. Nothing is remade while R
is off screen, and a render of a document that has not moved is answered from a
cache keyed on the buffer, its `changedtick`, the page's width and height, the
image encoding, the theme and whether animation frames were asked for, which is
what makes toggling back and forth free.

The page size is part of the key because an image has to fit the window showing
it; an image-free document renders the same at any height, but the plugin
cannot know that before the engine has answered.

Both kinds of change arrive in bursts — a drag-resize is one event per column,
typing is one per keystroke — so the render is deferred by `resize_debounce`
milliseconds and a burst costs one render. The deferral covers refreshes only:
a toggle is applied at once, so a resize cannot swallow the key that follows
it.

`setup()` and the startup file both attach the markdown buffer already in the
window. A package manager that loads the plugin from `FileType` — lazy.nvim's
`ft` is the usual case — sources it after `FileType` and `BufWinEnter` have
already fired; without that attach, the first buffer would stay in S until it
was reopened.

## Following links

`gf` opens whatever is under the cursor. It and `gF` are the keys besides the
toggle and the write key that are set in both states, because a link is worth
following from wherever you are reading:

- a **file** opens in the window, resolved relative to the document holding the
  link rather than to the working directory; an absolute destination — a POSIX
  path, a drive path in either slash style, or a UNC share — is used as given;
- a **URL** goes to `vim.ui.open`, which is the desktop's browser by default;
- an **anchor** — `#section`, on its own or after a path — scrolls to the
  heading it names, in this document or in the one just opened.

`gF` does the same but opens a **file** in a new tab, leaving the reading view
in the window it was in. A URL or an anchor still acts in place, since neither
is a file that could go in a tab, and a target the plugin does not manage — a
`.txt`, say — opens unchanged. No jumplist entry is recorded: the way back is
closing the tab, with `:tabclose` or `g<Tab>`.

A rendered diagram can carry links of its own: a mermaid `click NODE href "…"`
directive names a target for a node, and with the cursor on that node's label
the same key follows it. The engine reports the label's byte range along with
the artwork, so the node is followable without leaving the reading view and
without the plugin re-parsing the fence. The label is underlined in R so the
target is visible rather than guessed at; the hint is tied to the follow keys,
since with none bound an underline would advertise nothing. It is the
`MdRenderLink` highlight group and sets only `underline`, so a theme can
restyle it without touching the artwork's colours. The preview popup does not
bind the key, so it shows the diagram without the hint.

For everything else the plugin reads the source, never the rendered text. In R
the display row is first mapped back to the source line it came from — the same
step the toggle makes — and the link is read from there. That is what makes it
work from the reading view without crossing to S first. The engine never has to
carry link targets, which is why its wire format does not.

Following a file records the source line it was followed from, so `<C-o>` comes
back to that document and the plugin renders it again instead of leaving the
window on source. The record is a real jump-list entry rather than a side
effect of swapping buffers: the plugin's own R↔S swaps are `keepjumps`, so a
toggle cannot push a stray entry between the reader and where they came from.

The forms it resolves are the ones a cursor actually lands on: inline
`[text](target)` and `![alt](target)`, reference `[text][ref]` with the
definition anywhere in the buffer, `[text][]` and shortcut `[text]`, autolinks
`<https://…>`, and bare URLs. A destination's `"title"` and its `<…>` quoting
are stripped, and a link inside a code span or behind a backslash is text about
a link rather than a link.

When the cursor is not on a link the key goes back to Vim, so a path written as
plain text still opens the way `gf` always did.

## Images

A markdown image is drawn in R as character-cell artwork: the engine reads the
file named by the reference, averages its pixels down to the cells the page has
room for, and colours each cell from the palette the options ask for. PNG,
JPEG, GIF, WebP, BMP, TIFF and ICO are supported.

An animated GIF or WebP is drawn on its first frame and stays there. `<C-n>` on
the artwork advances it one frame, wrapping from the last frame back to the
first; the frames are fetched the first time the key is pressed on that image,
so a document that is never stepped through never pays for decoding them. The
cursor does not move, the artwork keeps its rows, and the key goes back to Vim
when the cursor is not on an animated image. Set `image_animation = false` to
turn the whole thing off. Decoding frames can take a second or two, so while
the fetch is in flight the bottom of the editor says so; pressing `<C-n>` again
in that window does not start a second fetch — the presses are remembered and
the image advances one frame for each of them when the frames arrive.

An animation longer than 256 frames is not refused: it is sampled down to at
most 256 evenly spaced frames that start at the image's first, and each kept
frame carries the delay of the frames it stands for, so the loop still takes as
long as the file says. A very long animation is still bounded by decode work,
though: one that decodes more than 4,096 frames or more than the engine's pixel
budget is refused, drawn on its first frame, and pressing `<C-n>` on it warns
that it is too large to animate instead of moving the cursor. The warning is
given once per render, so pressing again neither re-renders nor repeats it. The
popup warns on open in the same way.

`<CR>` on the artwork opens the image alone in a popup, and there it plays: one
one-shot timer is restarted with each frame's own delay, and the animation
loops until the popup is closed. A frame whose delay is under 20 ms is shown
for 100 ms, the floor browsers use, so a GIF encoded "as fast as possible"
cannot turn into a redraw loop. `Space` pauses and resumes from the frame on
screen, `<C-n>` steps one frame while paused, and closing the popup stops the
timer — as does anything that re-renders what it is showing. A still image's
popup binds neither key and creates no timer.

`gx` on an image — on its artwork, or on its alt text when the engine cannot
draw it — opens the referenced file with the operating system's default
application. A relative destination resolves against the document's directory,
as it does in the engine. A remote URL, a `data:` URI or a missing file is
reported rather than fetched or launched, and the key goes back to Vim when the
cursor is not on an image.

The picture is fitted to the window twice over — to the text width, and to the
text height or `image_max_height` when that is smaller — and is not enlarged
unless `image_min_rows` asks for it. `image_max_height` defaults to 20 display
rows, so a figure sits inside the page rather than filling it; because the
aspect ratio is preserved, the cap narrows the artwork too. Set it to `false`
to let an image use the whole page again. A picture smaller than both bounds
keeps its natural size. The preview popup is not capped: `<CR>` shows the
image at the popup's own size. Resizing the window redraws the inline artwork
at the new size.

Relative destinations resolve against the directory of the document holding the
reference, so `![](images/a.png)` means what it means everywhere else. Absolute
paths work too. A URL or `data:` URI is never fetched and is not something the
engine will draw. An image that cannot be drawn — missing file, unsupported
format, one over the engine's limits — falls back to its alt text, the rest of
the document renders normally, and nothing is reported: a picture the reader
cannot see is not an error in the document.

Images inside a table cell or a heading stay as alt text. Those constructs hold
inline text rather than blocks, so there is nowhere to put a picture without
changing the table's or heading's own layout.

`image_mode` chooses the drawing: `auto` picks braille with `'termguicolors'`
and ASCII without; `braille` draws eight dots in a 2×4 grid with one colour per
cell; `quads` and `blocks` use quadrant and half-block glyphs with two colours
per cell; `ascii` uses a luminance ramp; and `off` shows alt text. Braille dots
are ink on the page they sit on, so on a dark background the bright side of a
picture is drawn and a white screenshot becomes light dots with its own dark
features left as gaps; on a light background the dark side is drawn instead.
That page is the editor's own `Normal` background. The palette, background,
dithering, minimum-size and sharpening options sit on top of the encoding; see
`:help md-render-options`.

## The block preview

The engine lays a diagram or a table out against the window's column budget and
**clips what does not fit**. The characters that clip drops are not in the
rendered buffer at all, so scrolling sideways cannot recover them: in a narrow
window the right-hand side of a wide diagram does not exist.

`<CR>` on a ` ```mermaid ` fence or a table opens a centred popup showing that
block **re-rendered at a budget of its own**, which is what brings the clipped
columns back. The budget depends on what the engine does with a block that does
not fit:

- A **diagram** is laid out at the largest budget the engine accepts, so
  nothing is clipped. The engine discards the columns a diagram overflows by,
  and discarded columns are not in the buffer for scrolling to reach, so any
  smaller budget could lose the right-hand end of one.
- A **table** is laid out at the popup's own width, never narrower than the
  window's. The engine wraps a cell that does not fit rather than dropping it,
  so a table loses nothing at any budget, and a larger one would only spread
  its columns out.

A diagram's width is not a fact about it, though. The engine re-lays one out
against the budget it is given — narrowing the gaps, and wrapping node and
message labels — and only clips what is still too wide after that. So asking
for a smaller budget buys a narrower diagram, at the price of a taller one.

`+` and `-` in the popup make that choice. They re-lay the diagram out at
another budget and replace the popup's content in place; the window does not
move, so the diagram on screen never shifts under the cursor.

- `-` asks for the popup's own inner width, which is the most the popup can
  show at once.
- `+` asks for the largest budget again, restoring the layout the popup opened
  with.

Neither key ever shows a diagram with columns missing. Where the engine cannot
lay one out whole within the popup it lays it out at the narrowest budget at
which it *can* lay it whole, so a diagram still too wide to fit without
scrolling is nonetheless narrower than it opened, and whole.

That is the whole ladder — the natural width, the popup's inner width, and that
narrowest whole layout — so one press spends one of the two keys and leaves the
other. Where the diagram is already at the narrowest layout, or already fits,
`-` does nothing; once it is zoomed out, `+` is the live key. A key with
nothing to ask for returns without reaching the engine, so holding it down
costs nothing. Once the diagram is narrower than it opened, the popup's title
says by how much — the width it is laid out at, then the width it opened with.

In a table's popup the keys are bound and do nothing: the engine wraps a
table's cells rather than discarding them, so a table has nothing to zoom away
from, and a smaller budget would only make it harder to read.

`<C-l>` and `<C-h>` scroll the popup sideways, a step per press, and can be
held down. Vim's own sideways scrolling is `zl` and `zh` — two keystrokes
each, so there is no key to hold, and crossing a block wider than the popup
means alternating `z` and `l` by hand. These are one key each, so holding one
keeps the view moving. The step is the horizontal step of your own
`'mousescroll'` (6 columns by default), so the keys and a tilt wheel move the
view by the same amount.

Unlike the zoom keys, these do something in a table's popup too: a table is
laid out at the popup's inner width floored at the window's, so it can be wider
than the popup as well, and its columns past the edge are reached the same way.

`<C-l>` is one of Neovim's own mappings — `nohlsearch`, then a redraw — and in
the popup it is taken for scrolling. The mapping is buffer-local, so R and S
keep theirs, and `:nohlsearch` still works from the command line.

The popup is sized to fit the block and capped at `preview.max_width_pct` and
`preview.max_height_pct` of the editor. It is an ordinary buffer — scroll it,
search it, yank from it — but not a modifiable one, and it is not listed.
Zooming changes its content, never its frame, which is why a zoomed-out diagram
has dead space to its right.

`<CR>`, `q` and `Esc` close it, and the window underneath is left exactly as
it was. On anything else — prose, a non-diagram fence, a list — `<CR>` does its
ordinary job, so the key is safe to press anywhere.

The popup is a second reading of the block, not a magnifier of the first:
because the layout follows the budget, it can be *arranged* differently from
the window's copy. What it guarantees is that the whole block is there.

## The vendored crates

`crates/mermaid-text/` is the published `mermaid-text` 0.57.4, and
`crates/ascii-dag/` is the published `ascii-dag` 0.9.1 — the layout engine
`mermaid-text`'s Sugiyama backend is built on. Both are vendored to be
patchable, and both carry a fix that could not be taken from a release:

- **`mermaid-text`** — two changes. A `direction TB` subgraph inside an `LR`
  graph had its band ordered by `HashMap` iteration, so the same diagram laid
  out differently from one process to the next. And the renderer no longer
  fills cells with a Unicode shade block (`░▒▓`, U+2591-93): a `rect` block
  uses the ASCII ladder `.`/`:`/`#`, a gantt bar's empty cells and a pie bar's
  unfilled cells use `.`, and a sequence block interior is simply left blank.
  The shade blocks are dithered patterns, and a full-screen repaint of them
  costs far more than one of solid or ASCII glyphs at the same ink coverage —
  a diagram whose block interiors were all `░` made scrolling crawl in the
  editor, while the same cells blank or filled with `.` scroll smoothly. Only
  the fill changed: for a document that uses no `rect` block the output is
  byte-identical once the retired fill is mapped back to a space.
- **`ascii-dag`** — a level's subgraph blocks were ordered the same way, with
  the same result. Upstream fixed it in 0.10.1, but that release also rewrites
  the renderer and the layout API; the one function's fix is backported
  instead, with upstream's regression test. See
  [`crates/ascii-dag/VENDORED.md`](../crates/ascii-dag/VENDORED.md).

The engine's spec calls for byte-identical output for identical input, and a
per-process hash seed defeats a same-process determinism test: two renders
inside one test binary share a seed and agree. Both defects were found by
hashing separate runs of the same file.

Re-vendoring means reapplying these changes, not taking the next release
wholesale.

## Provenance and port headers

The rendering pipeline was ported from
[`markdown-reader`](https://github.com/leboiko/markdown-reader) at revision
`4f0f635` (2026-10-14), MIT licensed. See [`NOTICE`](../NOTICE) for the full
notice.

Every ported file begins with a line naming its origin:

```rust
//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
```

Where a module also carries an origin copyright notice, that notice is kept
verbatim below the header. Modules written for this repository have no such
header — its absence is the marker for "new code".

Files that were ported carry a second paragraph explaining what was removed and
why. A port is not a copy: the origin's types served the origin's interaction
model, and re-expressing the code against this crate's own types is what makes
it a library rather than a transplanted application. Where behaviour changed
deliberately, the change is stated in the header.

The port is a one-time lift. There is no upstream tracking.
