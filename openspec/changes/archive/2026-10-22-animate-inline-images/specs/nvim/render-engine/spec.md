# Spec Delta

## ADDED Requirements

### Requirement: Animation frames on request

The engine SHALL accept an explicit request to emit animation frames. For an animated GIF or an
animated WebP image, when that request is made, the document SHALL carry, in addition to the
artwork lines that show the first frame, the range of display lines the artwork occupies and, for
every frame, its delay in milliseconds and its display lines.

The document's own display lines SHALL remain the first frame, so a reader that ignores the
additional data sees exactly the document it saw before. Without the request, the engine SHALL emit
no animation data for any image.

Animation data SHALL be bounded: at most 256 frames, and frames SHALL stop being emitted once the
total decoded pixel count of the frames exceeds 64 megapixels. An image that exceeds either bound
SHALL render as its first frame with no animation data at all.

A refused animation SHALL be distinguishable from a still image: the document SHALL name the source
line of each reference whose animation the bounds refused, and SHALL omit that list when nothing was
refused.

Every frame SHALL obey the width bound, height bound and encoding of the document, and SHALL occupy
exactly as many display lines as the first frame.

Formats other than GIF and WebP SHALL carry no animation data even when it is requested, and an
animated image of either format whose file cannot be decoded SHALL fall back as any other
unrenderable image does.

#### Scenario: Animated GIF with frames requested

- **WHEN** a document references an animated GIF and animation frames are requested
- **THEN** its display lines show the first frame
- **AND** the document carries that frame's line range and every emitted frame's delay and lines

#### Scenario: Animated WebP with frames requested

- **WHEN** a document references an animated WebP and animation frames are requested
- **THEN** the document carries its frames, on the same terms as a GIF

#### Scenario: Frames not requested

- **WHEN** a document containing an animated GIF is rendered without the request
- **THEN** the output is identical to the output of the same document before animation existed
- **AND** no animation data is present

#### Scenario: A still image

- **WHEN** a document references a PNG or JPEG and animation frames are requested
- **THEN** the image is drawn as before
- **AND** no animation data is present

#### Scenario: An animation over the bounds

- **WHEN** an animated image has more frames or more total pixels than the bounds allow
- **THEN** it is drawn as its first frame
- **AND** no animation data is present
- **AND** its source line is listed as a refused animation

#### Scenario: Every frame respects the page

- **WHEN** frames are emitted for an image
- **THEN** no line of any frame is wider than the requested width
- **AND** every frame occupies the same number of display lines as the first frame

#### Scenario: Repeated rendering

- **WHEN** a document with an animated image is rendered twice with frames requested
- **THEN** the two outputs are byte-identical
