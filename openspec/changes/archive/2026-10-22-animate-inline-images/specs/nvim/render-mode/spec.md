# Spec Delta

## ADDED Requirements

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
