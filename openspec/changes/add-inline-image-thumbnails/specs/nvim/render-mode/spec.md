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
gets it, and it SHALL NOT alter the document's lines: a card occupies the box the artwork would
have, so the source mapping, the row count and every key behave as they do with artwork.

#### Scenario: Auto with a terminal that can draw

- **WHEN** the editor runs in a terminal the plugin can draw in and a document with an image is
  rendered in R
- **THEN** the image's block is a card
- **AND** the document's row count and source mapping are those the artwork would have produced
- **AND** the picture of the file is placed over it

#### Scenario: Auto without graphics

- **WHEN** `graphics = 'off'`, or the terminal is not one the plugin can identify, or a
  multiplexer is in the way, and `image_inline = 'auto'`
- **THEN** the image's block is a card
- **AND** nothing is placed over it

#### Scenario: Auto with image drawing switched off

- **WHEN** `image_inline = 'auto'`, `image_mode = 'off'` and the terminal can draw
- **THEN** the image's block is its alt text, as `image_mode = 'off'` produces
- **AND** nothing is placed over it

#### Scenario: Card forced on a drawing terminal

- **WHEN** `image_inline = 'card'` and the terminal can draw
- **THEN** the image's block is a card
- **AND** nothing is placed over it

#### Scenario: Card forced without graphics

- **WHEN** `image_inline = 'card'` and the terminal cannot draw
- **THEN** the image's block is a card
- **AND** nothing is placed over it

#### Scenario: Artwork forced with graphics

- **WHEN** `image_inline = 'art'` and the terminal can draw
- **THEN** the image's block is the artwork `image_mode` selects
- **AND** nothing is placed over it

#### Scenario: The popup is unaffected

- **WHEN** the preview key opens an image's popup
- **THEN** the popup shows what it shows with any other value of `image_inline`

### Requirement: A native inline image follows the viewport

When the terminal can draw and the inline image is a card, the plugin SHALL place a downscaled
picture of the file over the block's own cells, so that the reader sees the picture where the
document flows. It SHALL draw that picture only while the whole block is inside the window's
visible rows: a block that is partly scrolled out SHALL show its card and nothing over it, because
a placement is a paint over cells and a partly covered box would show the picture squeezed into
what remains.

The placement SHALL follow the window: after a scroll, a window resize or a re-render, the blocks
that are wholly visible SHALL have their pictures placed again, and the blocks that are not SHALL
have none. A burst of scroll or resize events SHALL produce at most one placement per block.

The plugin SHALL NOT ask the engine for the same thumbnail twice while the file is unchanged: a
re-place, a scroll back to a block, or a re-render whose file has the same length and modification
time SHALL reuse what was produced before. A document with an image SHALL therefore cost one
thumbnail request per distinct file and box, not one per placement.

A reference whose file cannot be read, one that is not a local file, and a picture the engine
refuses SHALL show their card and nothing over it, and SHALL NOT be reported to the reader as an
error. The buffer's content, its keys, its search and its yank SHALL be unaffected: the picture is
a paint over the card, as the preview's is over its artwork.

#### Scenario: A visible block

- **WHEN** a document with an image is rendered in R in a terminal that can draw, with the whole
  image block inside the window
- **THEN** the picture of the file is placed over the block's cells
- **AND** the block's content underneath is still its card

#### Scenario: A partly visible block

- **WHEN** the image's block is scrolled so that its first or last row is outside the window
- **THEN** that block shows its card
- **AND** no picture is placed over it

#### Scenario: Scrolling back

- **WHEN** the reader scrolls a block out of the window and back to being wholly visible
- **THEN** its picture is placed again
- **AND** the engine is not asked for the thumbnail a second time

#### Scenario: A re-render

- **WHEN** the document is edited elsewhere and rendered again, and the image file is unchanged
- **THEN** the picture is placed again for the blocks that are wholly visible
- **AND** the engine is not asked for the thumbnail a second time

#### Scenario: A burst of scrolls

- **WHEN** the reader holds a scroll key so that the window scrolls many times in a row
- **THEN** each wholly visible block is placed at most once for the burst

#### Scenario: A file that cannot be read

- **WHEN** an image block refers to a file that no longer exists
- **THEN** the block shows its card
- **AND** no picture is placed over it
- **AND** nothing is reported to the reader
