# Design

## Context

See `proposal.md` — Why. The constraints that shape the approach:

- The engine already accepts `--image-max-height`; the plugin passes the window's text height
  (`page_height(win)`) with every inline render, and the preview popup passes its own inner height
  through a separate request (`preview.view`).
- `cell_grid` (`engine/src/image_art.rs`) takes one scale factor — the minimum of the width fit and
  the height fit — so the height bound alone determines the size of any image that is wider than
  the window.
- Images narrower and shorter than both bounds are never enlarged, so a cap cannot make a small
  picture smaller.
- The render cache is keyed by width and height among other things, so a changed bound is a
  different cache entry rather than a stale hit.

## Goals / Non-Goals

**Goals:**

- One option controls the size of inline artwork, with a default that makes a figure sit inside a
  reading page instead of filling it.
- The preview popup remains the way to see the image large.
- No engine, wire-format or cache-shape change.

**Non-Goals:**

- Per-image sizing syntax in markdown (no standard one; out of scope).
- Changing the popup's geometry or its fraction-based caps.
- Controlling the width bound independently of the height bound.

## Decisions

### D1. Cap the height bound, and let the aspect ratio carry the width

The plugin computes the inline height bound as `min(page_height(win), image_max_height)` and passes
it as `--image-max-height`, as it already does. Because the engine scales both axes by one factor,
a shorter cap also produces a narrower artwork: the 640×360 GIF at 126 columns goes from 126×35
(bounded by width) to 71×20 (bounded by height). The alternative — a new `--image-max-width` flag —
would need an engine change and would allow non-proportional shapes for no gain, since a reader who
wants a smaller picture is expressing one size, not two.

### D2. The default is 20 rows, not "no cap"

The previous behaviour (cap at the window height) is what makes a single image fill the page, so
leaving the default at `nil` would ship the problem. Twenty rows is roughly 40% of a 50-row window
and keeps a landscape figure beside the prose that follows it; `test.gif` at 126 columns becomes
71×20 instead of 126×35. `false` remains available and restores the old behaviour exactly.

`false` rather than `nil`: `config.setup` merges with `vim.tbl_deep_extend`, where a `nil` value is
indistinguishable from a missing key, so `image_max_height = nil` would silently keep the default.
`false` is also what the keymap options already use for "off".

Alternative: a percentage of the window height (`0.4`). Rejected: the option would then be
"bigger in a bigger window", which is not what "this figure is too large" is asking for, and a
percentage is harder to reason about than a row count the reader can see.

### D3. The popup keeps its own bound

`preview.view` builds its own `height` from the popup's geometry (`max_h - 2`) and does not go
through the inline `request`, so it needs no guard: the option simply is not read there. That is
the intended reading — the page shows a figure small, and the preview key shows it at the popup's
size.

Alternative: apply the cap in the popup as well. Rejected: it would make the preview unable to show
an image larger than the inline cap, which is most of its value.

## Risks / Trade-offs

- **Every existing document's images get smaller by default.** → That is the requested change;
  `image_max_height = false` restores the previous size exactly, and the option is documented in
  `config.lua` and the README.
- **A very short window makes `min(window, 20)` smaller than 20.** → Intentional: the window is
  still the hard bound, so artwork never exceeds the page.
- **Users may expect a width option.** → The spec says the aspect ratio is preserved and the height
  is the knob; the README states the same.

## Migration Plan

Lua-only change, no engine rebuild. Rollback is configuration: `image_max_height = false`.

The delta modifies the requirement `Image artwork follows the window's page`, which
`render-inline-images` introduces. That change is still open, so `openspec/specs/` has no
`nvim/render-mode` yet and this delta cannot be archived first: archive `render-inline-images`
before this change, or the archive step will refuse the MODIFIED requirement for want of a target.
