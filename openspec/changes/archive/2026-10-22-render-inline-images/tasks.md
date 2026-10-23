# Tasks

## 1. Engine dependencies and CLI

- [x] 1.1 Add `image = { version = "0.25", default-features = false, features = ["png", "jpeg", "gif", "webp", "bmp", "tiff", "ico"] }` to `engine/Cargo.toml` and update its dependency-policy comment to name the decoder and the reason it is allowed; verify `cargo build --release -p md-render` succeeds and the binary still prints help.
- [x] 1.2 Add `engine/tests/dependencies.rs`, which reads `include_str!("../Cargo.toml")`, collects the names under `[dependencies]`, and fails on anything outside the explicit allowlist (`clap`, `mermaid-text`, `pulldown-cmark`, `serde`, `serde_json`, `syntect`, `unicode-width`, `image`); verify `cargo test -p md-render --test dependencies` passes and fails when a name is removed from the allowlist (try it, then restore).
- [x] 1.3 Correct the dependency rule in `CLAUDE.md` (line about "no image decoder ... asserted by a test") so it points at the new test and records the decoder as a deliberate exception; verify the wording matches what the test enforces.
- [x] 1.4 Add optional `--base <dir>`, `--image-max-height <rows>` and `--image-encoding <blocks|ascii|off>` to the CLI in `engine/src/main.rs`, defaulting to no base, no height bound and `blocks`; verify `md-render --help` lists all three and `md-render --width 80 --image-encoding bogus` exits non-zero with a clap error.

## 2. Image blocks from the renderer

- [x] 2.1 Add `DocBlock::Image { dest: String, alt: Vec<Span>, source_line: u32 }` in `engine/src/block.rs`, with `anchor_source_line` returning `Some(source_line)`; verify the crate builds and existing renderer tests still pass.
- [x] 2.2 Handle `Tag::Image` and `TagEnd::Image` in `engine/src/renderer.rs`: flush the pending line at the start tag, collect the alt text into a span vector under the current style stack instead of emitting it as text, flush the text block and push the image block at the end tag; verify a unit test renders `text before ![alt](x.png) text after` and finds a `Text`, an `Image` (with non-empty `alt`), and a `Text` block, in that order.
- [x] 2.3 Add a unit test that an image reference on its own paragraph yields exactly one `Image` block anchored at its own source line, and that the alt text no longer appears in a `Text` block.

## 3. Artwork pipeline (`engine/src/image_art.rs`)

- [x] 3.1 Implement destination resolution: absolute paths as given, relative against the base directory or the working directory, with `http`, `https` and `data:` rejected as unrenderable; verify unit tests cover all five cases.
- [x] 3.2 Implement loading with the caps: reject a file over 16 MiB by metadata before reading, read the header and reject more than 16 megapixels before decoding pixels, decode PNG/JPEG/GIF/WebP/BMP/TIFF/ICO, and use a GIF's first frame; verify unit tests against committed fixture images and a corrupt file, and that an oversized file's dimensions are never queried.
- [x] 3.3 Implement the integer-band box average with a 128 alpha threshold, producing the `cols × 2·rows` sample grid of palette-quantized RGBA; verify unit tests on tiny images where the expected average is exact arithmetic, plus one fully transparent and one half-transparent case.
- [x] 3.4 Implement quantization to the fixed palette by nearest CIELAB distance (ΔE76); verify a unit test that a smooth gradient stays inside the palette's size, that a palette colour maps to itself exactly, and that a dark neutral grey stays neutral.
- [x] 3.5 Implement the half-block encoder (`▀` for both halves and upper-only, `▄` for lower-only, space for none, identical halves sharing one colour) as `WireLine`s with at most one span per run and adjacent equal cells merged; verify unit tests assert the exact glyph and style for each of the five cell cases and that a uniform row merges to one span.
- [x] 3.6 Implement the ASCII encoder: one character per cell from `@%#*+=-:. ` ordered darkest-first, coloured with the cell's palette colour as foreground, no character outside the ASCII range; verify unit tests assert the ramp endpoints, the ASCII-only property, and that a transparent image yields only spaces.
- [x] 3.7 Implement the bounds arithmetic from `design.md` D3 (contain, no upscaling, height binding first, one-cell minimum, no-room fallback) and the `artwork(bounds, encoding, palette) -> Option<Vec<Line>>` entry point; verify table-driven tests for every scenario in "Scaling and page bounds", including the no-height case.

## 4. Layout integration

- [x] 4.1 Thread the new CLI values into rendering as one `ImageOptions { base, encoding, max_height }` value passed from `main.rs` through `layout_document`; verify every existing caller and test compiles and `cargo test -p md-render` is green with images still rendering as alt text.
- [x] 4.2 Add the `DocBlock::Image` arm to `layout_document`: call `artwork` at the requested bounds and push the returned lines anchored at the reference's source line, or push the alt spans through `Layout::push` when it returns `None`; verify a test renders a real fixture image and finds artwork lines where the reference was, and one renders a missing file and finds the wrapped alt text.
- [x] 4.3 Add property tests over rendered fixture documents: no artwork line exceeds the requested width, artwork rows do not exceed `--image-max-height`, every artwork line maps back to the reference's source line, every colour in the output is one of the palette's values, and two renders are byte-identical.
- [x] 4.4 Measure the cost of decoding and rendering a 1000×1000 PNG and a 4000×3000 JPEG through the CLI, record the numbers in the change's review notes, and confirm they stay well below the plugin's 100 ms debounce; if they do not, stop and report before continuing.

## 5. Plugin: page bound, mode and cache

- [x] 5.1 Add `image_mode = 'auto'` to `config.defaults` with the comment explaining `auto`/`quads`/`blocks`/`ascii`/`off`; verify `setup` merges an override and the value is reachable as `config.options.image_mode`.
- [x] 5.2 Extend `engine.render` to take the height bound and the resolved encoding, appending `--image-max-height` when the height is non-nil, `--image-encoding` always, and `--base` derived from the source buffer's file name (skipped for an unnamed buffer); verify a headless test spies on the constructed arguments.
- [x] 5.3 Add the height and the resolved encoding to the render cache key in `state.lua` (`cached`/`store`); verify a headless test that changes only the height and observes a new engine call instead of a cache hit.
- [x] 5.4 Resolve `auto` against `vim.o.termguicolors` at request time in `init.lua`, pass `nvim_win_get_height(win)` as the height bound, and make sure a runtime `image_mode` change takes effect on the next render; verify a headless test with `termguicolors` off produces `--image-encoding ascii`, and one with it on produces `quads`.
- [x] 5.5 Document `image_mode` and the image behaviour in `README.md` and in the `config.lua` comments, including that `off` reproduces the previous output; verify the documented option names match the code.
- [x] 5.6 Add headless tests: `image_mode = 'off'` shows alt text; a missing image file enters R, shows the surrounding document and the alt text, and reports no diagnostic; resizing the window shorter shrinks the artwork. Verify `nvim -l tests/headless/run.lua` is green.

## 6. Integration checks

- [x] 6.1 Run the full engine suite (`cargo test --workspace`) and the headless suite, and confirm zero failures.
- [x] 6.2 In Windows Terminal, open a document containing a PNG, a JPEG and a GIF at several window sizes, toggle R, and confirm the artwork fits the page, follows resizes, and leaves the rest of the document intact; record what was observed.
  - Deferred to `animate-inline-images` task 6.3, which performs the same Windows Terminal pass on the same code with the animation work in place; doing both separately would duplicate the check. Accept this change when that one's 6.3 is recorded.
  - Recorded there on 2026-10-22: the pass was accepted, so this task is satisfied by it.
- [x] 6.3 Rebuild `bin/md-render` from the changed engine and confirm the plugin resolves and runs it without a PATH edit.

## 7. Second pass: more subpixels and a larger palette

Driven by the first Windows Terminal look at a real screenshot: sixteen colours and half-cells
were too coarse. The spec now asks for 64 colours and adds a quadrant encoding.

- [x] 7.1 Replace the fixed xterm 16 with the 64-colour 4 × 4 × 4 cube (`0x00`, `0x55`, `0xaa`, `0xff` per channel), keeping CIELAB nearest-match; verify the gradient test stays inside 64 colours, palette colours map to themselves, and a dark neutral grey is still neutral.
- [x] 7.2 Add the quadrant encoder: a 2 × 2 sub-cell grid per cell over the block elements U+2596–U+259F, seven two-colour partitions scored in CIELAB, a single colour with no background when any sub-cell is transparent, U+2588 when both partitions agree; verify unit tests for vertical, horizontal and diagonal splits, the uniform and single-quadrant cells, the transparent case, the glyph table, and row merging.
- [x] 7.3 Add `quads` to `ImageEncoding` and the CLI's `--image-encoding`, expose `image_mode = 'quads'` in the plugin and resolve `auto` to it under `termguicolors`; verify headless 14.1 expects `quads` with true colour on.
- [x] 7.4 Measure `quads` against `blocks` on the 12-megapixel JPEG and record it in D11, confirming the total stays under the 200 ms ceiling.
- [x] 7.5 Update the spec deltas (encodings, 64-colour palette, transparency), `design.md` (D3, D5, D6, D7, D8, D10, D11, risks), `proposal.md`, and the README's `image_mode` section.
- [x] 7.6 Run `cargo test --workspace`, the headless suite and rebuild `bin/md-render.exe`; confirm zero failures.
