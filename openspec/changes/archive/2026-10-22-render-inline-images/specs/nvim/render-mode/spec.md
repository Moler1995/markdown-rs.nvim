# Spec Delta

## ADDED Requirements

### Requirement: Image rendering mode

The plugin SHALL expose an `image_mode` option with the values `auto`, `quads`, `blocks`, `ascii`
and `off`. The selected mode SHALL be passed to the engine with every render.

- `auto` SHALL select `quads` when `'termguicolors'` is enabled in the editor and `ascii` when it
  is not.
- `quads`, `blocks` and `ascii` SHALL select that encoding regardless of the editor's options.
- `off` SHALL render an image reference as its alt text, exactly as the plugin did before image
  rendering existed.

The option SHALL default to `auto`.

#### Scenario: Default mode in a truecolor editor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is enabled
- **THEN** a supported image is rendered in the quadrant encoding

#### Scenario: Default mode without truecolor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is disabled
- **THEN** a supported image is rendered in the ASCII encoding

#### Scenario: The mode is chosen explicitly

- **WHEN** `image_mode` is `blocks` and `'termguicolors'` is disabled
- **THEN** the half-block encoding is used anyway

#### Scenario: Image rendering turned off

- **WHEN** `image_mode` is `off`
- **THEN** the reference appears as its alt text
- **AND** no artwork is produced for it

### Requirement: Image artwork follows the window's page

The plugin SHALL derive the image bounds from the window showing the document: the width bound from
the window's text width, as for every other block, and the height bound from the window's text
height. Both SHALL be passed to the engine with every render.

When the window's size changes, the document SHALL be re-rendered against the new bounds. A render
produced for one pair of bounds SHALL NOT be reused for another.

The height bound SHALL NOT change the output for a document that contains no renderable image.

#### Scenario: A tall image in a short window

- **WHEN** a document with a tall image is shown in a window 30 rows high
- **THEN** the artwork is at most 30 display rows tall

#### Scenario: The window becomes shorter

- **WHEN** the window is resized to a smaller height
- **THEN** the document is re-rendered
- **AND** the artwork is shorter than before, still preserving its aspect ratio

#### Scenario: The window becomes taller again

- **WHEN** the window is restored to its earlier size
- **THEN** the artwork is rendered as it was at that size

#### Scenario: A document with no images

- **WHEN** a document without images is rendered in two windows of the same width but different
  heights
- **THEN** the rendered document is the same

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
