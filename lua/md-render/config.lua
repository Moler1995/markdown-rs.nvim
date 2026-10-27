-- Configuration for md-render.nvim.
--
-- One table of defaults, one `setup` that deep-merges over them. Nothing here
-- reaches the engine directly; this module only says what the user wants, and
-- the modules that act on it read from here.

local M = {}

M.defaults = {
  -- Path to the engine binary. When set, it is used as given and must be
  -- executable: a path that is missing or cannot run is an error, not a reason
  -- to search elsewhere, so a typo cannot silently run a different engine.
  --
  -- `nil` (or the empty string) means "resolve it", in this order:
  --
  --   1. `md-render` on `PATH`;
  --   2. `<plugin-root>/bin/md-render[.exe]`, a build copied next to the
  --      checkout;
  --   3. `<stdpath('data')>/md-render/md-render[.exe]`, where a downloaded
  --      release goes.
  --
  -- The repository's `bin/` stays ahead of the data directory so a fresh local
  -- build is not shadowed by an older download. See `engine.resolve`, and
  -- `:checkhealth md-render` for which step matched.
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

  -- What R shows for an inline image.
  --
  --   'auto'  A card — the picture's own box, with its name and size — on every
  --           terminal, and the picture itself painted over the card where the
  --           terminal can draw one. The card is what the cursor, the search and
  --           the yank see; the paint is over the card's cells and is redone
  --           after a scroll, so a reader who scrolls away and back gets the
  --           picture again rather than a hole.
  --   'card'  The card alone, never painted over. For a terminal that can draw
  --           but a reader who would rather see where the picture sits than the
  --           picture itself.
  --   'art'   The artwork `image_mode` selects, exactly as before this option
  --           existed, and nothing painted over it.
  --
  -- Where no picture is painted over the card — every terminal that cannot
  -- draw, and `card` on one that can — the card is three rows tall. Its width
  -- is still the picture's own, so the same picture keeps its footprint, and a
  -- flat height keeps a page of images from towering over the prose. Where a
  -- picture is painted over it the card keeps the artwork's whole box, because
  -- the picture is measured for exactly those cells.
  --
  -- `image_mode = 'off'` outranks `auto` and `card`: a reader who asked for no
  -- picture inline gets no card either, and the reference stays its alt text.
  --
  -- This changes R only. The preview popup shows the image itself at
  -- `image_mode`'s encoding whatever this is set to, and whether the terminal
  -- can draw is not consulted here at all — a card is a card on every terminal,
  -- and only the painting over it asks. An unknown value is handed to the
  -- engine as the encoding and refused there, the same way an unknown
  -- `image_mode` is.
  image_inline = 'auto',

  -- The largest file painted inline as it is, instead of downscaled first.
  --
  -- An inline picture is normally the engine's thumbnail: the picture's own
  -- cells, scaled to about 640 pixels across, re-encoded, and cached. That
  -- bounds what every settle sends back to the terminal, at the cost of
  -- sharpness on a large window. A file no larger than this is sent as it is —
  -- its own bytes, at its own resolution — because a file this small costs less
  -- to send than the encode it would replace. Only a still PNG or JPEG is sent
  -- this way: a GIF, a WebP or an APNG would play itself inline, and a format
  -- the terminal cannot decode would draw nothing.
  --
  -- Zero always asks for the thumbnail. The value is also capped by the 8 MiB
  -- the OSC 1337 transport can carry; the Kitty transport sends a path and is
  -- not affected either way.
  image_inline_original_bytes = 2097152,

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
  --
  -- Long animations still step: one over the engine's 256-frame budget is
  -- sampled down to a bounded subset, every frame's delay folded so the loop
  -- keeps its duration, and no warning is shown. Only an animation that would
  -- decode past the engine's 4,096-frame ceiling or its 64-megapixel budget is
  -- refused, drawn as its first frame, and reported when the step key is
  -- pressed.
  image_animation = true,

  -- Whether an image's preview popup shows the file itself, drawn by the
  -- terminal, instead of the artwork.
  --
  --   'auto'  Use the terminal's graphics protocol when the process environment
  --           names a client known to implement one, and the editor can write
  --           raw bytes to it. WezTerm and iTerm2 get the OSC 1337 inline-image
  --           protocol, whose terminals also play an animated GIF, APNG or WebP
  --           from the file itself; kitty and Ghostty get the Kitty graphics
  --           protocol, which reads the file from its path but has no playback,
  --           so an animated image there keeps its character-art animation.
  --   'off'   Never write a graphics sequence. Every popup is the artwork, in
  --           any terminal, exactly as it was before this option existed.
  --
  -- This changes only what the popup paints, never what the engine draws: the
  -- popup's window, its size and its position are the artwork's, and the
  -- artwork stays the buffer's content. A terminal the plugin cannot identify,
  -- a multiplexer, a URL or `data:` reference, or a file it cannot read leaves
  -- the artwork visible and warns about nothing.
  --
  -- :checkhealth md-render reports which transport is in use, or which
  -- condition turned graphics off.
  graphics = 'auto',

  -- Buffer-local keymaps set in R. Set a value to `false` to leave the key
  -- alone. `toggle` swaps between R and S; `preview` opens the block popup and
  -- belongs to R only, since in S the cursor is already on the block's source.
  -- The insert-entry keys are fixed and are not configurable, because they are
  -- the mode's escape hatch rather than a convenience.
  --
  -- `follow` is set in both states, because a link is followed from wherever
  -- the reader happens to be: in S it resolves the link under the cursor, and
  -- in R it first follows a link the engine laid into the rendered line — a
  -- mermaid node named by a `click` directive — and otherwise maps the display
  -- row back to its source line and resolves the link there. It shadows `gf`
  -- in a managed buffer, and hands the key back to Vim when the cursor is not
  -- on a link, so a bare path still opens the way it always did. Set it to
  -- `gd` or any other key if that suits your habits better.
  --
  -- `follow_tab` does the same thing in a new tab instead, leaving the
  -- reading view where it is. A URL or an anchor still acts in place — there
  -- is no file to put in a tab — and a filetype the plugin does not manage
  -- opens unchanged. The jumplist is not involved: the new tab is the way
  -- back, with `:tabclose` or `g<Tab>`. `gF` is the default because it sits
  -- next to `gf` and does not interfere with Vim's `<C-w>` prefix.
  --
  -- A link the engine laid into a diagram is also underlined, so a reader can
  -- see the node is followable without knowing the key first. The hint is tied
  -- to these keys: set both `follow` and `follow_tab` to `false` and the
  -- underline goes away with them, since there would be nothing left to
  -- follow.
  --
  -- An image shown as a card or as its alt text names the keys instead: the
  -- row ends with `<CR>/gx open image`, built from whichever of `preview` and
  -- `open_image` are bound, so the reference reads as something a key opens.
  -- With both set to `false` there is no hint, the character artwork is never
  -- hinted, and neither is a card the terminal paints a picture over. The hint
  -- is virtual text drawn over the row, not an underline: what it marks can be
  -- a band of surface cells with no text in it at all.
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
    follow_tab = 'gF',
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

  -- Milliseconds to coalesce the events that move or repaint the viewport —
  -- scrolling, resizing, moving the cursor — before the inline pictures are
  -- painted again. Every one of those events wipes what was painted, and the
  -- next paint has to wait until the rectangle has stopped moving; what shows
  -- meanwhile is the picture's card.
  --
  -- Its own knob, and much shorter than `resize_debounce`, because the two
  -- waits are not the same cost. Waiting on a re-render leaves the old picture
  -- on screen; waiting on a placement leaves a card where the picture should
  -- be, which is visible as a flicker on every scroll. One frame is enough to
  -- fold a burst into one paint, and short enough that the picture is back
  -- before the reader misses it. Lower it further to have pictures follow a
  -- scroll more closely; raise it on a terminal that chokes on payloads, since
  -- each paint re-sends one — and on the byte-carrying transport a block the
  -- window cuts asks the engine for a thumbnail of each new slice, which a
  -- longer wait folds together. `0` paints on the next event-loop tick, which
  -- still folds one burst into one paint.
  settle_debounce = 15,
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

--- The image encoding an inline render asks the engine for.
---
--- `image_inline` chooses between a card and the artwork; `image_mode` chooses
--- what the artwork is, so `art` is the only value that consults it, and `off`
--- is the one value that outranks the card. Both answers are values of the
--- engine's `--image-encoding`.
---
--- No branch here falls back, which is deliberate: an unknown `image_inline` is
--- returned as it stands, sent to the engine as the encoding, and refused there
--- by name — the same route an unknown `image_mode` takes today.
---
--- Whether the terminal can draw belongs to the graphics module, asked when a
--- placement is made. Nothing in this resolution needs it: a card is what every
--- terminal gets, and `graphics = 'off'` changes only whether it is painted
--- over.
function M.image_inline_encoding()
  local inline = M.options.image_inline
  if inline == 'art' then
    return M.image_encoding()
  end
  if inline == 'auto' or inline == 'card' then
    return M.options.image_mode == 'off' and 'off' or 'card'
  end
  return inline
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

--- The text that says which keys open an image, or nil when neither is bound.
---
--- Built from the keys actually bound, in the order an image reference names
--- them: the preview key first, then the open-image key. A hint for a key that
--- is not there would mislead, which is the rule the link hint already follows.
function M.image_hint_text()
  local keys = {}
  for _, key in ipairs({ M.options.keymaps.preview, M.options.keymaps.open_image }) do
    if type(key) == 'string' and key ~= '' then
      keys[#keys + 1] = key
    end
  end
  if #keys == 0 then
    return nil
  end
  return ' ' .. table.concat(keys, '/') .. ' open image'
end

--- The rows and the narrowest width a card is drawn with, and whether a
--- picture is painted over it.
---
--- A card the terminal paints over is the artwork's box, in both dimensions:
--- the picture is measured for those cells and is placed back on them, so the
--- card has to be exactly what the picture was cut for. A card that is the
--- whole of the image is a placeholder instead, and three rows is enough to
--- carry a caption and the hint — a page of images then reads as a page of
--- cards rather than as a column of towers. Its width stays the picture's;
--- the floor is only what the hint needs to fit inside the box.
---
--- The third answer is whether the picture goes over the card. It is what
--- decides the caption: a picture may be transparent, and a transparent pixel
--- shows whatever is under it, so a caption under one is read as part of the
--- picture. A card nothing is painted over keeps its caption, because the
--- caption is then all the reader gets.
---
--- `painting` is the graphics module's answer, passed in rather than asked
--- for: this module knows nothing about terminals, and the caller that places
--- pictures is the one that can see one.
local function card_shape(painting)
  if M.image_inline_encoding() ~= 'card' then
    return 0, 0, false
  end
  if M.options.image_inline == 'auto' and painting then
    return 0, 0, true
  end
  local text = M.image_hint_text()
  return 3, text and vim.fn.strdisplaywidth(text) + 2 or 0, false
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
---
--- `painting` is whether the terminal can draw a picture over a card; it
--- decides the card's shape and whether that card keeps its caption, and a
--- caller with no card to shape — the preview popup — passes nothing and gets
--- the artwork's own box, captioned.
function M.image_options(painting)
  local background = M.options.image_background
  local card_rows, card_min_width, painted = card_shape(painting)
  return {
    palette = M.image_palette(),
    background = background,
    dither = M.options.image_dither,
    min_rows = M.options.image_min_rows,
    sharpen = M.options.image_sharpen,
    paper = background == 'terminal' and page_background() or nil,
    card_rows = card_rows,
    card_min_width = card_min_width,
    card_caption = not painted,
  }
end

return M
