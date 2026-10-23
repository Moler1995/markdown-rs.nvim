# Spec Delta

## Purpose

Turns a markdown document into a width-bounded sequence of styled display lines that an editor can
place into a buffer, with every display line traceable back to the source line it came from.

## ADDED Requirements

### Requirement: Rendering input

The engine SHALL accept a markdown document supplied either as a file path or on standard input, a
display width in terminal columns, and a theme or palette selection. The width SHALL be explicit:
the engine SHALL NOT substitute a default, because wrapping decisions cannot be undone by the
caller once made.

#### Scenario: Document read from a file path

- **WHEN** the engine is invoked with a path to an existing markdown file
- **THEN** it renders that file's contents

#### Scenario: Document read from standard input

- **WHEN** the engine is invoked with no file path and markdown is piped to standard input
- **THEN** it renders the piped contents

#### Scenario: Width omitted

- **WHEN** the engine is invoked without a display width
- **THEN** it exits non-zero with a diagnostic on standard error
- **AND** writes nothing to standard output

### Requirement: Width-bounded display lines

Every display line the engine emits SHALL fit within the requested width. This SHALL hold for
prose, fenced code, tables, diagrams and formulas alike.

#### Scenario: Paragraph wider than the window

- **WHEN** a paragraph wider than the requested width is rendered
- **THEN** it is broken across multiple display lines
- **AND** no display line is wider than the requested width

#### Scenario: Code line wider than the window

- **WHEN** a fenced code block contains a line wider than the requested width
- **THEN** that line is broken across multiple display lines rather than emitted whole

#### Scenario: Diagram that does not fit

- **WHEN** a mermaid diagram cannot be laid out within the requested width
- **THEN** the engine still emits display lines that fit the requested width

### Requirement: Styled spans

Each display line SHALL be emitted as an ordered sequence of spans, and each span SHALL carry its
text together with the complete visual style that applies to it, expressed as colors the caller can
apply directly without consulting the source document.

#### Scenario: Syntax-highlighted code block

- **WHEN** a fenced code block with a recognized language is rendered
- **THEN** the spans covering that block carry per-token colors rather than one uniform color

#### Scenario: Consecutive characters sharing a style

- **WHEN** consecutive characters on a display line carry the same style
- **THEN** they are merged into a single span

#### Scenario: Heading emphasis

- **WHEN** a heading is rendered
- **THEN** its display line carries the heading's own color and weight, distinct from body text

### Requirement: Source anchoring

Every display line SHALL be reported together with the source line it was derived from. Display
lines with no source counterpart — table borders, diagram artwork, blank spacers — SHALL be marked
synthetic rather than attributed to an arbitrary source line. The engine SHALL also emit the
reverse mapping, from source line to display line, so a caller can place a cursor given a source
position.

#### Scenario: Source line wrapped across several display lines

- **WHEN** one source line is wrapped across several display lines
- **THEN** all of those display lines report that same source line

#### Scenario: Diagram occupying several source lines

- **WHEN** a mermaid block is rendered as text art
- **THEN** the artwork's display lines are marked synthetic or attributed to the block's opening
  fence line
- **AND** the reverse mapping for every source line in the block resolves to the first display line
  of the artwork

#### Scenario: Reverse mapping covers the whole document

- **WHEN** the caller looks up the display line for any source line of the document
- **THEN** it receives a display line index within the emitted range

### Requirement: Deterministic output

Rendering the same document at the same width with the same theme SHALL produce byte-identical
output.

#### Scenario: Repeated invocation

- **WHEN** the same document is rendered twice at the same width and theme
- **THEN** the two outputs are byte-identical

### Requirement: Failure reporting

When the engine cannot render — unreadable input, malformed arguments, an internal render error —
it SHALL exit non-zero with a diagnostic on standard error and SHALL NOT emit a partial document on
standard output.

#### Scenario: Input path does not exist

- **WHEN** the engine is given a path that does not exist
- **THEN** it exits non-zero with a diagnostic on standard error
- **AND** standard output is empty

#### Scenario: Document fails to render

- **WHEN** rendering aborts partway through a document
- **THEN** the engine exits non-zero
- **AND** standard output contains no truncated document that a caller could mistake for complete
