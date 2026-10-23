# Design

## Context

See `proposal.md` — Why. The constraints that shape the approach:

- `markdown-reader` is the source of the render pipeline, and it is a TUI *product*: the renderer is
  welded to ratatui, crossterm, tokio, resvg, ratatui-image and edtui. The pipeline itself is
  complete — `render_markdown(content, palette, theme, math_mode) -> Vec<DocBlock>`, with wrapping
  in `text_layout::wrap_spans(spans, max_width)`, diagrams in `mermaid::try_text_render_public`,
  formulas in `markdown::math::latex_to_unicode`, and source anchors already carried on every
  `DocBlock` variant (`Text.source_lines`, `Mermaid.source_line`, `Math.source_line`,
  `Table.row_source_lines`). The pipeline is worth carrying over; the application around it is not.
- The editor is Neovim 0.12.6 on Windows, built for `x86_64-pc-windows-gnu`; there is no local Rust
  toolchain, so the engine is cross-compiled on the Linux VM at `192.168.224.134`.
- `render-markdown.nvim` currently occupies the markdown rendering role and is being removed, so
  the replacement has to be loadable from `init.lua` the same day it is built.

## Goals / Non-Goals

**Goals:**

- An engine contract narrow enough that the plugin never needs to know anything about how markdown
  is parsed, and stable enough that improving the renderer never touches Lua.
- A mode switch that is cheap and reversible, with no path by which a reflexive `:w` can damage the
  document.
- An engine that depends only on the crates it actually needs, so it builds fast, ships small, and
  can be published on its own.

**Non-Goals (design-level; scope non-goals are in `proposal.md`):**

- A long-lived engine process. Stage 1 spawns one process per render and measures whether that is
  acceptable.
- Viewport-limited styling. Stage 1 styles the whole document once; see Risks.
- Deriving the render palette from Neovim's active colorscheme.
- Tracking `markdown-reader` upstream. The port is a one-time lift; the two copies are not kept in
  step.

## Decisions

### D1. The engine is an out-of-process CLI, not an in-process binding

`nvim-oxi` is the obvious "Rust nvim plugin" answer and is not available here: its Windows support
is gated on `target_env = "msvc"` (it links `lua51` via `raw-dylib`), and its `libuv` feature is
broken on Windows. The toolchain is `gnu`. An in-process `cdylib` reached through LuaJIT FFI would
work, but buys nothing over a process and turns any Rust panic into an editor crash.

A separate process also keeps the plugin in Lua, which is the language the rest of the user's config
is in, and makes the engine testable from a shell with no editor involved.

*Alternatives:* `nvim-oxi` cdylib (does not build on this target); in-process FFI (worse failure
mode, no benefit).

### D2. The engine emits lines and styles, not extmark instructions

This is the decision the whole design turns on. Because R is a *real buffer* rather than a
concealed source buffer, the engine never needs to express `conceal`, `virt_text`, `virt_lines`, or
`virt_text_pos`. Its output is "an ordered list of lines; each line is an ordered list of styled
spans; each line knows which source line it came from" — which is very close to what
`render_markdown` plus `wrap_spans` already produce.

The alternative — a render *plan* of extmark operations, so the source buffer could be decorated in
place — is where the reflow dead end lives: a buffer line's screen height is fixed, so a plan cannot
express a re-wrapped paragraph, and building it means designing a second, harder contract for no
capability the first one lacks. The user chose to replace only the rendering responsibility, so that
contract is not needed.

*Consequence:* `markdown/cursor_bridge.rs` is **not** reused. Its byte-to-visual mapping serves the
TUI's own layout; here the engine's line list *is* the layout, and the mapping is just the two
indices the engine already emits.

### D3. The window swaps buffers; buffer contents are never rewritten

R and S are two different buffers displayed in the same window via `nvim_win_set_buf`. The source
buffer is never modified to show rendered content.

Rewriting the buffer in place was rejected on a measured failure: `:w` on the rendered buffer would
write rendered text over the `.md` file. With a scratch buffer of `buftype=nofile` the write is
refused — measured as `E382: Cannot write, 'buftype' option is set` — which is exactly the safety
property wanted, and it exists only because the rendered content lives in its own buffer.

Two further measurements make the swap cheap:

- `nvim_win_set_buf` remembers each buffer's view per window. Measured:
  `before topline=110 lnum=120 | after_set topline=1 lnum=1 | after_back topline=110 lnum=120`.
  Returning to S restores the cursor and scroll exactly, with no `winsaveview` bookkeeping.
- A rendered buffer is derived state and can be discarded at will.

Rendered buffer options: `buftype=acwrite` (see D8), `bufhidden=wipe`, `modifiable=false`,
`swapfile=false`, and `buflisted=false` — re-applied *after* each swap, because
`nvim_set_current_buf` re-lists an unlisted buffer (measured).

### D4. The engine ports the render pipeline; it does not depend on `markdown-reader`

`markdown-reader` is a TUI application. Depending on it — which would also require it to grow a
`[lib]` target — would make a "markdown to styled lines" engine link ratatui, crossterm, tokio,
resvg, image, ratatui-image and edtui, and would make the plugin impossible to publish. The engine
therefore lives in its own repository and carries the parts of the pipeline it needs.

**Ported**, adapted to the engine's own span and colour types:

| From `markdown-reader` | Non-test lines | Note |
|---|---|---|
| `src/markdown/renderer.rs` | 1324 | the core: pulldown-cmark events to styled runs |
| `src/markdown/math.rs` | 461 | LaTeX to Unicode |
| `src/text_layout.rs` | 369 | `wrap_spans`; the fits-the-width guarantee lives here |
| `src/ui/table_render.rs` | 356 | table column widths |
| `src/markdown/highlight.rs` | 183 | syntect wrapper |
| `src/mermaid.rs` | ~50 of 756 | only the text-render wrapper; the rest is the TUI's image pipeline |

**Not ported:** `markdown/cursor_bridge.rs` (the TUI's own byte-to-visual mapping), link and
heading-anchor plumbing, the image render pipeline, `theme/themes.rs` in full (the engine needs one
palette, not eight), and every screen.

*Alternative:* depend on `markdown-reader` through a `[lib]` target added to the fork. Rejected on
the dependency tree, and because it makes the plugin unpublishable.

*Cost accepted:* the two copies drift. A renderer fix made in `markdown-reader` does not reach the
engine, and the renderer's tests and snapshots do not come across — they have to be rebuilt. Each
ported file therefore carries a header naming its origin and the revision it was taken from, so a
future comparison is at least possible.

### D5. Wire format: a deduplicated style table, per-line spans, and both directions of the map

```jsonc
{
  "version": 1,
  "width": 120,
  "styles": [                                  // deduplicated once per render
    { "fg": "#cba6f7", "bg": null, "bold": true }
  ],
  "lines": [
    { "source": 0,    "spans": [[0, "Title"], [3, " rest of line"]] },
    { "source": null, "spans": [[7, "+--------+"]] }        // synthetic
  ],
  "source_map": [0, 0, 4, 4, 4, 9]             // len == source line count
}
```

- `styles` is deduplicated so the Lua side defines each highlight group once and can cache the
  style-to-group mapping across renders. Spans reference a style by index.
- `spans` are `[style_index, text]` pairs rather than objects — this is the hot path for both pipe
  volume and Lua decode cost, and the shape is fixed, so objects buy nothing.
- `lines[].source` is `null` for synthetic lines, satisfying the spec's source-anchoring
  requirement without attributing borders and diagram artwork to an arbitrary line.
- `source_map` is emitted rather than derived so the plugin does not have to reimplement the
  "first display line at or after source line N" scan, and so the mapping stays a single source of
  truth.

### D6. Rendering is asynchronous, generation-counted, and cached by `changedtick`

The plugin spawns the engine with `vim.system` and applies the result in the callback. Each window
holds a generation counter; a callback whose generation is stale is discarded, so a resize during a
render cannot land an out-of-date document.

The cache key is `(buffer, width, changedtick)`. `changedtick` is the cheap invalidation token and
is what makes the spec's "toggling without an edit does not re-render" hold — a cache hit swaps
buffers immediately.

The previous state stays on screen until a render arrives, which is why the spec says the window
keeps showing the source while rendering is in flight. There is no "rendering…" placeholder state.

### D7. Bistable mode, with the insert-entry keys as escape hatches

`i a I A o O` from R swap to S at the mapped cursor position and enter the corresponding insert
mode; the toggle mapping swaps and stays in normal mode. `Esc` does not return to R.

The alternative — strict modality, where insert mode shows source and normal mode shows rendered —
matches `render-markdown.nvim`'s existing habit and was rejected for two reasons. It makes every
normal-mode editing command unavailable in the state the user lands in after `Esc` (`dd` silently
does nothing in a `nomodifiable` buffer), and it forces a re-render on every `Esc`, which on a
342 KB document is a visible stall plus a cursor jump to the start of the rendered paragraph.

Because R is a real buffer, `gg`, `G`, `/` and yanking work on it with no special handling — the
same cannot be said of a concealed source buffer, where screen lines and buffer lines disagree.

### D8. Writes in R are intercepted with `acwrite` + `BufWriteCmd`

`buftype=acwrite` means "always written via `BufWriteCmd`, never to disk". A buffer-local
`BufWriteCmd` autocmd on the rendered buffer writes the *source* buffer instead, satisfying the
spec's write requirement while keeping `:w` from erroring at the user.

`nofile` would make `:w` fail loudly instead. That is the safer failure, but the spec asks for the
write to be redirected, and `acwrite` is the mechanism designed for exactly this. *Verify during
implementation:* whether an unnamed `acwrite` buffer reaches `BufWriteCmd` or is rejected first; if
it is rejected, fall back to explicit mappings for `:w` and `<C-s>`.

### D9. Theme: add a Catppuccin Mocha palette to the engine

The editor's colorscheme is `catppuccin`; the engine's `Theme` enum has eight variants and none of
them match. A rendered view that is a different palette from the editor around it is worse than no
rendering.

Stage 1 adds a `Theme::CatppuccinMocha` variant to `theme/mod.rs`, using the same palette source as
the editor's. Code-block token colors still come from syntect's bundled themes
(`Theme::syntax_theme_name()` maps the app theme onto one of three), and no bundled syntect theme is
catppuccin, so code tokens will be an approximation of the editor's. That mismatch is accepted for
stage 1 and recorded as an open question.

*Alternative:* have the plugin read Neovim's active highlight groups and pass them as an explicit
palette. This is the right long-term answer — it makes the rendered view follow whatever
colorscheme is loaded — but it means mapping ~30 `Palette` fields onto highlight groups *and*
separately reconciling syntect's theme, which is a change of its own.

### D10. One repository, `markdown-rs.nvim`, holding engine and plugin

```
D:\projects\rust\markdown-rs.nvim\
  Cargo.toml           workspace
  engine/              the md-render crate
  lua/md-render/       the plugin
  plugin/md-render.lua
  bin/md-render.exe    cross-compiled artifact, committed
  docs/
```

A single clone delivers both halves. The repository name and the code's name differ on purpose:
`markdown-rs.nvim` is the branding, `md-render` is the binary, the Lua module and the command name.
That keeps the engine's name usable outside Neovim, and it is the ordinary
`foo.nvim`-with-a-different-module arrangement.

During development the directory is prepended to `runtimepath` from `init.lua`, because
`vim.pack.add` installs by `git clone` and there is no remote yet. Moving to `vim.pack.add` is a
later, mechanical step.

### D11. Binary discovery

The plugin takes a configurable engine path, defaulting to `md-render` on `PATH`, with a fallback to
`<repo>/bin/md-render.exe`. The build artifact is cross-compiled on the VM and copied into `bin/`,
which keeps a clone self-contained and avoids requiring a `PATH` edit.

## Risks / Trade-offs

- **[Extmark call volume]** Styling is one `nvim_buf_set_extmark` call per span, and a large
  document may have tens of thousands of spans; at a few microseconds per Lua-to-API call this could
  cost hundreds of milliseconds. → Measure on the 342 KB test document. The engine already merges
  adjacent same-style characters per line, which is the cheap win; if that is not enough, the
  fallback is to style only the visible range plus a margin and re-style on scroll, at the cost of
  a second invalidation path.

- **[Process spawn per render]** A fresh `md-render.exe` per render adds process startup to parse
  and highlight cost. → **Measured, 2026-10-19, on the Windows development machine, `min` over 20
  runs after warm-up (release build, `bin/md-render.exe`, 4.84 MB).** Process startup alone
  (`--themes`, which exits before reading input): **4 ms**. A one-line paragraph with no code:
  **4 ms** — prose is essentially free, and 486 KB of it costs 50 ms. The first code block in a
  process costs **34 ms** (38 ms total), which is syntect's lazily-deserialised syntax and theme
  sets, paid once per invocation. The 340 KB generated document (225 chapters, each with a table,
  a Rust block, a mermaid diagram and display math) renders in **386 ms** at width 80 and 377 ms at
  width 200, emitting **1.74 MB and 1.64 MB** of JSON — 15,975 display lines, 39,150 spans and
  19 distinct styles at width 80. The generated document is not committed; its recipe is
  `tools/make-bench-doc.sh`.

  **The fallback is not needed.** The common case — a README-sized file with a code block or two —
  is ~45 ms end to end, well inside a debounced re-render budget, and the 340 KB worst case is
  386 ms, which is a visible pause but a one-off one, since `(buffer, width, changedtick)` caching
  means it is paid on the first render and not on every toggle. A long-lived process with a line
  protocol would remove the ~40 ms fixed cost and nothing else; it stays out of scope. What the
  numbers *do* make non-optional is the debounce (10.3) and the changedtick cache (10.2) — without
  them a resize drag would pay 386 ms per event.

- **[Extmark call volume — engine-side part]** Measured: the 340 KB document renders to **39,150
  spans** (15,975 display lines, 19 distinct styles), so the plugin's one-extmark-per-span scheme
  means ~39,000 API calls for that document. Merging adjacent same-style characters per line is
  already in the engine, so this is the minimum the styling can be expressed in — the lever left is
  on the plugin side, and task 9.1 measures it.

- **[First-open flash]** A `.md` file shows raw source until the first render arrives, which on a
  large document is a visible delay. → Accepted and specified. Rendering synchronously would block
  the UI, which is worse.

- **[Resize storms]** `WinResized` fires repeatedly during a drag. → Debounce, as
  `render-markdown.nvim` does. Note the measured precedent: its 100 ms debounce gate *drops* a
  toggle issued immediately after a render. The debounce here must not swallow a user-initiated
  toggle, only coalesce resizes.

- **[`bufhidden=wipe` and splits]** Two windows showing the same rendered buffer, then toggling one,
  would wipe the buffer out from under the other. → Track rendered buffers per window and only wipe
  when no window shows it; or detect the case and switch to `bufhidden=hide` with explicit cleanup.

- **[Deferred wipe]** `bufhidden=wipe` does not take effect synchronously — measured: after swapping
  back to the source, the rendered buffer still reported `valid=true`. → Never assume the previous
  rendered buffer is gone; check `nvim_buf_is_valid` before use.

- **[Yanking in R yields rendered text]** Visual-selecting a table or heading in R copies the
  artwork, not markdown. → Inherent to the design and accepted; the source is one key away.

- **[No language tooling in R]** LSP, gitsigns and diagnostics attach to the source buffer, so they
  are absent while reading. → Accepted: these are editing concerns, and S restores all of them. This
  is the cost the "replace only the rendering responsibility" choice does not remove.

- **[Unverifiable in headless]** Neovim reports `mode=n` under `--headless` even for a bare
  `feedkeys("i")` (measured, four variants), so the "swap then enter insert mode" behaviour cannot be
  confirmed headlessly. → Verify interactively.

## Migration Plan

1. Add `[lib]` and the `md-render` binary; build and test it on the VM with
   `cargo run --bin md-render -- --width 100 --theme catppuccin-mocha <file>`.
2. Cross-compile `x86_64-pc-windows-gnu`, copy `md-render.exe` into `nvim-plugin/bin/`.
3. Add `nvim-plugin/` and prepend it to `runtimepath` in `init.lua`, alongside the existing
   `render-markdown.nvim` entry so the two can be compared.
4. Verify R/S behaviour interactively against the 342 KB test document, including the
   `md-render`-absent path and a resize.
5. Remove the `render-markdown.nvim` entry from `vim.pack.add` and delete its `depua` setup block.
6. `vim.pack.del({ 'render-markdown.nvim' })`, so the installed-but-unused plugin stops being
   reported by `:checkhealth` and stops being updated by `vim.pack.update()`, which updates every
   plugin it manages whether or not the session added it.

**Rollback:** re-add the `render-markdown.nvim` entry to `vim.pack.add`, restore its setup block, and
drop the `runtimepath` line. Because step 6 removed the plugin from disk, that first step is a fresh
`git clone`: it needs the network, and it installs the revision upstream is at that day rather than
the `8e87953` the plugin was pinned to. Verified both ways — with the directory present the entry
alone brings it back offline at the same revision, and after the removal the entry alone re-clones
and renders. Nothing in the TUI's own behaviour changes either way.

## Open Questions

- Code-block token colors come from syntect's bundled themes and will not exactly match the editor's
  catppuccin. Whether to bundle a catppuccin `.tmTheme`, or to move to a Neovim-derived palette, can
  be decided after living with the approximation.
- Whether the extmark volume needs viewport-limited styling is a measurement question, not a design
  question; the engine's output shape does not change either way.
