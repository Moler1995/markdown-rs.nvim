# markdown-rs.nvim

A markdown rendering engine and the Neovim plugin that uses it.

Opening a markdown file shows it rendered — headings in colour, tables drawn as
tables, diagrams drawn as diagrams, images drawn as character-cell artwork, code
highlighted. A key toggles back to the
source, which is an ordinary editable buffer. The engine does the rendering;
the plugin decides when to call it and where the result goes.

```text
D:\projects\rust\markdown-rs.nvim\
  Cargo.toml           workspace
  engine/              the md-render crate
  crates/mermaid-text/ vendored diagram renderer
  crates/ascii-dag/    vendored layout engine, one fix backported
  lua/md-render/       the plugin
  plugin/md-render.lua entry point
  bin/md-render.exe    engine binary, built locally — not in the repository
  docs/                the wire format, and porting notes
```

## The engine

`engine/` builds `md-render`, a program that reads markdown and writes JSON to
stdout:

```bash
md-render --width 120 --theme nord README.md
md-render --width 120 < README.md
```

The width is required — the engine lays tables and diagrams out against a
column budget, so there is no sensible default. The output is described in
[`docs/md-render-format.md`](docs/md-render-format.md): styled display lines
sized to the requested width, plus the mapping between those lines and the
source lines they came from.

The engine knows nothing about Neovim. It takes text and a width and returns
data. That is what makes it testable without an editor, and what makes the
plugin a consumer rather than a component.

## The plugin

`lua/md-render/` is a Neovim plugin. It renders through the engine binary,
shows the result in a read-only buffer in the same window, and toggles back to
the source on request. Put the repository on `runtimepath` and markdown files
open rendered.

### The two states

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

R is a view, not a second document. Its buffer is named after the source so that
a write can be routed back, unlisted so it stays out of `:ls` and `:bnext`,
unmodifiable so that an edit command cannot corrupt what is on screen, and wiped
when hidden so that returning to S leaves nothing behind. The source buffer is
untouched throughout — it is simply not the buffer in the window.

The state is per window, not per buffer. Two windows on one file each get their
own rendered buffer, so one window returning to S cannot disturb the other.

### Staying in step

R is remade when the window's width changes and when the source buffer changes,
and it is remade from the buffer rather than from the file — so an edit made in S
and not yet written is what the next render shows. Nothing is remade while R is
off screen, and a render of a document that has not moved is answered from a
cache keyed on the buffer, its `changedtick`, the page's width and height, the
image encoding, the theme and whether animation frames were asked for, which is
what makes toggling back and forth free.
The page size is part of the key because an image has to fit the window showing
it; an image-free document renders the same at any height, but the plugin cannot
know that before the engine has answered.

Both kinds of change arrive in bursts — a drag-resize is one event per column,
typing is one per keystroke — so the render is deferred by `resize_debounce`
milliseconds and a burst costs one render. The deferral covers refreshes only: a
toggle is applied at once, so a resize cannot swallow the key that follows it.

### Keymaps

<!-- keymaps -->

| Key | Where | Does |
| --- | --- | --- |
| `<leader>mr` | R and S | swap between the rendered view and the source |
| `<C-s>` | R and S | write the source buffer |
| `gf` | R and S | follow the link under the cursor |
| `gx` | R only | open the image under the cursor with the system application |
| `<C-n>` | R and the animation popup | show the next frame of the animated image under the cursor; step one frame in the popup while paused |
| `<CR>` | R only | preview the block or image under the cursor, or close the preview |
| `i` | R only | cross to S and insert before the cursor |
| `a` | R only | cross to S and insert after the cursor |
| `I` | R only | cross to S and insert at the first non-blank |
| `A` | R only | cross to S and insert at the end of the line |
| `o` | R only | cross to S and open a line below |
| `O` | R only | cross to S and open a line above |

The six insert-entry keys are how R gets out of the way. Each puts the source
back in the window with the cursor on the source line the display line came
from, and then hands the key to Vim, so that `A` in R inserts at the end of that
source line exactly as `A` does in any other buffer. They are not configurable:
they are the mode's way out, not a convenience.

`Esc` is deliberately not one of them. Leaving insert mode is Vim's business,
and a view that came back on `Esc` would be a view you could not edit in.

The toggle crosses in normal mode, on the source line the display line came
from, so the two states read as one document rather than two.

### Following links

`gf` opens whatever is under the cursor. It is the one key besides the toggle
and the write key that is set in both states, because a link is worth following
from wherever you are reading:

- a **file** opens in the window, resolved relative to the document holding the
  link rather than to the working directory;
- a **URL** goes to `vim.ui.open`, which is the desktop's browser by default;
- an **anchor** — `#section`, on its own or after a path — scrolls to the
  heading it names, in this document or in the one just opened.

It reads the source, never the rendered text. The engine drops link targets, so
in R the display row is first mapped back to the source line it came from —
the same step the toggle makes — and the link is read from there. That is what
makes it work from the reading view without crossing to S first.

The forms it resolves are the ones a cursor actually lands on: inline
`[text](target)` and `![alt](target)`, reference `[text][ref]` with the
definition anywhere in the buffer, `[text][]` and shortcut `[text]`, autolinks
`<https://…>`, and bare URLs. A destination's `"title"` and its `<…>` quoting
are stripped, and a link inside a code span or behind a backslash is text about
a link rather than a link.

When the cursor is not on a link the key goes back to Vim, so a path written as
plain text still opens the way `gf` always did.

### Images

A markdown image is drawn in R as character-cell artwork: the engine reads the
file named by the reference, averages its pixels down to the cells the page has
room for, and colours each cell from a fixed sixty-four-colour palette. PNG, JPEG,
GIF, WebP, BMP, TIFF and ICO are supported.

An animated GIF or WebP is drawn on its first frame and stays there. `<C-n>` on
the artwork advances it one frame, wrapping from the last frame back to the
first; the frames are fetched the first time the key is pressed on that image,
so a document that is never stepped through never pays for decoding them. The
cursor does not move, the artwork keeps its rows, and the key goes back to Vim
when the cursor is not on an animated image. Set `image_animation = false` to
turn the whole thing off. Decoding frames can take a second or two, so while the
fetch is in flight the bottom of the editor says so; pressing `<C-n>` again in
that window does not start a second fetch — the presses are remembered and the
image advances one frame for each of them when the frames arrive.

An animation is refused when it has more than 256 frames or more than 64 million
decoded pixels in total; the image is then drawn on its first frame, and pressing
`<C-n>` on it warns that it is too large to animate instead of moving the cursor.
The warning is given once per render, so pressing again neither re-renders nor
repeats it. The popup warns on open in the same way.

`<CR>` on the artwork opens the image alone in a popup, and there it plays: one
one-shot timer is restarted with each frame's own delay, and the animation loops
until the popup is closed. A frame whose delay is under 20 ms is shown for 100 ms,
the floor browsers use, so a GIF encoded "as fast as possible" cannot turn into a
redraw loop. `Space` pauses and resumes from the frame on screen, `<C-n>` steps
one frame while paused, and closing the popup stops the timer — as does anything
that re-renders what it is showing. A still image's popup binds neither key and
creates no timer.

`gx` on an image — on its artwork, or on its alt text when the engine cannot
draw it — opens the referenced file with the operating system's default
application. A relative destination resolves against the document's directory,
as it does in the engine. A remote URL, a `data:` URI or a missing file is
reported rather than fetched or launched, and the key goes back to Vim when the
cursor is not on an image.

The picture is fitted to the window twice over — to the text width, and to the
text height or `image_max_height` when that is smaller — and is never enlarged.
`image_max_height` defaults to 20 display rows, so a figure sits inside the page
rather than filling it; because the aspect ratio is preserved, the cap narrows
the artwork too. Set it to `false` to let an image use the whole page again. A
picture smaller than both bounds keeps its natural size. The preview popup is
not capped: `<CR>` shows the image at the popup's own size. Resizing the window
redraws the inline artwork at the new size.

`image_mode` chooses the drawing:

- `auto` (the default) uses quadrant blocks — `▘▝▖▗`, four sub-cells in two
  colours — when `'termguicolors'` is on, and the ASCII ramp otherwise;
- `quads` always uses quadrant blocks, twice the horizontal detail of half
  blocks; it needs a font with the block elements (Cascadia Mono, the Windows
  Terminal default, has them);
- `blocks` uses half blocks — `▀`, two colours per cell — for a font without
  quadrants;
- `ascii` uses one ASCII character per cell, coloured from the same palette, so
  it works in a terminal without true colour;
- `off` draws no artwork at all and shows each reference's alt text, which is
  exactly what the plugin did before images were supported.

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

### Commands

| Command | Does |
| --- | --- |
| `:MdRenderToggle` | what the toggle mapping does, for when there is no key to press |
| `:MdRenderShow` | show R |
| `:MdRenderSource` | show S |
| `:MdRenderReset` | forget every cached render and highlight group |

### Config

```lua
require('md-render').setup({
  engine = nil,                 -- nil resolves to `md-render` on PATH, then
                                -- <repo>/bin/md-render.exe
  theme = 'catppuccin_mocha',   -- passed to the engine as --theme
  image_mode = 'auto',          -- 'auto' | 'quads' | 'blocks' | 'ascii' | 'off'
  image_max_height = 20,        -- display rows one inline image may occupy;
                                -- false lets it fill the page again
  image_animation = true,       -- fetch an animated image's frames on demand
  filetypes = { 'markdown' },   -- the filetypes that open in R
  keymaps = {
    toggle = '<leader>mr',
    write = '<C-s>',
    preview = '<CR>',
    follow = 'gf',
    open_image = 'gx',            -- in R, on an image
    frame_next = '<C-n>',         -- in R and in the animation popup
    pause = '<Space>',            -- in the animation popup, while it plays
    zoom_in = '+',                -- in the preview popup, on a diagram
    zoom_out = '-',
    scroll_left = '<C-h>',        -- in the preview popup, on any block
    scroll_right = '<C-l>',
  },
  preview = {                   -- the popup's caps, as fractions of the editor
    max_width_pct = 0.9,
    max_height_pct = 0.9,
  },
  resize_debounce = 100,        -- milliseconds to coalesce stale-R events:
                                -- resizes and edits. Toggles are not delayed.
})
```

Every field is optional and the merge is deep, so `setup{ keymaps = { toggle =
'gm' } }` keeps the write key. A filetype that is not listed is left alone
entirely: no state, no autocmds, no keymaps. Setting `keymaps.toggle`,
`keymaps.write`, `keymaps.preview`, `keymaps.follow`, `keymaps.open_image`,
`keymaps.frame_next` or `keymaps.pause` to `false` leaves that key alone, and so
do `keymaps.zoom_in`, `keymaps.zoom_out`, `keymaps.scroll_left` and
`keymaps.scroll_right`.

The four preview keys are set in the popup's own buffer rather than in R or S,
because they act on the block the popup is showing. They are deliberately not in
the keymap table above: that table describes R and S, and these keys belong to
neither.

### The block preview

The engine lays a diagram or a table out against the window's column budget and
**clips what does not fit**. The characters that clip drops are not in the
rendered buffer at all, so scrolling sideways cannot recover them: in a narrow
window the right-hand side of a wide diagram does not exist.

`<CR>` on a ` ```mermaid ` fence or a table opens a centred popup showing that
block **re-rendered at a budget of its own**, which is what brings the clipped
columns back. The budget depends on what the engine does with a block that does
not fit:

- A **diagram** is laid out at the largest budget the engine accepts, so nothing
  is clipped. The engine discards the columns a diagram overflows by, and
  discarded columns are not in the buffer for scrolling to reach, so any smaller
  budget could lose the right-hand end of one.
- A **table** is laid out at the popup's own width, never narrower than the
  window's. The engine wraps a cell that does not fit rather than dropping it, so
  a table loses nothing at any budget, and a larger one would only spread its
  columns out.

A diagram's width is not a fact about it, though. The engine re-lays one out
against the budget it is given — narrowing the gaps, and wrapping node and
message labels — and only clips what is still too wide after that. So asking for
a smaller budget buys a narrower diagram, at the price of a taller one.

`+` and `-` in the popup make that choice. They re-lay the diagram out at
another budget and replace the popup's content in place; the window does not
move, so the diagram on screen never shifts under the cursor.

- `-` asks for the popup's own inner width, which is the most the popup can show
  at once.
- `+` asks for the largest budget again, restoring the layout the popup opened
  with.

Neither key ever shows a diagram with columns missing. Where the engine cannot
lay one out whole within the popup it lays it out at the narrowest budget at
which it *can* lay it whole, so a diagram still too wide to fit without
scrolling is nonetheless narrower than it opened, and whole.

That is the whole ladder — the natural width, the popup's inner width, and that
narrowest whole layout — so one press spends one of the two keys and leaves the
other. Where the diagram is already at the narrowest layout, or already fits, `-`
does nothing; once it is zoomed out, `+` is the live key. A key with nothing to
ask for returns without reaching the engine, so holding it down costs nothing.
Once the diagram is narrower than it opened, the popup's title says by how much —
the width it is laid out at, then the width it opened with.

In a table's popup the keys are bound and do nothing: the engine wraps a table's
cells rather than discarding them, so a table has nothing to zoom away from, and
a smaller budget would only make it harder to read.

`<C-l>` and `<C-h>` scroll the popup sideways, a step per press, and can be held
down. Vim's own sideways scrolling is `zl` and `zh` — two keystrokes each, so
there is no key to hold, and crossing a block wider than the popup means
alternating `z` and `l` by hand. These are one key each, so holding one keeps the
view moving. The step is the horizontal step of your own `'mousescroll'` (6
columns by default), so the keys and a tilt wheel move the view by the same
amount.

Unlike the zoom keys, these do something in a table's popup too: a table is laid
out at the popup's inner width floored at the window's, so it can be wider than
the popup as well, and its columns past the edge are reached the same way.

`<C-l>` is one of Neovim's own mappings — `nohlsearch`, then a redraw — and in
the popup it is taken for scrolling. The mapping is buffer-local, so R and S keep
theirs, and `:nohlsearch` still works from the command line.

The popup is sized to fit the block and capped at `preview.max_width_pct` and
`preview.max_height_pct` of the editor. It is an ordinary buffer — scroll it,
search it, yank from it — but not a modifiable one, and it is not listed. Zooming
changes its content, never its frame, which is why a zoomed-out diagram has dead
space to its right.

`<CR>`, `q` and `Esc` close it, and the window underneath is left exactly as it
was. On anything else — prose, a non-diagram fence, a list — `<CR>` does its
ordinary job, so the key is safe to press anywhere.

The popup is a second reading of the block, not a magnifier of the first: because
the layout follows the budget, it can be *arranged* differently from the window's
copy. What it guarantees is that the whole block is there.

### Tests

```bash
MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua
nvim -l tests/interactive/run.lua
```

The headless runner drives the plugin directly, and is where most of it is
checked. The interactive runner starts a real Neovim, sends keys with
`--remote-send`, and reads back what that server observed.

Two things can only be checked there, both for the same reason: `nvim -l` never
runs the main input loop. The six insert-entry keys hand the key back to Vim
through `nvim_feedkeys`, and only that loop reads a key queued that way. And
`TextChanged` — the event the plugin re-renders on — is raised from that loop's
own change handling, so under `nvim -l` no edit route raises it at all, not
`nvim_buf_set_lines`, not `:normal!`, not `nvim_input`.

## Building

The workspace builds with a stock Rust toolchain:

```bash
cargo build --release -p md-render
cargo test
```

`bin/md-render.exe` is not in the repository — it is a build artifact. A clone
has to produce it once before the plugin will render anything. See
[`docs/porting.md`](docs/porting.md) for what the plugin does when it is
missing.

### Installing the engine binary

From the repository root:

```bash
cargo build --release -p md-render
cp target/release/md-render.exe bin/md-render.exe
```

`bin/md-render.exe` is the first place the plugin looks, after
`g:md_render_binary`, so the copy is the step that matters. It used to be
committed, because the plugin cannot build Rust and a Windows user without a
toolchain had no way to produce it; it is built locally now, which is one
command and keeps a 4.6 MB artifact out of the history.

The binary was cross-compiled from Linux against `x86_64-pc-windows-gnu` when
that was the only route. A native GNU toolchain builds it directly — check
`rustc -vV`'s `host` for `x86_64-pc-windows-gnu` — and the cross-compile is
only needed from a machine that has no Windows toolchain of its own:

```bash
rustup target add x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu -p md-render
cp target/x86_64-pc-windows-gnu/release/md-render.exe bin/md-render.exe
```

## Provenance

The rendering pipeline — markdown parsing, table layout, syntax highlighting,
LaTeX-to-Unicode conversion, and diagram text rendering — was ported from
[`markdown-reader`](https://github.com/leboiko/markdown-reader), a terminal
markdown reader, at revision `4f0f635` (2026-10-14), MIT licensed,
© leboiko.

It was ported rather than depended on. `markdown-reader` is a complete
application: it owns a terminal, negotiates graphics protocols, and carries a
dependency set for all of that. An engine that turns markdown into styled lines
needs none of it, and linking it would make this crate heavy, slow to build,
and impossible to publish on its own. The port takes the parts that render
text and leaves the application behind.

The two copies are not kept in step. The port is a one-time lift; there is no
upstream tracking.

### The vendored crates

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
  [`crates/ascii-dag/VENDORED.md`](crates/ascii-dag/VENDORED.md).

The engine's spec calls for byte-identical output for identical input, and a
per-process hash seed defeats a same-process determinism test: two renders
inside one test binary share a seed and agree. Both defects were found by
hashing separate runs of the same file.

### The port-header convention

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

## License

MIT. See [`LICENSE`](LICENSE).
