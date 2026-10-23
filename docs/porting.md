# Building and shipping the engine binary

The plugin does not build Rust. It looks for a prebuilt `md-render` executable,
and this document covers where that executable comes from, where the plugin
looks for it, and what happens when it is missing or out of step.

## Where the engine comes from

There are two routes, and neither involves the plugin fetching anything.

**A release.** Each tagged release ships one archive per target:

| Archive | Target |
| --- | --- |
| `md-render-vX.Y.Z-x86_64-unknown-linux-musl.tar.gz` | Linux, static musl |
| `md-render-vX.Y.Z-x86_64-pc-windows-msvc.zip` | Windows, static MSVC CRT |
| `md-render-vX.Y.Z-universal-apple-darwin.tar.gz` | macOS, Intel and Apple silicon |

Unpack it and put the binary where the plugin looks (see below), most often
`<stdpath('data')>/md-render/md-render[.exe]`.

**A source build.** A stock toolchain builds the engine for whatever platform
it runs on:

```bash
cargo build --release -p md-render
```

That produces `target/release/md-render` (or `md-render.exe`). A plugin loaded
from a checkout finds a copy in the repository's `bin/`:

```bash
cargo build --release -p md-render
mkdir -p bin
cp target/release/md-render bin/md-render
```

PowerShell:

```powershell
cargo build --release -p md-render
New-Item -ItemType Directory -Force bin | Out-Null
Copy-Item target/release/md-render.exe bin/md-render.exe
```

`Cargo.toml` sets `lto = "thin"`, `strip = "symbols"` and `panic = "abort"` for
the release profile. The engine is spawned once per render, so start-up latency
is visible to the user and a smaller binary is a faster one to page in.

Cross-compiling from a machine without a Windows toolchain still works and
needs a mingw-w64 linker:

```bash
rustup target add x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu -p md-render
cp target/x86_64-pc-windows-gnu/release/md-render.exe bin/md-render.exe
```

The release workflow uses the MSVC target instead, so the published Windows
archive has no MinGW runtime to install.

## Where the plugin looks

The order is implemented in `lua/md-render/engine.lua` and must match this list:

1. the `engine` option (`require('md-render').setup{ engine = '...' }`), used
   as given;
2. `md-render` on `PATH`;
3. `<plugin-root>/bin/md-render[.exe]` — a local build;
4. `<stdpath('data')>/md-render/md-render[.exe]` — a downloaded release.

A configured `engine` is authoritative: a path that is missing or not
executable is reported and the search stops. Falling through would silently run
a different engine than the one the user named. The automatic candidates are
checked with `executable()`, so a file that exists but cannot run is skipped
rather than failing later with `EACCES`.

The repository's `bin/` is ahead of the data directory so a fresh local build
is not shadowed by an older download. `:checkhealth md-render` reports the path
that won and the step that produced it, which is what makes a `PATH` shadow
visible.

If nothing resolves, the plugin does not render. It leaves the buffer as
source, reports every location searched, and gives both ways of obtaining the
engine. It does not fall back to a partial render or to a placeholder: showing
something that is not the document would be worse than showing the document.

## The wire-version check

Every document carries a `version` field: the wire format the engine speaks.
The plugin refuses a document whose version it does not know:

```
the engine at <path> speaks wire format 2, but this plugin expects 1.
Rebuild the engine from this checkout (`cargo build --release -p md-render`),
or upgrade the plugin and the engine together.
```

This is the only staleness the plugin can detect, and it is a hard error
because the alternative is reading a document whose shape has changed as if it
had not. A binary built from a revision that kept the wire format is
indistinguishable — byte-identical output is the contract, so there is nothing
else to compare.

## Keeping the local binary current

`bin/` is untracked, so nothing tells a developer when its engine falls out of
step with the sources. Rebuild and copy after every engine change:

```bash
cargo build --release -p md-render
mkdir -p bin
cp target/release/md-render bin/md-render
```

The plugin's test suites both run against the real binary, so a stale copy can
also make a correct plugin change fail. See `CONTRIBUTING.md` for the full
sequence.
