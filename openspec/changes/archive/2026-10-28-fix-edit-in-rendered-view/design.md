# Design

## Context

See `proposal.md` — Why. Two facts about the current implementation shape the approach:

- R is a scratch buffer created by the plugin (`buftype=acwrite`, `bufhidden=wipe`, named
  `md-render://<win>/<name>`), and it has a `BufWriteCmd` but no reader. An `acwrite` buffer with no
  `BufReadCmd` accepts `:edit`, which unloads it and reads nothing.
- `FileType` is the plugin's attach trigger, and it decides by `filetype` alone. A rendered
  buffer's name ends in the source's extension, so reading it (or setting its filetype) fires the
  trigger for a buffer that is not a document.

The state module already records every rendered buffer in `state.by_rendered`, and the
`BufWinEnter` handler already uses it to refuse rendered buffers. That record is the check the
`FileType` path lacks.

## Goals / Non-Goals

**Goals:**

- `:e` in R behaves like `:edit` everywhere else: re-read the document from disk, honour the bang
  and `E37`, leave the view in R.
- No window is closed, and no attach is ever started for a rendered buffer.

**Non-Goals:**

- Making `:edit` from R a no-op that tells the reader to toggle to S. The source buffer is the
  document; reloading it is what `:edit` means.
- Auto-reloading on `FileChangedShell`/`'autoread'`. That is a separate behaviour and not what the
  report asked for.
- Changing what `:w` does, or any engine, wire-format or option behaviour.

## Decisions

**Refuse rendered buffers in `attach`, not in each caller.** `attach` is the one function every
path funnels through — `FileType`, `BufWinEnter`, the split handler, `follow`, `setup`. A guard
there is the same rule the `BufWinEnter` handler states in prose, enforced once. `attach_current`
and the scheduled `FileType` callback need no change: they already re-check the window, and
`attach` now stops them before any state is touched.

**Give the rendered buffer a reader for its scheme, rather than a special case for `:edit`.**
`BufReadCmd` on `md-render://*` is the mechanism Vim offers for "this buffer's contents do not come
from a file"; it makes `:e`, `:e!` and a `:bufdo edit` all mean the right thing without the plugin
intercepting the command. The reader runs `:edit`/`:edit!` in the *source* buffer with
`nvim_buf_call`, then asks for R again. Without a reader, `:edit` wipes the rendered buffer; with
one, Vim unloads it and calls the reader, and the buffer survives the read — which is what keeps a
split window open.

**Let Vim enforce `E37`.** The reader issues a plain `:edit` in the source buffer; Vim raises `E37`
when the source is modified and the command has no bang. The reader catches the failure, reports
it, and re-asks for R so the window is not left blank. Re-implementing the check by hand would get
the `'hidden'` interaction wrong.

**Re-render rather than reuse.** The render cache is keyed on the source's `changedtick`, which a
reload moves, so `show_rendered` naturally produces a new document. A reload that found identical
bytes still costs one render; that is acceptable for an explicit `:e` and keeps the reader's
"reload = show what is on disk" promise exact.

## Risks / Trade-offs

- **A reload of a file that is gone** → the source `:edit` fails; the reader reports the error
  through `vim.notify` and asks for R again, so the window keeps showing the document instead of
  going blank.
- **`state.by_rendered` is only populated when the rendered buffer is created.** A buffer created
  but not yet recorded cannot be in a window, so the guard's blind spot is unreachable in practice.
- **`FileType` still fires for the rendered buffer** during its read. The guard makes it harmless,
  but the event is visible to other plugins; a plugin that acts on `FileType` for a scratch buffer
  is a broader problem than this change can settle.
