# Tasks

## 1. Generalize the fence scan in `preview.lua`

- [x] 1.1 Extract the fence-walking loop of `M.find_fence` into `local function scan_fence(lines, line, accept)` that takes a predicate over the opening fence, and make `M.find_fence` pass `names_mermaid` so `<CR>` still rejects non-mermaid fences. Verify with `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua`: sections 8.3–8.5 (block preview and zoom) stay green.
- [x] 1.2 Add `M.find_code_fence(lines, line)` on top of `scan_fence` with a predicate that accepts every fence, returning `first`, `last`, `info`, `lines` and a `body` slice that excludes the fence lines. Verify the unclosed-fence and over-indented cases by hand with `nvim --headless -u NONE -l` over `tests/fixtures/blocks.md`, confirming `find_code_fence` returns nil for a fence indented past three spaces.

## 2. The copy key

- [x] 2.1 Add `yank_block = 'gy'` to `M.defaults.keymaps` in `lua/md-render/config.lua`, with a comment recording that it applies in both states, what the four block kinds contribute, and that an unhandled position is handed back to Vim. Verify `:lua print(vim.inspect(require('md-render.config').defaults.keymaps.yank_block))` prints `gy`.
- [x] 2.2 Add `local function copyable(doc, row, col, source, lines)` and `M.yank_block(win)` to `lua/md-render/init.lua`, beside `M.follow`: resolve the source row with `render.source_line_for` in R and the cursor row in S, try the code fence, then the table, then the image reference, write the text to `"` and `0` with the register type that matches the block, and `feed(key)` on every miss. Verify with `tests/fixtures/blocks.md` in a real Neovim that `gy` on the fence, the table and the image puts the expected text in `0`, and that a paragraph leaves `0` and `"` untouched.
- [x] 2.3 Register the key in `M.set_keymaps` beside `follow`, before the `insert_entry` early return, so both R and S get it. Verify `nvim_buf_get_keymap` reports `gy` on both the rendered and the source buffer.
- [x] 2.4 Add the fixture `tests/fixtures/blocks.md` — a heading, a paragraph, a ```rust fence, a GFM table and a line holding an image reference — and a new `section('8.6', ...)` in `tests/headless/run.lua` covering: the R fence body, the unnamed register holding the same text, the linewise register type, no engine spawn, the table, the image as characterwise text, a paragraph leaving a sentinel in `0`, the same fence and table from S, the image found by column in S, a paragraph in S, and `keymaps.yank_block = false` leaving `gy` unmapped. Add `yank_block = 'gy'` to section 8.1's literal keymaps table. Verify with `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua`.

## 3. Documentation

- [x] 3.1 Add the key to the README key table (`<!-- keymaps -->` block) with `yank_block` in the Where column written exactly as `R and S` — the headless suite reads this table. Verify with `bash tools/check-readme.sh`.
- [x] 3.2 Add `keymaps.yank_block` to the options default block and to section 7's keymap list in `doc/md-render.txt`, then regenerate the tags: `nvim --headless -u NONE -c 'helptags doc' -c q && git diff --exit-code doc/tags`. Verify `:help md-render` still opens and the new entry is reachable.

## 4. Integration

- [x] 4.1 Rebuild the engine is not required (no Rust change); confirm `bin/md-render.exe` exists and is the binary the Lua suites resolve. Verify with `:checkhealth md-render` reporting the `bin/` path.
- [x] 4.2 Run the full gate and fix anything it reports: `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua`, `nvim -l tests/interactive/run.lua`, `bash tools/check-readme.sh`, `openspec validate --all --no-interactive`.
- [x] 4.3 Check by hand that `<CR>` on a ```rust fence still opens no preview while `gy` copies it — the two keys share a scan but must not share an opinion about which fences are blocks.
