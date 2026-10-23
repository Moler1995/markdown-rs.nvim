# Contributing

md-render.nvim is two halves joined by one JSON format: a Rust engine
(`engine/`, the `md-render` binary) and a Neovim plugin (`lua/md-render/`). A
change belongs on one side of that line: rendering decisions in Rust, buffer and
window policy in Lua.

## Prerequisites

- Rust 1.92 or newer (`rust-version` in `Cargo.toml`). CI checks the declared
  version, so a newer compiler locally is fine.
- Neovim 0.10 or newer for the plugin suites. CI runs 0.10.x and stable.
- A branch and a pull request against `main`. CI runs on every pull request; the
  aggregate `gate` job is the check to require.

## Build and install the engine

The plugin resolves the engine as: the configured `engine` path, then
`md-render` on `PATH`, then `<repo>/bin/md-render[.exe]`. For development, the
last one is the one you want, and `bin/` is not committed, so build it first.

POSIX:

```bash
cargo build --release -p md-render --locked
mkdir -p bin
cp target/release/md-render bin/
```

PowerShell:

```powershell
cargo build --release -p md-render --locked
New-Item -ItemType Directory -Force bin | Out-Null
Copy-Item target/release/md-render.exe bin/md-render.exe -Force
```

Rebuild and copy after every engine change: nothing detects a stale binary, and
a `PATH` copy shadows `bin/`.

## Tests

The Rust workspace:

```bash
cargo test --workspace --locked
```

The plugin suites, both of which exercise the real binary in `bin/`:

POSIX:

```bash
MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua
nvim -l tests/interactive/run.lua
```

PowerShell:

```powershell
$env:MDRN_REPO = (Get-Location).Path
nvim --headless -l tests/headless/run.lua
nvim -l tests/interactive/run.lua
```

`MDRN_REPO` must be set for the headless suite. The interactive suite starts a
real Neovim and drives it with `--remote-send`, because `nvim -l` never runs the
main input loop and so cannot test `nvim_feedkeys` or `TextChanged`. Anything
that depends on either belongs there.

## Formatting and lint

Both gates are scoped to the engine package and run unchanged in CI:

```bash
cargo fmt -p md-render -- --check
cargo clippy -p md-render --all-targets --locked -- -D warnings
```

`crates/mermaid-text` and `crates/ascii-dag` are vendored as published and are
deliberately not rustfmt-clean. Do not format them: re-vendoring must stay a
small, reviewable diff. `cargo fmt -p md-render` fixes the engine.

## Snapshots

Snapshots use `insta`. A `.snap.new` file is written when output changes; it is
gitignored until accepted. Read the diff first — it is the evidence that a
rendering change did what it claimed — then accept it:

```bash
INSTA_UPDATE=always cargo test -p mermaid-text --test snapshots
INSTA_UPDATE=always cargo test -p md-render --test corpus
```

## Specs and changes

Planning lives in `openspec/` and is written with the OpenSpec CLI:

```bash
npx --yes @fission-ai/openspec@1.13.2 validate --all --no-interactive
```

A change lives in `openspec/changes/<name>/` with a proposal, spec deltas,
design notes and a task list; implementation marks tasks complete as it goes.
Archive a finished change rather than deleting it.

## Help tags

`doc/md-render.txt` is the reference; `doc/tags` is generated and committed
because `vim.pack` and a plain `runtimepath` entry do not generate tags. After
editing the help file, regenerate the tags and commit both:

```bash
nvim --headless -u NONE -c 'helptags doc' -c q
```

CI regenerates them and fails when the tracked file differs.

## Editing the plugin

Neovim caches required Lua modules. After editing anything under
`lua/md-render/`, restart Neovim; `:MdRenderReset` clears the render and
highlight caches only, and does not reload a module's code.

## License

The project is MIT-licensed (`LICENSE`). Ported and vendored material is
recorded in `NOTICE`; keep both current when you move code in or out.
