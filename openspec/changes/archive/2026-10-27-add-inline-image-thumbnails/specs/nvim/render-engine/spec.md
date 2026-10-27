# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
