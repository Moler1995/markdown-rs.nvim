# Tasks

## 1. Spike: does the raw-bytes API reach the terminal

- [ ] 1.1 In WezTerm, open a real Neovim 0.12 with any PNG and run one hand-written sequence through `nvim_ui_send` — a cursor move to a known cell, then `ESC_Gi=99,a=T,f=100,c=20,r=10,t=f;<absolute path>ESC\` — and confirm an image appears over the popup-free screen. Record the Neovim version, the WezTerm version and the outcome. If `nvim_ui_send` is absent or the image does not appear, stop: report which of the two failed and do not continue with the engine or plugin tasks.
- [ ] 1.2 In the same session, delete it with `ESC_Gi=99,a=d,d=I ESC\` and confirm it is gone, so the removal mechanism the design relies on is known to work before any module depends on it.

## 2. Engine reports drawn images

- [ ] 2.1 Add `WireImage { source, path }` and `images: Vec<WireImage>` to `WireDoc`, skipped when empty, and populate it in `document.rs::push_image` for references the engine drew — never for alt-text fallbacks. Verify with a unit test that a PNG reference produces one entry whose path is the resolved absolute path, and an SVG reference produces none.
- [ ] 2.2 Verify ordering and determinism: two images in one document are reported in source-line order, and two renders of the same document report identical lists. Add both as unit tests.
- [ ] 2.3 Update `docs/md-render-format.md` with the `images` field and its absence rules, and extend `engine/tests/wire_format_doc.rs` so the prose and the struct still agree field for field. Verify `cargo test -p md-render --test wire_format_doc`.
- [ ] 2.4 Run the corpus and accept the snapshot move for fixtures containing images, reading the diff first: the only additions are `images` entries. Verify `cargo test -p md-render`.

## 3. The plugin's graphics module

- [ ] 3.1 Add the `graphics` option to `config.lua` with `'auto'` and `'off'`, documented in the module's own comment style, and add nothing else to `M.defaults`. Verify the headless suite's option-default checks still pass.
- [ ] 3.2 Write `lua/md-render/graphics.lua`: the decision function over injected inputs (whether the raw-bytes API exists, whether a UI is attached, the option, the identified terminal), the identification from `TERM_PROGRAM`, the `ESC[>q` query and the `TermResponse` reply cached for the session, and `M.available()`. Verify with headless tests that each of the four conditions turns it off, that a known `TERM_PROGRAM` turns it on without a query, and that an unknown one stays off until the reply arrives.
- [ ] 3.3 Add the sequence builder and the injectable sender: `M.place(win, path, id)` returns the exact bytes for a given popup geometry, and `M.remove(id)` the delete sequence. Verify with headless tests asserting the byte string for a known window position, box and path, and that the delete names the same id.
- [ ] 3.4 Add the path fallback: build a `t=f` sequence for an ASCII path and a chunked `t=d` sequence for a non-ASCII one, reading the file with `vim.uv.fs_read`. Verify with a headless test over a temporary file, asserting the chunk boundaries (4096 bytes, `m=1` on all but the last) and that the reassembled payload is the file.
- [ ] 3.5 Report the decision in `health.lua`: one entry saying graphics is in use, or naming the condition that turned it off. Verify `require('md-render.health').probe()` returns the entry in each of the four off cases set up by 3.2's tests.

## 4. The preview popup draws the image

- [ ] 4.1 In `preview.lua`, when the document carries an `images` entry and graphics is available, place the file after the window opens, sized to its interior, and record the placement id on the popup. Verify by hand in WezTerm that a PNG's popup shows the file; verify in the headless suite that the popup's buffer is still the artwork and its window geometry is unchanged.
- [ ] 4.2 Do not start playback and do not bind the pause or frame-step keys for a popup that has a placement, so those keys keep their ordinary meaning there. Verify with a headless check that the popup's keymap table has no entry for either key in that case.
- [ ] 4.3 Remove the placement in every close path — `M.close`, the `WinClosed` handler and the path that deletes a stale buffer — so no image outlives its popup. Verify with a headless test using a recording sender that close emits exactly one delete with the placed id, and that a second close emits none.
- [ ] 4.4 Verify the fallbacks are byte-for-byte the old popup: with `graphics = 'off'`, with no UI attached, with an image whose reference the engine could not draw, and with an engine that reports no `images` entry, no sequence is sent and the popup opens, plays and pauses exactly as the existing sections assert.

## 5. Documentation and integration

- [ ] 5.1 Document the option in `doc/md-render.txt`, regenerate `doc/tags`, and add a `README.md` paragraph on what graphics changes and how to turn it off. Verify `nvim --headless -u NONE -c 'helptags doc' -c q && git diff --exit-code doc/tags` and `bash tools/check-readme.sh`.
- [ ] 5.2 Rebuild `bin/md-render.exe` and run the CI gates from `CLAUDE.md` that touch this change: `cargo test --workspace --locked`, `cargo clippy -p md-render --all-targets --locked -- -D warnings`, `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua`, `nvim -l tests/interactive/run.lua`, and `openspec validate --all --no-interactive`.
- [ ] 5.3 Verify by hand in WezTerm: a still PNG and an animated GIF both show their file in the popup, the GIF plays with its own timing, the graphic disappears when the popup closes, and `graphics = 'off'` restores the text artwork. Record what was seen, since no automated test can.
