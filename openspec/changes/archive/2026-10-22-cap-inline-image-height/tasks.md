# Tasks

## 1. Option and inline bound

- [x] 1.1 Add `image_max_height = 20` to `config.defaults` in `lua/md-render/config.lua`, with a comment stating the unit (display rows), that the aspect ratio carries the width, that `false` restores the previous window-only bound, and that the preview popup is not affected.
- [x] 1.2 In `lua/md-render/init.lua`'s `request`, compute the height bound as the smaller of `page_height(win)` and `config.options.image_max_height`, treating `false` (and any non-positive value) as "no cap". Verify headless tests on the harness's 8-row window (which the default of 20 cannot bind): with `image_max_height = 4` the engine is asked for `--image-max-height 4`, and with `false` it is asked for the window's text height. The default itself is asserted as `config.defaults.image_max_height == 20`.
- [x] 1.3 Verify the cap reaches the artwork: a headless test on the 16×16 fixture (8 rows uncapped at width 80) that with `image_max_height = 4` the artwork is at most 4 rows tall and correspondingly narrower than 16 columns, and one with `false` that asserts the 8-row artwork is back.

## 2. Preview stays uncapped

- [x] 2.1 Verify the popup is unaffected: a headless test that spies on `engine.render` for `preview.view` of an image and asserts the requested height is the popup's own bound (`geometry.max_h - 2`), not `image_max_height`, with the option at its default.

## 3. Documentation and checks

- [x] 3.1 Document `image_max_height` in `README.md` (default 20 rows, width follows the aspect ratio, `false` restores the window-only bound, the preview is not capped) and verify the documented name and default match `config.lua`.
- [x] 3.2 Run `nvim -l tests/headless/run.lua` and `cargo test --workspace`; confirm zero failures.
- [x] 3.3 In Windows Terminal, open the document that motivated this change: confirm the inline image is visibly smaller than the full text width and that `<CR>` still opens it at the popup's size; record what was observed.
  - Observed 2026-10-22, accepted by the reader: the inline artwork is a figure on the page rather than a page-filling picture — 71×20 in the 126-column window, where the uncapped bound is 126×35 — and `<CR>` still opens the popup at the popup's own size, larger than the inline drawing. `image_max_height` is not consulted by the popup.
