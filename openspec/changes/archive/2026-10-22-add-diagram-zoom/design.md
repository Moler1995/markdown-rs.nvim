# Design

## Context

See `proposal.md` — Why. The current state that shapes the approach:

- The preview popup picks its column budget once, when it opens, and never changes it
  (`lua/md-render/preview.lua`, `M.geometry`). A diagram gets `MAX_BUDGET = 65535`; a table gets the
  popup's inner width.
- The engine's only response to a diagram that does not fit is `clip_to_width`
  (`engine/src/document.rs`), which drops columns. Once dropped they are not in the buffer, so
  scrolling cannot reach them. That is the whole reason `MAX_BUDGET` exists.
- The engine already knows how to re-lay a diagram out to fit: `render_with_width`
  (`crates/mermaid-text/src/lib.rs`) walks `COMPACT_CONFIGS` for narrower gaps and then falls back
  to wrapping node labels proportionally to `max_lbl * budget / actual_w`. This works, and is
  limited: in practice a flowchart compacts from 108 to 87 columns and no further.
- Only flowcharts and state diagrams reach that pipeline. Every other kind `return`s early, and
  `DiagramKind::Sequence` returns `render::sequence::render(&diag)` with no width argument at all
  (`lib.rs:291`), so a sequence diagram is always laid out at its natural width and then clipped.
- Sequence layout is driven by label widths. `compute_layout` (`render/sequence.rs:265`) sets
  `box_width = (label_w + 2*BOX_PAD + 2).max(8)`, and `gap_mins[i]` is the widest message label
  spanning that gap plus `LABEL_PADDING`. Nothing else contributes to the width.
- `wrap_note_text` (`render/sequence.rs:517`) already wraps note text to a display-column budget,
  preserving explicit `<br>` breaks. It is the wrapping primitive this change reuses.

The reference case is the sequence diagram in
`D:\projects\go\k8s\llm-d\Wind.Traefik.LLM.Routing\docs\architecture.md` §2: seven participants,
`autonumber`, six `alt`/`else` branches, 357 display columns naturally, reported as 358 by
`strdisplaywidth` in a window with `wrap` on.

## Goals / Non-Goals

**Goals:**

- A reader can, from inside the popup, ask a too-wide diagram to be re-laid out to fit, and get the
  whole diagram rather than a crop.
- The engine can tell the plugin whether it discarded anything, so the popup never has to guess.
- Sequence diagrams participate in width-aware layout instead of ignoring the budget.

**Non-Goals:**

- Free-form scaling. The engine has no scale factor and this change does not add one; it re-lays
  diagrams out at a different width, which changes wrapping and spacing, not glyph size.
- Zooming tables. A table has no clipped state to escape, and a smaller budget only makes it worse.
- Remembering a zoom across popups, or auto-zooming on open. The popup still opens at the natural
  width, so the existing `block-preview` scenarios are unchanged.
- Any change to R. Zoom lives entirely inside the popup.
- Raising `MAX_BUDGET` or changing what a diagram's natural width is.

## Decisions

### `layout_width` on the wire, rather than a `clipped` boolean

The engine reports the widest display line it laid out, measured before truncation. Truncation
happened exactly when `layout_width > width`.

A boolean would be the direct answer to "was anything dropped", but it is a second source of truth
for a fact the lines already imply, and the two can disagree: a `clipped` flag computed at the
wrong point reports a document as whole while columns are missing, and nothing in the document
contradicts it. A width is checkable against the lines, and it is also the number the popup wants
to show the reader.

The alternative — the plugin computing the widest line itself — is not available. The plugin only
ever sees the truncated lines; that is the problem being solved.

`version` stays `1`. The field is additive, and a reader written against version 1 ignores unknown
fields. Bumping it would make an older plugin reject the entire document rather than one field,
which is a worse failure for a cosmetic gain.

`layout_width` covers the whole document, not diagrams alone, so the plugin does not have to know
which kind of block was truncated to notice that something was. It is computed where lines are
pushed, before `clip_to_width`, so there is one place that can get it wrong.

### Sequence diagrams are compacted by wrapping labels

The width of a sequence diagram is entirely a function of participant label widths and message
label widths. Both are wrappable text, and the crate already has the wrapper. So the compaction
pass is:

1. Lay out at the natural width. If it fits the budget, return it unchanged.
2. Compute a target label width, the same proportional estimate the flowchart fallback uses:
   `target = (max_label * budget / actual_width).max(MIN)`.
3. Wrap participant labels and message labels to `target` with `wrap_note_text`, re-lay out.
4. If it fits, return it. If not, step the target down and try again a bounded number of times.
5. If nothing fits, return the narrowest layout achieved, exactly as the flowchart path does — the
   document is still clipped by `clip_to_width` downstream, but less of it is lost.

Wrapping a participant label makes its box taller, and wrapping a message label means a message
occupies more than one label row. So `BOX_HEIGHT` stops being a constant and `EVENT_ROW_H` stops
being a constant; the row accounting in `render` becomes a function of the wrapped labels. This is
the bulk of the work and the reason the change is not a two-line edit.

Alternatives considered:

- **A proper constraint solver over the sequence layout.** Correct, and far more than this needs.
  The proportional estimate plus a bounded retry is what the crate already does for flowcharts, and
  matching it keeps one story rather than two.
- **Shrinking gaps only.** There is no headroom. `gap_mins` is already the minimum that fits the
  labels spanning it, and `MIN_GAP = 2` is a floor; the width is labels, not slack.
- **Leaving sequence diagrams clipped and relying on the popup's scrolling.** That is today's
  behaviour, and it is the thing the reader cannot use: the missing participants are not in the
  buffer to scroll to.

### Zoom has one target, not a ladder of rungs

Zooming out asks for the popup's own inner width. There is no ladder of smaller rungs worth
visiting: a budget of `inner` is the most permissive budget that achieves the reader's goal —
seeing the whole diagram without scrolling sideways — and if the engine cannot lay the diagram out
whole at `inner`, it cannot do so at any smaller budget either, since a smaller budget is strictly
harder. A budget below `inner` makes the diagram taller, not easier to read.

That reasoning holds, but it does not make the choice binary. There is a third budget between the
diagram's natural width and the popup's inner width: the narrowest one at which the engine still
lays the diagram out whole. The engine reports it as `layout_width`, and for the reference diagram
(`Wind.Traefik.LLM.Routing/docs/architecture.md` §2) it is **214** against a natural width of
**357**. That is not a budget any ordinary popup can reach — the popup's inner width is
`floor(vim.o.columns * 0.9) - 2`, which is 106 on a 120-column terminal and 178 on a 200-column
one — so it is exactly the case the "two rungs" picture had no place for.

The rungs are therefore the natural width, the popup's inner width, and — where the second clips —
the floor. Zooming out lands on the second when it can and on the floor when it cannot.

### A zoom-out is applied only when the result is whole

The popup asks the engine for a layout at the popup's inner width and compares the returned
`layout_width` against that budget. If it is within, that layout is what the reader sees. If it
exceeds, the popup asks again at `layout_width` itself: the engine's own report of the widest line
it laid out at is a budget at which its layout is whole by construction, so one more render lands
on the floor. If that is not narrower than what the reader already had, the popup keeps what it
had.

The thing that must never happen is showing a diagram with columns missing. That is what the popup
exists to avoid, and doing it silently while the reader pressed a key expecting *more* of the
diagram is worse than doing nothing.

But refusing outright — keeping the natural layout whenever `inner` clips — would make the zoom a
no-op on exactly the diagrams it was written for. The reference diagram's floor is 214, above every
ordinary popup's inner width, so "refuse when `inner` clips" leaves `-` dead on it. Falling back to
the floor gives the reader a diagram well under half the natural width with nothing dropped.

The reader's mental model survives either way: the diagram on screen is always whole, and if `-`
does nothing, the diagram is already at the narrowest whole layout there is. That last case is
settled without asking the engine. The popup records which of the three budgets it is sitting on
when it adopts a layout, so a key pressed with no rung left in the direction asked for returns
before the render: three budgets and no fourth means one of the two keys is always spent, and a
spent key that spawned a process to re-render the layout already on screen would be a round trip
whose answer the popup already had. The rung is recorded by the code that adopted the layout rather
than derived back out of `budget`, because the floor and the popup's inner width can be the same
number and a reader of the code should not have to work out which rung a budget implies.

### The popup's window does not resize on zoom

Only the content changes. A window that resized with each zoom would move and jump, and its new
inner width would be the input to the next zoom decision, which makes the ladder depend on its own
output. Fixing the frame also means `inner` is a constant for the life of the popup, so "does it
fit" is a stable question.

The cost is dead space to the right of a zoomed-out diagram. That is cheaper than a frame that
moves under the reader's hands.

### The zoom keys are bound in the popup, and inert for tables

`+` and `-` are bound in the popup buffer alongside `q` and `Esc`, so they shadow Vim's line
motions there. Inside a popup that is a reading surface, that is the same trade already made for
`q`.

In a table's popup the keys are bound and do nothing. Leaving them unbound would let them fall
through to the line motions, which is a different behaviour for the same key depending on what the
block happens to be; binding them and doing nothing is at least consistent, and it is what the
reader asked for.

### The popup scrolls sideways on one key per direction

Vim's sideways scrolling is `zh` and `zl`, and neither can be held. Pressing `z` and then holding `l`
sends `z` followed by a run of `l`: the first `l` completes `zl`, and the rest are cursor motions.
Measured, with the view at column 2, `zllll` leaves `leftcol` at 3 and moves the cursor from 3 to 6 —
one column of view and four of cursor. A reader crossing a block wider than the popup would have to
alternate `z` and `l` by hand.

So the popup binds one key per direction, with the count in the mapping itself (`6zl`), and holding
one repeats it. The count is read from the reader's own `'mousescroll'` rather than fixed at a
number, so the keys move the view by what a horizontal wheel notch moves it by: a reader with a tilt
wheel and one without see the same block move the same distance, and a reader who has tuned the
option gets what they tuned.

The alternative — a mapping that sets `leftcol` directly through `winsaveview`/`winrestview` — does
not work. Neovim constrains `leftcol` to keep the cursor visible, so a direct assignment is undone:
measured, four presses of such a mapping left `leftcol` at 6 and it never moved again. `zl` moves the
view and the cursor together, which is why a count is the way to set the step.

These keys are bound in a table's popup and are *not* inert there, unlike the zoom keys. The
difference is what each is for: a table has nothing to zoom away from, but it is laid out at a budget
floored at the window's, so it can be wider than the popup, and it has columns past the edge to
scroll to.

`<C-l>` is one of Neovim's own mappings — `nohlsearch`, then a redraw — so the popup shadows it. The
mapping is buffer-local, so R and S keep theirs, and `:nohlsearch` is still reachable from the
command line.

### The popup's title reports the zoom state

A zoomed diagram and a naturally narrow diagram look alike, and the difference matters — one can be
zoomed back in. The title carries the diagram's current layout width and its natural width, so the
state is legible without a second popup or a status message.

### The comment in `preview.lua` keeps its numbers and gains its source

The comment cites "a sequence diagram 358 columns wide laid out at 200". Those numbers are correct
and were measured: the diagram in `Wind.Traefik.LLM.Routing/docs/architecture.md` §2 is 357 columns
naturally, and `strdisplaywidth` reports 358 for it in a window with `wrap` on. They stay.

What changes is the sentence around them, because this change makes part of it false: the engine no
longer drops a sequence diagram's columns at a finite budget without first trying to re-lay it out.
The comment gains a provenance note naming the document, so a later reader can re-measure rather
than wonder where 358 came from.

## Risks / Trade-offs

- **The compaction floor may sit above the popup's inner width for the reference diagram**, in
  which case `-` does nothing on the exact diagram that motivated the change. Seven participants at
  a box width of at least 8 plus `MIN_GAP = 2` each is already ~68 columns before any message label
  is placed, and message labels add to the gaps. → Measure the floor for
  `architecture.md` §2 during implementation, before committing to `inner` as the only target. If
  the floor is above a typical popup width, the target has to change — most likely by letting the
  popup's cap be exceeded for a zoomed diagram, or by accepting a fit that still scrolls
  vertically. This is the first thing to check, not the last.
- **A zoomed-out sequence diagram is taller**, because wrapped labels add rows. The reader trades
  sideways scrolling for vertical scrolling. → Acceptable, and the popup already scrolls; but the
  compaction should stop stepping the target down once the layout fits, rather than aiming for the
  narrowest possible.
- **Layout width is not guaranteed monotone in the budget.** A different wrap point can change box
  widths and produce a wider layout at a smaller budget. → The design never assumes monotonicity:
  each candidate is rendered and measured, and a candidate that does not fit is rejected on its own
  measurements.
- **Sequence snapshots change.** Any committed snapshot of a sequence diagram rendered with a width
  budget will differ. → Only where a budget is supplied; the unbounded rendering is unchanged. The
  change to `strict_max_width.rs`, which documents in a comment that a sequence diagram "ignores
  `max_width` entirely", is part of this change rather than a surprise.
- **`layout_width` under-reported.** If a truncation site does not go through the tracked path,
  clipping goes undetected and the popup will adopt a clipped layout. → Compute it at the single
  push site, and assert in a test that a deliberately over-wide document reports a `layout_width`
  above the requested width.
- **Determinism.** This crate has had layout nondeterminism before, from `HashMap` iteration order
  reaching the layout. The wrapping pass adds a new ordering-sensitive step. → The `render-engine`
  spec already requires byte-identical output for the same input and width; the existing repeated-
  invocation tests cover it, and the compaction must not introduce a set or map into the layout
  path.
- **A wrapped label can be wrapped badly**, splitting a token that reads as one word. → Reuse
  `wrap_note_text`, whose behaviour for an over-long word is already established and snapshotted.

## Migration Plan

No migration. The wire field is additive and an older plugin ignores it; the plugin's zoom is
opt-in by keypress and the popup still opens at the natural width, so nothing a reader sees today
changes until they press `-`. Rollback is a revert of the change; a document emitted with
`layout_width` is still readable by an older plugin.

**Ordering constraint.** `nvim/block-preview` and `nvim/render-engine` exist only as deltas in the
two completed, unarchived changes `add-nvim-block-preview` and `add-nvim-full-render-mode`;
`openspec/specs/` is empty. `openspec validate` therefore reports that archiving this change would
refuse the `MODIFIED` delta for `nvim/block-preview`, because the target spec does not exist yet.
That is an ordering constraint, not an error in this change: archiving the two completed changes
first creates those specs, after which this change's delta applies cleanly. Archiving them is
outside this change's scope and is left to the reader.

## Open Questions

- Whether the popup's height cap should grow when a diagram is zoomed out and gets taller. Deferrable:
  the popup already scrolls, and the height cap is configurable.
- **Closed during implementation.** Whether the compaction floor is reachable in a typical popup.
  Measured against the reference diagram: it is not. The floor is 214 columns against a natural
  width of 357, while a popup's inner width is 106 on a 120-column terminal and 178 on a
  200-column one. The gate this question was guarding fired, and the answer is the floor fallback
  described in "A zoom-out is applied only when the result is whole". The measurements are
  recorded in `tasks.md` under 2.6.
