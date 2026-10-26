# nvim/graphics Specification

## Purpose

Drawing an image through the terminal's own graphics protocol instead of as character cells: how
the plugin decides the terminal can do it and which transport it speaks, how it places an image
over the preview popup, what happens when the terminal is resized, and what happens when it cannot
be done at all.

## Requirements

### Requirement: Graphics is used only where it is known to work

The plugin SHALL place images through a terminal graphics protocol only when all of these hold:
the editor exposes the API that writes raw bytes to the terminal host, a terminal UI is attached,
the `graphics` option is not `'off'`, the process environment identifies the terminal as a client
known to implement one of the two supported protocols, and no terminal multiplexer is in the way.

Identification SHALL be synchronous, from the process environment alone. The transport SHALL be
chosen in this order, so that a terminal implementing both gets the one that can animate:

1. `TERM_PROGRAM` naming WezTerm, or `WEZTERM_PANE` — the OSC 1337 inline-image protocol.
2. `TERM_PROGRAM` naming iTerm2, or `LC_TERMINAL` naming it — the OSC 1337 protocol.
3. `KITTY_WINDOW_ID`, a `TERM` naming kitty, or a `TERM_PROGRAM`/`TERM` naming Ghostty — the Kitty
   graphics protocol.
4. Anything else — no graphics.

Under `tmux` or `screen` — `TMUX` set, or a `TERM` starting with either name — the plugin SHALL
treat the terminal as one that cannot draw, whatever else the environment says.

The plugin SHALL NOT send a query to the terminal, SHALL NOT delay opening a popup while deciding,
and SHALL NOT place an image it has not identified a terminal for. The `graphics` option SHALL
default to `'auto'`, and `'off'` SHALL mean no graphics sequence is ever written, whatever the
terminal.

#### Scenario: WezTerm

- **WHEN** the editor exposes the raw-bytes API, a UI is attached, and `TERM_PROGRAM` is `WezTerm`
- **THEN** an image's popup is drawn with the OSC 1337 protocol

#### Scenario: iTerm2

- **WHEN** `TERM_PROGRAM` is `iTerm.app`, or `LC_TERMINAL` is `iTerm2`
- **THEN** an image's popup is drawn with the OSC 1337 protocol

#### Scenario: kitty or Ghostty

- **WHEN** the environment names kitty or Ghostty
- **THEN** an image's popup is drawn with the Kitty graphics protocol

#### Scenario: An unknown terminal

- **WHEN** the environment names no client the plugin knows
- **THEN** no graphics sequence is written and every popup is the artwork

#### Scenario: A multiplexer

- **WHEN** the editor runs under `tmux` or `screen`
- **THEN** no graphics sequence is written and every popup is the artwork

#### Scenario: An editor without the raw-bytes API

- **WHEN** the editor does not expose the raw-bytes API
- **THEN** no graphics sequence is written and every popup is the artwork

#### Scenario: Turned off

- **WHEN** `graphics` is `'off'`
- **THEN** no graphics sequence is written even in a terminal that supports it

### Requirement: The popup shows the image file over its interior

When an image's popup is drawn with graphics, the plugin SHALL show the file the reference names,
placed so that its first cell is the popup's first interior cell and its extent is the popup's
interior in cells. The plugin SHALL NOT re-encode or resample the image.

The transport SHALL be the one the terminal was identified for: a protocol whose terminal reads
the file from a path SHALL be sent the path, and a protocol that carries the file's bytes SHALL be
sent those bytes. A size limit SHALL apply only to the transport that carries the bytes; the one
that carries a path has no such cost and SHALL NOT inherit it.

The popup's window SHALL be the same window, at the same size and position, that the artwork
would have opened, and its buffer content SHALL remain the artwork. The editor's cursor SHALL end
up where it was before the placement.

A file the plugin cannot read, one larger than the size it is willing to send, or one whose bytes
the terminal cannot draw SHALL leave the artwork visible and SHALL NOT be reported as an error or
a warning.

#### Scenario: A still image

- **WHEN** a still image's popup is drawn with graphics
- **THEN** the file is shown at the terminal's resolution, filling the popup's interior
- **AND** no row or column of the artwork is left visible beside or below it, so the file is
  stretched to the box the artwork was laid out in where the two aspect ratios differ

#### Scenario: The popup's content is unchanged

- **WHEN** a graphic is placed over a popup
- **THEN** the popup's buffer still holds the artwork the engine produced
- **AND** the popup's window has the size and position it would have had

#### Scenario: A destination that is not a local file

- **WHEN** the reference names a URL or a `data:` URI
- **THEN** no graphics sequence is written
- **AND** the popup shows the artwork or alt text the engine produced

#### Scenario: A file that cannot be read

- **WHEN** the destination does not resolve to a readable file
- **THEN** no graphics sequence is written
- **AND** no warning is shown

### Requirement: The image appears whole

The placement SHALL NOT be followed by any editor painting that removes part of it. Every cell
the image covers SHALL be the image's when the placement returns, so the reader never sees holes
where the editor's own content landed.

#### Scenario: Opening over existing content

- **WHEN** the popup opens over a window full of text
- **THEN** the image is whole the moment it appears
- **AND** no cell inside it shows the text underneath

### Requirement: Playback belongs to whichever layer can play the file

Where the terminal can play an animated file, it SHALL own playback: the plugin SHALL request no
animation frames for the popup, SHALL start no timer, SHALL swap no lines, and SHALL NOT bind the
pause and frame-step keys, whose ordinary actions the reader keeps.

Where the terminal draws images but cannot play a file, a popup whose image is animated SHALL keep
the artwork and its playback: no graphic SHALL be placed over it, and the rules of
`nvim/block-preview` SHALL apply unchanged. An image with no animation to play SHALL still be
drawn natively on that transport.

Where the popup is not drawn with graphics at all, the animation requirements of
`nvim/block-preview` apply unchanged.

#### Scenario: An animated image on a playing transport

- **WHEN** an animated file's popup is drawn with a transport that plays files
- **THEN** the terminal plays the file's own frames with the file's own delays
- **AND** no playback timer exists and no pause or frame-step key is bound

#### Scenario: An animated image on a transport that cannot play files

- **WHEN** an animated image's popup is on a terminal that draws images but cannot play a file
- **THEN** no graphic is placed
- **AND** the artwork's own playback runs, with its pause and frame-step keys

#### Scenario: A still image on a transport that cannot play files

- **WHEN** a still image's popup is on such a terminal
- **THEN** the file is drawn natively over the popup

### Requirement: A graphic does not outlive its popup, and survives a resize

Closing the popup SHALL leave no part of the image on screen. Opening a new preview SHALL leave
exactly one image on screen, the new one.

Removal SHALL be achieved by whatever the transport offers: a placement that lives in the cells it
covers is removed by the repaint that closing causes, and a placement that survives cell rewrites
SHALL be deleted explicitly, naming only the identifier the plugin assigned, before the popup
closes.

A resize of the editor SHALL restore the image: the popup SHALL place its image again, at its
current position, without reading the file again. The placement SHALL happen once per burst of
resize events rather than once per event.

A full redraw the plugin did not cause — `:redraw!`, or `CTRL-L` — may clear the image until the
next resize; the help SHALL say which transports that affects.

#### Scenario: Closing the popup

- **WHEN** a popup drawn with graphics is closed
- **THEN** the image is gone from the screen
- **AND** nothing the plugin did not place is removed

#### Scenario: A second preview

- **WHEN** a preview is closed and another image's preview is opened
- **THEN** exactly one image is on screen after the second preview is placed

#### Scenario: Resizing the terminal

- **WHEN** the editor is resized while a graphic popup is open
- **THEN** the popup is still open and its image is shown again at the popup's current position

### Requirement: Falling back leaves the artwork exactly as it was

Where graphics is off, unavailable, not identified, not used for this image, or not used because
the image animates and the transport cannot play it, the popup SHALL be the text artwork, on the
same terms as before this capability existed, with the pause and frame-step keys it already had.

The absence of graphics SHALL NOT change any other behavior: no popup SHALL open later or
differently, no key SHALL change meaning, and no warning SHALL be emitted.

#### Scenario: A terminal without the protocol

- **WHEN** the terminal is not known to implement either protocol
- **THEN** every popup is the artwork
- **AND** the popup's keys are exactly what they were

### Requirement: What graphics is doing is reportable

`:checkhealth md-render` SHALL report which transport images are drawn with and, when they are
not, which condition decided it: the option, the editor's API, the missing UI, the terminal's
identity, or the multiplexer. The entry SHALL NOT fail the report: the plugin works without it.

#### Scenario: Health with graphics unavailable

- **WHEN** health is run in a terminal that cannot draw images
- **THEN** the report says graphics is off
- **AND** it names the condition that turned it off
- **AND** the report is still healthy
