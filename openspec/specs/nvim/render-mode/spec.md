# nvim/render-mode Specification

## Purpose
The plugin's reading view for a markdown document: how document images are shown inline in R, how
an animated image is stepped by hand, how an image is opened with the system application, and what
happens when an image cannot be drawn at all.

## Requirements

### Requirement: Image rendering mode

The plugin SHALL expose an `image_mode` option with the values `auto`, `braille`, `quads`, `blocks`,
`ascii` and `off`. The selected mode SHALL be passed to the engine with every render.

- `auto` SHALL select `braille` when `'termguicolors'` is enabled in the editor and `ascii` when it
  is not.
- `braille`, `quads`, `blocks` and `ascii` SHALL select that encoding regardless of the editor's
  options.
- `off` SHALL render an image reference as its alt text, exactly as the plugin did before image
  rendering existed.

The option SHALL default to `auto`.

The plugin SHALL expose palette, background and dithering options, all passed to the engine with
every render:

- `image_palette` SHALL accept `auto`, `theme`, `adaptive` and `full`, and SHALL default to `auto`.
  `auto` SHALL select `full` for the braille and ASCII encodings, where a cell carries one colour,
  and `adaptive` for the half-block and quadrant encodings, where a cell carries a colour pair.
- `image_background` SHALL accept `terminal`, `theme` or a `#rrggbb` colour string, and SHALL default
  to `terminal`. `terminal` SHALL leave transparent pixels to the terminal's background, as before;
  the other values SHALL be used to composite partly transparent pixels.
- `image_dither` SHALL accept `auto`, `true` and `false`, and SHALL default to `auto`. `auto` SHALL
  enable dithering for the braille encoding, and for the ASCII encoding when the palette is not
  `full`, and SHALL disable it for the half-block and quadrant encodings.

The plugin SHALL expose `image_min_rows`, defaulting to 0, and `image_sharpen`, defaulting to
`false`. Zero SHALL mean an image is never enlarged; a positive value SHALL be passed to the engine
as the minimum number of display rows an image is enlarged to reach.

Every option above SHALL form part of the render cache key, so changing one SHALL produce a new
render rather than reusing an older one.

#### Scenario: Default mode in a truecolor editor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is enabled
- **THEN** a supported image is rendered in the braille encoding

#### Scenario: Default mode without truecolor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is disabled
- **THEN** a supported image is rendered in the ASCII encoding

#### Scenario: The mode is chosen explicitly

- **WHEN** `image_mode` is `quads` and `'termguicolors'` is disabled
- **THEN** the quadrant encoding is used anyway

#### Scenario: Image rendering turned off

- **WHEN** `image_mode` is `off`
- **THEN** the reference appears as its alt text
- **AND** no artwork is produced for it

#### Scenario: The palette follows the encoding

- **WHEN** `image_palette` is `auto` and the encoding is `braille`
- **THEN** the engine is asked for the full palette
- **AND** when the encoding is `quads`, the engine is asked for the adaptive palette instead

#### Scenario: A changed option re-renders

- **WHEN** the user changes `image_palette`, `image_background`, `image_dither`, `image_min_rows` or
  `image_sharpen` while the document is shown
- **THEN** the next render uses the new value rather than a cached rendering

#### Scenario: A named background

- **WHEN** `image_background` is set to a `#rrggbb` colour
- **THEN** that colour is passed to the engine and partly transparent images blend into it

### Requirement: Image artwork follows the window's page

The plugin SHALL derive the image bounds from the window showing the document: the width bound from
the window's text width, as for every other block, and the height bound from the smaller of the
window's text height and the `image_max_height` option. Both SHALL be passed to the engine with
every render.

`image_max_height` SHALL be the largest number of display rows inline artwork may occupy, and SHALL
default to 20. Setting it to `false` SHALL remove the cap, leaving the window's text height as the
only height bound.

Because the engine scales both axes by one factor, capping the height SHALL also narrow the
artwork; the image's aspect ratio SHALL be preserved.

The option SHALL apply to the inline render only. The block preview popup SHALL keep its own
bounds, so the preview key SHALL still show an image larger than the page does.

When the window's size changes, the document SHALL be re-rendered against the new bounds. A render
produced for one pair of bounds SHALL NOT be reused for another.

The height bound SHALL NOT change the output for a document that contains no renderable image.

#### Scenario: A tall image in a short window

- **WHEN** a document with a tall image is shown in a window 30 rows high
- **THEN** the artwork is at most 30 display rows tall

#### Scenario: A tall image at the default cap

- **WHEN** a document with an image taller than the default cap is shown and `image_max_height` is
  at its default
- **THEN** the artwork is at most 20 display rows tall

#### Scenario: The cap also narrows the artwork

- **WHEN** a 640×360 image is rendered in a 126-column window with `image_max_height` set to 20
- **THEN** the artwork is at most 20 rows tall
- **AND** its width is correspondingly narrower than the 126 columns it would otherwise use
- **AND** its aspect ratio is preserved

#### Scenario: A raised cap

- **WHEN** `image_max_height` is set to 40 and the window is tall enough
- **THEN** the artwork may occupy up to 40 display rows

#### Scenario: The cap removed

- **WHEN** `image_max_height` is `false` and the window's text height is 50 rows
- **THEN** the artwork may occupy up to 50 display rows

#### Scenario: The window becomes shorter

- **WHEN** the window is resized to a smaller height
- **THEN** the document is re-rendered
- **AND** the artwork is shorter than before, still preserving its aspect ratio

#### Scenario: The window becomes taller again

- **WHEN** the window is restored to its earlier size
- **THEN** the artwork is rendered as it was at that size

#### Scenario: The preview is not capped

- **WHEN** the preview key opens an image whose inline artwork is bounded by `image_max_height`
- **THEN** the popup lays the image out at the popup's own height, not at the inline cap

#### Scenario: A document with no images

- **WHEN** a document without images is rendered in two windows of the same width but different
  heights
- **THEN** the rendered document is the same

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
the artwork's box exactly, columns and rows, so the placement covers all of it, and SHALL carry no
caption: a picture may be transparent, and a transparent pixel would show the caption as letters
inside the picture. A card nothing is painted over SHALL keep its caption, which is all the reader
has then.

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

#### Scenario: A transparent picture over its card

- **WHEN** the terminal paints a picture with transparent pixels over an image's card
- **THEN** the cells under the picture show the card's surface and no caption, so nothing of the
  document reads through the picture
- **AND** a card nothing is painted over still carries its caption

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
does. The path-carrying transport SHALL send a PNG's path, which is not affected by the threshold
and keeps the file's own resolution, and SHALL carry every other format as the engine's PNG
encode, because that transport names the picture's format in the sequence and decodes PNG alone.
A JPEG, a WebP, a GIF or a file of any other format is therefore painted there too, as a still
frame of that encode.

It SHALL draw that picture only while no floating window covers any of the block's cells, either.
A float owns the cells under it, and the terminal draws whatever was placed last, so a picture
painted under a float appears in front of the float's own content — over the preview popup's image
on the transport that keeps one image layer for the tabpage. A block a float covers SHALL show its
card, and SHALL have its picture placed again when the float closes.

The placement SHALL follow the window: after a scroll, a window resize or a re-render, the blocks
on screen SHALL have their pictures placed again over the rows that are visible, and the blocks
that are not on screen SHALL have none. A burst of scroll or resize events SHALL produce at most
one placement per block.

A window SHALL count as on screen only while its tab page is the current one. A window in another
tab page SHALL have no picture placed, and entering a tab page SHALL place the pictures of the
windows it shows.

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

#### Scenario: A format the path transport cannot name

- **WHEN** the image is a JPEG on a path-carrying terminal, and the viewport settles
- **THEN** the engine's PNG encode of it is placed over the block's cells
- **AND** the encode was asked for as PNG, at the block's own box
- **AND** no error is reported

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

#### Scenario: Another tab page is showing

- **WHEN** the reader switches to another tab page while a window in the first one shows a block
  whose picture is placed, and the viewport settles there
- **THEN** nothing is placed over the tab page that is showing
- **AND** the picture of the first tab page's block is placed again when that tab page is entered

#### Scenario: A burst of scrolls

- **WHEN** the reader holds a scroll key so that the window scrolls many times in a row
- **THEN** each block on screen is placed at most once for the burst

#### Scenario: A file that cannot be read

- **WHEN** an image block refers to a file that no longer exists
- **THEN** the block shows its card
- **AND** no picture is placed over it
- **AND** nothing is reported to the reader

### Requirement: An unrenderable image does not fail the reading view

When a document references an image that cannot be rendered, the rendered state SHALL still be
entered and SHALL show the document's other content. The plugin SHALL NOT treat the reference as a
rendering failure of the document, and SHALL NOT report a diagnostic for it.

#### Scenario: A document with one broken image

- **WHEN** the user opens a markdown document containing an image reference to a missing file
- **THEN** the window enters R
- **AND** the rest of the document is shown
- **AND** the broken reference appears as its alt text
- **AND** no error is reported

#### Scenario: Every image is broken

- **WHEN** every image reference in a document cannot be rendered
- **THEN** the window enters R and shows the document's text

### Requirement: Images stay still until asked to move

In R an image SHALL be drawn on its first frame and SHALL NOT change on its own.

The plugin SHALL expose a frame-step key, configurable and defaulting to `<C-n>`. Pressing it with
the cursor on an animated image SHALL advance that image one frame, wrapping from the last frame to
the first. Pressing it where the cursor is not on an animated image SHALL perform that key's
ordinary editor action instead.

Where the image is an animation the engine refused for size, the key SHALL NOT perform its ordinary
editor action: the image stays on its first frame and the plugin SHALL report that the image is too
large to animate. The report SHALL be given once per render of the document.

The plugin SHALL expose an `image_animation` option, defaulting to on. With it off, no animation
data is requested and the frame-step key behaves like any other key everywhere.

Stepping SHALL NOT move the cursor, and the display rows of the artwork SHALL keep mapping to the
source line of the image reference.

The first press on an image whose frames are not yet in memory SHALL fetch them, and SHALL show a
one-line status hint at the bottom of the editor while the fetch is in flight, cleared when the
answer arrives. A press that arrives before that answer SHALL NOT start a second fetch: it SHALL be
remembered, and the image SHALL advance one frame for each remembered press when the frames land.

#### Scenario: Cursor on an animated image

- **WHEN** R shows an animated image and the user presses the frame-step key on it
- **THEN** the image shows its next frame
- **AND** the frame is drawn within the same rows as before

#### Scenario: Wrapping

- **WHEN** the last frame is showing and the user presses the frame-step key again
- **THEN** the image shows its first frame

#### Scenario: Cursor not on an image

- **WHEN** the cursor is on prose and the user presses the frame-step key
- **THEN** no frame changes
- **AND** the key performs its ordinary editor action

#### Scenario: An animation over the engine's bounds

- **WHEN** the cursor is on an image whose animation the engine refused as too large
- **AND** the user presses the frame-step key
- **THEN** the image stays on its first frame
- **AND** the key does not perform its ordinary editor action
- **AND** the plugin reports that the image is too large to animate

#### Scenario: Animation off

- **WHEN** `image_animation` is off and the user presses the frame-step key on an animated image
- **THEN** the image remains on its first frame
- **AND** the key performs its ordinary editor action

#### Scenario: A re-render

- **WHEN** the window is resized or the document is edited while an image shows a later frame
- **THEN** the image is redrawn on its first frame

#### Scenario: Pressing again while the frames are being fetched

- **WHEN** the user presses the frame-step key again before the first fetch of the frames has
  answered
- **THEN** no second fetch is started
- **AND** the press is remembered
- **AND** when the frames arrive the image advances one frame for each press received
- **AND** the cursor does not move

#### Scenario: A slow frame fetch

- **WHEN** an image's frames take long enough to decode that the picture sits still
- **THEN** the editor shows a status hint at the bottom that the frames are being decoded
- **AND** the hint is cleared when the frames arrive

### Requirement: Opening the image with the system application

The plugin SHALL expose an open-image key, configurable and defaulting to `gx`, available in R.
Pressing it with the cursor on an image's artwork SHALL open the referenced file with the operating
system's default application for that file.

A relative destination SHALL resolve against the directory of the document holding the reference,
exactly as the engine resolves it; an absolute path SHALL be used as given. The key SHALL work for
any local image file, including a format the engine cannot draw.

A destination that is not a local file SHALL NOT be fetched or opened, and the plugin SHALL report
that it cannot open it. A local file that does not exist SHALL likewise be reported, and no
application SHALL be launched. Where the cursor is not on an image, the key SHALL perform its
ordinary editor action.

#### Scenario: A local image

- **WHEN** the cursor is on a rendered image and the user presses the open-image key
- **THEN** the image file is opened with the system default application

#### Scenario: A relative destination

- **WHEN** the reference is `![](images/a.png)` and the document is `/docs/readme.md`
- **THEN** `/docs/images/a.png` is opened

#### Scenario: An image the engine cannot draw

- **WHEN** the reference names an SVG file, whose alt text is shown instead of artwork
- **AND** the cursor is on that alt text
- **THEN** the SVG file is opened with the system default application

#### Scenario: A remote destination

- **WHEN** the reference is an `http` or `https` URL
- **THEN** nothing is fetched or opened
- **AND** the plugin reports that the image cannot be opened

#### Scenario: A missing file

- **WHEN** the referenced local file does not exist
- **THEN** no application is launched
- **AND** the plugin reports that the image cannot be opened

#### Scenario: Cursor not on an image

- **WHEN** the cursor is on prose and the user presses the open-image key
- **THEN** no image is opened
- **AND** the key performs its ordinary editor action

### Requirement: State on open

Opening a markdown file SHALL show the rendered state (R). Files that are not markdown SHALL be
unaffected: no rendered state exists for them and no rendering is attempted.

#### Scenario: Opening a markdown file

- **WHEN** the user opens a `.md` file
- **THEN** the window shows rendered content rather than raw markdown

#### Scenario: Opening a non-markdown file

- **WHEN** the user opens a file whose type is not markdown
- **THEN** the window shows the file normally
- **AND** no rendering process is started

#### Scenario: Rendered content is not yet available

- **WHEN** a markdown file is opened and rendering has not completed
- **THEN** the window continues to show the source
- **AND** the window shows the rendered content once rendering completes

### Requirement: Rendered state

R SHALL display the engine's output in a read-only buffer shown in the same window. The displayed
content SHALL be ordinary buffer content, so scrolling, searching and yanking operate on it with
the editor's normal mechanisms. Modification SHALL be refused.

#### Scenario: Scroll and search

- **WHEN** the user scrolls or searches while in R
- **THEN** the movement and the search operate on the displayed rendered content
- **AND** line-addressed motions such as `gg` and `G` resolve within the rendered content

#### Scenario: Modification is refused

- **WHEN** an editing command is issued while in R
- **THEN** the document is not modified
- **AND** the buffer contents are unchanged

#### Scenario: Rendered state does not outlive its window

- **WHEN** the window stops showing the rendered content
- **THEN** the rendered buffer is discarded rather than left in the buffer list

### Requirement: Source state

S SHALL display the document's source buffer in the same window, unmodified and fully editable,
with the editor's complete normal-mode vocabulary available — including undo, operators,
substitutions, and whatever language tooling attaches to the buffer.

#### Scenario: Editing in S

- **WHEN** the user edits while in S
- **THEN** the source buffer is modified as usual
- **AND** undo, operators and substitutions behave as they do for any other buffer

#### Scenario: Returning to a position

- **WHEN** the user leaves S for R and later returns to S
- **THEN** the window's cursor and scroll position in the source are restored

### Requirement: Crossing from R into S

The insert-entry keys `i`, `a`, `I`, `A`, `o` and `O` SHALL switch from R to S, place the cursor at
the source line corresponding to the display line the cursor was on, and enter the corresponding
insert mode. A toggle mapping SHALL also switch from R to S while remaining in normal mode, so that
normal-mode editing commands can be reached without passing through insert mode.

#### Scenario: Insert from a rendered paragraph

- **WHEN** the user presses `i` with the cursor on a display line derived from source line N
- **THEN** the window shows the source
- **AND** the cursor is on source line N
- **AND** the editor is in insert mode

#### Scenario: Open a new line

- **WHEN** the user presses `o` with the cursor on a display line derived from source line N
- **THEN** the window shows the source with the cursor on source line N
- **AND** a new line is opened below it in insert mode, as `o` does in any buffer

#### Scenario: Reach normal mode directly

- **WHEN** the user presses the toggle mapping while in R
- **THEN** the window shows the source
- **AND** the editor remains in normal mode

#### Scenario: Cursor on a synthetic display line

- **WHEN** the cursor is on a display line marked synthetic — a table border or diagram artwork
- **THEN** the cursor is placed on the source line of the construct that produced it

### Requirement: Returning to R

The toggle mapping SHALL switch from S to R. Leaving insert mode SHALL NOT change state: after
`Esc`, the editor SHALL remain in S until the user asks for R.

#### Scenario: Toggle back

- **WHEN** the user presses the toggle mapping while in S
- **THEN** the window shows the rendered content

#### Scenario: Leaving insert mode does not toggle

- **WHEN** the user presses `Esc` in insert mode while in S
- **THEN** the editor is in normal mode
- **AND** the window still shows the source
- **AND** normal-mode editing commands still apply to the source buffer

### Requirement: Writing while rendered

A write issued while in R SHALL write the source buffer. Rendered content SHALL never be written to
the document's file.

#### Scenario: Write with no pending edits

- **WHEN** the user issues a write while in R and the source has not been modified
- **THEN** the file on disk is unchanged

#### Scenario: Write after editing in S

- **WHEN** the user edits in S and then issues a write while in R
- **THEN** the edit is written to the document's file
- **AND** the rendered content is not written to the file

### Requirement: Freshness

R SHALL reflect the source buffer's current contents rather than the file on disk, so unsaved edits
are rendered. R SHALL be refreshed when the window's width changes or when the source buffer
changes. Re-entering R when neither has happened SHALL reuse the previous rendering rather than
rendering again.

#### Scenario: Unsaved edits

- **WHEN** the user edits in S without writing and then returns to R
- **THEN** the rendered content reflects the edit

#### Scenario: Window width changes

- **WHEN** the window is resized while in R
- **THEN** the rendered content is produced again at the new width

#### Scenario: Toggling without an edit

- **WHEN** the user toggles from R to S and back without editing
- **THEN** the previously rendered content is shown without a new rendering pass

### Requirement: Rendering failure

When rendering cannot be performed — the engine is unavailable, exits non-zero, or returns
unusable output — the editor SHALL remain in S and SHALL report the failure, rather than showing an
empty or partial rendered state.

#### Scenario: Engine unavailable

- **WHEN** the user opens a markdown file and the render engine cannot be executed
- **THEN** the window shows the source
- **AND** a diagnostic is reported

#### Scenario: Engine returns an error

- **WHEN** the engine exits non-zero for a document
- **THEN** the editor does not enter R for that document
- **AND** the diagnostic the engine produced is reported

### Requirement: State is per window

Each window SHALL carry its own state independently, so two windows on the same document may show
different states without interfering.

#### Scenario: Same document in two windows

- **WHEN** the same document is open in two windows and one is switched to S
- **THEN** the other window's state is unchanged

### Requirement: Following a link

The plugin SHALL expose a follow key, configurable and defaulting to `gf`, available in both R and S. With the cursor on a link, the key SHALL open its destination: a URL SHALL be handed to the operating system's URL handler, an anchor SHALL jump to the heading it names, and a local file SHALL open in the window.

A relative destination SHALL resolve against the directory of the document holding the reference. An absolute destination SHALL be used as given, whether it is written as a POSIX path beginning with `/`, a drive-letter path such as `C:/docs/a.md` or `C:\docs\a.md`, or a UNC path beginning with `\\`. A local destination that does not exist SHALL be reported, and no buffer SHALL be opened. With no link under the cursor, the key SHALL perform its ordinary editor action.

#### Scenario: A relative link

- **WHEN** the link target is `docs/guide.md` and the document is `/work/readme.md`
- **THEN** `/work/docs/guide.md` is opened

#### Scenario: An absolute POSIX path

- **WHEN** the link target is `/work/guide.md`
- **THEN** `/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute Windows drive path

- **WHEN** the link target is `C:/work/guide.md` or `C:\work\guide.md`
- **THEN** `C:/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute UNC path

- **WHEN** the link target is `\\server\share\guide.md`
- **THEN** that share path is opened
- **AND** the document's directory is not prepended

#### Scenario: A URL

- **WHEN** the link target is an `http` or `https` URL
- **THEN** the URL is handed to the operating system's URL handler
- **AND** no local path is resolved

#### Scenario: An anchor

- **WHEN** the link target is `#installation`
- **THEN** the cursor moves to the heading whose slug is `installation`

#### Scenario: A missing local file

- **WHEN** the resolved local path does not exist
- **THEN** no buffer is opened
- **AND** the plugin reports that the file does not exist

#### Scenario: No link under the cursor

- **WHEN** the cursor is on text that is not a link
- **THEN** the key performs its ordinary editor action

### Requirement: Setup and loading reach the buffer already on screen

The plugin SHALL work when sourced from `runtimepath` without calling `setup()`. `setup(opts)` SHALL apply the options and SHALL be idempotent: repeated calls SHALL NOT create duplicate autocmds, commands or keymaps.

When the plugin is sourced, or when `setup()` runs, while the current window shows a managed buffer, that buffer SHALL be attached without the user reopening the file, and the window SHALL enter R as the "State on open" requirement describes. When the plugin is loaded lazily after the `FileType` event, the buffer that triggered the load SHALL be attached the same way.

Attaching SHALL use the same checks as the `FileType` path: the buffer and window SHALL still be valid, the window SHALL still show that buffer, and a window already attached to that source SHALL not be attached a second time.

#### Scenario: The plugin is sourced with a markdown buffer on screen

- **WHEN** the plugin is added to `runtimepath` and sourced while the current window shows a markdown buffer
- **THEN** that buffer is attached without reopening the file
- **AND** the window shows R once rendering completes

#### Scenario: Setup runs with a markdown buffer on screen

- **WHEN** `require('md-render').setup{}` runs while the current window shows a markdown buffer
- **THEN** that buffer is attached
- **AND** the window shows R once rendering completes

#### Scenario: A plugin manager loads the plugin on FileType

- **WHEN** the plugin is loaded after the `FileType` event for a markdown buffer
- **THEN** the buffer that triggered the load is attached
- **AND** the first markdown file shows R without being reopened

#### Scenario: Setup is called twice

- **WHEN** `setup{}` is called twice with different options
- **THEN** no autocmd, command or buffer-local keymap is duplicated
- **AND** subsequent renders use the second set of options

#### Scenario: Setup runs before filetype detection

- **WHEN** `setup{}` runs while the current buffer has no managed filetype
- **THEN** no buffer is attached at that moment
- **AND** the later `FileType` event attaches the buffer normally
