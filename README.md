# markdown-rs.nvim

A markdown rendering engine and the Neovim plugin that uses it.

Opening a markdown file shows it rendered — headings in colour, tables drawn as
tables, diagrams drawn as diagrams, code highlighted. A key toggles back to the
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
  bin/md-render.exe    cross-compiled artifact, committed
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
cache keyed on the buffer, its `changedtick`, the width and the theme, which is
what makes toggling back and forth free.

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
| `<CR>` | R only | preview the block under the cursor, or close the preview |
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
  filetypes = { 'markdown' },   -- the filetypes that open in R
  keymaps = {
    toggle = '<leader>mr',
    write = '<C-s>',
    preview = '<CR>',
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
`keymaps.write` or `keymaps.preview` to `false` leaves that key alone.

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

The popup is sized to fit the block and capped at `preview.max_width_pct` and
`preview.max_height_pct` of the editor. It is an ordinary buffer — scroll it,
search it, yank from it — but not a modifiable one, and it is not listed.

`<CR>`, `q` and `Esc` close it, and the window underneath is left exactly as it
was. On anything else — prose, a non-diagram fence, a list — `<CR>` does its
ordinary job, so the key is safe to press anywhere.

The popup is a second reading of the block, not a zoom of the first: because the
layout follows the budget, it can be *arranged* differently from the window's
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

The committed `bin/md-render.exe` is a Windows build cross-compiled from Linux
against the `x86_64-pc-windows-gnu` target. See
[`docs/porting.md`](docs/porting.md) for what the plugin does when it is
missing.

### Rebuilding the committed binary

There is no Windows Rust toolchain on the development machine, so the binary is
built on a Linux host and copied back. From the repository root:

```bash
cargo build --release --target x86_64-pc-windows-gnu --bin md-render
cp target/x86_64-pc-windows-gnu/release/md-render.exe bin/md-render.exe
```

The copy is the step that matters: `bin/md-render.exe` is what the plugin
falls back to when `md-render` is not on `PATH`, and a stale copy is a plugin
that renders with an old engine. Commit the result.

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
