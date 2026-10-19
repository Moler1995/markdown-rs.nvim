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

A span is a two-element array — `[style_index, text]` — rather than an object.
Spans are the bulk of the payload and their shape never varies, so field names
would be pure overhead on both the writing and the reading side.

Adjacent spans that resolve to the same style index are already merged, so a
line of uniform styling carries exactly one span. A line with no spans is
empty: it occupies a row and paints nothing.

### `source_map`

One entry per source line of the document: `source_map[n]` is the index into
`lines` of the first display line at or after source line `n`. Its length
equals the document's source line count.

It is emitted rather than left for the reader to derive, so that the mapping
has a single definition and the reader does not have to reimplement a scan.
Every entry is a valid index into `lines`; when nothing is at or after `n` the
entry is clamped to the last display line.

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
