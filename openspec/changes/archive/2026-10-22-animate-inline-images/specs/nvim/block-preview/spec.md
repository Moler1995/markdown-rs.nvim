# Spec Delta

## ADDED Requirements

### Requirement: The preview key opens an image

While R is showing and the cursor is on an image's artwork, the preview key SHALL open a popup
showing that image alone, on the same terms as the popup already opens for a diagram or a table.
The popup SHALL be laid out at its own width and height, so the image is scaled to the popup rather
than to the window, and it SHALL NOT be enlarged past its natural size.

An image the engine cannot draw SHALL still open a popup, showing the reference's alt text.

#### Scenario: Cursor on an image

- **WHEN** the cursor is on a rendered image and the user presses the preview key
- **THEN** a popup opens showing that image alone

#### Scenario: A small image

- **WHEN** the image is smaller than the popup
- **THEN** it is shown at its natural size

#### Scenario: Alt text instead of artwork

- **WHEN** the reference names an SVG file and the cursor is on its alt text
- **THEN** a popup opens showing that alt text

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
