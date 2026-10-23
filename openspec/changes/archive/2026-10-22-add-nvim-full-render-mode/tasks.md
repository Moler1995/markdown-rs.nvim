# Tasks

Porting convention for every task in groups 2 and 3: the file carries a header naming its origin
(`markdown-reader`, revision `4f0f635`, 2026-10-14) and keeps the original MIT copyright notice.
"Port" means the logic is carried over and re-expressed against the engine's own types — no ratatui
type may appear in the engine.

## 1. Repository scaffold

- [x] 1.1 Create `D:\projects\rust\markdown-rs.nvim`: a Cargo workspace (`members = ["engine", "crates/mermaid-text"]`), an `engine` crate whose `[[bin]]` is `md-render`, and the plugin directories `lua/md-render/` and `plugin/`, plus `bin/`, `docs/`, `LICENSE`, `README.md` and `.gitignore`. Run `git init` with no remote. Verify `cargo build` succeeds on the VM (`ssh -i "$env:USERPROFILE\.ssh\id_rsa_linux" root@192.168.224.134`) and the repository has one initial commit.
- [x] 1.2 Declare the engine's dependencies — `pulldown-cmark`, `syntect`, `unicode-width`, `serde`, `serde_json`, `clap`, and the vendored `mermaid-text`. Verify `cargo tree` lists none of `ratatui`, `crossterm`, `tokio`, `resvg`, `image`, `ratatui-image` or `edtui`.
- [x] 1.3 Vendor `mermaid-text`: copy `D:\markdown-reader\markdown-reader\crates\mermaid-text` into `crates/mermaid-text` unchanged, keeping its own licence, and depend on it by path. Verify `cargo build` links it and `cargo tree -p mermaid-text` reports version 0.57.4.
- [x] 1.4 Define the engine's own display types: a colour (RGB, indexed, or default), a style (colour, background, bold, italic, underline, strikethrough, dim, reversed), a span (style plus text) and a line (spans plus an optional source line). Verify unit tests cover RGB, indexed and default colours and at least two modifier combinations, and that `engine/src` contains no `ratatui` import.
- [x] 1.5 Implement the CLI: `--width <COLS>` required, `--theme <NAME>`, and an optional positional path falling back to stdin. Verify `--help` lists all three, that omitting `--width` exits non-zero with a message on stderr and nothing on stdout, that a missing path exits non-zero with empty stdout, and that `cat file.md | md-render --width 80` matches `md-render --width 80 file.md`.
- [x] 1.6 Write `README.md` stating the origin of the ported code, the attribution to `leboiko/markdown-reader`, and the port-header convention. Verify every ported file from groups 2 and 3 carries the header named in the README.

## 2. Ported foundation

- [x] 2.1 Port `src/text_layout.rs` — `wrap_spans` and its hard-split behaviour — against the engine's span type. Verify a unit test asserts every output line is within the requested width for prose, for a word longer than the width, and for a single character wider than the width.
- [x] 2.2 Port `src/markdown/math.rs` — `latex_to_unicode`. Verify the original's unit tests are carried over and pass.
- [x] 2.3 Port `src/markdown/highlight.rs` — the syntect wrapper and its `SYNTAX_SET`/`THEME_SET` lazy statics — against the engine's style type. Verify a fenced block in a recognised language yields more than one distinct style, and an unrecognised language falls back to one uniform style without panicking.
- [x] 2.4 Port the table column-layout logic from `src/ui/table_render.rs`, dropping everything that draws into a ratatui frame. Verify a unit test computes natural widths and a fitted layout for a table whose natural width exceeds the requested width.

## 3. Ported renderer

- [x] 3.1 Port `src/markdown/renderer.rs` and the `DocBlock`/`TableBlock` types from `src/markdown/mod.rs`, replacing `ratatui::text::Text`/`Span` with the engine's types and dropping `cursor_bridge` and the heading-anchor and link plumbing. Verify a fixture document covering headings, lists, task lists, tables, fenced code, links and nested block quotes renders to a non-empty block list, and that every block's source anchors are populated.
- [x] 3.2 Port the text-render wrapper from `src/mermaid.rs` (`try_text_render_public` and `try_text_render_with_gaps`), leaving the image pipeline behind. Verify a fixture diagram renders to text, and that a diagram too wide for the requested width still produces lines that fit.
- [x] 3.3 Build a fixture corpus covering headings, lists, task lists, tables, fenced code in several languages, mermaid, LaTeX, links and nested block quotes, and add `insta` snapshot tests over it. Verify `cargo test` passes and the snapshots are committed.

## 4. Wire format

- [x] 4.1 Define the serializable output types (`styles`, `lines`, `source_map`) and implement conversion from the engine's style type — foreground and background as `#rrggbb` or `null`, plus the modifier flags. Verify unit tests cover RGB, indexed and default colours and at least two modifier combinations.
- [x] 4.2 Serialize the document to stdout with `serde_json`. Verify the output parses as JSON and its `version` and `width` fields match the invocation.
- [x] 4.3 Deduplicate styles into the `styles` array and merge adjacent same-style characters within a line into one span. Verify a unit test where the same style appears on many lines yields exactly one `styles` entry, and a line of uniform style yields exactly one span.
- [x] 4.4 Verify determinism: render the same input twice at the same width and theme and assert the two outputs are byte-identical.
- [x] 4.5 Write `docs/md-render-format.md` describing every field of the wire format and the source-anchor semantics. Verify the document's example JSON parses and matches the field names emitted by a real invocation.

## 5. Rendering the document into lines

- [x] 5.1 Convert a text block into output lines: wrap at the requested width and attach each line's `source` from its source lines. Verify a fixture with a paragraph longer than the width produces several lines, all within the width, all reporting the same source line.
- [x] 5.2 Convert a table block using the ported column layout, emitting each row line with its `source` from the row source lines. Verify a fixture table's lines all fit the requested width and map back to the right source rows.
- [x] 5.3 Convert a mermaid block through the ported wrapper at the requested width. Verify a fixture diagram is emitted as several text lines that fit the width, all marked synthetic or attributed to the fence line.
- [x] 5.4 Convert a math block through `latex_to_unicode` and wrapping. Verify a fixture formula renders as text within the width.
- [x] 5.5 Emit `source_map` covering every source line of the document. Verify its length equals the source line count and that every entry is a valid index into `lines`.
- [x] 5.6 Verify the spec's width guarantee end to end: for every fixture in the corpus, at three widths, assert no emitted line exceeds the width. Verify the check runs as a test, not by inspection.

## 6. Theme

- [x] 6.1 Add a `CatppuccinMocha` theme — palette fields and its `syntax_theme_name()` mapping — alongside the themes carried over with the port. Verify the new variant resolves a palette whose colours match the editor's catppuccin values.
- [x] 6.2 Accept the theme on `--theme`. Verify an unknown theme name exits non-zero with a diagnostic, and that `catppuccin-mocha` is accepted and produces different colours from the default theme.

## 7. Build and ship the engine

- [x] 7.1 Cross-compile `md-render` on the VM for `x86_64-pc-windows-gnu`. Verify the produced `md-render.exe` runs on this Windows machine and prints JSON for a sample file.
- [x] 7.2 Measure engine wall time, split into process startup and render, plus output size and binary size, for a small file and for the 342 KB test document, and record the numbers in `design.md` under Risks. Verify the numbers exist and state whether the process-spawn risk needs its fallback.
- [x] 7.3 Copy `md-render.exe` into `bin/` and document the build-and-copy step in `README.md`. Verify the documented command produces the file at the documented path.

## 8. Plugin skeleton: the R/S state machine

- [x] 8.1 Create `lua/md-render/` and `plugin/` with the config table (engine path defaulting to `md-render` on `PATH`, then `<repo>/bin/md-render.exe`). Verify loading the repository in a scratch Neovim config leaves startup clean and that `require('md-render').config` returns the defaults.
- [x] 8.2 Implement the state machine: on opening a markdown buffer the window shows R once a render exists, and the toggle mapping swaps between R and S with `nvim_win_set_buf`. Verify interactively that toggling R→S→R restores the source cursor and scroll position exactly.
- [x] 8.3 Create the rendered buffer with `buftype=acwrite`, `bufhidden=wipe`, `modifiable=false`, `swapfile=false`, and `buflisted=false` re-applied after each swap. Verify `:ls` shows only the source buffer while in R, and that an edit command in R leaves the buffer contents unchanged.
- [x] 8.4 Map `i a I A o O` from R to swap into S and enter the corresponding insert mode, and the toggle mapping to swap and remain in normal mode. Verify interactively that each of the six keys lands on the mapped source line in the right insert mode, and that `Esc` from S does not return to R.
- [x] 8.5 Write the plugin section of `README.md` documenting the states, the keymaps and the config table. Verify every keymap named there is one the plugin actually sets, by listing buffer-local maps from a headless Neovim.

## 9. Styling and cursor mapping

- [x] 9.1 Convert the wire format's style table into `nvim_set_hl` groups, cached across renders by a stable name derived from the style, and apply one `nvim_buf_set_extmark` per span. Verify a rendered document shows heading colours, per-token code colours and table borders, and that a second render reuses the same highlight groups rather than redefining them.
- [x] 9.2 Use `lines[].source` to place the cursor when crossing R→S, and `source_map` when crossing S→R. Verify interactively: `i` from a rendered paragraph lands on that paragraph's source line; toggling from a source line deep in the file lands in R near the corresponding display line rather than at the top.
- [x] 9.3 Handle the synthetic-line case: the cursor on a table border or diagram artwork resolves to the source line of the construct. Verify interactively on a table and on a mermaid block.

## 10. Freshness, writes and failure handling

- [x] 10.1 Spawn the engine with `vim.system`, apply results in the callback, and discard results whose generation is stale. Verify that resizing during a render cannot leave an out-of-date document on screen.
- [x] 10.2 Cache rendered output by `(buffer, width, changedtick)`. Verify toggling R→S→R without editing reuses the previous render (no new process is spawned — check by counting engine invocations), and that editing then returning to R re-renders.
- [x] 10.3 Re-render on `WinResized`, debounced, without swallowing a user-initiated toggle. Verify a drag-resize produces one render, and that a toggle issued immediately after a render is not dropped.
- [x] 10.4 Re-render when the source buffer changes, and make R reflect unsaved edits. Verify: edit in S, do not write, return to R — the edit is visible; and that the file on disk is unchanged.
- [x] 10.5 Intercept `:w` and `<C-s>` in R with a buffer-local `BufWriteCmd` that writes the source buffer. Verify that `:w` in R with no pending edits leaves the file byte-identical, and that an edit made in S is written by `:w` issued in R.
- [x] 10.6 Handle engine failure: on a non-zero exit or unparseable output, stay in S and report the diagnostic. Verify by pointing the engine path at a missing binary and at a script that exits 1 — in both cases the window shows the source and the reason is reported.
- [x] 10.7 Handle the split case: two windows on the same rendered buffer. Verify that toggling one window back to S does not invalidate or wipe the buffer the other window is showing.

## 11. Config integration and integration verification

- [x] 11.1 Prepend the repository to `runtimepath` in `C:\Users\yhqian\AppData\Local\nvim\init.lua`, keeping the existing `render-markdown.nvim` entry so the two can be compared. Verify both plugins load and neither errors at startup.
- [x] 11.2 Compare the two on the same document and confirm R reproduces the reflow, table and diagram rendering that in-place rendering could not. Verify with the 342 KB test document and a document containing a mermaid block, a wide table and a LaTeX formula.
- [x] 11.3 Remove the `render-markdown.nvim` entry from `vim.pack.add` and delete its `depua` setup block. Verify startup is clean, `:checkhealth` reports nothing about markdown, and the toggle still works.
- [x] 11.4 Verify the rollback path: re-add the `render-markdown.nvim` entry, confirm the plugin loads and renders, then remove it again.
