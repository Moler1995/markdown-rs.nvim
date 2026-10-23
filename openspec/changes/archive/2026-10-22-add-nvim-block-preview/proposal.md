# Proposal

## Why

The engine lays every construct out against the window's column budget and **clips what does not
fit** — `push_mermaid` ends each artwork line with `clip_to_width(line, width)` (`engine/src/document.rs:149`),
and table columns are sized from the same budget. The characters dropped by that clip never reach
the rendered buffer, so in a narrow window the right-hand side of a wide diagram is not merely
off-screen: it does not exist, and no amount of horizontal scrolling brings it back. Reading a
diagram wider than the window is currently impossible.

## What Changes

- A new key in **R**, `<CR>`, opens a **centred floating preview of the block under the cursor**,
  re-rendered at the popup's own width rather than at the window's. Giving the layout a much larger
  budget is what recovers the clipped right-hand side; the popup is not a magnifier over the
  already-clipped text.
- Two block kinds are covered: a ` ```mermaid ` fence, and a GFM table. On anything else — prose, a
  non-diagram code fence, a list — `<CR>` does nothing, so the key stays safe to press anywhere.
- The popup is sized to fit its content, capped at 90% of the editor's columns and lines, and
  centred. A small diagram gets a small popup, not a large empty box.
- `<CR>`, `q` and `Esc` close it. The window underneath is never touched: the popup is a separate
  window, so the cursor, the scroll position and the state (R or S) survive the round trip with no
  bookkeeping.
- New configuration: `keymaps.preview` (default `<CR>`) and `preview = { max_width_pct, max_height_pct }`
  (defaults `0.9`, `0.9`).
- **No engine change and no wire-format change.** The popup feeds the block's own source lines back
  through the existing `md-render --width N` contract and paints the result with the existing
  `render.apply`. The one piece of engine-repository work the change carries is **test-only**: a
  fixture pinning the vendored `ascii-dag` patch end to end (see Impact), because a preview is a
  second render of the same block and therefore makes any layout nondeterminism visible.

## Capabilities

### New Capabilities

- `nvim/block-preview`: the preview popup's observable behaviour — which blocks open it, which key
  opens and closes it, what the popup shows and how it is sized, what happens when the cursor is on
  a block that is not previewable, and what happens when the re-render fails.

### Modified Capabilities

None. `nvim/render-mode` describes what R and S each show and how the user crosses between them;
the preview adds a key inside R without changing either state's content, its cursor mapping, or the
crossing keys. `nvim/render-engine` describes the process contract, and the preview reuses it
unchanged.

## Impact

- **Lua plugin only** (`D:\projects\rust\markdown-rs.nvim`): a new `lua/md-render/preview.lua`, plus
  additions to `lua/md-render/init.lua` (an exported entry point and the R-side mapping),
  `lua/md-render/config.lua` (two new options), `README.md` (the keymap table and the config block)
  and `tests/headless/`.
- **No Rust, no engine, no wire format.** The feature is a second consumer of the contract that
  already exists.
- **One test-only addition in the engine repository** (`D:\projects\rust\markdown-rs.nvim`): a
  subgraph diagram in `engine/tests/fixtures/diagrams.md` that reaches the tie in the vendored
  `crates/ascii-dag`, plus the regenerated corpus snapshot. No engine source changes and no behaviour
  change — the snapshot diff should be an addition only. What it buys is the missing end-to-end pin:
  today nothing fails if `[patch.crates-io]` stops redirecting `ascii-dag`, because the crate's own
  regression test passes as a workspace member either way, and no existing fixture contains a
  subgraph.
- **One engine process per preview opened.** The input is a single block, so the cost is at the low
  end of the measured range (a prose-only document renders in ~4 ms; see the design of the previous
  change). No cache is kept: the popup is a deliberate, occasional action.
- The preview is available in R only. In S the cursor is already on the block's source, which the
  user can read and edit directly, so a second way to look at it earns nothing.

**Non-goals**

- Previewing arbitrary blocks — paragraphs, lists, headings, non-diagram code fences. Their source
  extent has no reliable lexical boundary, and re-laying them out at a wider width reveals nothing
  that the source does not.
- Editing inside the popup. It is a reading aid; the source is one key away.
- Re-rendering the popup when the terminal is resized while it is open. The popup keeps the size it
  was opened at; closing and reopening refreshes it.
- Caching previews, or keeping more than one open at a time.
- Scaling the artwork down to fit. The engine re-lays out against a budget; it does not scale, and
  nothing in this change makes it.
