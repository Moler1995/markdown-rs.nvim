# Proposal

## Why

Zooming a wide sequence diagram out costs far more height than it buys in width, and most of that
cost is the compaction pass's own doing.

Measured on the reference diagram — `Wind.Traefik.LLM.Routing/docs/architecture.md` §2, seven
participants, the same document `add-diagram-zoom` measured its floor against:

```
natural   357 columns /  55 rows
floor     214 columns / 151 rows
```

One zoom-out narrows it by 40% and makes it 2.7× taller. On any ordinary terminal the popup's
inner width (70 at 80 columns, 106 at 120) is still below 214, so the reader is scrolling sideways
anyway — the press bought almost nothing and cost 96 rows. Task 4.2 of `add-diagram-zoom` is the
manual check that surfaced this, and it is still open.

Two causes, both in `render::sequence::render`'s compaction pass:

1. **Message labels are wrapped to the diagram-wide label target.** That target exists to size the
   *gaps* between lifelines. Every message label is also wrapped to it, even though the space a
   label occupies is usually wider than the target — and once the target has been stepped down to
   `MIN_LABEL = 6` to reach a width the diagram can barely make, labels with room for two rows are
   crushed into six. Measured on the floor layout: `Header.Set 覆盖注入 routeService + cookie 名`
   occupies **6 rows** in a gap **14 columns** wide.

2. **The target ladder halves, so it skips the targets that would have fitted.** From a
   proportional estimate it tries `t`, then `t/2`, then `t/4`, and returns the first attempt that
   fits. Measured: at a budget of 278 columns it returns a **228-column, 123-row** layout, when a
   **275-column, 84-row** layout fits the same budget — 39 rows thrown away, and no narrower a
   diagram either.

The second cause is the one that shows up at budgets the popup actually asks for, on wider
terminals; the first is what makes the floor itself so tall. Both make the reader's zoom key worse
than it should be, and neither is load-bearing: no arrangement is lost by fixing them.

## What Changes

- A diagram arranged to fit is arranged no taller than it needs to be: each message label is
  wrapped to the width it actually occupies in the resulting layout, rather than to the
  diagram-wide label target.
- Where more than one arrangement fits the requested width, the engine emits one with the fewest
  display rows, instead of the first arrangement its search happens to reach.
- The search for a fitting arrangement stops being a halving ladder and becomes a bounded scan, so
  that it cannot skip past the good targets and cannot run unbounded work on a large diagram.
- The content guarantees are untouched: no participant, message, note or block frame is dropped,
  a diagram that already fits its budget is still returned byte-identically, and a diagram
  rendered with no budget is still laid out exactly as written.

**Not** changing: the plugin. `add-diagram-zoom` already made the popup ask for the right budgets;
this change is only about what the engine answers with. The one plugin-side consequence is that the
numbers its headless suite asserts about the engine have to be re-measured.

## Capabilities

### New Capabilities

None. Both obligations belong to the existing `nvim/render-engine` capability, which already covers
arranging a diagram to fit a requested width.

### Modified Capabilities

- `nvim/render-engine`: two added requirements — a fitted arrangement is no taller than its labels
  require, and among arrangements that fit, the shortest is the one emitted. The capability's
  existing "Diagrams are laid out to fit rather than clipped" requirement is unchanged and still
  holds; so is "Deterministic output", which the new search has to respect.

## Impact

- `crates/mermaid-text/src/render/sequence.rs` — the target search in `render`, and the label
  wrapping in `render_wrapped`. `compute_layout`'s `gap_mins` derivation is the constraint the
  re-wrap has to satisfy without widening the layout.
- `crates/mermaid-text/tests/snapshots.rs` and `tests/strict_max_width.rs` — the sequence fixtures
  rendered at a budget, and any snapshot of one. Renderings with no budget are unchanged.
- `engine/src/document.rs` — `WIDE_SEQUENCE`'s compacted width (35 columns) is the premise of
  `TRUNCATING_WIDTH = 30`, and that file's comment describes the ladder this change replaces. If
  the scan finds a fitting arrangement narrower than 35, the constant has to drop again.
- `lua/md-render` tests — `tests/headless/run.lua` asserts engine output for
  `tests/fixtures/wide-diagram.md` (113 columns natural, floor 108) and `tests/fixtures/zoom-diagram.md`
  (166 natural, 64 at a 70-column budget). All three numbers are re-measured against the rebuilt
  engine.
- `bin/md-render.exe` — the plugin resolves `bin/` before `PATH`, so the local copy has to be
  refreshed from the rebuilt engine or the plugin's suite tests the old compaction.
- `add-diagram-zoom` task 4.2 — the manual zoom check reads differently once the floor is shorter;
  its expected result is worth restating against the new numbers rather than left as it is.
