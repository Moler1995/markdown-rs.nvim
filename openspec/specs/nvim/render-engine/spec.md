# nvim/render-engine Specification

## Purpose
How the engine turns images in a document into character-cell artwork: the encodings, the palette,
scaling to the page, the limits that keep a pathological file from eating the editor, the alt-text
fallback, the determinism the plugin's cache depends on, and the animation frames a caller may ask
for.

## Requirements

### Requirement: Base directory for relative destinations

The engine SHALL accept an optional base directory against which relative image destinations are
resolved. Absolute destinations SHALL be used as given. With no base directory, relative
destinations SHALL resolve against the working directory.

The base directory SHALL NOT change how the document itself is read, and SHALL NOT be required.

#### Scenario: Relative destination with a base directory

- **WHEN** a document containing `![](img/diagram.png)` is rendered with base directory `/docs`
- **THEN** the engine reads `/docs/img/diagram.png`

#### Scenario: Relative destination with no base directory

- **WHEN** that document is rendered from `/work` with no base directory
- **THEN** the engine attempts to read `/work/img/diagram.png`

#### Scenario: Absolute destination

- **WHEN** a document containing `![](/opt/icons/a.png)` is rendered with base directory `/docs`
- **THEN** the engine reads `/opt/icons/a.png`

### Requirement: Images rendered as character-cell artwork

The engine SHALL render an image reference whose destination names a readable image of a supported
format as a block of display lines that reproduces the image with terminal cells. The block SHALL
take the place of the reference in the document, and the alt text SHALL NOT also be emitted as
ordinary text.

A supported format SHALL mean PNG, JPEG, GIF, WebP, BMP, TIFF or ICO. A GIF SHALL be rendered as
its first frame.

The engine SHALL accept a request to produce no artwork, in which case every image reference SHALL
render as its alt text.

An image reference inside a table cell or inside a heading SHALL render as its alt text in place.
Those positions carry inline spans rather than a block, so artwork cannot be inserted without
changing the table's or heading's own layout. This is the only case where a renderable image does
not become artwork.

#### Scenario: A supported image

- **WHEN** a document contains `![overview](diagram.png)` and the file is a readable PNG
- **THEN** the output contains display lines drawn from that image's pixels
- **AND** the text `overview` does not appear as an ordinary paragraph

#### Scenario: An animated GIF

- **WHEN** the referenced file is an animated GIF
- **THEN** the output is a still rendering of its first frame

#### Scenario: Artwork not requested

- **WHEN** a document containing a readable image is rendered with artwork disabled
- **THEN** the reference appears as its alt text
- **AND** no artwork lines are produced

#### Scenario: Several images in one document

- **WHEN** a document contains two supported images
- **THEN** each is rendered, in document order, at its own position in the output

#### Scenario: An image inside a paragraph

- **WHEN** a paragraph contains text before and after an image reference
- **THEN** the artwork occupies its own display lines

#### Scenario: An image inside a table cell or heading

- **WHEN** an image reference appears inside a table cell or a heading
- **THEN** the cell or heading contains the reference's alt text
- **AND** no artwork lines are produced for it
- **AND** the text before and after it appears on lines around the artwork, in order

### Requirement: Image encodings

The engine SHALL support five encodings for image artwork.

In the **braille** encoding each cell SHALL be drawn as one character in U+2800 through U+28FF,
whose eight dots form a grid of two sub-cells across and four down. The dots SHALL be ink on the
page the artwork sits on: a dot SHALL be lit where its sub-cell lies away from that page — lighter
than a dark page, darker than a light page — and the share of lit dots SHALL follow how far the
sub-cell is from the page, so tone is carried by dot density rather than by brightness. A dot SHALL
NOT be lit for a sub-cell that matches the page, and a transparent sub-cell SHALL never be lit. The
page SHALL be the resolved background when the caller named one, and otherwise the page colour the
caller reports, falling back to the theme's background. The cell SHALL use one foreground colour,
which SHALL be the colour of the lit sub-cells, and SHALL emit no background colour, leaving the
rest of the cell to the terminal.

In the **half-block** encoding each cell SHALL be drawn as U+2580, with the upper pixel as the
cell's foreground color and the lower pixel as its background color.

In the **quadrant** encoding a cell SHALL be sampled as four sub-cells, two across and two down,
and SHALL be drawn with the block-element character whose ink covers exactly those sub-cells that
share one of the cell's two colors, that color being the foreground and the other the background.
A cell whose four sub-cells have one color SHALL be drawn as U+2588 in one color. The quadrant
encoding SHALL therefore sample twice as many sub-cells across as the half-block encoding does at
the same width, and SHALL emit only characters from the block-element range U+2580 through U+259F.

In the **ASCII** encoding each cell SHALL be a character from a fixed luminance ramp, and the
encoding SHALL emit no character outside the ASCII range.

In the **card** encoding no pixel of the picture SHALL be drawn as a glyph. Unless the caller
gives it a shape of its own, the block SHALL occupy the same cell box the artwork would occupy at
the same bounds and the same picture, so that a document laid out with the card and one laid out
with braille hold the same rows and the same source lines. The box SHALL be filled with the
theme's raised surface colour as the background, and one row of it — the middle one — SHALL carry
a caption in a muted foreground: the resolved file's name, followed by ` · <width>×<height>` when
the picture's header reports its size. The caption SHALL be centred in the box and truncated to
the box's width. A box with no room for a cell SHALL fall back as an unrenderable image does.

A caller MAY give the card a shape of its own. A requested height SHALL fix the card's display
rows, clamped to the page's height when one is given and never below one row. A requested minimum
width SHALL raise the card's columns to at least that many, capped at the page width. The picture's
own columns are kept unless a minimum width raises them, and the card's source attribution is
unchanged either way.

A caller MAY refuse the caption, for a card the terminal paints the picture over. A caption-less
card SHALL be the surface alone on every row, with the same rows, columns, colours and source
attribution the caption would have had: the picture is measured for that box, and a picture may be
transparent, so a caption under it would read as letters inside the picture.

The engine SHALL use the braille encoding unless the caller asks for another encoding.

#### Scenario: Default encoding

- **WHEN** an image is rendered with no encoding requested
- **THEN** every character emitted for the artwork is in U+2800–U+28FF
- **AND** the artwork uses one foreground colour per cell

#### Scenario: Braille sub-cell grid

- **WHEN** a cell is drawn on a light page and is darker in its upper-left sub-cell and uniform
  elsewhere
- **THEN** the emitted character is U+2801, the braille pattern for a single dot in the upper left

#### Scenario: Braille on a dark page

- **WHEN** a cell is drawn on a dark page and is lighter than that page
- **THEN** the lit dots are the light sub-cells, and the cell's foreground colour is light

#### Scenario: A light screenshot on a dark page

- **WHEN** a mostly white image with dark features is drawn on a dark page
- **THEN** the white area carries the dots and the dark features are left as gaps, so the picture is
  drawn in the light of its own page rather than in its shadows

#### Scenario: Braille tone

- **WHEN** a cell is a mid grey between the page and the far end of the range
- **THEN** some of its dots are lit and some are not, so consecutive tonal steps differ in dot
  count

#### Scenario: A fully transparent cell in braille

- **WHEN** every sub-cell of a cell is transparent
- **THEN** the cell is emitted as U+2800, or as an unstyled space, and carries no colour

#### Scenario: Quadrant encoding

- **WHEN** an image is rendered with the quadrant encoding requested
- **THEN** every character emitted for the artwork is in U+2580–U+259F
- **AND** a cell split top to bottom is U+2580 and a cell split left to right is U+258C

#### Scenario: ASCII encoding

- **WHEN** an image is rendered with the ASCII encoding requested
- **THEN** every character emitted for the artwork is ASCII
- **AND** darker regions use denser characters than lighter ones

#### Scenario: A single-color region

- **WHEN** the image contains a region of one uniform color
- **THEN** it is drawn with that color rather than a luminance approximation of it

#### Scenario: Card encoding

- **WHEN** an image is rendered with the card encoding requested and no shape of its own
- **THEN** the block occupies the same number of display rows and columns as the braille encoding
  of the same image at the same width and page height
- **AND** every one of its display lines is attributed to the reference's source line
- **AND** the box carries the theme's raised surface as its background
- **AND** no glyph of the box is a picture detail

#### Scenario: A card with a shape of its own

- **WHEN** an image is rendered with the card encoding, a height of three rows and a minimum width
- **THEN** the block is three display rows tall
- **AND** its columns are the picture's own, raised to the minimum width when that is wider
- **AND** every one of those rows is attributed to the reference's source line
- **AND** a page narrower than the minimum width, or shorter than the requested height, gives the
  card the page's width or height instead, never fewer than one row

#### Scenario: Card caption

- **WHEN** a card is drawn for `images/map.png`, a 800 × 600 file
- **THEN** the middle row of the box reads `map.png · 800×600`, centred and in a muted foreground

#### Scenario: Card caption without a readable header

- **WHEN** a card is drawn for a file whose header cannot be read
- **THEN** the caption names the file and reports no size

#### Scenario: Card caption refused

- **WHEN** an image is rendered with the card encoding and its caption refused
- **THEN** every row of the box is the raised surface alone, with no text and no foreground colour
- **AND** the box's rows, columns and source attribution are those the caption would have had

### Requirement: Image palette

The engine SHALL draw image colours from a palette chosen by the caller. It SHALL support three
palette modes:

- **theme**: one fixed palette of at most 64 colours, the same palette for every image and every
  document.
- **adaptive**: a palette of at most 64 colours derived from the image itself, so two images with
  unrelated colour schemes may use different palettes. The derivation SHALL be deterministic: the
  same image rendered at the same bounds SHALL yield the same palette.
- **full**: the sampled colour itself, without palette quantisation, so any colour the image
  contains may appear.

The mode SHALL be chosen by the caller. The engine's command line SHALL default to **theme**, so a
caller that does not know the option keeps the output it had before, and the editor plugin SHALL
request a mode explicitly on every render.

An image SHALL NOT introduce more than 4,096 distinct styles in one document. Under the **full**
mode, once a document has reached that bound, further colours SHALL be quantised to the image's
adaptive palette instead, so the bound holds without changing the colours already emitted.

A cell whose colours are the same SHALL use one colour, and adjacent cells with the same style
SHALL be merged into one span.

#### Scenario: Two unrelated images with adaptive palettes

- **WHEN** a document renders a mostly blue image and a mostly orange image with the adaptive palette
- **THEN** each image's artwork uses colours taken from its own image

#### Scenario: The same image twice

- **WHEN** the same image is rendered twice at the same bounds
- **THEN** both renders choose the same palette and produce byte-identical artwork

#### Scenario: The fixed palette

- **WHEN** the theme palette is requested for two images with unrelated colour schemes
- **THEN** the colours used by both are drawn from the same 64-colour palette

#### Scenario: Full colour

- **WHEN** an image is rendered with the full palette
- **THEN** a cell's colour is the image's own sampled colour rather than a palette entry
- **AND** a photograph shows colours the 64-colour palette cannot express

#### Scenario: A document over the style bound

- **WHEN** the images in a document would together produce more than 4,096 distinct styles under the
  full palette
- **THEN** the document contains no more than 4,096 distinct image styles
- **AND** the colours already emitted are not changed

### Requirement: Scaling and page bounds

Image artwork SHALL be scaled with an area average to fit the requested width and, when a maximum
height is given, that height as well. Both bounds SHALL apply together, preserving the image's
aspect ratio, so an image too wide and too tall is reduced until it fits whichever bound binds
first. Cell height SHALL count as two cell widths in that calculation.

The area average SHALL be taken in linear light, so that a downscaled image keeps the brightness and
contrast it had at full size rather than darkening.

An image smaller than both bounds SHALL NOT be enlarged, except that a caller MAY request a minimum
height in display rows. When one is requested and the image's natural height is below it, the image
SHALL be enlarged by the smallest whole factor — at most four — that reaches the minimum, using
nearest-neighbour sampling. Enlargement SHALL NOT make the artwork wider or taller than the bounds.

A caller MAY request sharpening. When it is requested and an image is reduced, the area average
SHALL be followed by an unsharp mask before quantisation.

Every display line of the artwork SHALL fit within the requested width, and the artwork SHALL
consist of no more than the maximum height's display rows when one is given. With no maximum height
the artwork's height SHALL follow the aspect ratio alone.

A sub-cell's alpha SHALL be averaged with its colour rather than thresholded. A fully transparent
cell SHALL be drawn as a space with no styling. In the half-block encoding a cell with one
transparent half SHALL draw the visible half's colour and leave the other half to the terminal's
background. A partly transparent quadrant cell SHALL be drawn in one colour, whose glyph covers the
visible sub-cells only, so the transparent sub-cells are left to the terminal. In the ASCII
encoding the ramp's lightest end SHALL be a space, so a transparent pixel produces no ink.

A caller MAY name a background colour, being the terminal's own (the default), the theme's
background, or an explicit colour. Where one is named, partially transparent pixels SHALL be
composited against it before quantisation, so an image with soft edges blends into that background
instead of being cut off at a threshold. Where the terminal's own background is named, no
compositing SHALL occur.

A caller MAY request ordered dithering. When it is requested, quantisation SHALL use a fixed
ordered pattern, so a gradient rendered from a reduced palette varies continuously rather than in
bands. The pattern SHALL be the same on every run.

If the bounds leave no room for a single cell, the reference SHALL fall back to its alt text.

#### Scenario: An image wider than the requested width

- **WHEN** a 1200-pixel-wide image is rendered at width 80
- **THEN** no artwork display line is wider than 80 columns
- **AND** the artwork's height reflects the image's aspect ratio, not the cell grid's

#### Scenario: An image narrower than the requested width

- **WHEN** a 16-pixel-wide image is rendered at width 80 in the half-block encoding
- **THEN** the artwork is 16 columns wide

#### Scenario: An image taller than the page

- **WHEN** a 400-by-2000-pixel image is rendered at width 80 with a maximum height of 40
- **THEN** the artwork is at most 40 display rows tall
- **AND** no display line is wider than 80 columns
- **AND** the artwork's aspect ratio is preserved

#### Scenario: The page is the binding bound

- **WHEN** a wide image is rendered at width 80 with a maximum height of 10
- **THEN** the artwork is at most 10 rows tall and correspondingly narrower than 80 columns

#### Scenario: A short image on a tall page

- **WHEN** an image is rendered with a maximum height much larger than its natural height
- **AND** no minimum height is requested
- **THEN** the artwork keeps its natural height

#### Scenario: A minimum height

- **WHEN** a 16×16 image is rendered in a window with room for 40 rows and a minimum height of 12
- **THEN** the artwork is at least 12 rows tall and continues to fit the width bound

#### Scenario: A transparent image

- **WHEN** every pixel of the image is transparent
- **THEN** the artwork consists of spaces

#### Scenario: A transparent half

- **WHEN** one half of a cell is opaque and the other is transparent
- **THEN** that half is drawn with the opaque colour
- **AND** the other half is left to the terminal's background

#### Scenario: A named background

- **WHEN** an image with a soft transparent edge is rendered against a named background colour
- **THEN** pixels that were partly transparent are blended with that colour
- **AND** the artwork shows no hard edge where the alpha crossed any threshold

#### Scenario: No room for a cell

- **WHEN** the bounds leave no room for even one cell of artwork
- **THEN** the reference appears as its alt text

### Requirement: Decoding limits

The engine SHALL refuse to decode an image file larger than 16 MiB, or an image whose pixel count
exceeds 16 megapixels, and SHALL treat it as unrenderable. The file-size limit SHALL be enforced
before the file is read, and the pixel limit before the pixels are decoded. These limits bound
decoded pixels: under the card encoding the picture's header MAY be read to learn its size, and
the box it occupies SHALL be computed from that size, whatever the file's length.

#### Scenario: Oversized file

- **WHEN** a referenced file is larger than 16 MiB
- **THEN** the image is not decoded
- **AND** the reference falls back as described below

#### Scenario: Oversized dimensions

- **WHEN** a referenced image declares more than 16 megapixels
- **THEN** the image is not decoded
- **AND** the reference falls back as described below

#### Scenario: An oversized image under the card encoding

- **WHEN** a 24-megapixel picture is rendered with the card encoding requested
- **THEN** its pixels are not decoded
- **AND** the reference is still drawn as a card sized from its header's dimensions

### Requirement: Unrenderable images fall back to alt text

When an image reference cannot be rendered — the file is missing or unreadable, the format is
unsupported, or the destination is not a local file — the engine SHALL render the reference's alt
text in its place and SHALL still emit the rest of the document successfully. An image reference
with no alt text SHALL render as no display lines.

A reference whose pixels exceed a decoding limit SHALL render as alt text under every encoding but
the card, where it renders as a card carrying the size its header reports.

A reference that is not a local file SHALL include an `http` or `https` URL and a `data:` URI.

#### Scenario: Missing file

- **WHEN** a document references a file that does not exist
- **THEN** the engine exits zero
- **AND** the document's other content is rendered normally
- **AND** the reference appears as its alt text

#### Scenario: Unsupported format

- **WHEN** a document references a readable SVG file
- **THEN** the reference appears as its alt text

#### Scenario: Remote destination

- **WHEN** a document references `https://example.com/a.png`
- **THEN** the engine does not fetch it
- **AND** the reference appears as its alt text

#### Scenario: No alt text

- **WHEN** an unrenderable reference has empty alt text
- **THEN** it contributes no display line

#### Scenario: An oversized image with alt text

- **WHEN** a 24-megapixel image with alt text `a map` is rendered with the braille encoding
- **THEN** the reference appears as `a map`

### Requirement: Image thumbnail output

The engine SHALL offer a thumbnail mode that writes one downscaled copy of a picture for a
requested cell box: a source path, a box of columns by rows, an output path, and a background
colour. This is the file a terminal paints over an inline image, and the engine is the only stage
with a decoder.

A request MAY also name a crop: a top row and a count of rows inside the box. With one, the engine
SHALL fit and centre the picture in the whole box first and cut those rows from that drawing, so
the output is the same picture at the same scale as the whole box, describing the part of the
block a window shows. A crop that is not inside the box — no rows at all, or rows past its last —
SHALL be refused like any other bad request.

The output SHALL be a single encoded picture whose pixel width to height ratio is the box's
columns to twice its rows, so that a terminal filling the box with it reproduces the picture's
proportions. The picture SHALL be scaled to fit inside that rectangle without distortion, centred,
and the remainder SHALL be filled with the requested background. The output SHALL be PNG when the
picture has transparency and JPEG otherwise, unless the request names a format: `png` SHALL be
written as PNG whatever the picture's transparency, and `jpeg` as JPEG, with any transparency
composited over the requested background because the format has no alpha channel. The thumbnail
mode SHALL NOT write to standard output, and its output SHALL be byte-identical for the same
picture, box, background and format.

The mode SHALL refuse a missing or unreadable file, an unsupported format, a box with no room for
a cell, and an output path it cannot write, each with a non-zero exit and a diagnostic on standard
error. It SHALL bound the pixels it produces, so that the file it writes stays small whatever the
picture's own size — subject to the same decoding limits as every other image.

#### Scenario: A thumbnail for a box

- **WHEN** a 3200 × 2400 picture is asked for as a thumbnail in a 40 × 12 cell box
- **THEN** the file written has a width to height ratio of 40 to 24
- **AND** it decodes to fewer pixels than the original
- **AND** its size on disk is a small fraction of the original's

#### Scenario: A crop of a box

- **WHEN** a picture is asked for in a 40 × 12 box, and again in that box cropped to its rows 3
  to 7
- **THEN** the second output is five twelfths the height of the first
- **AND** its pixels are the first output's rows 3 to 7, at the same scale
- **AND** a crop past the box's last row is refused, naming the crop

#### Scenario: Determinism

- **WHEN** the same picture is asked for twice with the same box and background
- **THEN** the two files are byte-identical

#### Scenario: Format follows transparency

- **WHEN** a picture with transparent pixels and one without are each asked for as a thumbnail
- **THEN** the first is written as PNG and the second as JPEG

#### Scenario: A format the caller names

- **WHEN** an opaque picture is asked for with `--format png`
- **THEN** the file written is a PNG
- **AND** a transparent picture asked for with `--format jpeg` is a JPEG whose transparent pixels
  take the requested background colour
- **AND** a format the engine does not encode is refused, naming the option

#### Scenario: A picture that cannot be read

- **WHEN** the thumbnail mode is asked for a missing file
- **THEN** it exits non-zero
- **AND** writes nothing to standard output
- **AND** names the file on standard error

### Requirement: Image blocks obey width, anchoring and determinism

Image artwork SHALL obey the guarantees already made for every other block: every display line fits
the requested width, every display line is attributed to the source line holding the image
reference, the reverse mapping for that source line resolves to the artwork's first display line,
and rendering the same document at the same width, theme and encoding produces byte-identical
output.

#### Scenario: Source mapping

- **WHEN** an image spanning several display lines is rendered from source line N
- **THEN** its display lines are attributed to N or marked synthetic
- **AND** the reverse mapping for source line N is the artwork's first display line

#### Scenario: Repeated rendering

- **WHEN** a document with an image is rendered twice at the same width and encoding
- **THEN** the two outputs are byte-identical

#### Scenario: An image in a narrow document

- **WHEN** the requested width is narrower than the smallest useful rendering
- **THEN** the artwork is scaled down rather than allowed to exceed the width

### Requirement: Animation frames on request

The engine SHALL accept an explicit request to emit animation frames. For an animated GIF or an
animated WebP image, when that request is made, the document SHALL carry, in addition to the
artwork lines that show the first frame, the range of display lines the artwork occupies and, for
every frame, its delay in milliseconds and its display lines.

The document's own display lines SHALL remain the first frame, so a reader that ignores the
additional data sees exactly the document it saw before. Without the request, the engine SHALL emit
no animation data for any image.

Animation data SHALL be bounded: at most 256 frames, and frames SHALL stop being emitted once the
total decoded pixel count of the frames exceeds 64 megapixels. An image that exceeds either bound
SHALL render as its first frame with no animation data at all.

A refused animation SHALL be distinguishable from a still image: the document SHALL name the source
line of each reference whose animation the bounds refused, and SHALL omit that list when nothing was
refused.

Every frame SHALL obey the width bound, height bound and encoding of the document, and SHALL occupy
exactly as many display lines as the first frame.

Formats other than GIF and WebP SHALL carry no animation data even when it is requested, and an
animated image of either format whose file cannot be decoded SHALL fall back as any other
unrenderable image does.

#### Scenario: Animated GIF with frames requested

- **WHEN** a document references an animated GIF and animation frames are requested
- **THEN** its display lines show the first frame
- **AND** the document carries that frame's line range and every emitted frame's delay and lines

#### Scenario: Animated WebP with frames requested

- **WHEN** a document references an animated WebP and animation frames are requested
- **THEN** the document carries its frames, on the same terms as a GIF

#### Scenario: Frames not requested

- **WHEN** a document containing an animated GIF is rendered without the request
- **THEN** the output is identical to the output of the same document before animation existed
- **AND** no animation data is present

#### Scenario: A still image

- **WHEN** a document references a PNG or JPEG and animation frames are requested
- **THEN** the image is drawn as before
- **AND** no animation data is present

#### Scenario: An animation over the bounds

- **WHEN** an animated image has more frames or more total pixels than the bounds allow
- **THEN** it is drawn as its first frame
- **AND** no animation data is present
- **AND** its source line is listed as a refused animation

#### Scenario: Every frame respects the page

- **WHEN** frames are emitted for an image
- **THEN** no line of any frame is wider than the requested width
- **AND** every frame occupies the same number of display lines as the first frame

#### Scenario: Repeated rendering

- **WHEN** a document with an animated image is rendered twice with frames requested
- **THEN** the two outputs are byte-identical

### Requirement: Rendering input

The engine SHALL accept a markdown document supplied either as a file path or on standard input, a
display width in terminal columns, and a theme or palette selection. The width SHALL be explicit:
the engine SHALL NOT substitute a default, because wrapping decisions cannot be undone by the
caller once made.

#### Scenario: Document read from a file path

- **WHEN** the engine is invoked with a path to an existing markdown file
- **THEN** it renders that file's contents

#### Scenario: Document read from standard input

- **WHEN** the engine is invoked with no file path and markdown is piped to standard input
- **THEN** it renders the piped contents

#### Scenario: Width omitted

- **WHEN** the engine is invoked without a display width
- **THEN** it exits non-zero with a diagnostic on standard error
- **AND** writes nothing to standard output

### Requirement: Width-bounded display lines

Every display line the engine emits SHALL fit within the requested width. This SHALL hold for
prose, fenced code, tables, diagrams and formulas alike.

#### Scenario: Paragraph wider than the window

- **WHEN** a paragraph wider than the requested width is rendered
- **THEN** it is broken across multiple display lines
- **AND** no display line is wider than the requested width

#### Scenario: Code line wider than the window

- **WHEN** a fenced code block contains a line wider than the requested width
- **THEN** that line is broken across multiple display lines rather than emitted whole

#### Scenario: Diagram that does not fit

- **WHEN** a mermaid diagram cannot be laid out within the requested width
- **THEN** the engine still emits display lines that fit the requested width

### Requirement: Styled spans

Each display line SHALL be emitted as an ordered sequence of spans, and each span SHALL carry its
text together with the complete visual style that applies to it, expressed as colors the caller can
apply directly without consulting the source document.

#### Scenario: Syntax-highlighted code block

- **WHEN** a fenced code block with a recognized language is rendered
- **THEN** the spans covering that block carry per-token colors rather than one uniform color

#### Scenario: Consecutive characters sharing a style

- **WHEN** consecutive characters on a display line carry the same style
- **THEN** they are merged into a single span

#### Scenario: Heading emphasis

- **WHEN** a heading is rendered
- **THEN** its display line carries the heading's own color and weight, distinct from body text

### Requirement: Source anchoring

Every display line SHALL be reported together with the source line it was derived from. Display
lines with no source counterpart — table borders, diagram artwork, blank spacers — SHALL be marked
synthetic rather than attributed to an arbitrary source line. The engine SHALL also emit the
reverse mapping, from source line to display line, so a caller can place a cursor given a source
position.

#### Scenario: Source line wrapped across several display lines

- **WHEN** one source line is wrapped across several display lines
- **THEN** all of those display lines report that same source line

#### Scenario: Diagram occupying several source lines

- **WHEN** a mermaid block is rendered as text art
- **THEN** the artwork's display lines are marked synthetic or attributed to the block's opening
  fence line
- **AND** the reverse mapping for every source line in the block resolves to the first display line
  of the artwork

#### Scenario: Reverse mapping covers the whole document

- **WHEN** the caller looks up the display line for any source line of the document
- **THEN** it receives a display line index within the emitted range

### Requirement: Deterministic output

Rendering the same document at the same width with the same theme SHALL produce byte-identical
output.

#### Scenario: Repeated invocation

- **WHEN** the same document is rendered twice at the same width and theme
- **THEN** the two outputs are byte-identical

### Requirement: Failure reporting

When the engine cannot render — unreadable input, malformed arguments, an internal render error —
it SHALL exit non-zero with a diagnostic on standard error and SHALL NOT emit a partial document on
standard output.

#### Scenario: Input path does not exist

- **WHEN** the engine is given a path that does not exist
- **THEN** it exits non-zero with a diagnostic on standard error
- **AND** standard output is empty

#### Scenario: Document fails to render

- **WHEN** rendering aborts partway through a document
- **THEN** the engine exits non-zero
- **AND** standard output contains no truncated document that a caller could mistake for complete

### Requirement: A label is wrapped to the space it occupies

Where the engine arranges a diagram to fit a requested width, a message label SHALL be wrapped to
the width available to it in the arrangement the engine emits, not to a target derived from the
diagram's overall width. A label that has room for two display rows SHALL NOT be broken across six.

Wrapping a label to the space available to it SHALL NOT widen the arrangement: the width the
engine reports for it SHALL be no greater than the width it would report had the label been wrapped
to the diagram-wide target.

#### Scenario: A label in a space wider than the wrap target

- **WHEN** a sequence diagram is arranged to fit a requested width, and a message label's space in
  the emitted arrangement is wider than the wrap target the arrangement used
- **THEN** that label is wrapped to the space it occupies
- **AND** it occupies no more display rows than that space requires

#### Scenario: The arrangement does not widen

- **WHEN** a sequence diagram is arranged to fit a requested width
- **THEN** the layout width the engine reports for it is no greater than the width of the same
  arrangement with every message label wrapped to the diagram-wide target

#### Scenario: No content is lost

- **WHEN** a sequence diagram is arranged to fit a requested width
- **THEN** every participant, message, note and block frame present at the natural width is still
  present in the output
- **AND** no label's text is shortened, abbreviated or truncated to make it fit

### Requirement: Among arrangements that fit, the shortest is emitted

Where more than one arrangement of a diagram fits the requested width, the engine SHALL emit one
with the fewest display rows. Where more than one arrangement has the same number of display rows,
the choice among them SHALL be the same on every run.

#### Scenario: A width with several fitting arrangements

- **WHEN** a diagram has more than one arrangement whose widest display line is within the
  requested width
- **THEN** the emitted arrangement has no more display rows than any of the others

#### Scenario: No arrangement fits

- **WHEN** no arrangement of a diagram fits the requested width
- **THEN** the engine emits the narrowest arrangement it can reach
- **AND** it reports a layout width above the requested width

#### Scenario: The natural arrangement fits

- **WHEN** a diagram's natural arrangement is within the requested width
- **THEN** the engine emits that arrangement, with no wrapping applied

#### Scenario: Repeated rendering

- **WHEN** a diagram with several fitting arrangements is rendered twice at the same width
- **THEN** both runs emit byte-identical output

### Requirement: Diagrams are laid out to fit rather than clipped

Where the engine can arrange a mermaid diagram to fit within the requested width, it SHALL arrange
it to fit, and SHALL NOT discard any of the diagram's content to do so. Discarding columns SHALL
be a last resort, taken only for a diagram that cannot be arranged to fit at all. Arranging a
diagram to fit MAY make it taller.

A diagram SHALL NOT be arranged to fit when no width is requested, and SHALL NOT be arranged to
fit when it already fits the requested width, so that a diagram's layout depends only on its
source and the requested width.

#### Scenario: A sequence diagram wider than the requested width

- **WHEN** a sequence diagram whose natural width exceeds the requested width is rendered
- **THEN** every emitted display line fits the requested width
- **AND** every participant, message label, note and block frame present at the natural width is
  still present in the output

#### Scenario: A sequence diagram that already fits the requested width

- **WHEN** a sequence diagram whose natural width is within the requested width is rendered
- **THEN** its layout is the same as it would be with no width requested

#### Scenario: A flowchart that can be arranged to fit

- **WHEN** a flowchart whose natural width exceeds the requested width can be arranged within it
- **THEN** every emitted display line fits the requested width
- **AND** no node or edge label is dropped from the output

#### Scenario: A diagram that cannot be arranged to fit

- **WHEN** no arrangement of a diagram fits within the requested width
- **THEN** the engine still emits display lines that fit the requested width
- **AND** the width it reports for the layout exceeds the requested width

#### Scenario: A diagram rendered with no width

- **WHEN** a diagram is rendered with no width requested
- **THEN** it is laid out at its natural width, unarranged

### Requirement: Reported layout width

The engine SHALL report, for each document it emits, the width of the widest display line it laid
the document out at, measured in display columns and taken before any truncation. A caller SHALL
be able to determine from that value alone whether the engine discarded anything: truncation
occurred exactly when the reported layout width exceeds the requested width.

The reported layout width SHALL cover the whole document, not diagrams alone, so that a caller
does not need to know which block was truncated to find out that one was.

#### Scenario: A document that fits

- **WHEN** a document is rendered whose every display line fits the requested width
- **THEN** the reported layout width is the width of its widest display line
- **AND** it does not exceed the requested width

#### Scenario: A document that is truncated

- **WHEN** a display line is truncated to meet the requested width
- **THEN** the reported layout width exceeds the requested width
- **AND** the widest emitted display line does not exceed the requested width

#### Scenario: A document whose widest line is not a diagram

- **WHEN** the widest line the engine laid out comes from prose, a table, code or a formula
- **THEN** the reported layout width reflects that line

#### Scenario: Rendering the same document twice

- **WHEN** the same document is rendered twice at the same width and theme
- **THEN** both runs report the same layout width
