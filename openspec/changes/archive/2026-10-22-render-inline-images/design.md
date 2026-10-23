# Design

## Context

See `proposal.md` for motivation and `specs/` for the required behaviour. What shapes the approach:

- **The pipeline.** `main.rs` reads the document, calls `render_markdown` (pulldown-cmark →
  `Vec<DocBlock>`), then `layout_document(&blocks, width, &palette, source_line_count)` → `WireDoc`
  → JSON. `DocBlock` has three variants (`Text`, `Table`, `Mermaid`) and `Tag::Image` currently
  matches nothing, so an image reaches the output only as its alt text inside a text run.
- **The engine does not know where the document is.** Content arrives on standard input, so a
  relative destination has nothing to resolve against.
- **Styles are the plugin's scarce resource.** `render.apply` sets one extmark per span, and each
  span's style is turned into a highlight group by `style.group`, which defines a new
  `nvim_set_hl` group per distinct style and caches it for the session. Measured in headless
  Neovim on this machine: 5,000 `nvim_set_hl` calls take **913 ms**, 5,000 `vim.fn.sha256` calls
  40 ms, 5,000 extmarks 6 ms. Half-block artwork of a 100×50 cell image has up to 5,000 distinct
  cell styles, so an unquantized image would freeze the editor for about a second — and repeat it
  after every resize.
- **Resizing already re-renders.** `WinResized`/`VimResized` are debounced by 100 ms and end in
  `request`, which lays out at the window's text width. Only the width reaches the engine today,
  and the render cache is keyed on (buffer, changedtick, width, theme).
- **The dependency rule is deliberate.** `engine/Cargo.toml` and `CLAUDE.md` state that the engine
  carries no image decoder. This change amends that rule on purpose, with the smallest feature set
  that covers the promised formats.

## Goals / Non-Goals

**Goals:**

- The cost of an image is bounded twice: by the cells it occupies (`width` × window height) and by a
  session-wide cap on highlight groups.
- Artwork is laid out once per render, from data the layout stage already has, and every failure is
  a fallback rather than an error.
- The wire format does not change; artwork is ordinary spans on ordinary lines.

**Non-Goals:**

- Photographic fidelity. This is a reading aid for diagrams, screenshots and charts, not an image
  viewer.
- Caching decoded bitmaps across renders; the engine is a fresh process each time.
- Colour in the ASCII encoding's character choice (the ramp is luminance only).
- Anything in the preview popup for an image block.

## Decisions

### D1. Decode, scale and encode in the engine, during layout

Alternatives considered:

1. **Decode in Lua.** No decoder, and hand-writing PNG/JPEG in Lua is out of the question.
2. **Shell out to an external tool** (`chafa`, ImageMagick). Adds a runtime dependency the plugin
   does not control, plus argument quoting and another process per image.
3. **Preprocess in a separate step and inline the art into the markdown.** The document would no
   longer be the document; every edit re-runs the preprocessing; and it cannot respond to width.

The engine already owns layout, and the width, height and base directory are layout inputs. An
`image_art` module exposes `artwork(path, bounds, encoding, palette) -> Option<Vec<Line>>`, and
`layout_document` calls it from the new `DocBlock::Image` arm. `None` means "fall back".

The cost is that a decode happens on every render, including every debounced typing pause. Bounded
by the caps (16 MiB, 16 MP), a typical diagram is a few milliseconds; the process spawn and syntax
highlighting already dominate. D10 measures it.

### D2. The renderer emits an image block; the layout stage decides its fate

```rust
DocBlock::Image {
    dest: String,
    alt: Vec<Span>,   // styled with the inline style stack at the reference
    source_line: u32, // the `![` byte offset's line
}
```

The renderer is the only stage that sees `Tag::Image { dest_url, .. }` and the alt text events
between it and `TagEnd::Image`. On the start tag it flushes the pending line, suppresses the alt
events into `alt`, and on the end tag flushes the text block and pushes the image block. A reference
in the middle of a paragraph therefore splits the paragraph into text before, artwork, text after —
documented in the spec, and the same thing a table already does to a paragraph.

Two positions cannot hold a block and keep the alt text instead: a table cell and a heading. A
cell is a `Vec<Span>` inside `TableBlock`, and a heading is spans inside the running `Text` block;
neither has a place to put a block of artwork lines, and splitting them would change the layout of
the table or the heading itself. An image there is therefore collected as its styled alt text, the
same way it was before this change. The spec records this as a deliberate boundary rather than
leaving it to be discovered.

The renderer cannot decode: it has no width, no height and no base directory. The layout stage has
all three, and it already owns `wrap_spans`, which is what an alt-text fallback needs. So the layout
stage is where `artwork` is called, and `None` falls through to `Layout::push(Some(source_line),
Line::from(alt))` — the alt text wraps exactly like paragraph text, at the reference's source line.

The wire format is untouched: `WireDoc`, `WireLine` and `WireStyle` never learn what an image is.
Artwork is spans, one line per cell row.

### D3. Page bounds: contain, no upscaling, height optional

```
cols0  = image_width_px
rows0  = ceil(image_height_px / 2)          // one cell row is two pixels tall
scale  = min(1, width / cols0, max_h / rows0)   // max_h omitted → no height bound
cols   = clamp(round(cols0 * scale), 1, width)
rows   = clamp(round(rows0 * scale), 1, max_h)  // when max_h is given
```

The sample grid is `cols × 2·rows`: each cell row averages two pixel rows, which is the half-block
geometry and the 2:1 cell aspect correction in one place. ASCII mode reuses the same grid and
averages each pair of rows into one cell. The quadrant encoding asks for a `2·cols × 2·rows` grid —
two samples across per cell as well — and halves the width again when it draws; the page bounds
above still apply to `cols`, so a quadrant image is bounded by the same width in *cells* and simply
carries twice the detail inside it.

Rounding twice can drift a column from the exact aspect ratio; discrete cell rows cannot always
carry it. The alternative — deriving one dimension from the other after rounding — has the same
problem in the other direction, and is what the clamp above already handles at the edges.

A bound of zero rows or columns means no room for a cell; that is the alt-text fallback, not a
one-cell smear. There is no separate "fit mode": contain-with-both-bounds is what a reader expects
from an image on a page, and "cover" would crop.

The height comes from the plugin (`--image-max-height`), which knows the window. The engine treats
it as optional so the CLI stays usable without it.

### D4. Sampling: a box average over integer source bands

For each output cell, take the source rectangle `[x0,x1) × [y0,y1)` where the band edges are
`round(i · src / out)`, and average its RGBA in `f32`. The bands are monotone and cover the source
exactly once, so the whole pass is O(source pixels) with no per-output search, no floating-point
edge weights, and a deterministic result independent of iteration order.

Alternatives: `fast_image_resize` (a second resize dependency, SIMD we do not need at these
output sizes); `image::imageops::resize` with a triangle filter (its weights are not an area
average, and the spec says area average). A manual box is about forty lines and is exact.

Alpha is thresholded at 128 when building the sample: below that, the pixel contributes nothing,
and a cell with no contributing pixels is transparent.

### D5. A fixed 64-colour palette, not per-image quantization

Both colours of a block cell come from the same palette, so a 64-colour palette gives at most
64 × 64 = 4,096 distinct cell styles — for every image in every document, for the whole session.
The plugin defines those groups once, on first use, and the cache never grows past them.

The palette is a 4 × 4 × 4 cube over the channels, the levels `0x00`, `0x55`, `0xaa`, `0xff`,
hardcoded in the engine. That gives a four-step grey ramp (including `#555555` and `#aaaaaa`) and
enough of the colour wheel to read an icon.

The first pass used the conventional xterm 16. It cannot show a photograph at all: its only dark
greys are black and `#808080`, and its four dark colours are saturated, so a dark neutral surface
becomes a speckle of navy and maroon. Sixty-four costs three more steps of chroma per channel and
keeps the bound explicit.

Alternatives considered:

- **A 256-colour palette.** 65,536 possible pairs, and measured on a 200-column photo the artwork
  used 1,675–1,742 styles against 485–497 for the 64-colour cube, so at the design's pessimistic
  183 µs per `nvim_set_hl` it is about 306 ms per image instead of about 89 ms. That breaks the
  200 ms render budget that was set as the acceptable ceiling.
- **Median-cut palette per image.** Better gradients, but the group names differ per image, so the
  highlight cache grows without bound as documents are browsed — precisely the 913 ms-per-5,000
  problem, spread over a session. Rejected on cost, not on looks.
- **No quantization.** Measured directly: about a second per image.

The colours are absolute rather than theme-derived because an image's colours are its content, not
the editor's chrome — a diagram should look the same under every theme.

The nearest palette entry is chosen by squared distance in **CIELAB** (ΔE76), not in RGB. RGB
distance is channel-wise, so it cannot tell a neutral colour from a saturated one that sits at a
similar point per channel: a desktop screenshot's dark grey rock at (74, 79, 85) is nearer to
`#000080` than to a neutral grey in every channel, and several hundred cells of a wallpaper came
out navy. CIELAB separates lightness from hue and sends the same grey to a neutral entry. This is
only how the nearest member is picked; the palette does not change. The conversion runs once per
colour already reduced to one per cell, so it costs only what a bigger cell grid costs: measured
on the twelve-megapixel JPEG, 5,400 cells took 2.9 ms more than a one-row grid with the same
decode, which does not move D11's totals.

### D6. Encodings

**Half-block.** Both halves visible: `▀` (U+2580), foreground = upper sample, background = lower
sample; identical halves use the same colour twice. Upper half visible only: `▀` with the colour as
foreground and no background. Lower half visible only: `▄` (U+2584) with the colour as foreground
and no background, which is what leaves the upper half showing the terminal's background. Neither
half visible: a space with no style.

**Quadrant.** Four sub-cells per character: `▘▝▖▗` (U+2598, U+259D, U+2596, U+2597) for one
visible quadrant, `▀▄▌▐` for a half, `▚▞` (U+259A, U+259E) for a diagonal pair, `▛▜▙▟` for three,
`█` for all four. With all four visible the encoder tries the seven partitions of the quadrants
into two colours (the complement of each is the same pair swapped), assigns each side the nearest
palette entry to its mean, and keeps the one with the lowest CIELAB error; the chosen side becomes
the foreground. A cell with one to three visible quadrants is drawn in a single colour whose glyph
covers exactly the visible ones, so transparency stays transparent instead of being painted over.
This is the default behind `auto` because it doubles the horizontal detail of the half-block
encoding for the same width in cells, at the cost of a larger palette and more styles (D5).

**ASCII.** One character per cell from the ramp `@%#*+=-:. `, densest for the darkest cell. The
character carries the cell's palette colour as its foreground; the ramp is ASCII-only, so the
encoding survives any terminal, and `░▒▓` are avoided deliberately — those shade glyphs are what
make this terminal's repaints crawl.

Choosing the glyph per cell rather than one glyph plus colours is also what keeps the encodings
apart: ASCII mode is readable when colour is unavailable or approximate.

The ramp assumes a dark background, since a single monotone ramp cannot serve both. That is listed
as an open question.

### D7. CLI surface

| Flag | Meaning | Default |
| --- | --- | --- |
| `--base <dir>` | Base for relative destinations | working directory |
| `--image-max-height <rows>` | Height bound in display rows | none |
| `--image-encoding <quads\|blocks\|ascii\|off>` | Artwork encoding, or no artwork | `blocks` |

All optional; `--width` is still required. `off` makes every reference render as its alt text, so
the engine has one switch that reproduces the pre-change output exactly.

### D8. Plugin: the page bound and the cache key

- `config.options.image_mode` (default `auto`) sits next to `theme`, with the values `quads`,
  `blocks`, `ascii` and `off`. `auto` resolves to `quads` against `vim.o.termguicolors` at render
  time, not at setup time, so toggling it takes effect on the next render. The engine's own default
  stays `blocks`, so a caller that does not know about quadrants — or a font without the block
  elements — is not switched silently.
- `request` gains `local height = vim.api.nvim_win_get_height(win)` — the text height, which
  excludes the statusline — and passes it to `engine.render`, which appends
  `--image-max-height` when it is non-nil.
- The cache key in `state.lua` gains the height and the resolved encoding. Without the height, a
  height-only resize (`:split`, dragging the terminal taller) would be answered from a stale
  document; without the encoding, changing `image_mode` would not take effect until an edit.
- Nothing else in the plugin changes. Failures of individual images never reach it: the engine falls
  back and exits zero.

### D9. Dependency policy, amended deliberately

```toml
image = { version = "0.25", default-features = false,
          features = ["png", "jpeg", "gif", "webp", "bmp", "tiff", "ico"] }
```

`engine/Cargo.toml` and the note in `CLAUDE.md` claim the dependency set is asserted by a test; no
such test exists today. This change adds one (`engine/tests/dependencies.rs`) that reads
`include_str!("../Cargo.toml")` and fails on any dependency outside an explicit allowlist, so the
next person adding a crate has to do it on purpose. The comment is updated to name the image
decoder and why it is allowed.

### D10. What the tests will measure

- Table-driven tests of the bound arithmetic: contain, no upscaling, height binding first, one-cell
  minimum, no-room fallback.
- Sampling on tiny hand-built images where the expected average is arithmetic, plus the alpha and
  half-visible cases.
- `artwork` output properties: no line wider than the bound, no more than the height bound's rows,
  colours ⊆ the 64, byte-identical on repeated runs — checked for every encoding.
- Fallbacks: missing file, SVG, `http`/`https`, `data:`, oversize file, oversize dimensions, `off`.
- A decode-cost measurement to confirm D1's premise; if it fails, the mitigation is a decode cache
  inside a persistent process, which is a larger change and out of scope here.
- Headless: `image_mode = off` reproduces the old output; a missing image shows alt text with no
  diagnostic; a height-only resize produces a shorter image.
- A committed fixture set (a few dozen bytes each): RGBA PNG, opaque PNG, JPEG, GIF, corrupt file.

### D11. Measured cost (2026-10-21, Windows, release build)

End-to-end `md-render --width 120 --image-max-height 40`, best of seven runs of the release binary,
with the image at its natural size in a one-line document. Baseline is the same document with the
image omitted.

| Case | Total | Over baseline |
|---|---|---|
| Prose only, no image | 59 ms | — |
| 1000×1000 PNG, `blocks` | 44 ms | ~0 (below run-to-run noise) |
| 1000×1000 PNG, `ascii` | 58 ms | ~0 |
| 4000×3000 JPEG, `blocks` | 152 ms | +91 ms |
| 4000×3000 JPEG, `off` | 60 ms | — |

The first measurement was worse: 201 ms for the 12-megapixel JPEG, +149 ms. Two changes brought it
down, both measured before and after:

- `load` no longer forces every decode through `into_rgba8`. A JPEG arrives as RGB8 and stays that
  way; the conversion alone cost 40 ms on 12 megapixels. Grayscale and indexed formats are still
  converted.
- Sampling walks row slices of the raw buffer instead of `get_pixel`: 34 ms → 12 ms on the same
  image. `sample` is generic over the channel count so the alpha test costs nothing for RGB.

Where the 152 ms goes: 79 ms decoding the JPEG, 12 ms sampling, under 1 ms encoding, and about
60 ms of process start, markdown parse and syntax highlighting that any render pays.

The quadrant encoding was measured the same way, against the half-block encoding in the same run
set: 14–21 ms more on the same 12-megapixel JPEG (four samples per cell and up to fourteen palette
lookups per cell, against two). That is about 165 ms total against the 200 ms ceiling. The first
version re-derived CIELAB for each of the fourteen candidates and was 30 ms slower again; indexing
the pre-computed palette coordinates removed that, leaving the palette lookup as the cost.

The acceptance line was "well below the plugin's 100 ms debounce". The image's own cost is now
91 ms at the top of the allowed range (12 megapixels, close to the 16 MP cap), and zero for
anything of diagram or screenshot size. The user set a hard limit of 200 ms total; the worst case
measured is 152 ms. Decoding a *smaller* image is not possible within the current dependency: the
`image` crate's JPEG decoder does not expose a scaled decode, so full-resolution pixels are
produced and then averaged. If large photographs ever become the common case, that is the next
lever, and it needs a second decoder crate.

## Risks / Trade-offs

- **64 colours still posterize a photograph.** → Accepted; the target content is diagrams and
  screenshots, and 64 was chosen as the largest palette whose measured style count stays inside the
  200 ms budget. The palette size is one constant and one cache bound if it proves too coarse.
- **Every render decodes.** → Caps bound it; the debounce coalesces; D10 measures it. If it
  dominates, the escape hatch is caching in the plugin, not in the engine.
- **ASCII art assumes a dark background.** → The common case here, and the only monotone choice.
  A `--background light` flag could be added later; the specs' "darker is denser" requirement is
  unaffected.
- **A rendered image breaks a paragraph around it.** → Visible and predictable, and fallback text
  still wraps normally. Markdown images are normally paragraphs of their own.
- **The engine grows (binary size, build time).** → Seven decoders, no SIMD, release profile
  strips. Build time is per machine, once.
- **An older bundled `bin/md-render` rejects the new flags.** → The engine's own clap error is
  surfaced through the existing failure path; the release notes must say to rebuild. There is no
  version handshake to add, and the wire version is unchanged because the format is unchanged.
- **Documents can reference arbitrary paths.** → Read-only, no network, no writes; the same trust
  the plugin already gives to links it follows. Symlinks are followed as any reader would.

## Migration Plan

1. Land the engine change with its tests; the default encoding (`blocks`) is new behaviour for
   direct CLI use.
2. Rebuild `bin/md-render` as part of the repository's normal build step.
3. Land the plugin change; `image_mode = 'off'` restores today's output exactly.
4. Rollback is `image_mode = 'off'` for behaviour, and reverting both commits for the binary. The
   wire version does not change, so a new plugin with a new engine is compatible; a new plugin with
   an old engine fails loudly on the unknown flag.

## Open Questions

- Whether the ASCII ramp should adapt to a light background, and whether the plugin should pass
  `vim.o.background` to say which. Deferrable: it changes one flag and the ramp direction, not the
  requirements.
- Whether decode cost justifies a cache across renders. Deferrable until D10 has a number.
