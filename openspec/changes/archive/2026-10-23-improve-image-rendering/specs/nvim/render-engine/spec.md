# Spec Delta

## REMOVED Requirements

### Requirement: Half-block, quadrant and ASCII encodings

**Reason**: Replaced by "Image encodings", which adds the braille encoding and makes it the default.
The three existing encodings keep their behaviour and their `--image-encoding` values.

**Migration**: None for callers: `blocks`, `quads`, `ascii` and `off` are accepted as before. A
caller that relied on the default being half-block now gets braille and must ask for `blocks`.

### Requirement: A fixed style palette

**Reason**: Replaced by "Image palette". Quantising every image to one fixed cube is the largest
single cause of colour error; the palette is now adaptive by default, with the fixed cube kept as
one of the modes.

**Migration**: None for callers: the fixed cube remains available as the `theme` palette mode.

## ADDED Requirements

### Requirement: Image encodings

The engine SHALL support four encodings for image artwork.

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

## MODIFIED Requirements

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
