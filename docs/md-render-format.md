# The `md-render` wire format

`md-render` writes one JSON object to stdout and nothing else. Diagnostics go to
stderr, so a caller can read stdout as data unconditionally.

```text
md-render --width 120 --theme nord path/to/file.md
```

The object describes a document already laid out for a specific column width.
It is not a parse tree and not an intermediate representation: the engine has
made every decision about where lines break, how wide a table column is, and
what a diagram looks like. A reader's job is to paint it.

## An example

Rendering `# Hi\n\nplain **bold** text\n` at width 40:

```json
{
  "version": 1,
  "width": 40,
  "layout_width": 15,
  "styles": [
    { "fg": "cyan", "bg": null, "bold": true, "underline": true },
    { "fg": "#dcdcdc", "bg": null },
    { "fg": "#dcdcdc", "bg": null, "bold": true }
  ],
  "lines": [
    { "source": 0, "spans": [[0, "█ Hi"]] },
    { "source": 0, "spans": [] },
    { "source": 2, "spans": [[1, "plain "], [2, "bold"], [1, " text"]] },
    { "source": 2, "spans": [] }
  ],
  "source_map": [0, 2, 2]
}
```

## Fields

### `version`

The format's version. An integer, currently `1`. A reader that does not
recognise the version should refuse the document rather than guess; the field
exists so that a future change to the shape is detectable instead of silently
producing a wrong picture.

### `width`

The column width the engine laid out to, echoed back. A reader that knows the
window has since changed size can compare against this and discard a result
that arrived late.

### `layout_width`

The widest display line the engine laid the document out at, in display
columns, measured *before* any truncation. It is at most `width` for a document
that fits, and above `width` for one that does not.

This field exists because truncation is otherwise invisible. Diagram artwork
wider than the requested width is truncated rather than wrapped — the right-hand
columns are dropped, and dropped columns are not in `lines`, so no reader can
see them and no amount of scrolling can reach them. Prose, tables, code and
formulas wrap instead, so they never contribute a value above `width`.

The rule is exact: **the engine truncated the document if and only if
`layout_width > width`.** A reader that needs to know whether it is looking at
a whole document — or whether asking for a narrower layout might bring more of
it into view — compares the two rather than measuring the lines itself, which
it cannot do, because the missing columns are exactly what it does not have.

It covers the whole document, not diagrams alone, so a reader does not have to
know which block was truncated to find out that one was. Note that it is a
property of the *document*, not of any one line: a document with one truncated
diagram and a hundred narrow prose lines still reports the diagram's width.

### `styles`

Every distinct style used anywhere in the document, in first-use order. Spans
reference an entry by its index in this array.

| Field | Type | Meaning |
|---|---|---|
| `fg` | string or null | Foreground colour. `null` means the terminal's default. |
| `bg` | string or null | Background colour. `null` means the terminal's default. |
| `bold` | bool | Omitted when false. |
| `dim` | bool | Omitted when false. |
| `italic` | bool | Omitted when false. |
| `underline` | bool | Omitted when false. |
| `strikethrough` | bool | Omitted when false. |
| `reverse` | bool | Omitted when false. |

`fg` and `bg` are always present, because `null` carries meaning. The modifier
flags are omitted when false, because most spans set none of them and the
saving is most of the payload.

A colour is one of three forms:

| Form | Example | Notes |
|---|---|---|
| RGB | `#cba6f7` | Lowercase hex, always six digits. |
| Named | `red`, `lightblue` | The sixteen terminal colour names, lowercase. |
| Indexed | `indexed:5` | A 256-colour palette index. |

The three forms are distinguishable and lossless — no colour is approximated
into RGB. `black` and `indexed:0` mean different things and are emitted
differently.

### `lines`

The display lines, top to bottom. Each has:

| Field | Type | Meaning |
|---|---|---|
| `source` | integer or null | The 0-indexed source line this display line came from. `null` for a line with no source counterpart. |
| `spans` | array of `[int, string]` | The line's styled text, left to right. |
| `links` | array, omitted when empty | Clickable runs of the line: `[start_byte, end_byte, target]`. |

A span is a two-element array — `[style_index, text]` — rather than an object.
Spans are the bulk of the payload and their shape never varies, so field names
would be pure overhead on both the writing and the reading side.

Adjacent spans that resolve to the same style index are already merged, so a
line of uniform styling carries exactly one span. A line with no spans is
empty: it occupies a row and paints nothing.

`links` names the parts of a line a reader can follow. Only rendered diagrams
supply them today: a mermaid `click NODE href "…"` directive names a URL, and
the engine reports the cells of the node's label so the link travels with the
picture rather than being parsed again by the reader. `start` and `end` are
0-based **byte** offsets into the line's text — the concatenated span text —
with `end` exclusive; bytes rather than display columns because that is what an
editor's cursor reports. A target is opened exactly like a markdown link
destination: a scheme is a URL, a leading `#` is an anchor, and anything else is
a path relative to the document holding the diagram.

The field is omitted when a line has no links, so an ordinary document's lines
keep the shape they had before the field existed. When a diagram row is clipped
to the requested width, a link that reached past the cut ends at the line's
edge and one that lay wholly past it is dropped: the columns the reader cannot
see are not clickable.

### `source_map`

One entry per source line of the document: `source_map[n]` is the index into
`lines` of the first display line at or after source line `n`. Its length
equals the document's source line count.

It is emitted rather than left for the reader to derive, so that the mapping
has a single definition and the reader does not have to reimplement a scan.
Every entry is a valid index into `lines`; when nothing is at or after `n` the
entry is clamped to the last display line.

### `animations`

Animated images, present only when the engine was run with `--image-animation`
and the document contains a GIF or an animated WebP whose whole animation fits
the engine's caps. The field is omitted entirely when there is nothing to
animate, so an ordinary render's document has exactly the shape it had before
the field existed.

Each entry has:

| Field | Type | Meaning |
|---|---|---|
| `source` | integer | The 0-indexed source line of the `![…](…)` reference. |
| `start` | integer | The index in `lines` of the animation's first display line. |
| `rows` | integer | How many display lines one frame occupies. |
| `frames` | array | Every frame, in playback order, including the first. |

A frame is `{ "delay": integer, "lines": [[ [style_index, text], … ], … ] }`.
`delay` is milliseconds as the file records it — a GIF's hundredths of a second
are multiplied by ten. Frame lines carry spans only, with no `source`, because
every line of every frame belongs to the reference the entry names. Their style
indices index the document's own `styles`, so a style shared with the first
frame is stored once and a reader that already defined the first frame's groups
needs to define nothing to show a later one.

**The first frame is also in `lines` at `start .. start + rows - 1`, unchanged.**
That is what makes the field additive: a reader that ignores `animations` paints
the still image, and a reader that swaps in frame 0 is redrawing exactly the
rows it was already showing.

The engine caps an animation at 256 frames and 64,000,000 decoded pixels in
total. An image past either bound renders as its first frame with no entry
here at all — the whole animation is present or none of it is, because a partial
one would loop back to a frame that is not the image's first.

### `animations_limited`

Source lines of image references whose animation the caps refused, present only
when there is at least one and omitted otherwise. It exists so a reader can tell
a still image from an animation that was too large: both have no `animations`
entry and both show the first frame, but the latter usually looks like it should
move. Entries are 0-indexed source lines, in document order.

```json
"animations_limited": [4]
```

The entry below is verbatim: rendering `![anim](image_animation.gif)` at width
20 with `--image-animation`, where the fixture is a 4×2 three-frame GIF with
delays of 40, 80 and 120 ms. The document's `lines` holds the first frame
(`{"source": 0, "spans": [[0, "▀▀▀▀"]]}`), and its `styles` holds the three
colours the frames use.

```json
[
  {
    "source": 0,
    "start": 0,
    "rows": 1,
    "frames": [
      { "delay": 40,  "lines": [[[0, "▀▀▀▀"]]] },
      { "delay": 80,  "lines": [[[1, "▀▀▀▀"]]] },
      { "delay": 120, "lines": [[[2, "▀▀▀▀"]]] }
    ]
  }
]
```

## Source anchoring

The two directions are independent and both are exact:

* **Display to source.** `lines[i].source` names the source line the display
  line came from. This is what a reader uses when the cursor is on a display
  line and the user asks for the source.
* **Source to display.** `source_map[n]` names where source line `n` appears.
  This is what a reader uses to put the cursor somewhere sensible when it
  switches back to the rendered view.

`source` is `null` when a display line has no source line of its own. Table
borders are the case that matters: `┌───┬───┐` is artwork produced by the table
as a whole, not by any one row. A reader that needs a source line for a
synthetic display line should use the enclosing construct's — for a table
border, `source_map` on the table's first row, or equivalently the nearest
preceding display line that has a `source`.

Note that a display line's `source` does not have to be unique: several display
lines can share one, which is what happens when a paragraph wraps or a diagram
renders to several rows of artwork. A diagram's artwork is anchored to the
fence line that opened it, so the whole diagram resolves to one source line in
both directions. The consequence for `source_map` is that source lines *inside*
a diagram's body resolve forward to whatever follows the diagram; a reader that
wants the diagram itself for such a line should search backwards for the fence
instead.

## Determinism

Rendering the same document at the same width and theme twice produces
byte-identical output. Styles are interned in first-use order, the line order
is the document's order, and nothing in the pipeline depends on iteration order
of a hash map or on a clock.
