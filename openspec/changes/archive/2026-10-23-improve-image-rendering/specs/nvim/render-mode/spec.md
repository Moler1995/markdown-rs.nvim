# Spec Delta

## MODIFIED Requirements

### Requirement: Image rendering mode

The plugin SHALL expose an `image_mode` option with the values `auto`, `braille`, `quads`, `blocks`,
`ascii` and `off`. The selected mode SHALL be passed to the engine with every render.

- `auto` SHALL select `braille` when `'termguicolors'` is enabled in the editor and `ascii` when it
  is not.
- `braille`, `quads`, `blocks` and `ascii` SHALL select that encoding regardless of the editor's
  options.
- `off` SHALL render an image reference as its alt text, exactly as the plugin did before image
  rendering existed.

The option SHALL default to `auto`.

The plugin SHALL expose palette, background and dithering options, all passed to the engine with
every render:

- `image_palette` SHALL accept `auto`, `theme`, `adaptive` and `full`, and SHALL default to `auto`.
  `auto` SHALL select `full` for the braille and ASCII encodings, where a cell carries one colour,
  and `adaptive` for the half-block and quadrant encodings, where a cell carries a colour pair.
- `image_background` SHALL accept `terminal`, `theme` or a `#rrggbb` colour string, and SHALL default
  to `terminal`. `terminal` SHALL leave transparent pixels to the terminal's background, as before;
  the other values SHALL be used to composite partly transparent pixels.
- `image_dither` SHALL accept `auto`, `true` and `false`, and SHALL default to `auto`. `auto` SHALL
  enable dithering for the braille encoding, and for the ASCII encoding when the palette is not
  `full`, and SHALL disable it for the half-block and quadrant encodings.

The plugin SHALL expose `image_min_rows`, defaulting to 0, and `image_sharpen`, defaulting to
`false`. Zero SHALL mean an image is never enlarged; a positive value SHALL be passed to the engine
as the minimum number of display rows an image is enlarged to reach.

Every option above SHALL form part of the render cache key, so changing one SHALL produce a new
render rather than reusing an older one.

#### Scenario: Default mode in a truecolor editor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is enabled
- **THEN** a supported image is rendered in the braille encoding

#### Scenario: Default mode without truecolor

- **WHEN** `image_mode` is `auto` and `'termguicolors'` is disabled
- **THEN** a supported image is rendered in the ASCII encoding

#### Scenario: The mode is chosen explicitly

- **WHEN** `image_mode` is `quads` and `'termguicolors'` is disabled
- **THEN** the quadrant encoding is used anyway

#### Scenario: Image rendering turned off

- **WHEN** `image_mode` is `off`
- **THEN** the reference appears as its alt text
- **AND** no artwork is produced for it

#### Scenario: The palette follows the encoding

- **WHEN** `image_palette` is `auto` and the encoding is `braille`
- **THEN** the engine is asked for the full palette
- **AND** when the encoding is `quads`, the engine is asked for the adaptive palette instead

#### Scenario: A changed option re-renders

- **WHEN** the user changes `image_palette`, `image_background`, `image_dither`, `image_min_rows` or
  `image_sharpen` while the document is shown
- **THEN** the next render uses the new value rather than a cached rendering

#### Scenario: A named background

- **WHEN** `image_background` is set to a `#rrggbb` colour
- **THEN** that colour is passed to the engine and partly transparent images blend into it
