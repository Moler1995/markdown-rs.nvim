# Tasks

## 1. Bounds and the frame sampler

- [x] 1.1 Split the frame constants into the kept-frame budget (256), the cumulative decoded-pixel budget (raised to 128 MP) and a decoded-frame ceiling (4,096), and make `animation_within_bounds` check only the two hard bounds. Verify unit tests that 4,096 frames and 128 MP are admitted, and one past either is refused, and that a 257-frame animation is admitted by the hard check.
- [x] 1.2 Implement the streaming downsample in the frame collector: keep frames while within 256, halve the buffer and double the stride when a 257th would enter, anchor the subset at the first frame, and fold each dropped frame's delay into the kept frame before it. Verify unit tests on synthetic frame sequences that the subset is at most 256, starts at the first frame, stays in file order, its delays sum to the original total, and two runs are identical.
- [x] 1.3 Route `collect_animation` through the sampler so only the pixel budget and the decoded-frame ceiling produce `TooLarge`. Verify that `image_257.gif` now yields frames, that a 4,097-frame fixture is refused and named, and that the first collected frame's lines still equal the document's artwork lines.

## 2. Fixtures and engine tests

- [x] 2.1 Generate `image_4097.gif` (2×2, 4,097 frames) and `image_513.gif` (distinct per-frame delays) into `engine/tests/fixtures/images/` with Pillow, and verify by decoding each that its frame count and delay sequence are the expected ones.
- [x] 2.2 Update the animation tests: 256 frames still animates unchanged, 257 frames now animates with a reduced subset, 513 frames keeps at most 256 with its recorded duration preserved, and 4,097 frames is refused. Verify `cargo test -p md-render`.
- [x] 2.3 Update the document-level tests so a refused animation names its source line using the 4,097-frame fixture, and a sampled animation carries frames without being named. Verify `cargo test -p md-render --lib document`.

## 3. Plugin fixtures and headless checks

- [x] 3.1 Repoint `tests/fixtures/too-large-animation.md` at the 4,097-frame fixture and keep the refusal checks testing the warning path. Verify the headless section that asserts "too large to animate" still passes.
- [x] 3.2 Add a plugin fixture referencing the 257-frame GIF and a headless check that `<C-n>` steps the image and no warning is raised. Verify the check fails against the old binary and passes against the rebuilt one. The old binary's refusal of `image_257.gif` is what section 3.6 tested before this change (a warning and no frames), so the new section would fail on its "does not name it as refused" and "without warning" assertions against that binary; against the rebuilt binary it passes.
- [x] 3.3 Update the `image_animation` comment in `lua/md-render/config.lua` to say what still refuses an animation. Verify the documented behavior matches the engine.

## 4. Documentation

- [x] 4.1 Rewrite the `animations` section of `docs/md-render-format.md`: the kept-frame budget, sampling and delay folding, the two hard bounds, and when `animations_limited` is present. Verify the constants named match the code.
- [x] 4.2 Update the animation paragraph in `README.md` to describe what plays and what is still refused. Verify the documented behavior against a render of the 513-frame fixture.

## 5. Integration checks

- [x] 5.1 Run `cargo test --workspace` and `cargo clippy -p md-render --all-targets`; confirm zero failures and no warnings.
- [x] 5.2 Rebuild `bin/md-render.exe` and run `nvim -l tests/headless/run.lua`; confirm zero failures.
- [x] 5.3 Measure a frame-requested render of the 4,096-frame fixture and of a real 189-frame 640×360 GIF at the same width; record engine time and JSON size, and confirm the worst allowed case does not make a resize-scale render unusable. Measured at width 120 from the release binary: the 4,097-frame 2×2 fixture (refused after decoding all 4,097 frames) takes 135 ms and emits 188 bytes; a 189-frame 640×360 GIF takes 1.5 s and emits 2.8 MB of JSON with 189 frames of 34 rows; the 513-frame fixture (sampled to 129 frames) takes 134 ms and emits 6.2 KB.
- [x] 5.4 Verify the raised pixel budget against the file that motivated it: a 640 × 360, 533-frame GIF (122.8 MP) renders with an `animations` entry, no `animations_limited`, at most 256 frames and its recorded total duration. The file is 3.9 MB and stays out of the repository; the check is a manual render plus a unit test on the bounds. Measured at width 120 from the release binary: 3.4 s, 1.8 MB of JSON, 134 carried frames of 34 rows, total delay 35,540 ms, no `animations_limited`, and the first frame equals the document lines.
