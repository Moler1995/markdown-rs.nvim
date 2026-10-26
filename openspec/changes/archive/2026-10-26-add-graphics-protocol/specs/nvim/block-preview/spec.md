# Spec Delta

## MODIFIED Requirements

### Requirement: The preview key opens an image

While R is showing and the cursor is on an image's artwork, the preview key SHALL open a popup
showing that image alone, on the same terms as the popup already opens for a diagram or a table.
The popup SHALL be laid out at its own width and height, so the image is scaled to the popup rather
than to the window, and it SHALL NOT be enlarged past its natural size.

An image the engine cannot draw SHALL still open a popup, showing the reference's alt text.

Where the terminal can draw images, the popup SHALL show the image file instead of the artwork:
the same window, opened at the same size and position, with the file placed over its interior by
the terminal. A reference that does not resolve to a readable local file SHALL still open the
artwork's popup.

#### Scenario: Cursor on an image

- **WHEN** the cursor is on a rendered image and the user presses the preview key
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
