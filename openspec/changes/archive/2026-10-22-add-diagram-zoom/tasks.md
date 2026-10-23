# Tasks

Rust commands below assume the local GNU toolchain is on `PATH`:

```bash
export PATH="/d/tools/mingw64/bin:$HOME/.cargo/bin:$PATH"
```

## 1. The engine reports the layout width it laid out at

- [x] 1.1 Add `layout_width` to `WireDoc` in `engine/src/wire.rs` and compute it in
      `engine/src/document.rs` at the single point where display lines are pushed, before
      `clip_to_width` runs; verify with a unit test that a document whose lines all fit reports its
      widest line and one with an over-wide diagram reports a value above the requested width
      (`cargo test -p md-render`).
- [x] 1.2 Extend `engine/tests/corpus.rs` — the existing
      `no_fixture_emits_a_line_wider_than_the_requested_width` test — to also assert that every
      fixture's `layout_width` is at least its widest emitted line, and that a fixture containing a
      diagram too wide for the snapshot width reports a `layout_width` above that width
      (`cargo test -p md-render --test corpus`).
- [x] 1.3 Document `layout_width` in `docs/md-render-format.md`, next to `width`, stating that it is
      measured before truncation and that `layout_width > width` is exactly the condition under
      which the engine discarded columns; verify the document's field list matches `WireDoc` field
      for field (`cargo test -p md-render --test wire_format_doc`).

## 2. Sequence diagrams are laid out to fit

- [x] 2.1 Give `render::sequence::render` a width parameter and thread the budget through from
      `render_with_width` in `crates/mermaid-text/src/lib.rs`, replacing the early return that
      currently drops the width for `DiagramKind::Sequence`; verify a sequence diagram rendered
      with no width is byte-identical to today's output (`cargo test -p mermaid-text --test
      snapshots`).
- [x] 2.2 Make a participant's box height a function of its wrapped label, and a message's label
      row count a function of its wrapped label, replacing the `BOX_HEIGHT` and `EVENT_ROW_H`
      constants in the height and row accounting in `render` (`crates/mermaid-text/src/render/
      sequence.rs`); verify with a unit test that a single participant whose label is wrapped to
      two lines produces a box three rows taller and no wider than the wrapped label requires.
- [x] 2.3 Add the compaction pass: wrap participant and message labels with `wrap_note_text` to a
      target derived from `max_label * budget / actual_width`, re-lay out, and step the target down
      a bounded number of times until the layout fits; return the narrowest layout achieved when
      nothing fits. Verify with a test that a sequence diagram wider than its budget yields a
      render whose widest line is within the budget and that still contains every participant
      (`cargo test -p mermaid-text`).

      This invalidated three tests in `engine/src/document.rs` whose premise was that a sequence
      diagram is always clipped at a finite budget — the same staleness 2.5 corrects in
      `strict_max_width.rs`, one crate over. `WIDE_SEQUENCE` now compacts to 35 columns, so the
      tests that need a genuinely truncated layout take a `TRUNCATING_WIDTH` of 30 and the fixture's
      comment says why. Found by `cargo test --workspace` during 4.1, not by the `-p mermaid-text`
      run this task specifies.
- [x] 2.4 Add a `crates/mermaid-text/tests/snapshots.rs` case for a sequence diagram rendered at a
      budget below its natural width, snapshotting the compacted output, and confirm the
      unbounded-rendering snapshots are unchanged (`INSTA_UPDATE=always cargo test -p mermaid-text
      --test snapshots`, then `git diff` shows only the new snapshot).
- [x] 2.5 Correct `crates/mermaid-text/tests/strict_max_width.rs`, whose comment states that a
      sequence diagram's layout "ignores `max_width` entirely" and whose `SEQ` fixture is chosen
      for that property; pick a fixture whose natural width is what the budget tests need, and
      verify the whole file passes (`cargo test -p mermaid-text --test strict_max_width`).
- [x] 2.6 Measure the compaction floor for the reference diagram: render
      `D:\projects\go\k8s\llm-d\Wind.Traefik.LLM.Routing\docs\architecture.md` §2 at descending
      budgets and record the smallest budget at which its layout is whole. If that floor exceeds a
      typical popup's inner width, stop and raise it — the design's zoom target assumes the floor
      is reachable, and group 3 must not be built on that assumption until it holds.

      **MEASURED — GATE FIRED, STOPPED.** Through `md-render --width N` on the §2 fence:
      natural width **357** columns, compaction floor **214** columns (whole at 214, clipped at
      213 — `layout_width` is 214 at every budget from 20 up). The floor is set by tokens
      `wrap_note_text` cannot split, which only breaks on ASCII whitespace. The widest is
      `session/requestId/cookie/routeService,解析` at **42** columns as a single token, so the
      arrow crossing its gap needs ≥44 columns; the seven participant boxes at their minimum
      widths (`routing-decision-service` alone forces a 30-wide box) add ~119 more.

      A popup's inner width is `floor(vim.o.columns * 0.9) - 2` (`config.options.preview.
      max_width_pct` = 0.9): 70 at 80 columns, 88 at 100, 106 at 120, 142 at 160, 178 at 200,
      214 at 240. So the floor is only reachable on a ≈240-column terminal, and zoom-out on the
      reference diagram is a no-op on anything ordinary.

      Breaking long tokens at the wrap target would help but not resolve it: floor 146 at a
      8-column target, 176 at 12, 196 at 16, 208 at 20 — i.e. 146 is the best case, reachable at
      ≈165 columns. Raised, and decided: the popup falls back to the floor rather than doing
      nothing. `specs/nvim/block-preview/spec.md` and `design.md` were updated to match; the
      consequence for task 3.4 is written there.

## 3. The popup zooms

- [x] 3.1 Add `keymaps.zoom_in = '+'` and `keymaps.zoom_out = '-'` to the defaults in
      `lua/md-render/config.lua`, and extend the `8.1 default keymaps` assertion in
      `tests/headless/run.lua` to cover them (`nvim --headless -l tests/headless/run.lua`).
- [x] 3.2 Have the popup hold the block it is showing and the budget it was laid out at, and add a
      re-render path that lays the block out at a new budget and replaces the popup buffer's
      content in place without touching the window (`lua/md-render/preview.lua`); verify a popup's
      window id, size and position are unchanged across a zoom.
- [x] 3.3 Bind `keymaps.zoom_in` and `keymaps.zoom_out` in the popup buffer, alongside the existing
      close keys, and make them inert for a table's popup; verify in `tests/headless/run.lua` that
      both are bound in a diagram's popup, that invoking the zoom-out mapping on a table leaves its
      content unchanged, and that rebinding the keys takes effect while the defaults stop working.
- [x] 3.4 Implement the zoom-out decision: lay the diagram out at the popup's inner width; if the
      engine's reported `layout_width` exceeds that budget, lay it out again at `layout_width`
      itself — the narrowest budget at which the engine lays it out whole — and adopt that unless
      it is no narrower than what is already shown, in which case leave the content alone. Adopt a
      layout only when it is whole, never a cropped one. Implement zoom-in as a re-render at the
      engine's largest budget. Verify in `tests/headless/run.lua` that a zoom-out on a diagram that
      fits produces content no wider than the popup's inner width; that a zoom-out on a diagram
      whose floor is above the popup's inner width produces a whole layout narrower than it opened
      with, and that a further zoom-out at that floor leaves the content byte-identical; and that
      zooming back in restores the layout the popup opened with.

      The runner's terminal is 80 columns, so the popup's inner width is 70. `wide-diagram.md`'s
      sequence diagram is 113 columns naturally and 108 at its floor — above 70, so it covers the
      fallback. Nothing existing covered the other half, a diagram wider than the popup that the
      engine *can* lay out inside it, so `tests/fixtures/zoom-diagram.md` was added: 166 columns
      naturally, 64 at a 70-column budget.
- [x] 3.5 Handle an engine that does not report `layout_width`, so that a missing field reads as
      "unknown" rather than as "fits": a zoom-out against such an engine must not adopt a layout it
      cannot verify is whole. Verify with a stubbed engine response that omits the field.
- [x] 3.6 Title the popup with the diagram's current layout width and its natural width when it is
      zoomed, and leave the title as it is when it is not. Verify in `tests/headless/run.lua` that a
      zoomed popup's buffer name differs from an unzoomed one and carries both numbers.

      The label is `mermaid 108/113` once the two differ, and plain `mermaid` while they do not. It
      is carried by the window title and by the buffer name, which is set to
      `md-render-preview://<win>/<label>` so the state is also readable from `:ls` and `<C-g>`.
- [x] 3.7 Add a `13.x` section to `tests/headless/run.lua` covering the zoom behaviours above
      end to end against the real engine, and verify the whole suite passes (`nvim --headless -l
      tests/headless/run.lua`). 448 checks, 0 failed, 76 engine spawns.
- [x] 3.8 Fix the comment above `MAX_BUDGET` in `lua/md-render/preview.lua`: keep the 357/358
      figures, name the document they were measured from
      (`Wind.Traefik.LLM.Routing/docs/architecture.md` §2) so a later reader can re-measure, and
      correct the surrounding claim that a finite budget always drops a sequence diagram's columns,
      which task 2.3 makes false.
- [x] 3.9 Document the zoom keys and the new config fields in `README.md`: the two keys in the
      config example and in the block-preview section's prose, plus the paragraph on what the
      engine does with a diagram that does not fit. The zoom keys do NOT go in the
      `<!-- keymaps -->` table — that table is checked against R and S only, and these keys live in
      the popup — so verify the `8.5` check still passes (`nvim --headless -l
      tests/headless/run.lua`).
- [x] 3.10 Make a zoom key with nothing left to ask for return without reaching the engine
      (`lua/md-render/preview.lua`).

      Added at the user's request after 3.1–3.9 were done, and outside the design as it then stood.
      Measured first: the popup has three budgets and no fourth, so after one effective press the
      spent key was still spawning an engine process (1, or 2 for a zoom-out that falls back to the
      floor) to re-render the layout already on screen. The popup now records which budget it sits
      on — `rung`, one of `'natural'`, `'fits'` or `'floor'`, written by `M.adopt` because the
      adopter is what knows — and `M.zoom` returns early when the direction asked for has no rung
      left. `design.md`'s "A zoom-out is applied only when the result is whole" gained the
      paragraph, and `README.md` the sentence. Verified with a new `13.6` section that counts engine
      spawns: 467 checks, 0 failed, 79 engine spawns (was 448/76). Broken deliberately — the guard
      removed — to confirm the three new checks fail.
- [x] 3.11 Add `keymaps.scroll_left = '<C-h>'` and `keymaps.scroll_right = '<C-l>'` to the defaults
      in `lua/md-render/config.lua`, and bind them in the popup buffer in
      `lua/md-render/preview.lua` as one holdable key per direction
      (`nvim --headless -l tests/headless/run.lua`).

      Also added at the user's request, in the same breath as 3.10, and also outside the design as
      it then stood. The problem is that `zh` and `zl` are two keystrokes each, so there is no key
      to hold: measured, with the view at column 2, `zllll` leaves `leftcol` at 3 and moves the
      cursor from 3 to 6. The popup now binds one key per direction with the count in the mapping
      (`6zl`). The count is read from the reader's `'mousescroll'` (`hor:6` by default) rather than
      fixed, so the keys and a horizontal wheel move the view by the same amount. A mapping that set
      `leftcol` through `winsaveview`/`winrestview` was tried and does not work — Neovim constrains
      `leftcol` to keep the cursor visible, and four presses left it at 6.

      Unlike the zoom keys these are bound in a table's popup and are not inert there: a table is
      laid out at a budget floored at the window's, so it can be wider than the popup too. `spec.md`
      gained a requirement and five scenarios, `design.md` a decision section, `README.md` the
      config fields and a paragraph — including the one consequence worth stating, that `<C-l>` is
      one of Neovim's own mappings (`nohlsearch` plus a redraw) and the popup shadows it, buffer-
      locally. Verified with a new `13.7` section: 498 checks, 0 failed, 82 engine spawns. Broken
      deliberately — the count dropped from the mapping — to confirm five of the new checks fail.

## 4. Integration checks

- [x] 4.1 Run both suites end to end against the rebuilt engine and confirm zero failures
      (`cargo build --release -p md-render`, then `nvim --headless -l tests/headless/run.lua` and
      the interactive suite).

      `cargo build --release -p md-render` then `cp target/release/md-render.exe bin/md-render.exe`
      (the plugin resolves `bin/` before `PATH`, so a stale copy there would have been used).
      `cargo test --workspace` 0 failed; headless 448 checks, 0 failed, 76 engine spawns;
      interactive 72 checks, 0 failed.
- [x] 4.2 Drive the zoom by hand in a real terminal against
      `Wind.Traefik.LLM.Routing/docs/architecture.md` §2: open the preview on the sequence diagram,
      confirm it opens at its natural width (357 columns, 55 rows) and scrolls sideways, press the
      zoom-out key, and confirm no participant is missing. The diagram's floor is 214 columns,
      above the popup's inner width on any ordinary terminal, so the expected result is a whole
      layout at 214 — well under half the natural width, still needing sideways scrolling — not a
      diagram on screen whole, and not a crop.

      **Restated by `improve-sequence-compaction`:** the floor is now **214 columns / 127 rows**,
      down from 151 rows. The width is unchanged on purpose — unbreakable tokens set it — so the
      check is still "whole at 214, still scrolls sideways". What is new is what to look for in the
      height: no message label should occupy six rows in a fourteen-column gap, and no block
      border should be drawn over a label's text (the `alt`'s top border used to eat the middle
      row of the first label when that label wrapped). Pressing zoom-out again at that floor must
      still change nothing.

      **Observed 2026-10-22, accepted by the reader:** the popup opens the sequence diagram at its
      natural width and scrolls sideways; one press of the zoom-out key gives a whole layout at the
      214-column floor — narrower than half the natural width, still needing sideways scrolling —
      with every participant present and no crop. No message label took six rows in a fourteen-column
      gap, no block border crossed a label's text, and pressing zoom-out again at the floor left the
      picture unchanged.
