# Spec Delta

## ADDED Requirements

### Requirement: A label is wrapped to the space it occupies

Where the engine arranges a diagram to fit a requested width, a message label SHALL be wrapped to
the width available to it in the arrangement the engine emits, not to a target derived from the
diagram's overall width. A label that has room for two display rows SHALL NOT be broken across six.

Wrapping a label to the space available to it SHALL NOT widen the arrangement: the width the
engine reports for it SHALL be no greater than the width it would report had the label been wrapped
to the diagram-wide target.

#### Scenario: A label in a space wider than the wrap target

- **WHEN** a sequence diagram is arranged to fit a requested width, and a message label's space in
  the emitted arrangement is wider than the wrap target the arrangement used
- **THEN** that label is wrapped to the space it occupies
- **AND** it occupies no more display rows than that space requires

#### Scenario: The arrangement does not widen

- **WHEN** a sequence diagram is arranged to fit a requested width
- **THEN** the layout width the engine reports for it is no greater than the width of the same
  arrangement with every message label wrapped to the diagram-wide target

#### Scenario: No content is lost

- **WHEN** a sequence diagram is arranged to fit a requested width
- **THEN** every participant, message, note and block frame present at the natural width is still
  present in the output
- **AND** no label's text is shortened, abbreviated or truncated to make it fit

### Requirement: Among arrangements that fit, the shortest is emitted

Where more than one arrangement of a diagram fits the requested width, the engine SHALL emit one
with the fewest display rows. Where more than one arrangement has the same number of display rows,
the choice among them SHALL be the same on every run.

#### Scenario: A width with several fitting arrangements

- **WHEN** a diagram has more than one arrangement whose widest display line is within the
  requested width
- **THEN** the emitted arrangement has no more display rows than any of the others

#### Scenario: No arrangement fits

- **WHEN** no arrangement of a diagram fits the requested width
- **THEN** the engine emits the narrowest arrangement it can reach
- **AND** it reports a layout width above the requested width

#### Scenario: The natural arrangement fits

- **WHEN** a diagram's natural arrangement is within the requested width
- **THEN** the engine emits that arrangement, with no wrapping applied

#### Scenario: Repeated rendering

- **WHEN** a diagram with several fitting arrangements is rendered twice at the same width
- **THEN** both runs emit byte-identical output
