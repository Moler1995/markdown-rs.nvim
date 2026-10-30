# Proposal

## Why

R and S already let a reader act on what is under the cursor — follow a link
(`gf`), open an image (`gx`), preview a block (`<CR>`) — but not take a copy of
it. Taking the block away is the step that most often follows reading one: a
code fence goes into a REPL, a table into another document, an image reference
into a different file. Today that means leaving R for S, finding the block by
hand and yanking it with motions, which is exactly the work the rendered view
was supposed to save.

## What Changes

- A new buffer-local key, `keymaps.yank_block`, defaulting to `gy`, available in
  **both** R and S.
- With the cursor in a copyable block it writes that block's content to the
  unnamed register and to register `0`:
  - a fenced code block of **any** language, mermaid included — the lines
    between the fences, without the opening and closing fence lines;
  - a GFM table — its own source lines, pipes included;
  - an image reference — the `![...](...)` text, characterwise.
- With the cursor in none of those (a paragraph, a heading, a list item, an
  indented code block, a fence indented past three spaces) the key performs its
  ordinary editor action and leaves both registers untouched.
- The key never spawns an engine process, and never moves the cursor.

`preview.lua` gains a language-agnostic fence finder (`find_code_fence`) beside
the existing mermaid-only `find_fence`; the `<CR>` preview path is unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `nvim/render-mode`: adds a requirement — a copy key available in both R and S,
  what each of the four block kinds contributes, the registers written, and the
  keys handed back to Vim.

## Impact

- `lua/md-render/config.lua` — a new `keymaps.yank_block` default.
- `lua/md-render/init.lua` — `M.yank_block(win)` and its keymap registration,
  placed with the other both-state keys.
- `lua/md-render/preview.lua` — `scan_fence` extracted; `M.find_code_fence`
  added. `M.find_fence`, `M.find_table` and `M.locate` keep their current
  contracts, so the preview popup is untouched.
- `README.md`, `doc/md-render.txt` — the documented key table and the keymap
  section.
- `tests/headless/run.lua` — the default-keymap literal, a new section `8.6`,
  and a new fixture `tests/fixtures/blocks.md`.
- No engine change: this is a buffer operation, not a rendering decision.
- No new dependency.
