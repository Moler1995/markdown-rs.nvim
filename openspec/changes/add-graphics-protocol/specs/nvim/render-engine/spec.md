# Spec Delta

## ADDED Requirements

### Requirement: Drawn images report the file they came from

The document SHALL report, for every image reference the engine drew as artwork, the 0-indexed
source line of the reference and the local path the reference resolved to.

The reported path SHALL be the path the engine read the image from: absolute when the base
directory is absolute, and never a URL or a `data:` URI. The same reference rendered twice at the
same width and options SHALL report the same path.

The list SHALL be ordered by source line, and SHALL be omitted entirely when it is empty, so a
document with no drawn image is byte-identical to what it was before this field existed.

A reference the engine rendered as alt text — a URL, a `data:` URI, a missing or unreadable file,
an unsupported format, or a decoding limit exceeded — SHALL NOT be reported.

#### Scenario: A drawn image

- **WHEN** a document references a readable PNG
- **THEN** the document reports the reference's source line and the file's path along with the
  artwork

#### Scenario: A relative destination

- **WHEN** a document with base directory `/docs` references `img/pic.png`
- **THEN** the reported path is `/docs/img/pic.png`

#### Scenario: A reference that could not be drawn

- **WHEN** the reference names an SVG file and the engine emits its alt text
- **THEN** the document reports no path for it

#### Scenario: A document with no images

- **WHEN** a document contains no image reference
- **THEN** the document carries no image list at all

#### Scenario: Repeated rendering

- **WHEN** the same document is rendered twice with the same width and options
- **THEN** both documents report the same paths in the same order
