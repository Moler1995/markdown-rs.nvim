# Proposal

## Why

A wide diagram in the preview popup can only be read by scrolling sideways, one screenful at a
time. The popup already lays the diagram out against the engine's largest budget, which is the
right default — nothing is lost — but it leaves the reader with a diagram wider than the popup and
no way to ask for a narrower one. The engine can already re-lay a flowchart at a smaller budget
without losing anything; the popup just never asks it to.

Sequence diagrams are the worst case. They ignore the width budget entirely, so the engine falls
back to clipping them, and a clipped sequence diagram loses its right-hand participants outright.
The diagram in `Wind.Traefik.LLM.Routing/docs/architecture.md` §2 is 357 columns wide and is
exactly this case: at any budget below its natural width, its right half simply disappears.

## What Changes

- The engine reports the width it actually laid a document out at, before any clipping, as a new
  wire field `layout_width`. A caller can then tell "this was clipped" (`layout_width > width`)
  apart from "this fits" without guessing.
- Sequence diagrams gain width-aware compaction: participant labels and message labels are wrapped
  to fit the budget, so a sequence diagram that can be laid out within the width is laid out
  within it instead of being clipped.
- The preview popup gains zoom. `+` and `-` step a diagram's layout budget up and down while the
  popup is open, re-rendering it each time. Both keys are configurable
  (`keymaps.zoom_in` / `keymaps.zoom_out`) and default to `+` and `-`.
- Zoom out stops at the last budget that does not clip the diagram. A reader is never shown a
  diagram with columns missing, and never lands on a rung that quietly loses content.
- Tables do not respond to zoom. A table has no "clipped" state — the engine wraps a cell rather
  than discarding it — so a budget ladder gives a table nothing to gain. The keys are bound in a
  table popup and do nothing there.
- The comment in `lua/md-render/preview.lua` that cites a 358-column sequence diagram gains a
  provenance note naming the document it was measured from. The numbers stay: they are correct.
- The popup gains sideways scrolling on one key per direction, because Vim's own `zh` and `zl` are
  two keystrokes each and so cannot be held down. Both keys are configurable
  (`keymaps.scroll_left` / `keymaps.scroll_right`) and default to `<C-h>` and `<C-l>`, and the step
  is the reader's own `'mousescroll'` horizontal step. Unlike zoom, this applies to a table's popup
  as well, since a table can be wider than the popup too.

  Added mid-implementation, at the reader's request, after the zoom work was done: the popup could
  zoom a diagram to fit but not be scrolled across one that still did not, and the built-in keys for
  that cannot be held. A zoom key that has nothing left to ask for also stops reaching the engine,
  which is recorded in `tasks.md` under 3.10.

## Capabilities

### New Capabilities

None. Zoom is a change to how the existing preview popup chooses its budget, not a capability of
its own.

### Modified Capabilities

- `nvim/block-preview`: the popup's budget is no longer fixed for the life of the popup. A diagram
  popup's budget becomes adjustable while it is open, bounded below by the last budget that lays
  the diagram out without clipping, and the popup's title reports the state. Table popups keep a
  fixed budget. The popup also gains sideways scrolling on one holdable key per direction, for both
  kinds of block.
- `nvim/render-engine`: the engine reports the layout width of the document it produced, and a
  diagram that can be laid out within the requested width is laid out within it rather than
  clipped. Sequence diagrams stop ignoring the width budget.

## Impact

- `engine/src/document.rs` — track the widest display line before `clip_to_width`, emit it.
- `engine/src/wire.rs` and `docs/md-render-format.md` — the new `layout_width` field. The wire
  `version` stays `1`: the field is additive, and bumping it would make an older plugin reject an
  entire document rather than ignore one field.
- `crates/mermaid-text/src/lib.rs` — pass the budget to the sequence renderer and give it a
  compaction pass, alongside the existing progressive compaction for flowcharts and state
  diagrams.
- `crates/mermaid-text/src/render/sequence.rs` — accept a width and wrap participant and message
  labels to meet it. Participant boxes grow taller and message labels may occupy more than one
  row, so the height and row accounting in `render` changes with the wrapped labels.
- `lua/md-render/preview.lua` — the popup holds its block and current budget, re-renders on zoom,
  refuses a rung whose render clips, titles itself with the state, and binds the scroll keys.
- `lua/md-render/config.lua` — `keymaps.zoom_in` / `keymaps.zoom_out` and `keymaps.scroll_left` /
  `keymaps.scroll_right`.
- `lua/md-render/init.lua` — no behavior change; the popup owns its own keys, as it does today.
- Tests and snapshots: `crates/mermaid-text/tests/strict_max_width.rs` currently asserts in a
  comment that "a sequence diagram's layout ignores `max_width` entirely", which this change makes
  false. The sequence snapshots in `crates/mermaid-text/tests/snapshots.rs` change only where a
  budget is supplied; at no budget the output is unchanged.
- The plugin's headless suite gains the zoom behavior; the interactive suite gains the key-driven
  case.
