# Tasks

## 1. Locating the block

- [x] 1.1 Add `lua/md-render/preview.lua` with `find_fence(lines, line)`: scan for a backtick or
      tilde fence whose info string is exactly `mermaid` and whose range contains `line`, returning
      its first and last line indices and its body. Verify with headless tests covering an indented
      fence, a `~~~` fence, a `mermaid` fence the anchor sits outside of, a non-mermaid fence, and an
      unterminated fence (which must not match).

- [x] 1.2 Add `find_table(lines, line)`: extend up and down from the anchor over non-blank lines
      containing `|`, and accept the run only when it has at least two lines and its second line is a
      delimiter row. Verify with headless tests covering a table with and without outer pipes, a
      right/centre-aligned delimiter row, a pipe-bearing paragraph (must not match), and the known
      divergence from design D5 — a table followed with no blank line by a pipe-bearing paragraph —
      asserted so the divergence is pinned rather than discovered later.

- [x] 1.3 Add `locate(doc, row, lines)` returning the block under a display row: anchor through
      `render.source_line_for`, then try the fence and then the table. Verify with headless tests that
      a table's border row resolves to its table, that any row of a diagram's artwork resolves to its
      fence, and that a row on prose returns nil.

## 2. Rendering one block at a given width

- [x] 2.1 Add `render_block(opts, block, width, cb)`: join the block's source lines and hand them to
      `engine.render` unchanged — a fence slice is itself a fenced diagram and a table slice is itself
      a table, so no wrapper is added. Verify with a headless test that renders one table at width 40
      and at width 120 and asserts the 120-wide result is wider, which is the spec's "columns the
      window clipped are present" made observable.

- [x] 2.2 Route an engine failure to the plugin's existing `report`-style diagnostic and do not open a
      popup. Verify with a headless test that points the engine at a non-existent binary, presses the
      preview path, and asserts no window was created and a diagnostic was reported.

## 3. The popup window

- [x] 3.1 Add `open(doc, geometry)`: create a scratch buffer (`buftype=nofile`, `bufhidden=wipe`,
      `swapfile=false`, `modifiable=false`, `buflisted=false`), paint it with `render.apply`, and
      open it centred with `relative='editor'`, `style='minimal'`, `wrap=false`, a rounded border and
      a title naming the block kind. Verify with headless tests that assert the window config, that
      the buffer is unlisted and unmodifiable, and that a small block gets a popup no larger than the
      block while an oversized one is capped at the configured fraction — the window is clamped to
      the cap even where the content laid out at the budget (3.3) is wider, which is what makes the
      block scrollable inside it.

- [x] 3.2 Add the close paths: the preview key, `q`, `Esc`, and a `WinClosed` handler that discards
      the popup's buffer and clears its state. Verify with a headless test that opens a popup, closes
      it by each route in turn, and asserts the window is gone, the buffer is no longer listed, and
      the window underneath still holds the same buffer, cursor line and view — the spec's "the view
      underneath is untouched" scenario.

- [x] 3.3 Add `geometry(kind, window_budget)`: the caps from the config, the editor's size, the
      popup's inner width, and the layout budget — chosen per kind (design D3). A table's budget is
      the inner width **floored at `window_budget`**, so that the popup never holds less of the table
      than the window did; a diagram's is the largest budget the engine accepts (`--width` is a
      `u16`, so 65535), because the engine discards the columns of a diagram that do not fit and
      discarded columns are not in the buffer for scrolling to reach. Verify with a headless test
      that for a table in a window as wide as the cap the budget equals the window's and in a
      narrower window it is the larger of the two, and that for a diagram the budget is the engine's
      maximum at every window width.

## 4. Wiring, configuration and the fall-through

- [x] 4.1 Add `keymaps.preview` (default `<CR>`) and `preview = { max_width_pct = 0.9,
      max_height_pct = 0.9 }` to `lua/md-render/config.lua`, and document both in `README.md`'s
      config block. Verify with a headless test that the deep merge holds — setting
      `preview = { max_width_pct = 0.5 }` keeps the height default — and that
      `keymaps = { preview = false }` leaves the key alone, matching the existing `toggle`/`write`
      convention. Verify the README's documented default matches the code by reading it back.

- [x] 4.2 Export `M.preview(win)` from `lua/md-render/init.lua` and bind the preview key in
      `M.set_keymaps` in the R branch only, so it is set in the rendered buffer and not in the source
      buffer. Verify with a headless test that asserts the mapping exists in R and is absent in S, and
      add the key's row to the README keymap table.

- [x] 4.3 Implement the fall-through from design D6: when `locate` finds no block, re-feed the key
      with `nvim_feedkeys(..., 'n', ...)` so it performs its ordinary editor action. Verify in the
      interactive runner, not headlessly — `nvim -l` never runs the main input loop, so a key queued
      by `nvim_feedkeys` is never read there. The check is that `<CR>` on prose moves the cursor to
      the first non-blank of the next line and opens no popup, which is also what proves the `'n'`
      flag is preventing the mapping from re-entering itself.

## 5. Integration checks

- [x] 5.1 In the interactive runner, **split the window** so it is narrower than the preview cap,
      open a document containing both a diagram and a table wider than that window, press the preview
      key on each, and assert that the popup's widest line exceeds the window's width in both cases —
      the end-to-end form of the spec's "a window narrower than the cap" scenario, exercising block
      location, rendering and popup geometry together. The split is not incidental: with one
      full-width window a table's budget is floored at the window's (design D3) and so cannot
      exceed it, which is what 5.3 covers instead.

- [x] 5.2 In the interactive runner, open a preview over a wide table, close it, and assert the
      window is still in R on the same buffer with the same cursor line and top line as before the
      preview opened.

- [x] 5.3 In the interactive runner, with the window at the full editor width — so a table's budget
      is floored at the window's — preview a table wider than the popup and assert that the popup's
      buffer holds no fewer columns than the window's rendering did, and that the popup's window is
      narrower than that content, so the rest is reachable by scrolling. This is the spec's "a window
      as wide as the cap" scenario, and the check that the floor in 3.3 is doing its job.

- [x] 5.4 *(added scope — the diagram half of the revised D3, which the plan did not have; 3.3's
      original floor was wrong for diagrams and the preview could not show one whole.)* In the
      interactive runner, preview a **diagram** wider than the popup's own inner width
      and assert that the popup's buffer holds more columns than that inner width. The threshold is
      what makes this a check of the budget rather than of the window: in a narrow window any budget
      derived from the window or the popup is at most the inner width, so content wider than it is
      content the popup did not clip. Add `tests/fixtures/wide-diagram.md` for it — a fixture of its
      own rather than a second fence in `wide.md`, because `wide.md`'s window-wide measurement is
      what 5.3 compares against and a diagram the window clips to its full width would move it.
      Verified by mutation: with the budget reverted to the floored popup width for both kinds,
      5.4's two checks fail and the suite is 72/2.

- [x] 5.5 Fix `widest` in `tests/interactive/server.lua` to measure a buffer in the context of the
      window the width is meant for. `strdisplaywidth` is not a property of the string alone — it
      simulates the line's display in the *current* window, so `'wrap'`/`'linebreak'` change it (the
      same 358-column artwork measures 358 with `wrap` on and 357 with it off). An open popup is
      `wrap=false` and takes focus, so `popup_widest` was being measured in a different context from
      `window_widest` and could report one or two columns fewer for no reason but the measurement —
      which would have made 5.3's and 5.4's comparisons drift by a column. Found while checking the
      fix against the document that motivated the change, where it read 357 for a diagram the engine
      renders at 358.

## 6. Pinning the vendored layout patch end to end

Why this is here rather than in a change of its own: a preview is a second render of the same block,
so it is where a nondeterministic layout becomes visible to the user (design D11). Today nothing
pins that the vendored `ascii-dag` patch actually applies.

- [x] 6.1 Add a diagram with subgraphs whose block average positions tie — the shape that reaches the
      tie in `block_partition_level`
      (`crates/ascii-dag/src/algorithms/sugiyama/subgraph.rs:92-137`) — to
      `engine/tests/fixtures/diagrams.md`, including a state diagram with a composite state, which
      reaches the same path without ever spelling `subgraph`. Regenerate the corpus snapshot and
      confirm the diff is an addition only: no existing diagram's output changes, which is what shows
      the patch's effect is confined to the tied case. Record the pin beside the ascii-dag entry in
      `VENDORED.md`.

- [x] 6.2 Confirm the fixture reaches the bug rather than merely looking like it does: revert the
      backported fix inside the vendored crate, leave it uncommitted, run the corpus test and require
      it to fail, then restore. Without this step the fixture may be a diagram that happens not to
      tie.

- [x] 6.3 Confirm the engine is actually using the vendored crate and not a registry copy: `cargo
      tree` must resolve `ascii-dag` to `crates/ascii-dag` rather than to a crates.io version. This
      is the check that fails silently today — the crate's own regression test passes as a workspace
      member whether or not the patch redirects anything.

## 7. Not adopting floats (added scope — see design D12)

These two tasks were not in this change's plan. They are recorded here because the work was done
during this change's implementation and because 5.1-5.3 cannot pass without it: the popup is a
float, and the plugin was attaching it as if it were a split of R.

- [x] 7.1 In `M.setup_autocmds`'s `WinEnter` handler (`lua/md-render/init.lua`), return early for a
      floating window — `cfg.relative ~= '' or cfg.external` — before the window's buffer is read.
      `nvim_open_win` fires `WinEnter` for the new float before swapping its own buffer in, so the
      float still holds the buffer it was opened over; reading it made the float match the
      split-inheritance rule, which then gave the float a rendered buffer of its own and wiped the
      preview's. The guard is on the window, not on the buffer, because the buffer is what is wrong
      at that moment.

- [x] 7.2 Pin it with a headless regression test that opens a **plain** float over R — not a preview
      — and asserts the float still shows the buffer it was opened with, that the plugin holds no
      state for it, that R is untouched, and that closing the float leaves R in R. Deliberately not a
      preview-shaped test: the defect is general (any hover or completion float opened over R had it
      too), and a test written against the preview would pass while the general rule stayed broken.
      Verified by mutation — without the guard, `11.3 and is not attached as a window of its own`
      fails; with it, the suite is 267 checks, 0 failures.
