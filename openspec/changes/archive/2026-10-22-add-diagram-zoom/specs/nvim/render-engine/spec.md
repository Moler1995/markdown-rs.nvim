# Spec Delta

## ADDED Requirements

### Requirement: Diagrams are laid out to fit rather than clipped

Where the engine can arrange a mermaid diagram to fit within the requested width, it SHALL arrange
it to fit, and SHALL NOT discard any of the diagram's content to do so. Discarding columns SHALL
be a last resort, taken only for a diagram that cannot be arranged to fit at all. Arranging a
diagram to fit MAY make it taller.

A diagram SHALL NOT be arranged to fit when no width is requested, and SHALL NOT be arranged to
fit when it already fits the requested width, so that a diagram's layout depends only on its
source and the requested width.

#### Scenario: A sequence diagram wider than the requested width

- **WHEN** a sequence diagram whose natural width exceeds the requested width is rendered
- **THEN** every emitted display line fits the requested width
- **AND** every participant, message label, note and block frame present at the natural width is
  still present in the output

#### Scenario: A sequence diagram that already fits the requested width

- **WHEN** a sequence diagram whose natural width is within the requested width is rendered
- **THEN** its layout is the same as it would be with no width requested

#### Scenario: A flowchart that can be arranged to fit

- **WHEN** a flowchart whose natural width exceeds the requested width can be arranged within it
- **THEN** every emitted display line fits the requested width
- **AND** no node or edge label is dropped from the output

#### Scenario: A diagram that cannot be arranged to fit

- **WHEN** no arrangement of a diagram fits within the requested width
- **THEN** the engine still emits display lines that fit the requested width
- **AND** the width it reports for the layout exceeds the requested width

#### Scenario: A diagram rendered with no width

- **WHEN** a diagram is rendered with no width requested
- **THEN** it is laid out at its natural width, unarranged

### Requirement: Reported layout width

The engine SHALL report, for each document it emits, the width of the widest display line it laid
the document out at, measured in display columns and taken before any truncation. A caller SHALL
be able to determine from that value alone whether the engine discarded anything: truncation
occurred exactly when the reported layout width exceeds the requested width.

The reported layout width SHALL cover the whole document, not diagrams alone, so that a caller
does not need to know which block was truncated to find out that one was.

#### Scenario: A document that fits

- **WHEN** a document is rendered whose every display line fits the requested width
- **THEN** the reported layout width is the width of its widest display line
- **AND** it does not exceed the requested width

#### Scenario: A document that is truncated

- **WHEN** a display line is truncated to meet the requested width
- **THEN** the reported layout width exceeds the requested width
- **AND** the widest emitted display line does not exceed the requested width

#### Scenario: A document whose widest line is not a diagram

- **WHEN** the widest line the engine laid out comes from prose, a table, code or a formula
- **THEN** the reported layout width reflects that line

#### Scenario: Rendering the same document twice

- **WHEN** the same document is rendered twice at the same width and theme
- **THEN** both runs report the same layout width
