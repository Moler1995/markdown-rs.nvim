# Design

## Context

See `proposal.md` — Why. The current state that shapes the approach:

- `render(diag, max_width)` (`crates/mermaid-text/src/render/sequence.rs:844`) lays the diagram out
  naturally; if that fits, it returns it. Otherwise it computes one proportional estimate —
  `target = widest_label * budget / actual_width`, floored at `MIN_LABEL = 6` — and then tries at
  most `COMPACTION_STEPS = 4` targets, **halving** each time, returning the first attempt that fits
  and otherwise the narrowest attempt seen.
- `render_wrapped(diag, wrap)` (`:908`) is the single place wrapping happens. It wraps every
  participant label and every message label to `wrap` and then everything downstream — box widths,
  gap minimums, row heights, the drawing passes — reads the wrapped text. Its comment says so: the
  alternative is a wrapped diagram drawn into rows sized for an unwrapped one.
- `compute_layout` (`:284`) turns wrapped labels into geometry: `box_width = max_line_width(label)
  + 2 * BOX_PAD + 2`, floored at 8; and `gap_mins[i] = max over messages spanning gap i of
  (max_line_width(label) + LABEL_PADDING)`, divided across `spans` when the diagram has no
  activations. So a message label's *wrapped* width is what sizes the gap it sits in.
- `wrap_note_text` breaks only on ASCII whitespace, never truncates, and never splits an over-long
  token. An unbreakable token therefore sets a hard floor on the gap it sits in, which is where the
  reference diagram's 214-column floor comes from.

Measured on the reference diagram (`Wind.Traefik.LLM.Routing/docs/architecture.md` §2) by calling
`render_wrapped` at each target directly:

```
natural   357 columns /  55 rows
target 29 287 columns /  79 rows
target 25 275 columns /  84 rows
target 20 246 columns / 106 rows
target 12 226 columns / 124 rows
target  6 214 columns / 151 rows   <- the floor
```

Two things fall out of that table. Rows are dominated by message labels, not by boxes: the boxes
grow from 3 rows to 5, but the diagram grows by 96. And the width is *not* controlled by the
target over most of its range — from target 12 to target 6 the width moves 12 columns while the
height moves 27 rows, because the gaps are already pinned by unbreakable tokens.

## Goals / Non-Goals

**Goals:**

- For a given budget, the arrangement emitted is the shortest one that fits, and it is the same one
  on every run.
- No label is wrapped narrower than the space it is drawn into.
- The search's cost is bounded and small compared with the rest of rendering a document.

**Non-Goals:**

- Lowering the floor below 214 by breaking unbreakable tokens. Task 2.6 of `add-diagram-zoom`
  measured that path (floor 146 at an 8-column target, 176 at 12, 196 at 16) and it does not reach
  a typical popup's inner width either. It is a separate trade-off about splitting identifiers and
  is left out.
- Changing what the popup asks for, or the popup at all.
- Changing `wrap_note_text`'s contract. Notes are wrapped to their own placement budget already and
  are untouched.

## Decisions

### A label is wrapped twice: once to size the gaps, once to fill them

Pass 1 wraps every label to the target and computes the layout, which fixes the gap widths. Pass 2
re-wraps each message label to the width available to it along its arrow, and the layout is
computed again.

The width cannot grow, and this is worth stating precisely because the second pass could otherwise
run away. Available width for a message is taken as `per_gap * spans - LABEL_PADDING`, where
`per_gap` is the value `compute_layout` divided its `label_need` into — not the raw sum of the
spanned clearances, which can be larger than `spans * per_gap` and would let the recomputed
`div_ceil(spans)` exceed the gap that was already allocated. With that cap, the re-wrapped label's
widest line plus `LABEL_PADDING` is at most `per_gap * spans`, so `compute_layout` reproduces
exactly the same `gap_mins`. Every term of the `max` is now larger and none is above the old value,
so every gap is exactly where it was:

- the layout width is unchanged — this is the spec's "the arrangement does not widen";
- the row counts drop, because each label now occupies the rows its space actually allows.

Two passes are enough, not because the second pass happens to converge but because its output is a
fixpoint: the gap set is unchanged, so a third pass would compute the same available widths and
produce the same labels.

The fill can only give a label room the first pass already allocated. At a very small target every
gap is set by the labels themselves — 8 columns at `MIN_LABEL` — so there is nothing to fill, and a
diagram whose labels are all breakable is exactly as tall at the floor as it was before. That is
measured, not assumed: `WIDE_SEQUENCE` in the engine's tests still compacts to 35 columns, and the
reference diagram's gain comes from gaps pinned by long identifiers and by the participant boxes
either side. What the scan adds is independent of this: when a budget *does* fit, the arrangement
chosen is the shortest one rather than whichever target halving happened to reach first.

Two cases are deliberately left alone. A **self-message** has no gap to fill — its excursion is
sized *from* its label, so there is no available width to wrap to; the 42-column token in the
reference diagram is a self-message label and stays one row. A **note** is wrapped to its own
placement budget already and is not a message label.

Alternative rejected: wrapping message labels to their natural width and letting the gaps follow.
That reads well at large widths and cannot compact at all, because the gaps would never shrink.

Alternative rejected: sizing gaps from the *unwrapped* label. Same failure from the other side — the
target would stop having any effect on width.

### A block border reserves the label beneath it

Task 2.2's test found a case the spec's "No content is lost" scenario already forbids: a block's top
border is placed at its message boundary and the row cursor advanced by 2 — one border row, one row
for the message's label — so a label of three rows starts two rows *above* the border and its upper
rows are drawn over. The defect predates this change, but it is only reachable with wrapped labels,
which is precisely what compaction produces: at the floor the reference diagram loses the middle
line of its first message label under `alt`'s border.

The fix is to advance by the label's remaining rows (`message_lines[pos] - 1`) after all events at a
boundary, and to add the same rows to the height budget. It is once per *boundary*, not per border:
several blocks can meet at one boundary and they share the single label below it. Single-line labels
are unaffected (`saturating_sub(1)` is zero), so no unwrapped rendering moves. The reference
diagram's floor grows from 119 to 127 rows, and those eight rows were previously drawn over text.

### The search scans downward and keeps the shortest fitting arrangement

Halving is replaced by a descending scan over the target domain `MIN_LABEL..=estimate`, measuring
each probe, and keeping the best by (fewest display rows, then narrowest, then largest target).

Rows come first because they are what the reader scrolls. Width breaks the tie rather than being
ignored, because at equal height the narrower diagram costs nothing and is what the caller sizes a
popup from — the wire's `layout_width` is the floor rung's width. The reference diagram shows the
difference: at a budget of 290 the targets from 28 to 33 are all 76 rows, and the narrower of them
is 287 columns against 289. The target is only a last tie-break, so two equally tall, equally wide
arrangements still resolve the same way on every run.

The domain is bounded without extra machinery: `estimate = widest_label * budget / actual` is at
most `widest_label`, so the scan is at most `widest_label - MIN_LABEL + 1` probes. For the
reference diagram that is 37 probes; measured, 41 `render_wrapped` calls on it take 0.14 s in an
**unoptimised** build, so the release cost is a few milliseconds — and the engine is spawned once
per preview, not per keystroke.

A `MAX_PROBES` cap is still applied, striding the scan when the domain is larger and always
including both ends. It can only bind for a label wider than about 260 columns, and when it binds
the engine still emits a fitting arrangement, just not provably the shortest.

### Rows, not width, is the objective

The budget is a ceiling, not a target. Once an arrangement fits, narrowing it further buys the
reader nothing — the popup is the same width either way — while every extra row is a row they have
to scroll. So the slack below the budget should be spent on height, and the arrangement chosen is
the shortest that fits rather than the narrowest available.

That is the reverse of what happens today when nothing fits, and the reverse is still right there:
with no fitting arrangement, narrowness is the only thing left to optimise, and the narrowest
arrangement is what the engine emits. The two rules are consistent — fit first, then height, then
width.

Note this also fixes the behaviour that made `add-diagram-zoom` task 4.2 read badly. At a budget of
278 columns the halving ladder returns a 228-column, 123-row layout, while a 275-column, 84-row
layout fits the same budget. The reader does not care that 228 is narrower than 275; they care
about the 39 rows.

### Why not simply iterate to a fixpoint

The obvious generalisation — re-wrap, re-layout, repeat until nothing changes — is not needed and
would not be better. The two-pass construction already terminates at a fixpoint after one
re-wrap, and any further iteration would be re-deriving the same labels. The scan is the outer
loop, over targets; the two passes are the inner work for one target. Keeping them separate is what
lets the width guarantee be argued once, in one place.

## Risks / Trade-offs

- **Layout width is not monotone in the target.** A different wrap point changes box widths, and
  the design never assumes otherwise: every probe is rendered and measured on its own. But it does
  mean the scan cannot use binary search to find the shortest fitting arrangement, which is why it
  enumerates. → Enumeration is bounded by `MAX_PROBES`.
- **The floor may not get much shorter.** The re-wrap removes rows, not columns; the floor stays at
  214 because unbreakable tokens set it. If the height gain turns out to be small, the change is
  not worth its churn. → Measure the floor's height before and after as the first task, and stop
  and report rather than shipping a cosmetic change.
- **Sequence snapshots and budget fixtures change.** Any test that renders a sequence diagram *with*
  a budget will differ; renderings with no budget are untouched. → Re-baseline deliberately, and
  check in the diff that only budget-supplied cases moved.
- **`engine/src/document.rs` loses its truncation premise.** `TRUNCATING_WIDTH = 30` exists because
  `WIDE_SEQUENCE` compacts to 35 columns and the tests need a diagram that genuinely cannot fit. A
  scan that finds a 30-column arrangement would make three tests assert nothing. → Re-measure the
  compacted width and lower the constant if it moved, as task 2.3 of `add-diagram-zoom` did for the
  same reason.
- **Determinism.** This crate has had layout nondeterminism before from `HashMap` iteration order.
  The two new steps are a linear scan and a per-message re-wrap over `diag.messages` in order, so
  neither introduces a map or set into the layout path — but the coupling between `render_wrapped`
  and `compute_layout` now runs twice, which is one more place to get the ordering wrong.
- **The plugin's asserted engine numbers move.** `tests/headless/run.lua` asserts 113/108 for
  `wide-diagram.md` and 166/64 for `zoom-diagram.md`. → Re-measure against the rebuilt engine and
  update the assertions; those fixtures are sequence diagrams and their floor is exactly what this
  change moves.

## Migration Plan

No migration: the change is inside the diagram renderer, the wire format is untouched, and the
plugin keeps asking for the same budgets. Refresh the local `bin/md-render.exe` from the rebuilt
engine before running the plugin's suite, because the plugin resolves `bin/` before `PATH`. Rollback
is a revert.

**Ordering constraint.** `openspec/specs/` is still empty: `nvim/render-engine` exists only as a
delta inside the unarchived changes `add-nvim-full-render-mode` and `add-diagram-zoom`. This
change's delta is therefore against a capability whose main spec does not exist yet, and
`openspec validate` reports that archiving it would refuse the delta until those two are archived
first. That is the same ordering constraint `add-diagram-zoom` recorded, not a defect in this
change.

## Open Questions

- Whether to lower the diagram's floor by breaking unbreakable tokens. Deferred with measurements:
  `add-diagram-zoom` task 2.6 puts the best case at 146 columns, still above a typical popup's inner
  width, at the cost of splitting identifiers mid-word. Nothing in this change depends on the
  answer.
