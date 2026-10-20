# Building and shipping the engine binary

The plugin does not build Rust. It looks for a prebuilt executable, and this
document covers where that executable comes from and what happens when it is
not there.

## Building

A stock toolchain builds the engine for whatever platform it runs on:

```bash
cargo build --release -p md-render
```

That produces `target/release/md-render` (or `md-render.exe`). This is the path
a developer working on the engine itself should use.

## The Windows binary

`bin/md-render.exe` is a build artifact and is not in the repository. Copy a
build there once and the plugin has its engine:

```bash
cargo build --release -p md-render
cp target/release/md-render.exe bin/md-render.exe
```

It was committed for a while, on the grounds that Neovim users on Windows have
no Rust toolchain and no build step. That is still true of the *user*, but the
binary belongs to whoever builds the plugin, and keeping a 4.6 MB artifact in
the history meant every rebuild showed up as a change to commit.

When the only route was a Linux development machine it was cross-compiled:

```bash
rustup target add x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu -p md-render
cp target/x86_64-pc-windows-gnu/release/md-render.exe bin/md-render.exe
```

The `x86_64-pc-windows-gnu` target needs a mingw-w64 linker. It links against
the GNU C runtime rather than MSVC's, which is what makes the cross-compile
possible from Linux without a Windows SDK — and it runs on Windows without any
runtime to install, because the MinGW runtime is statically linked in. A native
GNU toolchain produces the same target directly, so this is now only for a
machine that has no Windows toolchain of its own.

`Cargo.toml` sets `lto = "thin"`, `strip = "symbols"` and `panic = "abort"` for
the release profile. The engine is spawned once per render, so start-up latency
is visible to the user and a smaller binary is a faster one to page in.

## What the plugin does when the binary is missing

The plugin looks for the executable in this order:

1. `g:md_render_binary`, if the user set it.
2. `<plugin root>/bin/md-render.exe`.

If neither resolves, the plugin does not render. It leaves the buffer as
source, reports that the engine was not found, and says how to build it. It
does not fall back to a partial render or to a placeholder: showing something
that is not the document would be worse than showing the document.

A user who has a Rust toolchain can point `g:md_render_binary` at their own
build, which is also how an engine change is tested against the plugin without
installing the binary into `bin/`.

## Keeping the local binary current

`bin/md-render.exe` is untracked, so nothing tells you when it falls out of
step with the sources: a stale copy is a plugin that renders with an old engine.
When the wire format or the rendering changes, rebuild and reinstall it:

```bash
cargo build --release -p md-render
cp target/release/md-render.exe bin/md-render.exe
```

The plugin has no way to detect a stale binary beyond the `version` field in
the output, and a version mismatch is a hard error rather than a silent
misrender.
