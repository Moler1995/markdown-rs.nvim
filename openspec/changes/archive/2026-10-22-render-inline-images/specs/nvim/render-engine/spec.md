# Spec Delta

## ADDED Requirements

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

### Requirement: Half-block, quadrant and ASCII encodings

The engine SHALL support three encodings for image artwork.

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

The engine SHALL use the half-block encoding unless the caller asks for another encoding.

#### Scenario: Default encoding

- **WHEN** an image is rendered with no encoding requested
- **THEN** its cells are U+2580 with distinct foreground and background colors

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

### Requirement: A fixed style palette

In the half-block and quadrant encodings the engine SHALL draw every colour from a single fixed
palette of at most 64 colours, the same palette for every image and every document. It SHALL NOT
choose colours per image.

A cell whose colours are the same SHALL use one colour, and adjacent cells with the same style
SHALL be merged into one span. A cell taken from the palette as a pair of colours therefore draws
at most 64 × 64 = 4,096 distinct styles in a session.

#### Scenario: Two unrelated images

- **WHEN** a document renders two images with unrelated colour schemes
- **THEN** the colours used by both are drawn from the same 64-colour palette

#### Scenario: A smooth gradient

- **WHEN** the image contains a smooth gradient
- **THEN** its artwork uses no more than 64 distinct colours

### Requirement: Scaling and page bounds

Image artwork SHALL be scaled with an area average to fit the requested width and, when a maximum
height is given, that height as well. Both bounds SHALL apply together, preserving the image's
aspect ratio, so an image too wide and too tall is reduced until it fits whichever bound binds
first. Cell height SHALL count as two cell widths in that calculation.

An image smaller than both bounds SHALL NOT be enlarged.

Every display line of the artwork SHALL fit within the requested width, and the artwork SHALL
consist of no more than the maximum height's display rows when one is given. With no maximum height
the artwork's height SHALL follow the aspect ratio alone.

Fully transparent cells SHALL be drawn as spaces with no styling. In the half-block encoding a cell
with one transparent half SHALL draw the visible half's colour and leave the other half to the
terminal's background. A partly transparent quadrant cell SHALL be drawn in one colour, whose
glyph covers the visible sub-cells only, so the transparent sub-cells are left to the terminal.
In the ASCII encoding the ramp's lightest end SHALL be a space, so a transparent pixel produces no
ink.

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
- **THEN** the artwork keeps its natural height

#### Scenario: A transparent image

- **WHEN** every pixel of the image is transparent
- **THEN** the artwork consists of spaces

#### Scenario: A transparent half

- **WHEN** one half of a cell is opaque and the other is transparent
- **THEN** that half is drawn with the opaque colour
- **AND** the other half is left to the terminal's background

#### Scenario: No room for a cell

- **WHEN** the bounds leave no room for even one cell of artwork
- **THEN** the reference appears as its alt text

### Requirement: Decoding limits

The engine SHALL refuse to decode an image file larger than 16 MiB, or an image whose pixel count
exceeds 16 megapixels, and SHALL treat it as unrenderable. The file-size limit SHALL be enforced
before the file is read, and the pixel limit before the pixels are decoded.

#### Scenario: Oversized file

- **WHEN** a referenced file is larger than 16 MiB
- **THEN** the image is not decoded
- **AND** the reference falls back as described below

#### Scenario: Oversized dimensions

- **WHEN** a referenced image declares more than 16 megapixels
- **THEN** the image is not decoded
- **AND** the reference falls back as described below

### Requirement: Unrenderable images fall back to alt text

When an image reference cannot be rendered — the file is missing or unreadable, the format is
unsupported, a decoding limit is exceeded, or the destination is not a local file — the engine
SHALL render the reference's alt text in its place and SHALL still emit the rest of the document
successfully. An image reference with no alt text SHALL render as no display lines.

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
