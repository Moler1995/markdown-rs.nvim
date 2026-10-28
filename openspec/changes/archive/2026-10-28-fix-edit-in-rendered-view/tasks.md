# Tasks

## 1. The guard

- [x] 1.1 Make `attach` return early for any buffer in `state.by_rendered`, and state in the `FileType`
      handler why the rendered buffer's filetype is not a document. Verify by running
      `:e` in R with one window and with two: no `Invalid window id` or `Invalid buffer id` is
      raised, and no window closes.

## 2. The reader

- [x] 2.1 Register a `BufReadCmd` for `md-render://*` that reloads the owning state's source with
      `:edit`/`:edit!` according to `v:cmdbang`, reports a refused or failed read, and asks for R
      again. Verify by hand that `:e` in R picks up an on-disk change, `:e` with unsaved source
      changes raises `E37` and changes nothing, and `:e!` discards them.

## 3. Tests

- [x] 3.1 Add a headless section covering the reload: the rendered view survives `:e`, a split
      window survives it, the on-disk change appears in R, `E37` is raised without a bang, and the
      bang discards the unsaved edit. Verify
      `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua` passes.

## 4. Documentation and release

- [x] 4.1 Document the `:edit` behaviour in `doc/md-render.txt` and regenerate `doc/tags`.
- [x] 4.2 Run the quality gates that apply to a Lua-only change: both Neovim suites, `openspec
      validate --all --no-interactive`, and `bash tools/check-readme.sh`.
