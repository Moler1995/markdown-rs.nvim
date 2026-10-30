# Design

## Context

The plugin keeps two buffers per window: **R**, the rendered scratch buffer the
engine's output is painted into, and **S**, the file's own buffer. Every window
is in one of the two, and `state.get(win)` says which. Motivation and scope are
in `proposal.md` - this document covers how the copy key is built.

Four facts about the current code shape the approach:

- **Block location already has a home.** `preview.lua` finds "the block under the
  cursor" for `<CR>`: `M.find_fence` (mermaid), `M.find_table`, and `M.locate`,
  which tries them in order. The copy key needs the same question answered, so it
  belongs beside them rather than in a new module.
- **`M.find_fence` is mermaid-only by construction.** The scan loop around
  `preview.lua:85` calls `names_mermaid(open.info)` inline, so nothing else can
  reuse it. `<CR>` must keep rejecting a ```rust fence - it has no preview for one.
- **`st.doc` is nil in S.** R's buffer is `bufhidden=wipe`; when it is wiped the
  `BufWipeout` handler clears `st.doc` and `st.rendered`. A display row can only be
  converted to a source row while the document is there, so the R path must be
  able to fail cleanly and hand the key back.
- **Keymaps are installed per buffer, and `set_keymaps` returns early** at
  `init.lua:1600`-ish when `insert_entry` is false, because the insert-entry keys
  only make sense in R. A key that must work in both states has to be registered
  before that return; `follow` and `open_image` are already placed that way.

## Goals / Non-Goals

**Goals:**

- One key, one code path, two states. No second entry point for S.
- `<CR>`'s mermaid preview continues to reject non-mermaid fences, byte for byte.
- Register type matches what was copied, so a bare `p` does what the reader means.
- Zero engine spawns: this is a buffer operation, and the headless suite counts
  spawns, so a regression here would fail a check rather than pass silently.

**Non-Goals:**

- No second key for "copy the block with its fences".
- No system clipboard write; the registers below `"` and `0` are untouched too,
  except that `0` is overwritten as usual by an explicit yank.
- No new module, no new dependency, no engine change.
- No visual-range copy: the key copies the whole block the cursor is in, never a
  selection the user made first. Visual mode is left to Vim's own `y`.

## Decisions

### The fence scan takes a predicate

`scan_fence(lines, line, accept)` is extracted from `M.find_fence`; `M.find_fence`
passes `names_mermaid`, `M.find_code_fence` passes a predicate that accepts every
fence and additionally slices out `body` and records `info`. The alternative -
a second copy of the loop that matches all fences - was rejected because the
CommonMark rules it encodes (opening fence up to three spaces of indent, closing
fence at least as long and of the same character, an unclosed fence swallowing to
end of file) are exactly the rules that would drift between two copies, and the
preview would then disagree with the copy key about which lines are a block.

`find_code_fence` returns `body` rather than making the caller slice, so that the
"without the fences" rule has one place to live.

### Three locators in one order, each whole

`copyable()` tries `find_code_fence`, then `find_table`, then the image reference.
The order matters and is deliberate: a fence wins over a table because a table
cannot contain a fence, but an image reference can sit inside either. It is tried
last precisely so that the cursor on the *artwork* of an image that happens to be
inside a table cell still copies the table - the larger block the reader is
pointing at. Falling through any locator means the key is handed back to Vim.

### The image reference is read from the source text

The engine drops link targets, so the `![...](...)` text exists only in the file.
In S the reference is found with `link.at(lines, source, col)` - the cursor's
column is meaningful there. In R the cursor is on painted artwork or alt text, not
on the source characters, so the column is discarded and the reference is found by
row with `link.image_at_row(lines, doc, row)`. "Characterwise" in both cases means
`setreg(..., 'v')` with a single string; code fences and tables take a list and the
`'V'` form.

Writing the same text to both `"` and `0` is what makes `p` work after an
unrelated delete moved the unnamed register. Register `0` alone would need `"0p`.

### Handing the key back through `feed`

Every "not a copyable block" exit calls `feed(key)` - the existing helper that
feeds the key with the `'n'` flag so mappings do not re-enter - rather than
`fall_through()`, which feeds `<CR>`. This is the same pattern as `M.follow`,
`M.open_image` and `M.frame_next`. It also means the key is silent about its
failure: no message, no visual noise, just the ordinary editor action.

A rendered row that `render.source_line_for` cannot map is treated as "not
copyable" and handed back, rather than falling back to treating the display row as
a source row - that fallback would copy a block the reader never pointed at. The
two branches are written out rather than as `rendered and ... or row` so that a
nil from `source_line_for` cannot slip through the `or`.

### Placement in `set_keymaps`

The `map(...)` call goes beside `follow`, before the `insert_entry` early return,
so it lands in both buffers. `map()` already treats a falsy key as "do not bind",
which is what makes `keymaps.yank_block = false` work without a special case.

## Risks / Trade-offs

- **`gy` is a general-purpose prefix in some Vim muscle memory** (`g~~`, `g?`) →
  the key only acts inside a copyable block and otherwise hands itself back with
  the `'n'` flag, so a reader who expected Vim's own `gy` behaviour gets it. Only
  inside a fence, table or image does the mapping win; an explicit `false` in
  config removes the conflict entirely.
- **A table copied from R is the *source* table, not the laid-out one** → this is
  the intended reading: the thing a reader wants to paste elsewhere is the
  markdown, and the rendered table has lost its pipes. Documented in the README row.
- **Feedback is a `nvim_echo` status line, which can be missed** → the cost of
  missing it is low (the register is either filled or it is not, and a bare `p`
  shows which), and a notification would interrupt the reading flow this plugin
  exists to protect.
- **`find_code_fence` accepts fences the preview does not** → each caller keeps its
  own predicate, so the two can diverge only by editing the shared scan, which is
  the point of extracting it.

## Migration Plan

None. A new default key in a configuration table; no stored state, no wire format,
no on-disk artifact changes. Setting `keymaps.yank_block = false` restores the
previous behaviour in full.
