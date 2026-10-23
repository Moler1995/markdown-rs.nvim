# Design

## Context

See `proposal.md` — Why. The constraints that shape the approach:

- **The clipping happens inside the engine.** `push_mermaid` renders with
  `render_text(source, Some(self.width), Auto)` and then ends every line with
  `clip_to_width(line, self.width)` (`engine/src/document.rs:146-151`). Table columns are sized from
  the same budget. So the columns the window cannot show are not merely off-screen — they are absent
  from the rendered buffer, and horizontal scrolling cannot recover them. This is what makes the
  feature a re-render rather than a zoom.
- **`max_width` is a hint, not a clamp** (`engine/src/mermaid.rs:47-51`): it drives gap compaction
  and the layout backend's orientation choice, and the result may still exceed it. Giving the block
  a larger budget is therefore the mechanism by which a clipped block is recovered.
- **The engine contract already covers this case.** `md-render --width N` renders whatever markdown
  it is given, and a block's source slice *is* markdown: a ` ```mermaid ` fence slice is a fenced
  diagram, a table slice is a table.
- **The plugin already has both halves.** `engine.render(opts, content, width, cb)`
  (`lua/md-render/engine.lua`) spawns the process for any content at any width, and
  `render.apply(buf, doc)` (`lua/md-render/render.lua:26`) paints a document into any buffer with its
  styles. Nothing new is needed on either side.
- **The doc carries the cursor→source direction, not block extents.** `render.source_line_for`
  (`render.lua:78-102`) already walks forward-first over synthetic lines, so a table border resolves
  into its table. There is no equivalent for "where does this block start and end".
- **A float is an independent window.** Neovim keeps each window's buffer, cursor and view, so an
  overlay needs no save/restore of the view underneath.

## Goals / Non-Goals

**Goals:**

- Recover the whole block, using the engine's existing contract rather than a new one.
- Make the key safe to press anywhere in R: no preview where none is possible, and no motion lost.
- Keep the popup a real reading surface — scroll, search, yank — rather than a rendered picture.
- Leave the document view bit-for-bit untouched across an open/close cycle.

**Non-Goals (design-level; scope non-goals are in `proposal.md`):**

- Any change to the engine, the wire format, or the Rust crates.
- A preview cache, or more than one popup at a time.
- Scaling artwork. The engine re-lays out; it does not scale, and this design does not add a scaling
  path.
- Re-rendering the popup on terminal resize while it is open.

## Decisions

### D1. The popup re-renders the block; it does not magnify what R holds

The columns the window clipped are not in the buffer (see Context), so there is nothing to magnify
or pan to. The block's source is fed back through the engine at the budget D3 gives its kind.

*Alternatives:* showing R's own buffer in a `wrap=false` float and panning — recovers nothing, the
text is gone. Rendering the block at its natural width once at open time and caching it — still a
render, and it would be the same render a diagram gets anyway (D3), for a cache D9 declines.

### D2. The block's source slice is fed to the engine verbatim

No wrapper, no per-kind rendering path: a fence slice is itself a fenced diagram, and a table slice
is itself a table, so both go through `engine.render` unchanged. This is what keeps the feature
entirely on the Lua side.

*Alternatives:* render the whole document at the popup width and extract the block's rows — a
whole-document render to show one block, and the extraction needs the block's display range, which
is the same problem D4 solves. A new engine flag to render one block by source range — a wire-format
version bump in exchange for an input the contract already accepts.

### D3. The budget is per kind: a table's is the popup's width, a diagram's is the engine's maximum

The engine compacts gaps to fit a budget and clips what still does not fit, so rendering at a
budget yields the most compact layout available for that budget. There is no
render-wide-measure-shrink loop to write: the fitting already happens inside the engine.

What the budget should *be* turns on what the engine does with content that does not fit, and that
is not the same for the two kinds:

- **A diagram is laid out at `MAX_BUDGET`** — the largest column count `--width` accepts, 65535.
  `push_mermaid` ends every artwork line with `clip_to_width(line, self.width)`
  (`engine/src/document.rs:146-151`), and the clipped columns are not in the buffer at all. Any
  finite budget can therefore lose the right-hand end of a diagram: at a budget of 200 the
  steering sequence diagram in the document that motivated this change comes back 201 columns wide
  where its natural width is 358, and 158 columns are simply gone. The only budget that clips
  nothing is one no diagram reaches, which is why the number is the top of `u16` rather than a
  tuned value. `max_width` being a *hint* rather than a clamp does not weaken this — it means a
  diagram may come back wider than the budget, not that the clip is skipped.
- **A table keeps the popup's own inner width, floored at the window's.** The engine wraps a cell
  that does not fit instead of dropping it, so a table loses nothing at any budget, and a larger
  budget only makes its columns wider and harder to read. The floor is not a detail: the cap is a
  fraction of the *editor*, not of the window, so with one full-width window the popup's inner
  width — 90% of the editor, less the border — is *smaller* than the window's own budget. Without
  the floor the popup would lay the table out at a smaller budget than the window already used and
  so show strictly less of it.

The earlier form of this decision gave both kinds the floored popup width. It was wrong for
diagrams, and wrong in the way the feature exists to fix: it bounded the popup's budget by the
popup's *window*, so a diagram wider than the popup was clipped by the engine exactly as the
window's rendering had clipped it, and the popup could not show the block whole however far it was
scrolled. The popup's width is the right budget for what the popup *shows*; it is the wrong budget
for what the popup *lays out*, because the engine's clip is irreversible.

*Consequence, and it is expected:* the popup may show a **different arrangement** than R, because
the layout depends on the budget. The popup is a second reading of the block, not a zoom of the
first. For a table in a window as wide as the cap the two budgets are equal, the arrangement is the
same, and the popup is a scrollable window onto it rather than a wider view of it. For a diagram
the popup's buffer holds the diagram's natural layout, and its window — clamped to the cap — is a
scrollable window onto *that*.

### D4. Locating the block: anchor in the doc, extent in the source buffer

Two steps, each using the source that is authoritative for it:

1. **Anchor.** In R, the cursor's display row maps to a source line via
   `render.source_line_for(doc, row)` — which already resolves a synthetic line (a table border,
   diagram artwork) to the construct that produced it.
2. **Extent.** From that source line, scan the **source buffer** for the enclosing block: a fence
   runs from its opening delimiter to its closing one; a table runs over the pipe-bearing lines
   around the anchor.

The doc knows the cursor→source direction but not where a block begins and ends; the source buffer
is the only place where both kinds have a lexically obvious boundary.

*Alternatives:* have the engine emit block ranges in the wire format — a format version bump and a
much larger change than the feature. Reimplement the engine's fence and table parsing in Lua — the
same scan, plus a standing risk of disagreeing with pulldown-cmark about what a block is.

### D5. The table extent heuristic is the GFM table definition, and it is validated

From the anchor, extend up and down over non-blank lines that contain `|`; accept the run only if it
has at least two lines and its second line is a delimiter row (`|---|`, `:--:`). GFM's table syntax
*is* "a run of pipe-bearing lines whose second line is a delimiter row", so the rule agrees with the
engine's parser wherever a table exists rather than being an approximation of it.

*Known divergence:* a table immediately followed, with no blank line, by a pipe-bearing paragraph —
the run swallows that paragraph's line. Accepted: the popup shows what the engine makes of the
slice, so a mis-detect is visible rather than silent, and the alternative is a markdown parser in
Lua.

*Fences need no heuristic:* a ` ```mermaid ` opener and its closing delimiter are unambiguous, and
only explicitly tagged fences are considered — an untagged fence that the engine's
`looks_like_mermaid` heuristic would draw as a diagram (`engine/src/renderer.rs:1020`) is not
previewable, so the Lua side never has to mirror that heuristic.

### D6. The key falls through where there is no preview

The mapping is buffer-local to R. When the cursor is not on a previewable block, it re-feeds the key
with `nvim_feedkeys(..., 'n', ...)` — the mechanism `enter_insert` already uses
(`lua/md-render/init.lua:420`) — so `<CR>` keeps its ordinary "first non-blank of the next line"
action. The `'n'` (no-remap) flag is load-bearing here in a way it is not there: without it the fed
key would re-enter this same mapping and loop.

*Alternative:* consume the key and do nothing, which is what the original TUI's `Enter` does. It
costs a motion that R otherwise has, for no gain.

### D7. The popup is a floating window over an untouched one

`nvim_open_win` with `relative='editor'`, `style='minimal'`, `wrap=false`, a rounded border and a
title naming the block kind. Because it is a separate window, the view underneath needs no
bookkeeping: the buffer, the cursor, the scroll position and the R/S state are all still there when
it closes, which is what the spec's "the view underneath is untouched" scenario asks for.

`wrap=false` is not cosmetic — it is what keeps one row of artwork on one row, and it is what gives
the popup horizontal scrolling for free when the block still exceeds it.

*Alternatives:* a full-screen swap, which would need `winsaveview` save/restore and would hide the
surrounding document. The original TUI's overlay plus an explicit modal-state struct — unnecessary
here, because a Neovim window already carries exactly the state that struct was built to hold.

### D8. Sized to content, capped at 90%

Render first at the budget D3 describes, measure the widest resulting line and the line count, then
open the window at the smaller of the measurement and the cap's inner width, centred. The cap is
configurable (`preview.max_width_pct`, `preview.max_height_pct`, both defaulting to `0.9`).

The measurement and the displayed width are therefore two different numbers: the content is laid out
at the budget, and the window shows the first `min(widest, cap)` columns of it. Where the block is
wider than the cap, the rest is reached by scrolling horizontally — which `wrap=false` (D7) gives
for free, and which is the only thing that can reach it, since the engine's clip is what the budget
allowed.

*Alternative:* a fixed 90%×90% box, as the original TUI uses. Simpler geometry, but a 40-column
diagram ends up in a large empty frame.

### D9. No cache, one popup at a time

Each open is one engine process over one block — the low end of the measured cost range, where a
prose-only document renders in ~4 ms (see the previous change's design). A cache would need a key
over buffer, `changedtick`, popup width and theme, plus a second invalidation path, for an action
the user takes deliberately and occasionally.

### D10. R only

In S the cursor is already on the block's source, which is what the preview would be showing.

*Alternative:* bind in S as well. A second set of mappings, on a view that already shows the block,
for a popup that would show the same thing laid out.

### D11. The preview makes layout determinism observable, so this change pins the vendored patch

A preview is a *second* render of a block, in a second process. That makes visible a property R's
single render hides: if the engine's layout is not deterministic, the popup and R disagree for
reasons that have nothing to do with the width budget, and pressing the key twice yields two
pictures. The layout is deterministic today because of a backported fix in the vendored
`crates/ascii-dag`, reached through `[patch.crates-io]` at the workspace root.

What is *not* pinned is that the patch **applies**. The crate's own regression test runs as a
workspace member whether or not the patch redirects `mermaid-text`'s dependency to it, and no
fixture in `engine/tests/fixtures/diagrams.md` contains a subgraph — and the bug is unreachable
without one, because with no subgraphs every vnode keys to the same block in `block_partition_level`
(`crates/ascii-dag/src/algorithms/sugiyama/subgraph.rs:92-137`) and the tie-breaking sort is a
no-op. `corpus.rs`'s `every_fixture_is_deterministic` cannot close the gap either: it is in-process,
so it cannot see a per-process hash seed at all.

A lexical guard cannot stand in for the fixture. The engine's `auto_prefers_native`
(`engine/src/mermaid.rs:106-121`) scans the source for the `subgraph` keyword, but a `stateDiagram`
with a composite state compiles to a `Subgraph` without ever spelling it
(`crates/mermaid-text/src/parser/state.rs:16`) and so reaches the same path invisibly.

So: one fixture with tied subgraph blocks, plus the regenerated corpus snapshot, pins the chain from
the engine's own test suite. This is the only engine-repository work the change carries, and it is
test-only.

*Alternative:* leave it and rely on the vendored crate's regression test. It fails exactly when it
is needed — it passes with the patch inert.

### D12. A float is never adopted as a window of R

This is work the change did not set out to do. It is recorded here because the preview is what
exposed it, and because the popup cannot work without it.

`nvim_open_win` fires `WinEnter` for the new float **before** swapping its own buffer in, so at that
instant the float still holds the buffer it was opened over — which, for a popup opened over R, is
R's rendered buffer. The plugin's split-inheritance rule is "a window that appears showing R's
rendered buffer is a split of R, and is given a rendered buffer of its own", and it reads exactly
that buffer. The float is therefore attached as a window of the plugin: it is handed a rendered
buffer of its own, the preview's buffer is wiped out from under it, and what the user asked to see
is replaced by a render of a buffer that no longer exists.

The fix is to exclude floating windows **before** the buffer is looked at:

```lua
local cfg = vim.api.nvim_win_get_config(win)
if cfg.relative ~= '' or cfg.external then
  return
end
```

*Not preview-specific.* Any hover, signature or completion float opened while R is showing was being
treated the same way, so this is a defect in the plugin that the preview happened to be the first
thing to open a float over R. It is fixed generally, and the regression test opens a plain float
rather than a preview — a test written against the preview would pass while the general rule stayed
broken.

*Alternative:* attach the float and undo it afterwards — fighting an event rather than declining it,
and it would still have wiped the preview's buffer by the time the undo ran.

## Risks / Trade-offs

- **[The table extent can over-reach]** The run-walk can swallow a pipe-bearing line that follows a
  table without a blank line between them. → The run is validated against the GFM definition
  (delimiter row required, D5), which is the same rule the engine's parser applies; and the popup
  shows what the engine makes of the slice, so the failure is visible rather than silent.

- **[Still wider than the popup]** A block may be wider than the popup's window even though the
  popup laid it out at a budget nothing was clipped at. → The content is in the popup's buffer and
  `wrap=false` gives horizontal scrolling to reach it, with no line soft-wrapping, so the artwork
  stays readable row by row. What the popup must not do is clip, and for a diagram it does not: its
  budget is `MAX_BUDGET` (D3). A table cannot be clipped at any budget, because the engine wraps a
  cell rather than dropping it.

- **[A diagram at 65535 could be absurdly wide]** Nothing caps a diagram's natural width, so a
  pathological one could produce a buffer thousands of columns wide, where before the popup's
  window bounded it. → The cost is buffer size for a block the user deliberately asked to see
  whole, and the window is still clamped to the cap, so nothing is drawn off-screen. A cap below
  the maximum is not available as a middle ground: it reintroduces the clip D3 removes, at a
  threshold nobody can name in advance.

- **[A process per open]** Each preview costs a process spawn plus a one-block render. → Accepted,
  and it is what D9 declines to cache. If it ever matters, the fallback is a cache keyed on the
  block's source range and the popup width.

- **[The fall-through could loop]** If the fed key were remapped, `<CR>` on prose would re-enter the
  mapping. → Feed with `'n'` (D6), and pin it with a test that presses `<CR>` on prose and asserts
  the cursor moved to the next line's first non-blank.

- **[The popup and the plugin's per-window state]** A new window id appears in the plugin's state
  map's key space. → `WinClosed` already calls `state.forget(win)`, which returns immediately for a
  window that has no state (`lua/md-render/state.lua:56-58`); the popup's own cleanup is a separate,
  popup-local handler.

  *This risk was written too narrowly, and it materialised.* The state map was never the problem —
  the window-attachment rule was, because it runs on `WinEnter` before the float has its own buffer
  (D12). Anticipating the state map while missing the inheritance rule is what let the defect reach
  the implementation stage; the fix and its test are D12's.

- **[Terminal resized while the popup is open]** The popup keeps the geometry it was opened at and
  can end up larger than the screen. → Accepted for this change; closing and reopening refreshes it.
  Re-rendering on `VimResized` is a later addition, not a spec change.

- **[The popup's arrangement differs from R's]** A reader comparing the two sees a re-laid-out
  block, not a wider crop of the same one. → Inherent to a budget-driven layout, and stated in D3;
  the popup's value is showing the whole block, not matching the window's arrangement.

- **[The vendored patch can stop applying and no test would notice]** If `[patch.crates-io]` ever
  stops redirecting `ascii-dag`, or the vendored crate is dropped during a rebase, the tie returns
  and a subgraph diagram's layout varies between runs — and the preview, being a second render, is
  where the user sees the disagreement. → A fixture reaching the tie, with the corpus snapshot as the
  detector and `cargo tree` as the check that the path is live (tasks 6.1-6.3, D11).

## Migration Plan

Additive, with no data and no breaking change. The feature lands behind a key that is bound in R
only, and the plugin's existing keymap convention gives a rollback with no code change: setting
`keymaps.preview = false` leaves the key alone entirely, exactly as it does for `toggle` and
`write`. Removing the mapping restores R's previous behaviour with no residue — nothing else reads
the preview's state.

## Open Questions

- Whether the popup should carry chrome beyond its title — the original TUI had a hint line in the
  border and a footer showing scroll position and key hints. Cosmetic; decide after living with the
  plain version.
- Whether to re-render on terminal resize while the popup is open. Deferrable: it changes neither
  the spec nor the approach.
