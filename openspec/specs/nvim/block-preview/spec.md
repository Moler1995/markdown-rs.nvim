# nvim/block-preview Specification

## Purpose
The preview popup an image opens on its own: what the preview key does on artwork, and how an
animated image plays, pauses and stops there.

## Requirements

### Requirement: The preview key opens an image

While R is showing and the cursor is on an image's artwork or card, the preview key SHALL open a
popup showing that image alone when the terminal can draw the file in the editor — the conditions
the graphics transport requires: an editor with the raw-bytes API, an attached UI, `graphics` not
`'off'`, an identified terminal, and no multiplexer. The popup SHALL be on the same terms as the
popup already opens for a diagram or a table: laid out at its own width and height, so the image is
scaled to the popup rather than to the window, and never enlarged past its natural size.

An image the engine cannot draw SHALL still open a popup, showing the reference's alt text.

Where the terminal cannot draw the file, the preview key SHALL NOT open a popup for an image,
because a popup there could only show character artwork. It SHALL instead open the referenced file
with the operating system's default application, resolving and reporting exactly as the
open-image key does: a relative destination against the directory of the document holding the
reference, an absolute path as given, and a destination that is not a local file or does not exist
reported rather than fetched or launched.

The behavior of the preview key on a diagram or a table SHALL NOT depend on the terminal.

#### Scenario: Cursor on an image

- **WHEN** the terminal can draw the file, the cursor is on a rendered image and the user presses
  the preview key
- **THEN** a popup opens showing that image alone

#### Scenario: A small image

- **WHEN** the image is smaller than the popup
- **THEN** it is shown at its natural size

#### Scenario: Alt text instead of artwork

- **WHEN** the reference names an SVG file and the cursor is on its alt text
- **THEN** a popup opens showing that alt text

#### Scenario: A popup drawn by the terminal

- **WHEN** the terminal draws images and the preview key opens an image whose reference resolves
  to a readable file
- **THEN** the popup window is the one the artwork would have opened
- **AND** the image file is shown over its interior

#### Scenario: A terminal that cannot draw

- **WHEN** `graphics = 'off'`, or the terminal is not one the plugin identifies, or a multiplexer
  is in the way, and the cursor is on an image
- **THEN** no popup opens
- **AND** the referenced file is opened with the operating system's default application

#### Scenario: A relative destination without a popup

- **WHEN** the reference is `![](images/a.png)`, the document is `/docs/readme.md`, and the
  terminal cannot draw the file
- **THEN** `/docs/images/a.png` is opened

#### Scenario: A file that cannot be opened

- **WHEN** the terminal cannot draw, and the referenced file does not exist, or the reference is
  not a local file
- **THEN** no popup opens
- **AND** nothing is launched
- **AND** the plugin reports that the image cannot be opened

#### Scenario: A diagram on a terminal that cannot draw

- **WHEN** the cursor is within a `mermaid` fence's artwork on a terminal that cannot draw an
  image file
- **THEN** the popup opens showing the diagram, as on any other terminal

### Requirement: An animated image plays in the popup

When the popup's image is animated and `image_animation` is on, playback SHALL start automatically
once the popup opens and SHALL loop. Each frame SHALL be shown for the delay the image records; a
recorded delay below 20 milliseconds SHALL be played for 100 milliseconds, so that an image which
asks for "as fast as possible" does not spin.

The plugin SHALL expose a pause key, configurable and defaulting to `<Space>`, bound in the popup
only while an animated image is playing. It SHALL pause and resume playback. While paused, the
frame-step key SHALL advance one frame, wrapping at the end. Closing the popup SHALL stop playback
and leave no timer running.

For a still image, or with `image_animation` off, the popup SHALL show the first frame, the pause
and frame-step keys SHALL perform their ordinary actions, and no timer SHALL be started.

An image whose animation the engine refused for size SHALL likewise show its first frame and start
no timer, and the plugin SHALL report that the image is too large to animate.

Where the popup's image is drawn by the terminal, the terminal SHALL own playback and the rules
above SHALL be read as applying to a popup whose content is artwork: the plugin SHALL request no
frames for the popup, SHALL start no timer, SHALL swap no frames, and SHALL NOT bind the pause and
frame-step keys, whose ordinary actions the reader keeps.

#### Scenario: Opening an animated image

- **WHEN** an animated image is opened in the popup
- **THEN** it starts playing without another keypress
- **AND** it loops after its last frame

#### Scenario: Pausing

- **WHEN** the user presses the pause key while the image is playing
- **THEN** the frame on screen stops advancing
- **AND** pressing it again resumes from that frame

#### Scenario: Stepping while paused

- **WHEN** playback is paused and the user presses the frame-step key
- **THEN** the image advances exactly one frame

#### Scenario: Closing during playback

- **WHEN** the popup is closed while the image is playing
- **THEN** playback stops
- **AND** no further frame is applied anywhere

#### Scenario: A still image

- **WHEN** the popup shows a still image
- **THEN** the pause key performs its ordinary action in the popup
- **AND** no playback timer is started

#### Scenario: An animation over the engine's bounds

- **WHEN** the popup shows an image whose animation the engine refused as too large
- **THEN** it stays on its first frame with no timer
- **AND** the plugin reports that the image is too large to animate

#### Scenario: An animation drawn by the terminal

- **WHEN** an animated image's popup is drawn by the terminal
- **THEN** the terminal plays the file's frames
- **AND** no frames are requested for the popup, no timer is started, and the pause and frame-step
  keys keep their ordinary meaning

### Requirement: Opening the preview

While R is showing, the preview key SHALL open a popup for the block under the cursor when that
block is a `mermaid` fence or a table. The key SHALL be configurable and SHALL default to `<CR>`.

#### Scenario: Cursor on a diagram

- **WHEN** the cursor is anywhere within a `mermaid` fence's rendered artwork and the user presses the preview key
- **THEN** a popup opens showing that diagram

#### Scenario: Cursor on a table

- **WHEN** the cursor is on any row of a table and the user presses the preview key
- **THEN** a popup opens showing that table

#### Scenario: Cursor on a table border

- **WHEN** the cursor is on a table's border row, which carries no source line of its own
- **THEN** a popup opens showing the table that drew that border

#### Scenario: Configured key

- **WHEN** the user sets the preview key to another mapping and presses that mapping in R
- **THEN** the popup opens, and the default key no longer opens it

### Requirement: The preview key is not stolen

Where no preview is available the preview key SHALL perform its ordinary editor action rather than
doing nothing.

#### Scenario: Cursor on prose

- **WHEN** the cursor is on prose and the user presses the preview key
- **THEN** no popup opens
- **AND** the cursor moves to the first non-blank of the next line, as that key does in any buffer

#### Scenario: Cursor on a non-diagram code fence

- **WHEN** the cursor is on a fenced block that is not a diagram and the user presses the preview key
- **THEN** no popup opens
- **AND** the key's ordinary editor action is performed

### Requirement: Availability

The preview key SHALL be available in R only. It SHALL NOT be bound in S, where the block's source
is already on screen and editable.

#### Scenario: Pressed in S

- **WHEN** the window is showing S and the user presses the preview key
- **THEN** nothing preview-related happens

#### Scenario: Not a markdown buffer

- **WHEN** the buffer is not one the plugin manages
- **THEN** the preview key is not bound and the key behaves normally

### Requirement: The popup lays the block out against a budget of its own

The popup SHALL lay the block out against a column budget of its own, chosen per kind, and the
budget SHALL be no smaller than the window's, so that the popup never holds less of the block than
the window did.

For a diagram the budget SHALL begin at the largest the engine accepts, because the engine may
discard the columns of a diagram that do not fit, and discarded columns cannot be recovered by
scrolling. The budget SHALL remain at that value until the reader zooms it down, as the zoom
requirement describes.
For a table the budget SHALL be the popup's own inner width, floored at the window's, because the
engine wraps a cell that does not fit rather than discarding it. A table's budget SHALL NOT be
changed by zooming.

Where the popup's budget is larger than the window's, the popup SHALL hold columns that the window's
rendering clipped.

#### Scenario: A window narrower than the cap

- **WHEN** the window is narrower than the preview cap and the block is wider than the window's budget
- **THEN** the popup lays the block out against a budget larger than the window's
- **AND** columns that the window's rendering clipped are present

#### Scenario: A diagram wider than the popup

- **WHEN** a diagram is wider than the popup's own inner width and the popup opens for it
- **THEN** the popup's content is laid out at the engine's largest budget
- **AND** the popup holds the diagram's columns beyond its own inner width, reachable by scrolling

#### Scenario: A window as wide as the cap

- **WHEN** the window is as wide as the preview cap, so a table's budget cannot exceed the window's
- **THEN** the popup's content holds no less of the block than the window showed
- **AND** the part of the block wider than the popup is reachable by scrolling within it

#### Scenario: A table wider than the window

- **WHEN** a table is wider than the window's column budget and the popup opens for it
- **THEN** the popup shows the table's rows and columns laid out against the popup's inner width

#### Scenario: A block that fits the window

- **WHEN** the block is no wider than the window's column budget and the popup opens for it
- **THEN** the popup shows the block whole

### Requirement: A preview is repeatable

Previewing the same unchanged block twice SHALL show the same arrangement. Where the popup differs
from the window, the difference SHALL be attributable to the popup's width budget and not to the
render being a separate run.

#### Scenario: The same block previewed twice

- **WHEN** the user opens the preview for a block, closes it, and opens it again with the block unchanged
- **THEN** the popup shows the same content both times

#### Scenario: A diagram with subgraphs

- **WHEN** the block is a diagram containing subgraphs, including a composite state in a state diagram
- **THEN** the popup's arrangement is stable across runs
- **AND** any difference from the window's rendering is explained by the popup's width, not by the run

### Requirement: The popup is a reading surface

The popup's content SHALL be ordinary buffer content, so that the editor's own scrolling, searching
and yanking operate on it. Modification SHALL be refused, and the popup SHALL NOT be a listed
buffer.

Where a graphic is placed over the popup, the artwork SHALL remain the popup's content: it is what
a search and a yank act on, and the graphic covers it without changing the buffer.

#### Scenario: Scrolling a block larger than the popup

- **WHEN** the block is taller or wider than the popup and no graphic is placed over it
- **THEN** the popup's content can be scrolled to reach the rest of it
- **AND** no line is soft-wrapped, so a row of artwork stays on one row

#### Scenario: A graphic popup does not scroll

- **WHEN** a graphic is placed over the popup
- **THEN** the wheel, the vertical scroll keys and the configured sideways scroll keys do nothing,
  because a repaint that a scroll causes removes the image from the cells it covers on the
  cell-attached transport
- **AND** every other key, including the close key, keeps its meaning

#### Scenario: Modification is refused

- **WHEN** an editing command is issued while the popup has focus
- **THEN** the block's content is unchanged
- **AND** the source buffer is unchanged

### Requirement: The popup is not adopted as a window of R

A floating window SHALL NOT be treated as a split of R. The plugin's rule that a window appearing
with R's rendered buffer is a split of R and is given a rendered buffer of its own SHALL exclude
floating windows, because `nvim_open_win` fires `WinEnter` for a new float before swapping its own
buffer in, so at that moment the float still holds the buffer it was opened over. The rule is
general rather than preview-specific: any float opened over R is excluded.

#### Scenario: The preview's popup over R

- **WHEN** the preview key opens the popup while R is showing
- **THEN** the popup shows the block's rendering
- **AND** the plugin holds no window state for the popup
- **AND** closing the popup leaves the window underneath in R

#### Scenario: A float opened over R by anything else

- **WHEN** a floating window is opened over R showing a buffer of its own
- **THEN** the float still shows that buffer
- **AND** the plugin holds no window state for it
- **AND** the window showing R is unchanged

### Requirement: Popup geometry

The popup SHALL be centred and SHALL be sized to fit its content, capped at a configurable fraction
of the editor's columns and lines. The cap SHALL default to 90% in each dimension.

#### Scenario: A small block

- **WHEN** the block is smaller than the cap
- **THEN** the popup is no larger than the block needs
- **AND** it is centred in the editor

#### Scenario: A block larger than the cap

- **WHEN** the block is larger than the cap in either dimension
- **THEN** the popup is capped in that dimension
- **AND** the rest of the block is reachable by scrolling

### Requirement: Closing the preview

The preview key, `q` and `Esc` SHALL close the popup. Closing SHALL leave the window underneath
exactly as it was — same buffer, same cursor position, same scroll position — so that opening and
closing a preview is not observable in the document view.

#### Scenario: The same key closes it

- **WHEN** the popup is open and the user presses the preview key
- **THEN** the popup closes

#### Scenario: `q` or `Esc` closes it

- **WHEN** the popup is open and the user presses `q` or `Esc`
- **THEN** the popup closes

#### Scenario: The view underneath is untouched

- **WHEN** the user opens a preview and then closes it
- **THEN** the window shows the same buffer it showed before
- **AND** the cursor is on the same line
- **AND** the window is scrolled to the same position
- **AND** the window is still in R

#### Scenario: The popup does not outlive its window

- **WHEN** the popup is closed, by any route
- **THEN** its buffer is discarded rather than left in the buffer list

### Requirement: Preview failure

When the block cannot be rendered, the popup SHALL NOT open empty or partial, and the failure SHALL
be reported.

#### Scenario: The engine cannot be executed

- **WHEN** the preview key is pressed and the render engine cannot be executed
- **THEN** no popup is opened
- **AND** a diagnostic is reported

#### Scenario: A diagram that the engine cannot draw

- **WHEN** the popup is opened for a `mermaid` fence whose source the engine cannot render as a diagram
- **THEN** the popup shows what the engine produced for that block, as R shows it inline

### Requirement: Zooming a diagram

While a diagram's popup is open, the zoom keys SHALL re-lay the diagram out at a different column
budget. Zooming out SHALL ask for the popup's own inner width, so that the whole diagram is on
screen at once; zooming in SHALL ask for the engine's largest budget, restoring the layout the
popup opened with. Both keys SHALL be configurable and SHALL default to `+` and `-`.

A reader SHALL never be shown a diagram with columns discarded. Zooming out SHALL lay the diagram
out whole: at the popup's inner width where the engine can, and otherwise at the narrowest budget
at which the engine lays it out whole, so that a diagram whose narrowest whole layout is still
wider than the popup is nonetheless shown narrower than it opened. Where the diagram is already
laid out at its narrowest whole budget, or already fits the popup's inner width, zooming out SHALL
leave it as it was.

Zooming SHALL apply to diagrams only. In a table's popup the zoom keys SHALL be bound and SHALL do
nothing. Zooming SHALL change the popup's content and SHALL NOT change the popup's window.

The popup SHALL make its zoom state visible, so that a diagram laid out at a reduced budget is
distinguishable from one that is simply that wide.

#### Scenario: Zooming out a diagram too wide for the popup

- **WHEN** the popup shows a diagram wider than its inner width, the engine can lay that diagram out
  whole within the popup's inner width, and the user zooms out
- **THEN** the diagram is laid out within the popup's inner width
- **AND** the whole diagram is reachable without scrolling sideways
- **AND** no participant, node, label or note that the previous layout held is missing

#### Scenario: Zooming out a diagram whose narrowest whole layout exceeds the popup

- **WHEN** the engine cannot lay the diagram out whole within the popup's inner width, but can lay
  it out whole at a budget narrower than the one in force, and the user zooms out
- **THEN** the diagram is laid out at that narrowest whole budget
- **AND** no column of the diagram is lost
- **AND** the diagram is narrower than it was before the zoom

#### Scenario: Zooming out a diagram already at its narrowest

- **WHEN** the diagram is already laid out at the narrowest budget at which the engine lays it out
  whole and the user zooms out
- **THEN** the popup's content is unchanged
- **AND** no column of the diagram is lost

#### Scenario: Zooming out a diagram that already fits the popup

- **WHEN** the popup shows a diagram no wider than its inner width and the user zooms out
- **THEN** the popup's content is unchanged

#### Scenario: Zooming back in

- **WHEN** the user zooms out and then zooms in
- **THEN** the diagram is laid out at the engine's largest budget again
- **AND** its content is what the popup showed when it opened

#### Scenario: The window does not move

- **WHEN** the user zooms a diagram
- **THEN** the popup's window keeps its size and position
- **AND** only its content changes

#### Scenario: A table's popup

- **WHEN** the popup shows a table and the user presses either zoom key
- **THEN** the table's content is unchanged
- **AND** the popup stays open

#### Scenario: Configured zoom keys

- **WHEN** the user sets the zoom keys to other mappings and presses them in a diagram's popup
- **THEN** the diagram is re-laid out, and the default keys no longer zoom

#### Scenario: The zoom state is visible

- **WHEN** a diagram is laid out at a reduced budget
- **THEN** the popup identifies itself as zoomed
- **AND** a reader can tell the diagram's current width from its width when unzoomed

### Requirement: Scrolling the popup sideways

The popup SHALL bind one key that scrolls its content left and one that scrolls it right, each moving
the view by a fixed number of display columns per press, so that either key can be held down to
scroll continuously. Both keys SHALL be configurable and SHALL default to `<C-h>` and `<C-l>`.

The step SHALL be the horizontal step of the reader's `'mousescroll'` option, so that the keys and a
horizontal wheel move the view by the same amount.

The keys SHALL be bound in every popup, for a table as well as a diagram: a table is laid out at a
budget floored at the window's, so it can be wider than the popup too, and its columns past the edge
are reached the same way.

Scrolling SHALL move the view, SHALL NOT change the popup's content, and SHALL NOT reach the engine.

#### Scenario: Scrolling a block wider than the popup

- **WHEN** the popup holds a block wider than its own inner width and the user presses the
  scroll-right key
- **THEN** the view moves right by the horizontal step of `'mousescroll'`
- **AND** the popup's content is unchanged
- **AND** no engine is spawned

#### Scenario: Repeated presses

- **WHEN** the user presses the scroll-right key twice
- **THEN** the view has moved twice the step

#### Scenario: The left edge

- **WHEN** the view is at the left edge and the user presses the scroll-left key
- **THEN** the view stays at the left edge

#### Scenario: A table's popup

- **WHEN** the popup shows a table wider than the popup's inner width and the user presses a scroll
  key
- **THEN** the view moves

#### Scenario: Configured scroll keys

- **WHEN** the user sets the scroll keys to other mappings and presses them
- **THEN** those keys scroll the popup
- **AND** the default keys no longer scroll it
