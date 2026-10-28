# Proposal

## Why

In R, `:e` fails noisily. The window's buffer is the rendered buffer, so `:edit` re-reads *that*
rather than the document: it is an `acwrite` scratch buffer with no reader, so the read wipes it.
When R is shown in a split, wiping it closes the split's window outright; either way the `.md`
suffix of its name fires `FileType`, and the handler schedules an attach for a buffer that is
already gone. The result is `Invalid window id` / `Invalid buffer id` from `attach` — the exact
error a reader sees after editing a file outside Neovim and pressing `:e` to pick it up.

## What Changes

- A rendered buffer is never attached as a document. `attach` refuses any buffer in
  `state.by_rendered`, which is the check the `BufWinEnter` handler already makes; the `FileType`
  handler now gets it too.
- `:e` in R reloads the *source* from disk and re-renders, which is what `:edit` means in any
  other buffer. A `BufReadCmd` for the `md-render://` scheme forwards the read to the source
  buffer, honouring the bang: `:e` refuses unsaved source changes with `E37`, `:e!` discards them.
- The window, its state and its rendered buffer survive the reload; no window is closed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `nvim/render-mode`: R's buffer is not a document and is never attached as one; an `:edit`
  issued in R reloads the document from disk the way `:edit` does everywhere else, and leaves the
  window in R.

## Impact

- `lua/md-render/init.lua`: a guard in `attach`, a reader for the rendered buffer's scheme.
- `tests/headless/run.lua`: a section for the reload, in R and in a split, with and without unsaved
  source edits.
- `doc/md-render.txt`: the `:edit` behaviour is documented under the commands.
- No engine, wire-format or configuration change; a patch release.
