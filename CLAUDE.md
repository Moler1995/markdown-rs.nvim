# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Two halves joined by one data format:

- `engine/` is `md-render`, an editor-agnostic Rust binary. It reads markdown and writes a JSON document of styled display lines already laid out for a requested column width, plus the mapping between those lines and the source lines they came from.
- `lua/md-render/` is the Neovim plugin. It spawns the engine, paints the JSON into a read-only buffer, and owns all interaction (toggle, links, preview, zoom).
- `crates/mermaid-text/` and `crates/ascii-dag/` are vendored, patchable copies of published crates. The engine depends on `mermaid-text` by path; `ascii-dag` is forced in through `[patch.crates-io]` so the vendored fix is what resolves.

The engine knows nothing about Neovim; the plugin knows nothing about markdown. Keep that boundary: rendering decisions belong in Rust, buffer/window policy in Lua.

## Commands

### Build and install the engine

```bash
cargo build --release -p md-render
mkdir -p bin
cp target/release/md-render.exe bin/md-render.exe
```

PowerShell:

```powershell
cargo build --release -p md-render
New-Item -ItemType Directory -Force bin | Out-Null
Copy-Item target/release/md-render.exe bin/md-render.exe
```

`bin/` is gitignored — the copy is a local install step, not a commit. The plugin resolves the engine as: configured `engine` path (authoritative) → `md-render` on `PATH` → `<repo>/bin/md-render[.exe]` → `<stdpath('data')>/md-render/md-render[.exe]`. A `PATH` copy therefore shadows `bin/`, and nothing detects a stale binary; rebuild and copy after any engine change before running the Lua suites. `:checkhealth md-render` reports which step matched.

Cross-compiling from a machine without a Windows toolchain (needs a mingw-w64 linker):

```bash
rustup target add x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu -p md-render
```

### Rust tests

```bash
cargo test                     # every workspace member
cargo test -p md-render        # engine only
cargo test -p mermaid-text     # diagram renderer only
```

Run a single test by passing a substring, with the test target selected:

```bash
cargo test -p mermaid-text --lib fill_message_labels
cargo test -p md-render --test corpus no_fixture_emits_a_line_wider_than_the_requested_width
cargo test -p md-render --test wire_format_doc
```

Snapshots use `insta`. `.snap.new` files are gitignored; accept a deliberate change with:

```bash
INSTA_UPDATE=always cargo test -p mermaid-text --test snapshots
INSTA_UPDATE=always cargo test -p md-render --test corpus
```

Read the diff before accepting it: a snapshot move is the evidence that a rendering change did what it claimed.

### Neovim tests

```bash
MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua
nvim -l tests/interactive/run.lua
```

`MDRN_REPO` must be set for the headless suite. The interactive suite starts a real Neovim and drives it with `--remote-send`; it exists because `nvim -l` never runs the main input loop, so `nvim_feedkeys` (the insert-entry keys) is never read and `TextChanged` (the re-render trigger) never fires. Anything depending on either can only be tested there.

Editing `lua/md-render/` does not reload it in a running Neovim: Lua modules are cached in `package.loaded`, so restart the editor after a plugin change. `:MdRenderReset` clears cached renders and highlight groups only — it is not a module reload.

### Quality gates

CI (`.github/workflows/ci.yml`) runs these, and a PR is blocked on the aggregate `gate` job:

```bash
cargo fmt -p md-render -- --check
cargo clippy -p md-render --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo check --workspace --locked                      # MSRV 1.92
MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua
nvim -l tests/interactive/run.lua
nvim --headless -u NONE -c 'helptags doc' -c q && git diff --exit-code doc/tags
openspec validate --all --no-interactive
bash tools/check-readme.sh
```

The plugin job also opens `:help md-render` and calls `require('md-render.health').probe()`, failing when `report.ok` is false. `doc/tags` is committed and must be regenerated when `doc/md-render.txt` changes.

Formatting and clippy are scoped to `md-render` on purpose: `crates/mermaid-text` and `crates/ascii-dag` are vendored copies kept close to upstream, and formatting them would bury the patches they carry.

### Looking at output by hand

```bash
cargo run -p md-render -- --width 120 README.md > /tmp/out.json
python tools/show_wire.py /tmp/out.json

cargo run -p mermaid-text --bin mermaid-text -- --width 80 diagram.mmd
```

The engine writes only JSON to stdout; diagnostics go to stderr, so stdout is always parseable.

## Architecture

### The engine pipeline

```text
source ──▶ renderer ──▶ [DocBlock] ──▶ document ──▶ WireDoc ──▶ JSON
           (parse)      (structure)     (layout)     (wire)
```

- `engine/src/renderer.rs` walks pulldown-cmark events and groups them into `block::DocBlock` values. It decides *what* the document contains. A document is a sequence of blocks rather than flat lines because a table's column widths depend on every cell in the column and a diagram must be fitted as a unit.
- `engine/src/document.rs` decides *how wide* everything is. It is the only module that knows the target width, and the only place the width guarantee is enforced.
- `engine/src/wire.rs` is the normative definition of the output; `docs/md-render-format.md` is the prose contract and `engine/tests/wire_format_doc.rs` checks the two agree field for field. Change one, change the other.

### The width contract

Every emitted line fits `width`. Two mechanisms produce that:

- Prose and table cells wrap, via `wrap_spans` in `engine/src/text_layout.rs`. That module is the single source of truth for display width and wrapping; call `measure`/`wrap_spans` rather than measuring strings inline. Width is Unicode display columns, never bytes or chars — CJK and combining marks have dedicated tests.
- Diagram artwork cannot be wrapped, so `clip_to_width` drops its right edge.

`layout_width` is measured *before* clipping. The invariant the plugin relies on is exact: `layout_width > width` if and only if the engine discarded columns. A reader cannot recover dropped columns by scrolling — they are absent from `lines` — which is why the preview re-renders a block at a larger budget instead of scrolling the copy in the window.

Rendering is deterministic: same source, width and theme produce byte-identical output. Nothing in layout may depend on `HashMap` iteration order or a clock. Two vendored fixes exist precisely because hash order once made diagram layouts differ between processes; keep new layout code ordered.

### Themes and mermaid

- `engine/src/theme/` defines semantic `Tokens`, derives a flat `Palette` from them, and keeps one constructor per theme in `themes.rs`. Add a theme there, not in the token types.
- `engine/src/mermaid.rs` wraps the vendored `mermaid-text`. `MermaidTextBackend::Auto` is a narrow lexical heuristic: it picks the Native backend only for a `subgraph` containing its own `direction` line, where Sugiyama is documented to be less compact; everything else uses Sugiyama.
- The dependency set is deliberately small and is asserted by `engine/tests/dependencies.rs`: no terminal-drawing crate, no async runtime. The one decoder is `image`, added knowingly for image artwork: markdown images are decoded and drawn as character cells by `engine/src/image_art.rs`, the only stage that knows both the width and the page height. The same module draws the card — the theme's raised surface in the shape the caller asks for: three rows where no terminal paints the picture, the picture's box where one does (`--image-card-rows`, `--image-card-min-width`) — and encodes the thumbnail the plugin paints over it, through the `md-render thumbnail` subcommand. Adding any other crate means adding it to that test's allowlist, with the job it does.

### The plugin

The design is one paragraph in `lua/md-render/init.lua`: a managed window is always in one of two states, each a buffer. **R** is a scratch buffer holding the engine's output (`buftype=acwrite`, `bufhidden=wipe`, `modifiable=false`, unlisted) swapped into the window with `nvim_win_set_buf`. **S** is the file's own buffer. R is a real buffer, not conceal or virtual text, which is why every normal-mode motion, search and yank works there, and why an edit command cannot reach the source through it. The state is per window, so two windows on one file do not disturb each other.

Module responsibilities:

| Module | Owns |
| --- | --- |
| `init.lua` | autocmds, keymaps, commands, the R↔S transitions, insert-entry keys, and the settle that repaints inline pictures |
| `state.lua` | which mode each window is in; the render cache keyed on buffer, `changedtick`, width and theme |
| `engine.lua` | binary resolution, spawning, top-level JSON validation — nothing about markdown |
| `render.lua` | writing lines into R and placing one extmark per span, plus the image hint's virtual text; display↔source mapping |
| `style.lua` | interning wire styles into highlight groups named by a hash of the style, so re-renders reuse groups instead of redefining them |
| `link.lua` | resolving the link under the cursor from the *source* text (the engine drops link targets) |
| `preview.lua` | finding the block under the cursor, the float, its own render budget and the zoom ladder |
| `graphics.lua` | terminal identification, the two graphics transports, the escape sequences — every placement wrapped in a cursor save/restore, so the raw move it needs does not desync Neovim's own cursor tracking — the injectable raw-bytes sender, the thumbnail and original-file caches, the placement of pictures over their cards — cropped to the rows the window shows, where the transport carries bytes, and only a PNG where the transport carries a path — and the rule that a block a floating window covers is not painted |

Refreshes are debounced by `resize_debounce` (100 ms) because resizes and typing arrive in bursts; toggles are applied immediately so a pending refresh cannot swallow the key after a resize.

### Block preview and zoom

`<CR>` on a mermaid fence or a table re-renders that block at a budget of its own in a float. The budget rules are load-bearing:

- A diagram is laid out at the engine's maximum budget, because any narrower budget may clip it.
- A table is laid out at the popup's inner width floored at the window's, because tables wrap rather than clip.

`-` re-renders the popup's inner width; if the engine reports that the result is still clipped, it re-renders at that reported `layout_width` (the narrowest whole layout) and adopts it only if whole and actually narrower. `+` restores the maximum budget. The popup records which rung it is on (`'natural'`, `'fits'`, `'floor'`) so a spent key returns without spawning a process. A cropped layout is never shown by a zoom. `<C-h>`/`<C-l>` scroll sideways by the horizontal step of the user's `'mousescroll'`.

## Testing conventions

- The engine corpus is directory-driven: every `.md` file in `engine/tests/fixtures/` is snapshotted at 80 columns and swept at widths 20/40/80/120. Adding a fixture is adding a file.
- `crates/mermaid-text/tests/strict_max_width.rs` is a property test over diagram types; `snapshots.rs` pins diagram geometry.
- `tests/headless/run.lua` is the main plugin suite, in numbered sections, with fixtures in `tests/fixtures/`. It counts engine spawns in some sections, so a change that adds a redundant spawn fails a check.
- Verify plugin changes against a freshly built `bin/md-render.exe`; both Lua suites exercise the real binary.

## Repository conventions

- Every ported file begins with `//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.` followed by a paragraph on what was removed and why. The absence of that header is the marker for new code. Ports are one-time lifts; there is no upstream tracking.
- The vendored crates are patchable on purpose. `crates/ascii-dag/VENDORED.md` records the backport it carries; `mermaid-text` carries a determinism fix and a fill change (no `░▒▓` shade blocks — they make full-screen repaints crawl). Re-vendoring means reapplying those, not taking the next release.
- Rust is edition 2024, `rust-version = "1.92"`.
