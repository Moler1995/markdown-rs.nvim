-- Configuration for md-render.nvim.
--
-- One table of defaults, one `setup` that deep-merges over them. Nothing here
-- reaches the engine directly; this module only says what the user wants, and
-- the modules that act on it read from here.

local M = {}

M.defaults = {
  -- Path to the engine binary. `nil` means "resolve it": `md-render` on PATH
  -- first, then `<repo>/bin/md-render.exe`. See `engine.resolve`.
  engine = nil,

  -- Theme handed to the engine with `--theme`. The default matches the
  -- colorscheme the editor is configured with, so the rendered view is not a
  -- different palette from the window around it.
  theme = 'catppuccin_mocha',

  -- Filetypes whose buffers open in R. A buffer not listed here is left alone
  -- entirely — no state, no autocmds, no keymaps.
  filetypes = { 'markdown' },

  -- How images in the document are drawn.
  --
  --   'auto'    `braille` when the terminal can show 24-bit colour
  --             (`'termguicolors'`), `ascii` when it cannot. Resolved when a
  --             render is asked for, not at setup, so toggling `'termguicolors'`
  --             takes effect on the next render.
  --   'braille' Eight dots in a 2×4 grid, one colour per cell: eight times the
  --             sub-cell detail of a half block, drawn as dot density. The dots
  --             are ink on the page they sit on, so on a dark background the
  --             bright side of the picture is drawn and a white screenshot
  --             shows as light dots with its own dark features as gaps; on a
  --             light background the dark side is drawn instead. Needs a font
  --             with the braille patterns (Cascadia Mono and Segoe UI Symbol
  --             have them).
  --   'quads'   Quadrant glyphs, four sub-cells in two colours. Twice the
  --             horizontal detail of `blocks` at the same width, and only worth
  --             it with true colour and a font that draws the block elements.
  --             `image_mode = 'quads'` restores the look the plugin had before
  --             braille was the default.
  --   'blocks'  Half-block glyphs, two colours per cell. The fallback for a
  --             terminal whose font has no quadrants.
  --   'ascii'   One ASCII glyph per cell from a fixed luminance ramp. Works in
  --             any terminal, in one colour per cell.
  --   'off'     No artwork at all: every image reference reads as its alt text,
  --             which is exactly what the plugin showed before images were
  --             supported.
  --
  -- An image the engine cannot draw — a URL, a missing file, an unsupported
  -- format, one over the size limits — falls back to its alt text whatever this
  -- is set to, so no document can fail to render because of a picture.
  image_mode = 'auto',

  -- Where an image's cell colours come from.
  --
  --   'auto'      `full` for `braille` and `ascii`, where a cell carries one
  --               colour and exact colours are what makes the picture look like
  --               itself; `adaptive` for `quads` and `blocks`, where a cell
  --               carries a colour pair and a per-image palette keeps the pair
  --               coherent. Resolved with the encoding, at the same time.
  --   'theme'     The engine's fixed 64-colour cube. The colours the plugin
  --               used before this option existed.
  --   'adaptive'  Up to 64 colours cut from the image itself.
  --   'full'      The sampled colour itself, up to 4,096 styles per document;
  --               past that the engine quantises to the adaptive palette.
  --
  -- Every distinct image style becomes one highlight group in the session, and
  -- a group is never removed while the editor runs, so `full` is bounded by the
  -- engine rather than free-form.
  image_palette = 'auto',

  -- What partly transparent pixels are blended with, before quantisation.
  --
  --   'terminal'  Nothing: the terminal's own background shows through. The
  --               gentle default, and what the plugin always did.
  --   'theme'     The selected theme's background colour.
  --   '#rrggbb'   An explicit colour, for an image meant for one background.
  --
  -- A named background is what removes the hard halo around a logo with soft
  -- edges; `terminal` leaves those pixels alone instead. A named background is
  -- also the page braille inks against; with `terminal`, the editor's own
  -- `Normal` background is sent as the page, since only the editor knows it.
  image_background = 'terminal',

  -- Whether image quantisation is ordered-dithered.
  --
  --   'auto'   On for `braille`, and for `ascii` with a reduced palette; off
  --            for the two-colour encodings, where a dithered cell would
  --            speckle, and for `full`, where there is nothing to dither.
  --   true     Always dither.
  --   false    Never. `false` with `image_mode = 'quads'` and
  --            `image_palette = 'theme'` is the pre-braille output.
  image_dither = 'auto',

  -- Enlarge a small image to at least this many display rows.
  --
  -- Zero (the default) never enlarges. A positive value asks the engine for the
  -- smallest whole factor from 2 to 4 that reaches the count, by
  -- nearest-neighbour sampling and without crossing the width or height bound,
  -- so pixel art gets bigger instead of staying a thumbnail.
  image_min_rows = 0,

  -- Sharpen an image that was reduced to fit the page.
  --
  -- Applies a fixed unsharp mask after the area average, which restores some of
  -- the edge contrast a downscaled photograph loses. A natural-size or enlarged
  -- image is unchanged.
  image_sharpen = false,

  -- The most display rows one inline image may occupy.
  --
  -- The engine scales an image by a single factor, so capping the height also
  -- narrows the artwork: a 640×360 picture in a 126-column window is 72×20
  -- rather than the 126×35 the width alone would allow. The aspect ratio is
  -- preserved and the window's own height remains a hard bound, so this is a
  -- "sit inside the page" setting, not a zoom.
  --
  -- `false` removes the cap, leaving the window's text height as the only
  -- bound — the behaviour before this option existed. `nil` cannot mean that:
  -- `setup` merges with `vim.tbl_deep_extend`, where a nil value is
  -- indistinguishable from a missing key.
  --
  -- The block preview is unaffected: its popup has its own height, so the
  -- preview key still shows an image larger than the page does.
  image_max_height = 20,

  -- Whether an animated GIF or WebP is rendered with its frames.
  --
  -- The rendered view never plays by itself: it shows the first frame, and
  -- `keymaps.frame_next` steps through the rest. `true` asks the engine for the
  -- frames in the first place; `false` renders every image as its first frame
  -- with no animation data at all, and the stepping key is left alone.
  --
  -- This costs decode time and payload only for documents that contain an
  -- animated image: the engine's animation field is omitted entirely when
  -- there is nothing to animate.
  image_animation = true,

  -- Buffer-local keymaps set in R. Set a value to `false` to leave the key
  -- alone. `toggle` swaps between R and S; `preview` opens the block popup and
  -- belongs to R only, since in S the cursor is already on the block's source.
  -- The insert-entry keys are fixed and are not configurable, because they are
  -- the mode's escape hatch rather than a convenience.
  --
  -- `follow` is the one key set in both states, because a link is followed from
  -- wherever the reader happens to be: in S it resolves the link under the
  -- cursor, and in R it first follows a link the engine laid into the rendered
  -- line — a mermaid node named by a `click` directive — and otherwise maps
  -- the display row back to its source line and resolves the link there. It
  -- shadows `gf` in a managed buffer, and hands the key back to Vim when the
  -- cursor is not on a link, so a bare path still opens the way it always did.
  -- Set it to `gd` or any other key if that suits your habits better.
  --
  -- A link the engine laid into a diagram is also underlined, so a reader can
  -- see the node is followable without knowing the key first. The hint is tied
  -- to this key: set it to `false` and the underline goes away with it, since
  -- there would be nothing left to follow.
  --
  -- `zoom_in` and `zoom_out` are set in the preview popup's buffer rather than
  -- in R or S, because they act on the block the popup is showing. In a table's
  -- popup they are bound and do nothing: the engine wraps a table's cells rather
  -- than discarding them, so a table has nothing to zoom away from.
  --
  -- `scroll_left` and `scroll_right` are set there too, and for the same reason.
  -- They are the popup's sideways scrolling on one key each, because `zh` and
  -- `zl` are two keystrokes: there is no key to hold down, so a reader cannot
  -- cross a wide block by holding one. Unlike the zoom keys these do something
  -- in a table's popup, which can be wider than the popup as well.
  --
  -- `frame_next` belongs to R and to the popup's buffer. In R it steps the
  -- animated image under the cursor — paused is the default state, so one press
  -- is one frame — and off such an image the key goes back to Vim, so `<C-n>`
  -- keeps its ordinary meaning everywhere else. In the popup it steps while
  -- playback is paused.
  --
  -- `open_image` belongs to R: it resolves the image reference under the
  -- cursor — the reference's artwork, or its alt text when the engine cannot
  -- draw it — and hands the file to `vim.ui.open`. Off an image it goes back to
  -- Vim. It shadows `gx`, which means "open this with the system handler"
  -- already, so a URL or a path on prose keeps working.
  --
  -- `pause` is the popup's playback toggle, bound there only while an animated
  -- image is playing.
  keymaps = {
    toggle = '<leader>mr',
    write = '<C-s>',
    preview = '<CR>',
    follow = 'gf',
    open_image = 'gx',
    frame_next = '<C-n>',
    pause = '<Space>',
    zoom_in = '+',
    zoom_out = '-',
    scroll_left = '<C-h>',
    scroll_right = '<C-l>',
  },

  -- The preview popup's caps, as fractions of the editor's size. The popup is
  -- sized to fit the block and only then clamped, so a small diagram gets a
  -- small popup rather than a large empty frame.
  preview = {
    max_width_pct = 0.9,
    max_height_pct = 0.9,
  },

  -- Milliseconds to coalesce the events that make R stale — `WinResized` and
  -- `TextChanged`. A drag-resize fires the first per column and typing fires
  -- the second per keystroke; without coalescing, each one would spawn an
  -- engine. Only refreshes are coalesced: a toggle is applied at once, so this
  -- cannot delay or swallow one.
  resize_debounce = 100,
}

M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults and return the result.
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

--- True when `ft` is one the plugin manages.
function M.manages(ft)
  return vim.tbl_contains(M.options.filetypes, ft)
end

--- The image encoding to ask the engine for, with `auto` resolved now.
---
--- Resolved per call rather than at setup because `'termguicolors'` can be
--- toggled at any moment; a choice made once at setup would be wrong from the
--- first toggle onwards. Braille's per-cell colour is what makes it worth the
--- extra styles, so a terminal that cannot show 24-bit colour gets the ASCII
--- ramp instead.
function M.image_encoding()
  local mode = M.options.image_mode
  if mode == 'auto' then
    return vim.o.termguicolors and 'braille' or 'ascii'
  end
  return mode
end

--- The palette to ask the engine for, with `auto` resolved against the
--- encoding this render will use.
---
--- One colour per cell (`braille`, `ascii`) is what makes `full` worthwhile:
--- quantising the cell's single colour to 64 entries throws away the tone that
--- the dot pattern is reproducing. Two colours per cell (`quads`, `blocks`)
--- need the pair to be coherent, which the per-image adaptive palette gives.
function M.image_palette()
  local mode = M.options.image_palette
  if mode ~= 'auto' then
    return mode
  end
  local encoding = M.image_encoding()
  if encoding == 'braille' or encoding == 'ascii' then
    return 'full'
  end
  return 'adaptive'
end

--- `#rrggbb` of the editor's own background, or nil when it has none.
---
--- Read per call, like the encoding, because a colourscheme change moves it
--- and a braille image inked for the old page is the wrong way round on the
--- new one. `termguicolors` off leaves the colour to the terminal, which this
--- cannot see, so the engine falls back to the theme.
local function page_background()
  if not vim.o.termguicolors then
    return nil
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = 'Normal' })
  if not ok or type(hl.bg) ~= 'number' then
    return nil
  end
  return string.format('#%06x', hl.bg)
end

--- The image options in the shape the render views carry.
---
--- One place resolves `auto`, so the inline render and the preview popup cannot
--- disagree about what an option means. The engine's builder turns these into
--- flags; nothing here knows a flag name.
---
--- `paper` is only named when transparency is left to the terminal: then the
--- page an image is drawn on is the editor's own background, and braille needs
--- it to know which side of a cell is ink. A named background already says
--- what the page is, so the engine uses that instead.
function M.image_options()
  local background = M.options.image_background
  return {
    palette = M.image_palette(),
    background = background,
    dither = M.options.image_dither,
    min_rows = M.options.image_min_rows,
    sharpen = M.options.image_sharpen,
    paper = background == 'terminal' and page_background() or nil,
  }
end

return M
