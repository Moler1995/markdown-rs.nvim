# Spec Delta

## MODIFIED Requirements

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
