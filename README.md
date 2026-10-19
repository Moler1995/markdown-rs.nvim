# markdown-rs.nvim

A markdown rendering engine and the Neovim plugin that uses it.

Opening a markdown file shows it rendered — headings in colour, tables drawn as
tables, diagrams drawn as diagrams, code highlighted. A key toggles back to the
source, which is an ordinary editable buffer. The engine does the rendering;
the plugin decides when to call it and where the result goes.

```text
D:\projects\rust\markdown-rs.nvim\
  Cargo.toml           workspace
  engine/              the md-render crate
  crates/mermaid-text/ vendored diagram renderer
  lua/md-render/       the plugin
  plugin/md-render.lua entry point
  bin/md-render.exe    cross-compiled artifact, committed
  docs/                the wire format, and porting notes
```

## The engine

`engine/` builds `md-render`, a program that reads markdown and writes JSON to
stdout:

```bash
md-render --width 120 --theme nord README.md
md-render --width 120 < README.md
```

The width is required — the engine lays tables and diagrams out against a
column budget, so there is no sensible default. The output is described in
[`docs/md-render-format.md`](docs/md-render-format.md): styled display lines
sized to the requested width, plus the mapping between those lines and the
source lines they came from.

The engine knows nothing about Neovim. It takes text and a width and returns
data. That is what makes it testable without an editor, and what makes the
plugin a consumer rather than a component.

## The plugin

`lua/md-render/` is a Neovim plugin. It renders through the engine binary,
shows the result in a read-only buffer in the same window, and toggles back to
the source on request.

## Building

The workspace builds with a stock Rust toolchain:

```bash
cargo build --release -p md-render
cargo test
```

The committed `bin/md-render.exe` is a Windows build cross-compiled from Linux
against the `x86_64-pc-windows-gnu` target. See
[`docs/porting.md`](docs/porting.md) for how it is produced and what the plugin
does when it is missing.

## Provenance

The rendering pipeline — markdown parsing, table layout, syntax highlighting,
LaTeX-to-Unicode conversion, and diagram text rendering — was ported from
[`markdown-reader`](https://github.com/leboiko/markdown-reader), a terminal
markdown reader, at revision `4f0f635` (2026-10-14), MIT licensed,
© leboiko.

It was ported rather than depended on. `markdown-reader` is a complete
application: it owns a terminal, negotiates graphics protocols, and carries a
dependency set for all of that. An engine that turns markdown into styled lines
needs none of it, and linking it would make this crate heavy, slow to build,
and impossible to publish on its own. The port takes the parts that render
text and leaves the application behind.

The two copies are not kept in step. The port is a one-time lift; there is no
upstream tracking.

### The port-header convention

Every ported file begins with a line naming its origin:

```rust
//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
```

Where a module also carries an origin copyright notice, that notice is kept
verbatim below the header. Modules written for this repository have no such
header — its absence is the marker for "new code".

Files that were ported carry a second paragraph explaining what was removed and
why. A port is not a copy: the origin's types served the origin's interaction
model, and re-expressing the code against this crate's own types is what makes
it a library rather than a transplanted application. Where behaviour changed
deliberately, the change is stated in the header.

## License

MIT. See [`LICENSE`](LICENSE).
