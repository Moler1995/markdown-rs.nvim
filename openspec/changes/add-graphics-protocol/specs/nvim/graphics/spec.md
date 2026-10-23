# Spec Delta

## Purpose

Drawing an image through the terminal's own graphics protocol instead of as character cells: how
the plugin decides the terminal can do it, how it places an image over the preview popup, and what
happens when it cannot.

## ADDED Requirements

### Requirement: Graphics is used only where it is known to work

The plugin SHALL place images through the terminal's graphics protocol only when all of these hold:
the editor exposes the API that writes raw bytes to the terminal host, a terminal UI is attached
to it, the `graphics` option is not `'off'`, and the terminal is identified as a client known to
implement the protocol.

Identification SHALL come from the process environment's `TERM_PROGRAM` where that names a known
client, and otherwise from the terminal's reply to a version query, whose answer SHALL be cached
for the session. Until the terminal has been identified the plugin SHALL NOT send a graphics
sequence. The plugin SHALL NOT block the editor, nor delay opening a popup, while waiting for a
reply: a popup opened before the answer arrives SHALL show the artwork.

The `graphics` option SHALL default to `'auto'`, and `'off'` SHALL mean no graphics sequence is
ever written, whatever the terminal.

#### Scenario: A known terminal

- **WHEN** the editor exposes the raw-bytes API and `TERM_PROGRAM` names a terminal known to
  implement the protocol
- **THEN** an image's popup is drawn with graphics

#### Scenario: A terminal identified only by its reply

- **WHEN** `TERM_PROGRAM` names nothing the plugin knows and the terminal answers the version query
  with a known client's name
- **THEN** identification is cached for the session
- **AND** images opened before the answer arrived were shown as artwork

#### Scenario: An editor without the raw-bytes API

- **WHEN** the editor does not expose the raw-bytes API
- **THEN** no graphics sequence is written and every popup is the artwork

#### Scenario: Turned off

- **WHEN** `graphics` is `'off'`
- **THEN** no graphics sequence is written even in a terminal that supports it

### Requirement: The image file is placed over the popup

When an image's popup is drawn with graphics, the plugin SHALL place the file the engine reported
over the popup's interior: the image's top-left corner SHALL sit on the popup's first interior
cell, and its size SHALL be the popup's inner width in cells by its inner height in cells,
preserving the image's aspect ratio within that box.

The image placed SHALL be the file the reference resolved to, read by the terminal, rather than a
re-encoding of it. The popup's window SHALL be the same window, at the same size and position,
that the artwork would have opened. The placement SHALL NOT move the editor's cursor or the
terminal cursor, and SHALL NOT change the popup's buffer content.

An animated file SHALL be animated by the terminal; the plugin SHALL start no timer for a graphic.

#### Scenario: A still image

- **WHEN** a still image's popup is drawn with graphics
- **THEN** the file is shown at native resolution, scaled into the popup's interior
- **AND** no playback timer exists

#### Scenario: An animated image

- **WHEN** an animated image's popup is drawn with graphics
- **THEN** the terminal plays the file's own frames with the file's own delays
- **AND** the plugin runs no timer and swaps no frames

#### Scenario: An image larger than the popup

- **WHEN** the image is larger than the popup's interior in either dimension
- **THEN** it is scaled down to fit, preserving its aspect ratio

#### Scenario: The popup's content is unchanged

- **WHEN** a graphic is placed over a popup
- **THEN** the popup's buffer still holds the artwork the engine produced
- **AND** the popup's window has the size and position it would have had

### Requirement: A graphic is removed when the popup goes

Closing the popup SHALL leave no part of the image on screen. Replacing the popup's image with a
different one SHALL leave exactly one image on screen, the new one.

Removal SHALL name the identifier the plugin assigned to the placement, and SHALL NOT delete
images the plugin did not place.

#### Scenario: Closing the popup

- **WHEN** a popup drawn with graphics is closed
- **THEN** the image is gone from the screen
- **AND** nothing else drawn by another program is removed

#### Scenario: A second preview

- **WHEN** a preview is closed and another image's preview is opened
- **THEN** exactly one image is on screen after the second preview is placed

### Requirement: Falling back leaves the artwork exactly as it was

Where graphics is off, unavailable, or not used, the popup SHALL be the text artwork, on the same
terms as before this capability existed, with the pause and frame-step keys it already had.

Where the engine reported no path for the image — a URL, a `data:` URI, a missing or unreadable
file, an unsupported format — the popup SHALL likewise be the artwork or the alt text the engine
produced, and the absence of a graphic SHALL NOT be reported as an error or a warning.

The absence of graphics SHALL NOT change any other behavior: no popup SHALL open later or
differently, and no key SHALL change meaning.

#### Scenario: A terminal without the protocol

- **WHEN** the terminal is not known to implement the protocol
- **THEN** every popup is the artwork
- **AND** the popup's keys are exactly what they were

#### Scenario: An image the engine could not draw

- **WHEN** the popup shows a reference whose alt text the engine emitted
- **THEN** no graphics sequence is written
- **AND** no warning is shown

### Requirement: What graphics is doing is reportable

`:checkhealth md-render` SHALL report whether images are drawn with graphics and, when they are
not, which condition decided it: the option, the editor's API, or the terminal's identity.

#### Scenario: Health with graphics unavailable

- **WHEN** health is run in a terminal that cannot draw images
- **THEN** the report says graphics is off
- **AND** it names the condition that turned it off
