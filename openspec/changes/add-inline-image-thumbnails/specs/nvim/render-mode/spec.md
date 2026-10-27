# Spec Delta

## ADDED Requirements

### Requirement: Inline image presentation

The plugin SHALL expose an `image_inline` option with the values `auto` (the default), `card` and
`art`. It chooses what R shows for an inline image, and SHALL NOT change what the block preview's
popup shows.

- `art` SHALL leave the inline image to `image_mode`, exactly as before this option existed.
- `card` SHALL ask the engine for the card encoding whenever `image_mode` would draw artwork, so
  an inline image is a labelled box whatever the terminal can do, and nothing is ever placed over
  it.
- `auto` SHALL ask for the same card as `card`, and SHALL additionally place the picture over it
  when the terminal's graphics can be used for the buffer on screen now — the conditions the
  preview already applies: an editor with the raw-bytes API, an attached UI, `graphics` not
  `'off'`, an identified terminal, and no multiplexer. Where those conditions do not hold the card
  remains, and it remains the whole of the image.
- Under `auto` and `card`, `image_mode = 'off'` SHALL keep its alt text: a reader who asked for no
  picture inline gets no card and nothing placed over the reference.

The choice SHALL be made for every render, so a window opened after the terminal was identified
gets it, and it SHALL NOT alter any line of the document outside the picture: every row of a card
is attributed to the reference's source line, and every key behaves there as it does on artwork.

A card that nothing is placed over SHALL be three display rows tall, whatever the picture's shape,
so every image in a document takes the same number of rows; a page with fewer rows than that gives
the card the page's height instead. Its width SHALL be the width the artwork's box would have had,
raised to fit the hint below, and SHALL never exceed the page width. A card that the terminal paints a picture over SHALL take
the artwork's box exactly, columns and rows, so the placement covers all of it.

A card or an alt text SHALL carry a hint that names the keys which open the picture, built from
whichever of `keymaps.preview` and `keymaps.open_image` are bound, because neither says by itself
that a key opens the picture. The hint SHALL be text, drawn as virtual text on the card's last
display row, a column in from the card's right edge, or after the last displayed row of the alt
text, and SHALL NOT be drawn over the artwork or over a card the terminal paints a picture over.
It SHALL NOT change the line's own bytes. With both keys bound to `false` there SHALL be no hint.

#### Scenario: Auto with a terminal that can draw

- **WHEN** the editor runs in a terminal the plugin can draw in and a document with an image is
  rendered in R
- **THEN** the image's block is a card
- **AND** the block's row count and the document's source mapping are those the artwork would
  have produced
- **AND** the picture of the file is placed over it

#### Scenario: Auto without graphics

- **WHEN** `graphics = 'off'`, or the terminal is not one the plugin can identify, or a
  multiplexer is in the way, and `image_inline = 'auto'`
- **THEN** the image's block is a card
- **AND** that card is three rows tall
- **AND** nothing is placed over it

#### Scenario: Auto with image drawing switched off

- **WHEN** `image_inline = 'auto'`, `image_mode = 'off'` and the terminal can draw
- **THEN** the image's block is its alt text, as `image_mode = 'off'` produces
- **AND** nothing is placed over it

#### Scenario: Card forced on a drawing terminal

- **WHEN** `image_inline = 'card'` and the terminal can draw
- **THEN** the image's block is a card
- **AND** that card is three rows tall, since nothing is placed over it

#### Scenario: Card forced without graphics

- **WHEN** `image_inline = 'card'` and the terminal cannot draw
- **THEN** the image's block is a card
- **AND** that card is three rows tall
- **AND** nothing is placed over it

#### Scenario: Every image takes the same number of rows

- **WHEN** a document holds images of different shapes and none of them is painted over
- **THEN** every image's block is three rows tall
- **AND** each block is at least as wide as the hint it carries
- **AND** no block is wider than the page

#### Scenario: Artwork forced with graphics

- **WHEN** `image_inline = 'art'` and the terminal can draw
- **THEN** the image's block is the artwork `image_mode` selects
- **AND** nothing is placed over it

#### Scenario: The popup is unaffected

- **WHEN** the preview key opens an image's popup
- **THEN** the popup shows what it shows with any other value of `image_inline`

#### Scenario: The hint on a card or alt text

- **WHEN** an image is shown as a card or as its alt text and `keymaps.preview` or
  `keymaps.open_image` is bound
- **THEN** the card's last display row, inside the card, or the end of the alt text's last
  displayed row, carries a hint naming those keys
- **AND** the hint is virtual text, so the line's own bytes and width are unchanged
- **AND** with the image shown as character artwork no hint is drawn
- **AND** with the card painted over by the terminal's picture no hint is drawn
- **AND** with both keys bound to `false` no hint is drawn

### Requirement: A native inline image follows the viewport

When the terminal can draw and the inline image is a card, the plugin SHALL place a downscaled
picture of the file over the block's own cells, so that the reader sees the picture where the
document flows. It SHALL draw that picture over the rows of the block that the window shows, and
only once the viewport has been still for the debounce.

A block the window cuts SHALL be painted up to the window's edge rather than squeezed into the
part that is left: on the byte-carrying transport the engine SHALL cut the shown rows out of the
whole block's picture, so the placement carries the same picture at the same scale as the whole
block, continuing above and below the window. The path-carrying transport is handed the file's
path and cannot cut it, so there a block SHALL be painted only while it is wholly visible and
SHALL show its card otherwise.

The payload SHALL be the file itself when the file is no larger than the configured threshold and
is a still PNG or JPEG, and a thumbnail of it otherwise. A block the window cuts SHALL always
carry the engine's encode, because the file's own bytes are the whole picture and the terminal
cannot cut them. The file itself keeps its own resolution; the thumbnail is downscaled to the
block's cell box at about 640 pixels across, and the engine produces it. A GIF, a WebP and an
APNG are never sent unchanged, because the inline view is one still picture and the terminal
would play them; any other format is left to the engine, which decodes more than the terminal
does. The path-carrying transport sends the file's path and is not affected by the threshold, but
only for a PNG: that transport names the format in the sequence and decodes no other one, so a
JPEG, a WebP, a GIF or a file of any other format SHALL keep its card there rather than be sent to
be refused.

It SHALL draw that picture only while no floating window covers any of the block's cells, either.
A float owns the cells under it, and the terminal draws whatever was placed last, so a picture
painted under a float appears in front of the float's own content — over the preview popup's image
on the transport that keeps one image layer for the tabpage. A block a float covers SHALL show its
card, and SHALL have its picture placed again when the float closes.

The placement SHALL follow the window: after a scroll, a window resize or a re-render, the blocks
on screen SHALL have their pictures placed again over the rows that are visible, and the blocks
that are not on screen SHALL have none. A burst of scroll or resize events SHALL produce at most
one placement per block.

The plugin SHALL NOT ask the engine for the same thumbnail twice while the file is unchanged: a
re-place, a scroll back to a block, or a re-render whose file has the same length and modification
time SHALL reuse what was produced before. The visible slice SHALL be part of what identifies a
thumbnail, because the rows on screen are a different picture. A document with an image SHALL
therefore cost one thumbnail request per distinct file, box and slice, not one per placement.

A reference whose file cannot be read, one that is not a local file, and a picture the engine
refuses SHALL show their card and nothing over it, and SHALL NOT be reported to the reader as an
error. The buffer's content, its keys, its search and its yank SHALL be unaffected: the picture is
a paint over the card, as the preview's is over its artwork.

#### Scenario: A visible block

- **WHEN** a document with an image is rendered in R in a terminal that can draw, with the whole
  image block inside the window
- **THEN** the picture of the file is placed over the block's cells
- **AND** the block's content underneath is still its card

#### Scenario: A file the path transport cannot decode

- **WHEN** the image is a JPEG on a path-carrying terminal, and the viewport settles
- **THEN** the block keeps its card and nothing is placed over it
- **AND** no error is reported, because the card is what the reader was already looking at

#### Scenario: A block cut by the window's last row

- **WHEN** the image's block is scrolled so that its last rows are below the window, and the
  viewport settles
- **THEN** the rows still on screen are painted with the top of the picture, cut at the window's
  edge
- **AND** the block's content underneath is still its card

#### Scenario: A block cut by the window's first row

- **WHEN** the image's block is scrolled so that its first rows are above the window, and the
  viewport settles
- **THEN** the rows still on screen are painted with the rest of the picture, cut at the window's
  edge
- **AND** a path-carrying terminal shows the block's card instead, because it cannot cut a file it
  reads itself

#### Scenario: A float over the block

- **WHEN** a floating window is opened over the cells of a wholly visible block, and the viewport
  settles
- **THEN** the block shows its card
- **AND** no picture is placed over it
- **AND** the float's own content, including the preview popup's image, is not covered by one

#### Scenario: The float closes

- **WHEN** that floating window closes
- **THEN** the picture is placed again on the settle that follows

#### Scenario: A small file is sent unchanged

- **WHEN** a wholly visible block's picture is a PNG or JPEG no larger than the configured
  threshold, on the byte-carrying transport
- **THEN** the placement carries the file itself
- **AND** the engine is not asked for a thumbnail
- **AND** a block the window cuts carries the engine's encode instead, whatever the file's size
- **AND** a file over the threshold, or an animation, carries the engine's thumbnail too

#### Scenario: Scrolling back

- **WHEN** the reader scrolls a block out of the window and back onto it
- **THEN** its picture is placed again
- **AND** the engine is not asked for the thumbnail a second time for the slice it already has

#### Scenario: Scrolling a cut block by one row

- **WHEN** a block the window cuts is scrolled by one row and the viewport settles
- **THEN** the rows on screen are a different slice, and its encode is asked for

#### Scenario: A re-render

- **WHEN** the document is edited elsewhere and rendered again, and the image file is unchanged
- **THEN** the picture is placed again for the blocks on screen
- **AND** the engine is not asked for the thumbnail a second time for a slice it already has

#### Scenario: A burst of scrolls

- **WHEN** the reader holds a scroll key so that the window scrolls many times in a row
- **THEN** each block on screen is placed at most once for the burst

#### Scenario: A file that cannot be read

- **WHEN** an image block refers to a file that no longer exists
- **THEN** the block shows its card
- **AND** no picture is placed over it
- **AND** nothing is reported to the reader
