# Proposal

## Why

Markdown is currently read in Neovim through `render-markdown.nvim`, which renders *in place* by
overlaying extmarks and concealing source bytes. That technique is structurally capped: a buffer
line's screen height is fixed, so a paragraph cannot be reflowed; a table cannot be restructured;
a mermaid diagram or a LaTeX formula cannot be drawn as text art. What it buys — the buffer stays
real text so search/LSP/gitsigns keep working — matters for *editing*, not for *reading*.

`D:\markdown-reader` already contains a renderer that does all of those things — pulldown-cmark for
structure, syntect for code highlighting, `mermaid-text` for diagrams, `ratex` for LaTeX — but it
is welded into a TUI application with no way to call it from outside.

This change builds a standalone engine that carries that render pipeline into its own repository,
and a full-width **rendered reading mode** in Neovim on top of it, then removes
`render-markdown.nvim`. Its rendering responsibility is taken over completely; its in-place overlay
role is dropped deliberately, because once a one-key switch to a true rendered view exists,
overlaying the source buffer costs more than it gives.

## What Changes

**New repository — `D:\projects\rust\markdown-rs.nvim`**

- A standalone Rust engine, binary `md-render`, that **ports** the render pipeline out of
  `markdown-reader` rather than depending on it. `markdown-reader` is a complete TUI product:
  depending on it would make a "markdown to styled lines" engine link ratatui, crossterm, tokio,
  resvg, image, ratatui-image and edtui, and would make the plugin unpublishable.
- Ported and adapted: the pulldown-cmark renderer, span wrapping, table column layout, syntect
  code highlighting, LaTeX-to-Unicode, and the thin wrapper over the `mermaid-text` crate.
- Deliberately not ported: the TUI itself — the cursor bridge, link and heading-anchor plumbing,
  the image render pipeline, and every screen. Ported files keep their MIT licence and attribution
  to `leboiko/markdown-reader`.
- Contract: read markdown from a file or stdin, take `--width N` and a theme, write JSON to stdout
  — an array of rendered lines, each a list of styled spans, each carrying the source line it came
  from.

**Neovim side — the same repository**

- A bistable **R / S** mode. `nvim foo.md` opens in **R** (rendered, full width).
- **R** shows the rendered output in a read-only scratch buffer displayed in the same window.
  Scrolling, `/` search and yanking work because it is a real buffer; editing commands are inert
  by construction rather than by remapping.
- **S** is the source buffer, fully editable with the complete Vim vocabulary (`dd`, `/`, `u`,
  `:%s/`, LSP, gitsigns — all of it).
- Crossing: `i a I A o O` from R swaps to S at the mapped cursor position and enters the
  corresponding insert mode; `<leader>p` toggles and always lands in normal mode. **Leaving insert
  does not auto-return to R** — otherwise `Esc` followed by `dd` silently does nothing.
- `:w` / `<C-s>` while in R write the *source* buffer, so a reflexive save cannot write rendered
  text over the `.md` file.
- Rendering is asynchronous and cached by `changedtick`, so re-toggling without an edit is
  instant. Re-render is triggered by `WinResized` (width change) and by source-buffer edits.
- **BREAKING** (for the user's own config): remove `render-markdown.nvim` from `vim.pack.add` and
  delete its `depua` setup block in `init.lua`. In-place light rendering in S is intentionally not
  replaced.

## Capabilities

### New Capabilities

- `nvim/render-engine`: the `md-render` process contract — its inputs (markdown, width,
  theme/palette), its JSON output shape (styled lines plus per-line source anchors), and the
  guarantees a caller may rely on (deterministic output, width-stable wrapping, every rendered line
  traceable to a source line).
- `nvim/render-mode`: the plugin's observable behaviour — what R and S each show, which buffer the
  window holds in each state, the mappings that cross between them, the cursor-mapping rules in
  both directions, and the triggers that re-render or invalidate.

### Modified Capabilities

None — this project has no specs yet, so every capability is new.

## Impact

- New repository `D:\projects\rust\markdown-rs.nvim`: a Cargo workspace with the `md-render`
  engine crate, the Lua plugin under `lua/` and `plugin/`, and the built `bin/md-render.exe`.
- The engine's dependency set is five crates — `pulldown-cmark`, `syntect`, `mermaid-text`,
  `unicode-width`, `serde_json` — instead of the TUI's full tree.
- `D:\markdown-reader` is **read-only for this change**: it is the source the port is taken from,
  and the fork is not modified. Any future renderer fix there must be carried over by hand, which
  is the price of the engine being standalone.
- `C:\Users\yhqian\AppData\Local\nvim\init.lua` — remove the `render-markdown.nvim` entry from
  `vim.pack.add` and the ~45-line setup block that derives its config.
- Build and test happen on the Linux VM (`192.168.224.134`); there is no local Rust toolchain.
  `md-render.exe` is cross-compiled for `x86_64-pc-windows-gnu`.

**Non-goals**

- Split-pane simultaneous S+R view (and the scroll/cursor synchronisation it would need).
- In-place conceal rendering in S — the whole point of dropping it.
- Image rendering inside the buffer.
- MSVC toolchain support; the `gnu` target is the supported one.
- Tracking `markdown-reader` upstream. The port is a one-time lift; keeping the two copies in step
  is not a goal.

**Known risk to resolve in design**

Spawning `md-render.exe` per render adds process-startup cost on top of parse and highlight cost.
If that proves noticeable on large documents, the fallback is a long-lived process with a line
protocol — a much larger design, so it is deliberately out of scope unless measurement demands it.
