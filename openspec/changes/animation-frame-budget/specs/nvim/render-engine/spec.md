# Spec Delta

## MODIFIED Requirements

### Requirement: Animation frames on request

The engine SHALL accept an explicit request to emit animation frames. For an animated GIF or an
animated WebP image, when that request is made, the document SHALL carry, in addition to the
artwork lines that show the first frame, the range of display lines the artwork occupies and, for
every emitted frame, its delay in milliseconds and its display lines.

The document's own display lines SHALL remain the first frame, so a reader that ignores the
additional data sees exactly the document it saw before. Without the request, the engine SHALL emit
no animation data for any image.

Animation data SHALL be bounded by a kept-frame budget of 256 frames. An animation within that
budget SHALL be emitted in full. An animation with more frames SHALL be reduced to a deterministic
subset of at most 256 frames, in file order, that begins with the image's first frame, rather than
being refused. Each emitted frame's delay SHALL account for the frames the subset skips, so the
loop's total duration is preserved. The subset SHALL be identical on every run of the same image
at the same bounds.

Animation data SHALL also be bounded by the cumulative decoded pixel count of the frames, at most 128
megapixels, and by the number of frames decoded, at most 4,096. An animation that exceeds either of
those bounds SHALL render as its first frame with no animation data at all.

A refused animation SHALL be distinguishable from a still image: the document SHALL name the source
line of each reference whose animation the bounds refused, and SHALL omit that list when nothing was
refused. An animation reduced to a subset SHALL NOT be named as refused, because it does animate.

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

#### Scenario: An animation over the kept-frame budget

- **WHEN** an animated image has more than 256 frames and its total decoded pixels are within the
  pixel budget
- **THEN** the document carries at most 256 frames
- **AND** the first carried frame is the image's first frame
- **AND** the sum of the carried delays equals the sum of the image's recorded delays
- **AND** the reference is not listed as a refused animation

#### Scenario: A sampled animation repeats identically

- **WHEN** the same over-budget animation is rendered twice at the same width and options
- **THEN** both renders carry the same frames with the same delays

#### Scenario: An animation over the bounds

- **WHEN** an animated image has more than 4,096 frames or would decode more than 128 megapixels in
  total
- **THEN** it is drawn as its first frame
- **AND** no animation data is present
- **AND** its source line is listed as a refused animation

#### Scenario: An animation over the pixel budget

- **WHEN** an animated image would decode more than 128 megapixels in total
- **THEN** it is drawn as its first frame
- **AND** no animation data is present
- **AND** its source line is listed as a refused animation

#### Scenario: An animation over the decoded-frame ceiling

- **WHEN** an animated image has more than 4,096 frames
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
