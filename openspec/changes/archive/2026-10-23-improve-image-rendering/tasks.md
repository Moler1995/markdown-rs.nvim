# Tasks

## 1. Sampling in linear light, alpha and dithering

- [x] 1.1 Replace the sRGB-byte area average with a linear-light average: a 256-entry sRGB→linear lookup per source pixel, sums in linear light, one conversion back per sample. Verify a unit test that averages a 50% black/white pair and expects the sRGB midpoint of light (≈188), not 128, and that a uniform image is unchanged.
- [x] 1.2 Average alpha with the colour, weighting the colour sum by alpha so transparent pixels do not darken a cell. Verify a unit test on a cell that is half opaque red and half fully transparent: its colour is red, not 50% red.
- [x] 1.3 Add compositing against a named background: none (the terminal's), the theme's background colour, or an explicit colour. Verify unit tests that a 50%-alpha white pixel against black yields the midpoint grey, that no compositing happens when the background is the terminal's, and that a fully transparent cell still renders as an unstyled space.
- [x] 1.4 Add a fixed Bayer 4×4 ordered dither, applied by offsetting a sample before the nearest-colour search. Verify a unit test that a smooth grey ramp quantised to the theme palette uses more than one colour and that two runs are byte-identical.
- [x] 1.5 Regenerate the image unit-test expectations and any document snapshots that contain artwork, and confirm the new values follow from linear-light averaging rather than from a bug. Verify `cargo test --workspace` passes.

## 2. Palettes

- [x] 2.1 Implement the adaptive palette: stride the samples to at most 4,096, convert to CIELAB, split the widest box until 64 boxes exist, and take weighted means back in sRGB. Verify a unit test that the palette is deterministic across runs and that a two-colour image's palette contains colours closer to those two than the theme palette's entries are.
- [x] 2.2 Route sampling through a palette mode: `theme` keeps today's fixed cube and must reproduce today's output byte for byte; `adaptive` uses the per-image palette. Verify a unit test pinning `theme` output against the pre-change expectation for a fixture.
- [x] 2.3 Add the `full` mode with the 4,096-image-style bound: emit sampled colours exactly until the bound, then quantise the rest to the adaptive palette without changing colours already emitted. Verify unit tests for a small image that keeps exact colours, and for a large one whose style count stops at 4,096 while its first colours are unchanged.
- [x] 2.4 Measure the sampling cost on the 16-megapixel rejection path and on a 640×360 photograph at width 126 in each palette mode; record the numbers and confirm the adaptive palette does not push an ordinary render past the existing 500 ms target. Measured on the local release build: a 640×360 photograph at width 126 takes 67–93 ms in every encoding/palette combination (braille: theme 75–113 ms with a 274 ms cold run, adaptive ≈75 ms, full ≈78 ms; blocks 67–78 ms; quads 87–93 ms), and the 20-megapixel rejection path takes 60 ms.

## 3. Braille encoding and the new default

- [x] 3.1 Implement the braille encoder: a 2×4 sub-cell grid, the standard dot numbering (dots 1–3 and 7 down the left column, 4–6 and 8 down the right), emitted as U+2800 plus the dot bits, with one foreground colour and no background. Verify unit tests for the bit mapping, including a single upper-left dot yielding U+2801 and a full cell yielding U+28FF.
- [x] 3.2 Decide each dot by its distance from the page the artwork is drawn on — per channel, not by luminance — with the ordered dither offset moving the threshold from the page towards the far end of the range, take the ink colour from the lit sub-cells, and never light a transparent sub-cell. Verify unit tests: a uniform cell at the page's far end is all dots in its colour, a cell that matches the page is blank, a vertical edge lights one column, a cell that is entirely transparent is U+2800, and a mostly white screenshot on a dark page inks the white and leaves the dark features as gaps. (Revised during 7.3: the first cut compared each dot with the cell's own average luminance, which lit about half the dots of every cell that had any contrast and drew only a picture's shadows. See design D2.)
- [x] 3.3 Make braille the engine's default encoding and keep `blocks`, `quads`, `ascii` and `off` unchanged. Verify that `--image-encoding blocks` on a fixture is byte-identical to the previous binary's output, and that an unqualified render emits only U+2800–U+28FF.
- [x] 3.4 Check the braille path against the style bound: with `full` and a 126×20 image, confirm the document's image styles stay within the cap and record the count for a photograph. Measured: a 640×360 photograph in braille at 126×20 uses 2,518 distinct image styles, inside the 4,096 cap.

## 4. Enlargement and sharpening

- [x] 4.1 Implement `image_min_rows` as the smallest whole enlargement factor from 1 to 4 that reaches the requested row count, by nearest-neighbour sampling, never exceeding the width or height bounds. Verify unit tests for a 16×16 image enlarged to a minimum, for a minimum already met (no change), and for a bound that forbids the factor.
- [x] 4.2 Implement `image_sharpen` as a fixed 3×3 unsharp mask applied after the area average and before quantisation, only when the image was reduced. Verify a unit test where an edge's contrast increases and one where a natural-size image is unchanged.

## 5. Engine flags

- [x] 5.1 Add `--image-palette <theme|adaptive|full>`, `--image-background <terminal|theme|#rrggbb>`, `--image-dither <auto|on|off>`, `--image-min-rows <N>` and `--image-sharpen`, defaulting to the engine's conservative behaviour (`theme`, `terminal`, off, 0, off), and add `braille` to `--image-encoding`. Verify `--help` lists them and a render with each flag produces the documented effect.
- [x] 5.2 Document the flags in `docs/md-render-format.md` or the engine's usage docs, and verify the documented spellings match `--help`.

## 6. Plugin options and plumbing

- [x] 6.1 Add `image_palette`, `image_background`, `image_dither`, `image_min_rows` and `image_sharpen` to `config.defaults` with the defaults from the spec, plus `braille` in the `image_mode` documentation. Verify a headless test that `setup` merges overrides and that the defaults are reachable.
- [x] 6.2 Pass the five options from the shared argument builder in `engine.lua` and add them to the render cache key in `state.lua`. Verify a headless test spying on the constructed arguments for every value, and one that changing an option between two requests produces two engine calls.
- [x] 6.3 Resolve `image_mode = 'auto'` to `braille` with `'termguicolors'` and `ascii` without, and `image_palette = 'auto'` to `full` for braille/ASCII and `adaptive` for half-block/quadrant. Verify headless tests for each combination.
- [x] 6.4 Confirm the preview popup receives the same five options through the shared builder, without its own copies. Verify a headless test spying on the popup's engine arguments.
- [x] 6.5 Document every new option in `README.md` and the `config.lua` comments, including that braille is now the default, what it looks like, and how to restore the previous output (`image_mode = 'quads'`, `image_palette = 'theme'`, `image_dither = false`). Verify the documented names and defaults match the code.

## 7. Integration checks

- [x] 7.1 Run `cargo test --workspace` and `nvim -l tests/headless/run.lua`; confirm zero failures. Recorded: the workspace suite is green (engine lib 201, corpus 8, dependencies 3, image_layout 6, wire format 6; mermaid-text and ascii-dag suites all green), and the headless run reports 803 checks, 0 failed, 142 engine spawns.
- [x] 7.2 Rebuild `bin/md-render.exe` and rerun both suites against it; confirm the plugin resolves it without a PATH edit. Recorded: the release binary was copied to `bin/md-render.exe`; the headless suite then ran against it (the plugin resolves `bin/` before PATH) with 803 checks, 0 failed, and the workspace suite stayed green.
- [x] 7.3 In Windows Terminal, render a photograph, a logo with transparency and a line-art screenshot in braille (`auto`) and in `quads`, and confirm: braille shows recognisable tone, the logo has no hard halo, the line art is sharper than in quads, and `image_mode = 'quads'` restores a colour-cell picture. Record what was observed. First pass failed: a white document screenshot in braille was almost invisible on the dark terminal, because the rule then in place inked only each cell's darker side (see 3.2 and design D2). After the rule was replaced by the distance from the page, the same screenshot rasterises as a light field with its dark features left as gaps — its heading, table and step layout are visible, though the body text is not, since 119 columns of braille is 238×160 dots and a line of text is thinner than one dot. The gradient fixture now uses 19 of the 20 distinct braille glyphs it can at its size, so tone is carried by dot density; the transparent-background logo draws a clean red disc. Accepted by the reader on 2026-10-23, who asked for the change to be archived.
- [x] 7.4 Count the highlight groups created while showing a page of photographs in `full` and confirm the session stays responsive and the count stays within the style bound. Record the count. Recorded: four 640×360 photographs on one page at 126 columns in braille/full create exactly 4,096 styles and 4,096 highlight groups (the cap), and the first render (engine plus painting) takes about 1.1 s in a headless Neovim.
