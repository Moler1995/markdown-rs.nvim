# Spec Delta

## MODIFIED Requirements

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
