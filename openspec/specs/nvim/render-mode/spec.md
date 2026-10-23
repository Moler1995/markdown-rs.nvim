# nvim/render-mode Specification

## Purpose
The plugin's reading view for a markdown document: how document images are shown inline in R, how
an animated image is stepped by hand, how an image is opened with the system application, and what
happens when an image cannot be drawn at all.

## Requirements

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

### Requirement: Images stay still until asked to move

In R an image SHALL be drawn on its first frame and SHALL NOT change on its own.

The plugin SHALL expose a frame-step key, configurable and defaulting to `<C-n>`. Pressing it with
the cursor on an animated image SHALL advance that image one frame, wrapping from the last frame to
the first. Pressing it where the cursor is not on an animated image SHALL perform that key's
ordinary editor action instead.

Where the image is an animation the engine refused for size, the key SHALL NOT perform its ordinary
editor action: the image stays on its first frame and the plugin SHALL report that the image is too
large to animate. The report SHALL be given once per render of the document.

The plugin SHALL expose an `image_animation` option, defaulting to on. With it off, no animation
data is requested and the frame-step key behaves like any other key everywhere.

Stepping SHALL NOT move the cursor, and the display rows of the artwork SHALL keep mapping to the
source line of the image reference.

The first press on an image whose frames are not yet in memory SHALL fetch them, and SHALL show a
one-line status hint at the bottom of the editor while the fetch is in flight, cleared when the
answer arrives. A press that arrives before that answer SHALL NOT start a second fetch: it SHALL be
remembered, and the image SHALL advance one frame for each remembered press when the frames land.

#### Scenario: Cursor on an animated image

- **WHEN** R shows an animated image and the user presses the frame-step key on it
- **THEN** the image shows its next frame
- **AND** the frame is drawn within the same rows as before

#### Scenario: Wrapping

- **WHEN** the last frame is showing and the user presses the frame-step key again
- **THEN** the image shows its first frame

#### Scenario: Cursor not on an image

- **WHEN** the cursor is on prose and the user presses the frame-step key
- **THEN** no frame changes
- **AND** the key performs its ordinary editor action

#### Scenario: An animation over the engine's bounds

- **WHEN** the cursor is on an image whose animation the engine refused as too large
- **AND** the user presses the frame-step key
- **THEN** the image stays on its first frame
- **AND** the key does not perform its ordinary editor action
- **AND** the plugin reports that the image is too large to animate

#### Scenario: Animation off

- **WHEN** `image_animation` is off and the user presses the frame-step key on an animated image
- **THEN** the image remains on its first frame
- **AND** the key performs its ordinary editor action

#### Scenario: A re-render

- **WHEN** the window is resized or the document is edited while an image shows a later frame
- **THEN** the image is redrawn on its first frame

#### Scenario: Pressing again while the frames are being fetched

- **WHEN** the user presses the frame-step key again before the first fetch of the frames has
  answered
- **THEN** no second fetch is started
- **AND** the press is remembered
- **AND** when the frames arrive the image advances one frame for each press received
- **AND** the cursor does not move

#### Scenario: A slow frame fetch

- **WHEN** an image's frames take long enough to decode that the picture sits still
- **THEN** the editor shows a status hint at the bottom that the frames are being decoded
- **AND** the hint is cleared when the frames arrive

### Requirement: Opening the image with the system application

The plugin SHALL expose an open-image key, configurable and defaulting to `gx`, available in R.
Pressing it with the cursor on an image's artwork SHALL open the referenced file with the operating
system's default application for that file.

A relative destination SHALL resolve against the directory of the document holding the reference,
exactly as the engine resolves it; an absolute path SHALL be used as given. The key SHALL work for
any local image file, including a format the engine cannot draw.

A destination that is not a local file SHALL NOT be fetched or opened, and the plugin SHALL report
that it cannot open it. A local file that does not exist SHALL likewise be reported, and no
application SHALL be launched. Where the cursor is not on an image, the key SHALL perform its
ordinary editor action.

#### Scenario: A local image

- **WHEN** the cursor is on a rendered image and the user presses the open-image key
- **THEN** the image file is opened with the system default application

#### Scenario: A relative destination

- **WHEN** the reference is `![](images/a.png)` and the document is `/docs/readme.md`
- **THEN** `/docs/images/a.png` is opened

#### Scenario: An image the engine cannot draw

- **WHEN** the reference names an SVG file, whose alt text is shown instead of artwork
- **AND** the cursor is on that alt text
- **THEN** the SVG file is opened with the system default application

#### Scenario: A remote destination

- **WHEN** the reference is an `http` or `https` URL
- **THEN** nothing is fetched or opened
- **AND** the plugin reports that the image cannot be opened

#### Scenario: A missing file

- **WHEN** the referenced local file does not exist
- **THEN** no application is launched
- **AND** the plugin reports that the image cannot be opened

#### Scenario: Cursor not on an image

- **WHEN** the cursor is on prose and the user presses the open-image key
- **THEN** no image is opened
- **AND** the key performs its ordinary editor action

### Requirement: State on open

Opening a markdown file SHALL show the rendered state (R). Files that are not markdown SHALL be
unaffected: no rendered state exists for them and no rendering is attempted.

#### Scenario: Opening a markdown file

- **WHEN** the user opens a `.md` file
- **THEN** the window shows rendered content rather than raw markdown

#### Scenario: Opening a non-markdown file

- **WHEN** the user opens a file whose type is not markdown
- **THEN** the window shows the file normally
- **AND** no rendering process is started

#### Scenario: Rendered content is not yet available

- **WHEN** a markdown file is opened and rendering has not completed
- **THEN** the window continues to show the source
- **AND** the window shows the rendered content once rendering completes

### Requirement: Rendered state

R SHALL display the engine's output in a read-only buffer shown in the same window. The displayed
content SHALL be ordinary buffer content, so scrolling, searching and yanking operate on it with
the editor's normal mechanisms. Modification SHALL be refused.

#### Scenario: Scroll and search

- **WHEN** the user scrolls or searches while in R
- **THEN** the movement and the search operate on the displayed rendered content
- **AND** line-addressed motions such as `gg` and `G` resolve within the rendered content

#### Scenario: Modification is refused

- **WHEN** an editing command is issued while in R
- **THEN** the document is not modified
- **AND** the buffer contents are unchanged

#### Scenario: Rendered state does not outlive its window

- **WHEN** the window stops showing the rendered content
- **THEN** the rendered buffer is discarded rather than left in the buffer list

### Requirement: Source state

S SHALL display the document's source buffer in the same window, unmodified and fully editable,
with the editor's complete normal-mode vocabulary available — including undo, operators,
substitutions, and whatever language tooling attaches to the buffer.

#### Scenario: Editing in S

- **WHEN** the user edits while in S
- **THEN** the source buffer is modified as usual
- **AND** undo, operators and substitutions behave as they do for any other buffer

#### Scenario: Returning to a position

- **WHEN** the user leaves S for R and later returns to S
- **THEN** the window's cursor and scroll position in the source are restored

### Requirement: Crossing from R into S

The insert-entry keys `i`, `a`, `I`, `A`, `o` and `O` SHALL switch from R to S, place the cursor at
the source line corresponding to the display line the cursor was on, and enter the corresponding
insert mode. A toggle mapping SHALL also switch from R to S while remaining in normal mode, so that
normal-mode editing commands can be reached without passing through insert mode.

#### Scenario: Insert from a rendered paragraph

- **WHEN** the user presses `i` with the cursor on a display line derived from source line N
- **THEN** the window shows the source
- **AND** the cursor is on source line N
- **AND** the editor is in insert mode

#### Scenario: Open a new line

- **WHEN** the user presses `o` with the cursor on a display line derived from source line N
- **THEN** the window shows the source with the cursor on source line N
- **AND** a new line is opened below it in insert mode, as `o` does in any buffer

#### Scenario: Reach normal mode directly

- **WHEN** the user presses the toggle mapping while in R
- **THEN** the window shows the source
- **AND** the editor remains in normal mode

#### Scenario: Cursor on a synthetic display line

- **WHEN** the cursor is on a display line marked synthetic — a table border or diagram artwork
- **THEN** the cursor is placed on the source line of the construct that produced it

### Requirement: Returning to R

The toggle mapping SHALL switch from S to R. Leaving insert mode SHALL NOT change state: after
`Esc`, the editor SHALL remain in S until the user asks for R.

#### Scenario: Toggle back

- **WHEN** the user presses the toggle mapping while in S
- **THEN** the window shows the rendered content

#### Scenario: Leaving insert mode does not toggle

- **WHEN** the user presses `Esc` in insert mode while in S
- **THEN** the editor is in normal mode
- **AND** the window still shows the source
- **AND** normal-mode editing commands still apply to the source buffer

### Requirement: Writing while rendered

A write issued while in R SHALL write the source buffer. Rendered content SHALL never be written to
the document's file.

#### Scenario: Write with no pending edits

- **WHEN** the user issues a write while in R and the source has not been modified
- **THEN** the file on disk is unchanged

#### Scenario: Write after editing in S

- **WHEN** the user edits in S and then issues a write while in R
- **THEN** the edit is written to the document's file
- **AND** the rendered content is not written to the file

### Requirement: Freshness

R SHALL reflect the source buffer's current contents rather than the file on disk, so unsaved edits
are rendered. R SHALL be refreshed when the window's width changes or when the source buffer
changes. Re-entering R when neither has happened SHALL reuse the previous rendering rather than
rendering again.

#### Scenario: Unsaved edits

- **WHEN** the user edits in S without writing and then returns to R
- **THEN** the rendered content reflects the edit

#### Scenario: Window width changes

- **WHEN** the window is resized while in R
- **THEN** the rendered content is produced again at the new width

#### Scenario: Toggling without an edit

- **WHEN** the user toggles from R to S and back without editing
- **THEN** the previously rendered content is shown without a new rendering pass

### Requirement: Rendering failure

When rendering cannot be performed — the engine is unavailable, exits non-zero, or returns
unusable output — the editor SHALL remain in S and SHALL report the failure, rather than showing an
empty or partial rendered state.

#### Scenario: Engine unavailable

- **WHEN** the user opens a markdown file and the render engine cannot be executed
- **THEN** the window shows the source
- **AND** a diagnostic is reported

#### Scenario: Engine returns an error

- **WHEN** the engine exits non-zero for a document
- **THEN** the editor does not enter R for that document
- **AND** the diagnostic the engine produced is reported

### Requirement: State is per window

Each window SHALL carry its own state independently, so two windows on the same document may show
different states without interfering.

#### Scenario: Same document in two windows

- **WHEN** the same document is open in two windows and one is switched to S
- **THEN** the other window's state is unchanged

### Requirement: Following a link

The plugin SHALL expose a follow key, configurable and defaulting to `gf`, available in both R and S. With the cursor on a link, the key SHALL open its destination: a URL SHALL be handed to the operating system's URL handler, an anchor SHALL jump to the heading it names, and a local file SHALL open in the window.

A relative destination SHALL resolve against the directory of the document holding the reference. An absolute destination SHALL be used as given, whether it is written as a POSIX path beginning with `/`, a drive-letter path such as `C:/docs/a.md` or `C:\docs\a.md`, or a UNC path beginning with `\\`. A local destination that does not exist SHALL be reported, and no buffer SHALL be opened. With no link under the cursor, the key SHALL perform its ordinary editor action.

#### Scenario: A relative link

- **WHEN** the link target is `docs/guide.md` and the document is `/work/readme.md`
- **THEN** `/work/docs/guide.md` is opened

#### Scenario: An absolute POSIX path

- **WHEN** the link target is `/work/guide.md`
- **THEN** `/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute Windows drive path

- **WHEN** the link target is `C:/work/guide.md` or `C:\work\guide.md`
- **THEN** `C:/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute UNC path

- **WHEN** the link target is `\\server\share\guide.md`
- **THEN** that share path is opened
- **AND** the document's directory is not prepended

#### Scenario: A URL

- **WHEN** the link target is an `http` or `https` URL
- **THEN** the URL is handed to the operating system's URL handler
- **AND** no local path is resolved

#### Scenario: An anchor

- **WHEN** the link target is `#installation`
- **THEN** the cursor moves to the heading whose slug is `installation`

#### Scenario: A missing local file

- **WHEN** the resolved local path does not exist
- **THEN** no buffer is opened
- **AND** the plugin reports that the file does not exist

#### Scenario: No link under the cursor

- **WHEN** the cursor is on text that is not a link
- **THEN** the key performs its ordinary editor action

### Requirement: Setup and loading reach the buffer already on screen

The plugin SHALL work when sourced from `runtimepath` without calling `setup()`. `setup(opts)` SHALL apply the options and SHALL be idempotent: repeated calls SHALL NOT create duplicate autocmds, commands or keymaps.

When the plugin is sourced, or when `setup()` runs, while the current window shows a managed buffer, that buffer SHALL be attached without the user reopening the file, and the window SHALL enter R as the "State on open" requirement describes. When the plugin is loaded lazily after the `FileType` event, the buffer that triggered the load SHALL be attached the same way.

Attaching SHALL use the same checks as the `FileType` path: the buffer and window SHALL still be valid, the window SHALL still show that buffer, and a window already attached to that source SHALL not be attached a second time.

#### Scenario: The plugin is sourced with a markdown buffer on screen

- **WHEN** the plugin is added to `runtimepath` and sourced while the current window shows a markdown buffer
- **THEN** that buffer is attached without reopening the file
- **AND** the window shows R once rendering completes

#### Scenario: Setup runs with a markdown buffer on screen

- **WHEN** `require('md-render').setup{}` runs while the current window shows a markdown buffer
- **THEN** that buffer is attached
- **AND** the window shows R once rendering completes

#### Scenario: A plugin manager loads the plugin on FileType

- **WHEN** the plugin is loaded after the `FileType` event for a markdown buffer
- **THEN** the buffer that triggered the load is attached
- **AND** the first markdown file shows R without being reopened

#### Scenario: Setup is called twice

- **WHEN** `setup{}` is called twice with different options
- **THEN** no autocmd, command or buffer-local keymap is duplicated
- **AND** subsequent renders use the second set of options

#### Scenario: Setup runs before filetype detection

- **WHEN** `setup{}` runs while the current buffer has no managed filetype
- **THEN** no buffer is attached at that moment
- **AND** the later `FileType` event attaches the buffer normally
