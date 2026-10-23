# Design

## Context

See `proposal.md` — Why. The constraints that shape the approach:

- The engine is a one-shot process: it reads the document, lays it out, prints one JSON document and
  exits. There is no daemon and no state between renders.
- `image_art::artwork` decodes a reference once (`ImageReader::decode`, which yields the first GIF
  frame), samples it onto a cell grid, quantizes to the 64-colour palette and encodes to lines.
  Layout then pushes those lines at the reference's source line.
- The wire document is `{version, width, layout_width, styles, lines, source_map}`; spans are
  `[style_index, text]` and styles are interned, deduplicated and palette-bounded.
- The plugin keeps R as a real buffer and caches the document by
  `(buffer, changedtick, width, height, encoding, theme)`; `render.apply` writes every line and one
  extmark per span.
- The preview popup is a second render of one block at its own budget. It currently locates a
  `mermaid` fence or a GFM table from the source line the cursor's display row maps to, and renders
  that slice with image artwork turned off.
- The user's acceptance ceiling for an ordinary render is 200 ms; a 12-megapixel JPEG already costs
  about 150 ms, and the quadrant encoding about 165 ms.

## Goals / Non-Goals

**Goals:**

- An animated image is still by default in R and moves only when asked.
- The motion is driven by the image's own delays, in a popup that opens like the diagram preview.
- No ordinary render and no resize pays for frame decoding.
- One key hands the image to the operating system's default application.

**Non-Goals:**

- Animating APNG, AVIF, HEIC or anything else; only GIF and WebP, as decoded by `image`.
- A player in R itself: no auto-play outside the popup, no progress bar, no seeking.
- Keeping playback in sync across windows, or surviving a resize mid-playback.
- Background pre-fetching of frames, or a persistent engine process.

## Decisions

### D1. Frames are opt-in on the engine command line

A new `--image-animation` flag requests frames. It defaults to off, so every existing caller — the
plugin's ordinary render, tests, the CLI — gets byte-identical output to today.

Alternatives:

- **Always emit frames.** Rejected: every resize of a document with a GIF would decode every frame.
  A 100-frame GIF is 100 decodes behind a drag-resize.
- **One engine call per frame.** Rejected: process start alone is about 60 ms, so playback could not
  reach even 10 fps, and each call would re-decode the GIF from the start.
- **A persistent engine.** Rejected as a separate architectural change: it changes process
  lifetime, failure handling and the plugin's whole request model.

### D2. Frames ride the existing wire document

`WireDoc` gains an optional `animations` array and an optional `animations_limited` array; both are
omitted when empty, so the wire version stays 1 (an added field does not break an existing reader).

```json
{
  "version": 1,
  "styles": [ ... ],
  "lines": [ ... ],            // the first frame, exactly as today
  "source_map": [ ... ],
  "animations": [
    {
      "source": 2,             // source line of the reference
      "start": 7,              // first line index in `lines`
      "rows": 38,
      "frames": [
        { "delay": 100, "lines": [ [[1, "▀▀▜..."], [2, "..."]], ... ] }
      ]
    }
  ],
  "animations_limited": [4]   // source lines of animations the caps refused
}
```

Frame lines carry spans only — no `source`, because every line of every frame belongs to the same
reference. Their style indices come from the same `StyleTable`, so a style shared between frames is
stored once and a frame swap never has to define a new highlight group for a style the first frame
already used.

The first frame stays in `lines` rather than being only frame 0 of the animation, so:

- the static view is the unchanged document;
- a reader that ignores `animations` (an older plugin) draws the first frame;
- the source map and cursor mapping need no new rules.

`start` and `rows` are recorded by the layout stage where it pushes the image block (its
`lines.len()` before the push, and the number of lines pushed), because that is the only place that
knows them; the frame lines are pushed through the same `Layout::push` as the first frame, so they
inherit the width clamp.

Alternative: a separate `--frames` subcommand returning only animation data. Rejected: two layouts
of the same document can drift (width, encoding), and it adds a second render to every popup.

### D3. The plugin fetches frames lazily

The normal R render does not pass `--image-animation`. The animated document is requested only:

- when the frame-step key is pressed on an animated image for the first time after a render, or
- when the image popup opens.

The animated document replaces the cached one, keyed by the same tuple plus an `animation` boolean.
Its `lines` are identical to the static document's, so adopting it does not change the buffer.

Why: frame decode is proportional to frame count, and a resize re-renders. Most documents never
press the key; those that do pay once per (size, content) generation, not per frame.

Cost of the choice: the first step waits for an engine render (tens to hundreds of milliseconds)
with no visible change until it lands. Later steps are immediate because the frames are in memory.
The headless test measures the first-step latency; the caps in D7 bound it.

Alternative: always request frames in R. Rejected: the resize path would pay frame decode for every
document containing an animated image, and the 200 ms ceiling would be broken by content the reader
is not looking at.

### D4. Applying a frame touches only the artwork's lines

`render.frame(buf, doc, animation, index)` replaces buffer lines `start .. start + rows - 1` and
re-sets the extmarks for exactly those lines, using the frame's spans and the document's style
table. It toggles `modifiable` around the write and clears the modified flag, like `apply`.

- The buffer's line count and every other line are untouched, so the source mapping, cursor and
  scroll position remain valid; the frame has the same `rows` as the first frame by construction.
- Styles are defined on demand: `style.group` interns `(style, index)` and caches the highlight
  group. A frame that uses a style no earlier frame used costs one `nvim_set_hl`; the palette bound
  (4,096 pairs) still bounds the session total.
- The buffer is not re-rendered from the document, which is what makes a 10–20 fps update cheap.

Alternative: re-apply the whole document per frame. Rejected: every frame would rewrite every line
and every extmark, and would reset the detected buffer state each time.

### D5. Playback is a one-shot timer restarted per frame

The popup owns one `vim.uv` timer. It is not a repeating timer, because GIF delays vary per frame:
after applying frame `i`, the timer is started for frame `i+1`'s delay. Buffer writes are wrapped in
`vim.schedule`, since the timer callback is on the libuv thread.

Delay policy: `delay < 20 ms` is played as 100 ms. GIF delays are recorded in hundredths of a
second, and a delay of 0 or 1 is how an encoder says "as fast as possible"; browsers clamp those to
100 ms, and a literal 10 ms would spin the editor and the engine. Longer delays are played as
recorded — a slideshow GIF with a 10-second hold is content, not a bug.

Pause stops the timer and keeps the current frame index; resume restarts it after that frame's
delay. Closing goes through `M.close`, and the popup's `WinClosed` handler must stop the timer too,
because a window closed by any other route (`:close`, a mouse click elsewhere) bypasses `M.close`.
A frame is applied only if the popup is still the one it was scheduled for; the existing
`M.popup ~= popup` guard covers a close, and the doc identity covers a re-render.

### D6. The image popup is located from the reference, not the artwork

`preview.locate` already maps a display row to its source line. For an image, the artwork lines are
anchored to the reference line, so the same row-to-source step lands on the `![alt](dest)`.

`link.lua` already parses images as well as links (it handles the `!` prefix); it gains an `image`
flag on each entry. `preview.locate` returns a new kind, `image`, carrying the reference's exact
source text.

The popup renders that reference text alone, not the whole source line: a line such as
`text ![a](x.png) more` would otherwise show the surrounding prose. Using the reference's own text
keeps its alt text, so an undrawable image still shows a useful popup.

Geometry: the budget is the popup's inner width and `--image-max-height` is its inner height. Unlike
a diagram, an image is scaled rather than clipped, so `MAX_BUDGET` is not needed and would only make
the popup smaller than the image. `--base` comes from the document's path, as for the main render.

`<CR>` on artwork that is not an image still falls through to Vim, as today.

### D7. Decode bounds are all-or-nothing, and a refusal is reported

`--image-animation` adds two limits on top of the existing ones:

- at most **256 frames**;
- at most **64 megapixels** of decoded frame area in total (`frames × width × height`).

The pixel cap is cumulative because the per-image 16 MP cap bounds one frame, not a hundred of them.
Frames are sampled and turned into lines as they are decoded, so peak pixel memory stays at one
frame; the cap is about decode CPU, not memory.

Sixty-four megapixels covers an ordinary 640 × 360 GIF of 189 frames (43.5 MP), which the first
32 MP bound refused; it still stops the animations whose first step would take seconds.

Exceeding either limit makes the image render as its first frame with **no** animation data. A
partially animated image would misrepresent the content (it would loop back to a frame that is not
the first), while a still first frame is honest and is what the static view shows anyway.

A refused animation is not the same as a still image, and leaving the reader to guess between them
made the step key look broken on a real over-cap file. The engine therefore records the refused
reference's source line in `animations_limited`, and the plugin reports it: in R the frame-step key
is consumed with a warning naming the file, and the popup warns when it opens rather than sitting
motionless. The warning is given once per render — the refusal is remembered in the window state
until the next render — so pressing the key again neither spawns the engine nor repeats the
message. A still GIF, a missing file and an undecodable one stay on the ordinary fall-through.

### D8. Opening the image uses `vim.ui.open` and the engine's own resolution rules

`vim.ui.open(path)` dispatches to the platform's handler (`start` on Windows, `open` on macOS,
`xdg-open` elsewhere) and reports failure through its second return value. The project already
requires a Neovim new enough for it (0.10+; the development machine runs 0.12.6).

Resolution mirrors the engine: an absolute destination as given; a relative one against the
document's directory, or the working directory for an unnamed buffer. `http`, `https` and `data:`
destinations are refused before anything is launched — the engine never fetches them, and the
plugin will not hand them to a browser either. A missing local file is checked with `uv.fs_stat`
first, so the reader gets one clear message instead of an OS dialog.

The key falls through with the existing `feed` helper when the cursor is not on an image, the same
way `follow` does for a non-link.

Alternatives: hand-rolling the OS command per platform (more code, worse error reporting);
`netrw`'s `gx` (depends on netrw being loaded and its own file detection).

### D9. Configuration and cache

- `image_animation = true` — off means no frames are requested and the step/pause keys fall through.
- `keymaps.frame_next = '<C-n>'` (R and the popup), `keymaps.open_image = 'gx'` (R),
  `keymaps.pause = '<Space>'` (the popup, only when an animated image is playing).
- The state cache key gains the animation flag, next to the encoding: an animated document and the
  static one have the same lines but different payloads, and returning one for the other would
  silently drop the frames or re-fetch them on every press.

`<C-n>` is unbound in normal mode by default; `gx` is Neovim's own "open with the system handler",
which is exactly what the key does when it does not fall through.

## Risks / Trade-offs

- **The first step is visibly delayed.** → It waits for one engine render; the caps bound it, the
  frame arrives when it arrives (no error, no flicker), and later steps are immediate. If the
  measured latency is unacceptable, the fallback is to request frames in R and accept the resize
  cost — a one-line change with a measured trade-off, recorded in tasks.
- **Large animations produce large JSON.** → 256 frames at 126×38 is about 800 KB–8 MB depending on
  span density; the caps bound it and the first implementation measures parse time. Measured: the
  100-frame 480×270 case is 402 ms / 1.37 MB, and the 189-frame 640×360 case (43.5 MP, the file that
  motivated the 64 MP bound) is 1.07–1.08 s / 3.53 MB. If Lua's JSON decode dominates, drop the
  frame cap (it is one constant).
- **A frame write races a re-render.** → A frame is applied only while the popup/document identity
  is unchanged; any render replaces the document and stops playback (`M.adopt`/`show_rendered`).
- **`vim.ui.open` differs by platform.** → It is the editor's own dispatch layer; failures are
  returned and reported. The alternative is worse on all three platforms.
- **Animated WebP support depends on the `image` crate's decoder.** → Verified at implementation
  time: `WebPDecoder` implements `AnimationDecoder` and reports `has_animation` in `image` 0.25.10.
  If a format turns out not to expose frames, it is treated as still, not as an error.
- **Timers outliving their popup.** → One timer per popup, stopped by both `M.close` and the
  `WinClosed` handler; a scheduled frame re-checks the popup identity before writing.

## Migration Plan

1. Engine first, behind `--image-animation`; the default path is unchanged, so the plugin can be
   updated in a second step without a flag day.
2. Plugin: options, keys, popup and lazy fetch.
3. Rebuild `bin/md-render.exe`, run both suites, then the manual Windows Terminal check.
4. Rollback is config-level: `image_animation = false` is enough. An older plugin against the new
   engine is safe (it ignores `animations`); a new plugin against an older engine is not supported,
   because the old engine rejects the unknown flag. Engine and plugin are rebuilt and released
   together, as the existing change already requires.

## Open Questions

- Whether a frame-step key should also pause/resume an animation in R (this design keeps R manual).
  Deferred: the popup is where playback lives, and R has no timer by design.
