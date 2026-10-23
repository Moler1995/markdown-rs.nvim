# Tasks

Rust commands below assume the local GNU toolchain is on `PATH`:

```bash
export PATH="/d/tools/mingw64/bin:$HOME/.cargo/bin:$PATH"
```

## 1. Measure the baseline

- [x] 1.1 Measure the reference diagram before touching the code, and record the numbers here.
      Render `D:\projects\go\k8s\llm-d\Wind.Traefik.LLM.Routing\docs\architecture.md` §2 (section
      heading at line 54, fence at 56–89) through `render_wrapped(diag, Some(target))` for every
      target from 6 to the widest label, printing each arrangement's width and row count, plus the
      natural arrangement. Also render it through `render(diag, Some(278))` for the ladder-skip
      case. Verify the natural arrangement is 357 columns / 55 rows and the floor (target 6) is
      214 / 151, and that the 278 budget returns something near 228 / 123 while a 275-column,
      84-row arrangement also fits it. A temporary test inside `src/render/sequence.rs` is the
      cheapest way to reach the private `render_wrapped`; delete it before the group is done.

      **MEASURED.** `widest_label` is 69 columns, so the ladder's estimate is `69 * budget / 357`.
      Natural: 357 columns / 55 rows. The floor is target 6–7, at 214 / 151. Full curve, targets
      6–46:

      ```
      t  6 -> 214/151   t 12 -> 226/124   t 18 -> 244/108   t 24 -> 271/ 90   t 30 -> 289/ 79
      t  8 -> 218/147   t 13 -> 228/122   t 20 -> 246/106   t 25 -> 275/ 84   t 34 -> 298/ 75
      t 10 -> 220/142   t 14 -> 234/118   t 21 -> 263/102   t 26 -> 279/ 82   t 38 -> 319/ 69
      t 11 -> 222/128   t 17 -> 240/112   t 23 -> 270/ 92   t 29 -> 287/ 79   t 46 -> 326/ 67
      ```

      Through `render`: budget 214 → 41/20/10/6 → **214 / 151**; budget 278 → 53/26/13 →
      **228 / 122**, while targets 25–27 (275–279 columns, 82–84 rows) fit 278; budget 290 →
      56/28 → **287 / 80**, while targets 29–33 give 287–289 columns at **79** rows. The ladder
      costs 38 rows at 278 and 1 row at 290 — the skip is worst in the middle of the range, which
      is exactly where a popup's inner width falls.

## 2. A message label is wrapped to the space it occupies

- [x] 2.1 Re-wrap message labels in a second pass. After the pass-1 layout fixes `gap_mins` and the
      box widths, compute each message's available width as `per_gap * spans - LABEL_PADDING`
      (using the value `compute_layout` itself divided `label_need` into, not the raw sum of the
      spanned clearances), re-wrap that message's label to it, and re-lay out. Leave self-messages
      alone — their excursion is sized from their label, so they have no space to fill. Verify with
      a unit test that a diagram whose message label sits in a gap wider than the wrap target
      produces a layout whose `layout_width` is unchanged and whose row count is lower than the
      same target without the second pass, and that a self-message's label is byte-identical to
      what it was before.

- [x] 2.2 Verify no content is lost and no label is shrunk, as the spec's "No content is lost"
      scenario requires: assert over a compacted layout that every participant label, every message
      label's full text, and every block frame is present in the output (`cargo test -p
      mermaid-text`).

- [x] 2.3 Fix what 2.2's test found. A block's border row is placed at its message boundary and the
      event cursor advanced by 2 — one border row plus one row for the next label — so a label of
      three rows was drawn one row *above* the border and its upper rows were overdrawn by it.
      (Pre-existing, but only reachable with wrapped labels, which is exactly what compaction
      produces.) Advance by `message_lines[pos] - 1` extra for the rest of that message's label,
      once per boundary however many borders meet there, and add the same rows to the `block_rows`
      height budget. Measured cost on the reference diagram: the floor goes from 119 to 127 rows —
      those eight rows were being drawn *over* labels before.

## 3. The shortest fitting arrangement is chosen

- [x] 3.1 Replace the halving ladder in `render` with a descending scan: probe every target from
      the proportional estimate down to `MIN_LABEL`, measure each, and keep the best by (fewest
      display rows, then largest target). Apply a `MAX_PROBES` cap that strides the scan when the
      domain is larger, always including both ends. When nothing fits, keep the existing rule and
      emit the narrowest arrangement. Replace `COMPACTION_STEPS` with the new constant and rewrite
      the doc comments above it and above `render`, which currently describe the halving and the
      "first attempt that fits" return. Verify with tests that a budget with several fitting
      arrangements yields the shortest one (the measured 278-column case), that a budget no
      arrangement fits still yields the narrowest, that an unconstrained render is unchanged, and
      that two runs at the same width are byte-identical.

## 4. Re-measure, and stop if the gain is not there

- [x] 4.1 Repeat 1.1's measurement against the changed engine and compare. Record the floor's new
      width and height. The width is expected to stay at 214 — unbreakable tokens set it, and this
      change does not touch them — and the height is expected to fall. **If the floor's height does
      not fall materially, stop and report rather than finishing the change**: a change that removes
      a few rows does not justify the test churn in group 5, and the honest outcome is to say so.

      **MEASURED.** Floor: 214 / 127, down from 214 / 151 — the width is unchanged as expected and
      the height falls by 24 rows (16%). Targets 6–7 both sit at 214, 8–20 between 218 and 246, and
      the rest of the curve is 8–18 rows shorter than the target-wise baseline at every point. The
      gain is material, so the change continues.

      Through `render`, where the scan now replaces the ladder: budget 214 → **214 / 127**; budget
      278 → **275 / 80** (was 228 / 119 — 39 rows for no gain in width); budget 290 → **289 / 76**
      (was 287 / 76; equally tall, so the tie-break takes the least-wrapped target). Natural is
      untouched at 357 / 55.

## 5. Re-baseline the tests this moves

- [x] 5.1 Re-baseline the sequence cases rendered with a budget: `crates/mermaid-text/tests/
      snapshots.rs` (the width-constrained cases) and `crates/mermaid-text/tests/
      strict_max_width.rs`. Check the diff rather than accepting it wholesale: only cases that
      supply a budget may change, and every change should be a shorter arrangement at the same or
      narrower width. Verify with `INSTA_UPDATE=always cargo test -p mermaid-text` followed by
      `git diff` (`cargo test -p mermaid-text --test snapshots`, `--test strict_max_width`).

      **DONE.** Exactly one snapshot moved, `sequence_width_constrained_rendering` (the 80-column
      budget case); `strict_max_width.rs` is a property test and still passes unchanged, and no
      unbudgeted rendering moved. The snapshot went from 65 × 37 to 80 × 29 — eight rows shorter
      and fifteen columns wider, at exactly the 80-column budget. The width increase is the
      objective working as specified: the old ladder stopped at the first arrangement that fit, and
      a taller one happened to be narrower. The 29-row arrangement is the shortest that fits, and
      among the arrangements of that height it is the narrowest. `cargo test -p mermaid-text` is
      green.

- [x] 5.2 Re-measure `WIDE_SEQUENCE`'s compacted width in `engine/src/document.rs`. It is the
      premise of `TRUNCATING_WIDTH = 30`, three tests assert against it, and the comment above them
      describes the halving ladder this change replaces. Lower the constant if the compacted width
      moved, rewrite the comment, and verify with `cargo test -p md-render`.

      **MEASURED.** The compacted width is still 35 (natural 54 × 11, floor 35 × 19), so
      `TRUNCATING_WIDTH = 30` stands. It does not move because neither of the fixture's labels has
      an unbreakable token: at the floor target every gap is already set by the labels themselves,
      so the second wrapping pass has no room to give back — see the note added under the first
      design decision. The comment above the fixture now describes the scan instead of the ladder,
      and records that 35 was re-measured. `cargo test -p md-render`: 114 + 8 + 6 + 0 passing.

## 6. The plugin, which consumes these numbers

- [x] 6.1 Rebuild the engine, copy it over the local `bin/md-render.exe` (the plugin resolves
      `bin/` before `PATH`, so a stale copy would silently test the old compaction), re-measure
      `tests/fixtures/wide-diagram.md` and `tests/fixtures/zoom-diagram.md`, and update the
      assertions in `tests/headless/run.lua` that hardcode 113/108 and 166/64. Verify with
      `cargo build --release -p md-render`, `cp target/release/md-render.exe bin/md-render.exe`,
      and then `nvim --headless -l tests/headless/run.lua` plus the interactive suite.

      **MEASURED.** `wide-diagram.md`: natural 113 (20 rows), floor 108 (22 rows) — both unchanged,
      and 107 still clips, so section 13.3's numbers stand. `zoom-diagram.md`: natural 166
      unchanged; at a 70-column budget it is now **69 columns / 36 rows**, where the old search
      stopped at 64 / 40 — five columns wider, still inside the budget, four rows shorter. No
      assertion pinned 64 (the numbers in `run.lua` were comments), so the code change is the two
      comments plus the fixture's own prose. Headless: **498 checks, 0 failed, 82 engine spawns**.
      Interactive: **72 checks, 0 failed**.

- [x] 6.2 Restate `add-diagram-zoom` task 4.2's expected result with the new floor height, so the
      manual check has a number to look for instead of the shape of a diagram. Its width expectation
      stands: the floor is still 214, still above every ordinary popup's inner width.

      **RESTATED** in `add-diagram-zoom/tasks.md`: 214 columns / 127 rows (was 151), with the two
      things the manual check should specifically look for — a label no longer crushed into the
      gap, and no block border drawn over a label's text.

## 7. Integration check

- [x] 7.1 Run the whole workspace end to end against the rebuilt engine and confirm zero failures
      (`cargo test --workspace`, then `nvim --headless -l tests/headless/run.lua` and the
      interactive suite).

      **GREEN.** `cargo test --workspace`: **1441 passed, 0 failed**. Headless 498 / 0, interactive
      72 / 0, against the `bin/md-render.exe` rebuilt in 6.1.
