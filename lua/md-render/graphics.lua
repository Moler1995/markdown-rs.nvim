-- Drawing an image with the terminal, over the preview popup.
--
-- The engine draws an image as character cells, so the picture is shown at the
-- resolution of the character grid: braille gives 2 x 4 dots per cell. A
-- terminal that implements a graphics protocol draws the file itself instead,
-- at the resolution of the display. This module owns the half of that the
-- plugin is responsible for: deciding whether the terminal can do it, reading
-- the file, and writing one escape sequence at the popup's position.
--
-- Two transports, because the two protocols are not interchangeable:
--
--   osc     The iTerm2 inline-image protocol, `ESC ] 1337 ; File=...`. The
--           whole file crosses the pty in one sequence, and the terminal decodes
--           and composites it at native resolution. WezTerm and iTerm2 also play
--           an animated GIF, APNG or WebP from those bytes with the file's own
--           delays, so an animated image needs nothing from the editor.
--   kitty   The Kitty graphics protocol, `ESC _ G ... ESC \`. A PNG is sent as
--           its path, so the terminal reads the file and almost nothing crosses
--           the pty; everything else is sent as the engine's PNG encode, because
--           the protocol's data transmission decodes PNG alone. The protocol has
--           no file playback; see `design.md` D7 for what the popup does with an
--           animated image here.
--
-- Identification is from the process environment, never a query: a query is an
-- asynchronous round trip, and its answer would name the terminal rather than
-- what it implements. Nothing here waits, so the first popup is drawn with
-- graphics if the terminal is known.
--
-- The module has no idea what a markdown image is. It is handed a reference the
-- link module already parsed, and the directory it resolves against.

local config = require('md-render.config')
local link = require('md-render.link')

local M = {}

local ESC = string.char(27)
-- The two-byte string terminator both protocols end with: `ESC \`.
local ST = string.char(92)
-- Save and restore the cursor around a placement: `DECSC` and `DECRC`.
--
-- Neovim's TUI remembers where it last put the cursor and skips a move that it
-- believes is redundant. A raw CSI move sent behind its back therefore leaves
-- the real cursor where the picture goes while the TUI still believes it is
-- where the last frame left it — and the next text it writes without a move
-- (a message echoed with `nvim_echo`, most visibly) lands on the picture
-- instead of the message line. Measured in WezTerm: the status hint appeared
-- over a card's cells and stayed there after being cleared. Restoring the
-- cursor after the placement keeps the TUI's belief true.
local SAVE_CURSOR = ESC .. '7'
local RESTORE_CURSOR = ESC .. '8'

--- The largest file an OSC placement carries, in bytes.
---
--- The whole file is base64-encoded into one sequence, so this bounds a single
--- write to the pty at about 11 MiB of text. A preview is not worth an unbounded
--- one; a file over the cap simply keeps its artwork. The Kitty transport's path
--- transmission is not capped, because the terminal reads the file itself.
M.MAX_BYTES = 8 * 1024 * 1024

--------------------------------------------------------------------------------
-- The inputs a test replaces
--------------------------------------------------------------------------------

--- The process environment. Replaced by the headless suite, which has none.
function M.env()
  return vim.env
end

--- The attached UIs, as `nvim_list_uis` returns them.
function M.uis()
  return vim.api.nvim_list_uis()
end

--- Whether the editor can write raw bytes to the terminal host.
---
--- `nvim_ui_send` is Neovim 0.12: it is the only way to put a sequence in front
--- of the terminal without going through a buffer, and a buffer would give the
--- sequence a cell, a cursor position and a place in the undo history.
function M.has_send()
  return vim.api.nvim_ui_send ~= nil
end

--- Write `bytes` to the terminal. Replaced by the headless suite.
function M.send(bytes)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(bytes)
  end
end

--------------------------------------------------------------------------------
-- Which terminal, and which transport
--------------------------------------------------------------------------------

--- True when a multiplexer sits between the editor and the terminal.
---
--- `TMUX` is set for every tmux pane; `TERM` starts with `tmux` inside tmux and
--- `screen` inside screen, which is also what a tmux configured as a screen
--- terminal reports. The two protocols would need passthrough wrapping that this
--- module does not write, so the multiplexer is treated as a terminal that
--- cannot draw rather than guessed past.
function M.multiplexed(env)
  env = env or M.env()
  if env.TMUX and env.TMUX ~= '' then
    return true
  end
  local term = env.TERM or ''
  return term:sub(1, 6) == 'screen' or term:sub(1, 4) == 'tmux'
end

--- The transport `env` names, or nil.
---
--- Only clients known to implement a protocol are accepted, and the order
--- matters: WezTerm implements the Kitty protocol too, but on Windows its
--- default ConPTY drops APC sequences (measured) while OSC 1337 reaches the
--- terminal and animates, so WezTerm is decided first and gets OSC on every
--- platform.
function M.identify(env)
  env = env or M.env()
  if M.multiplexed(env) then
    return nil
  end

  local term = env.TERM or ''
  local program = env.TERM_PROGRAM or ''

  if program == 'WezTerm' or (env.WEZTERM_PANE and env.WEZTERM_PANE ~= '') then
    return 'osc'
  end
  if program == 'iTerm.app' or env.LC_TERMINAL == 'iTerm2' then
    return 'osc'
  end
  if (env.KITTY_WINDOW_ID and env.KITTY_WINDOW_ID ~= '')
    or term == 'xterm-kitty'
    or term:match('%-kitty$')
    or program == 'ghostty'
    or term == 'xterm-ghostty'
  then
    return 'kitty'
  end
  return nil
end

--- The transport to use now, or nil and the condition that turned it off.
---
--- The conditions are checked in the order the specification names them, so the
--- first one that fails is the one reported: the editor's API, the missing UI,
--- the option, the multiplexer, the terminal's identity. Every one of them is a
--- normal state rather than an error — the popup is the artwork and nothing is
--- warned about.
function M.tier()
  if not M.has_send() then
    return nil, 'this editor has no nvim_ui_send (Neovim 0.12 or newer is required)'
  end
  if #M.uis() == 0 then
    return nil, 'no terminal UI is attached'
  end
  if config.options.graphics == 'off' then
    return nil, "graphics is 'off'"
  end
  local env = M.env()
  if M.multiplexed(env) then
    return nil, 'a terminal multiplexer is in the way (tmux or screen)'
  end
  local tier = M.identify(env)
  if not tier then
    return nil, 'the terminal is not one the plugin can identify'
  end
  return tier
end

--- True when images can be drawn by the terminal right now.
function M.available()
  return M.tier() ~= nil
end

--- What a user's name for the transport is.
function M.name(tier)
  if tier == 'osc' then
    return 'the OSC 1337 inline-image protocol'
  end
  return 'the Kitty graphics protocol'
end

--- One sentence for `:checkhealth`: the transport in use, or why not.
---
--- `available` is returned too, because the caller asks the report to stay
--- healthy either way and only the sentence differs.
function M.reason()
  local tier, why = M.tier()
  if tier then
    return string.format('images are drawn by the terminal, with %s', M.name(tier)), true
  end
  return 'images are drawn as character cells: ' .. why, false
end

--------------------------------------------------------------------------------
-- The file
--------------------------------------------------------------------------------

--- The local path `dest` names, resolved the way the engine resolves it, or nil.
---
--- `image_art::resolve` is the contract here: an `http://`, `https://` or
--- `data:` destination is not a file at all; an absolute path is used as it is;
--- anything else is joined to `base`, the document's directory, which is the
--- engine's working directory when the buffer has no name.
function M.resolve(dest, base)
  local target = vim.trim(dest or '')
  if target == '' then
    return nil
  end
  local lower = target:lower()
  if lower:sub(1, 7) == 'http://' or lower:sub(1, 8) == 'https://' or lower:sub(1, 5) == 'data:' then
    return nil
  end
  if link.is_absolute(target) then
    return target
  end
  if base and base ~= '' then
    return vim.fs.joinpath(base, target)
  end
  return target
end

--- The file at `path`, or nil. `size` is the length already stat'ed.
local function read_file(path, size)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local ok, data = pcall(vim.uv.fs_read, fd, size, 0)
  vim.uv.fs_close(fd)
  if not ok or type(data) ~= 'string' or #data ~= size then
    return nil
  end
  return data
end

--- The first eight bytes of every PNG.
local PNG_SIGNATURE = '\137PNG\r\n\26\n'

--- True when `path` is a PNG, read from its own bytes.
---
--- Kitty's transmissions name the picture's format in the sequence (`f=100`),
--- and the protocol decodes PNG alone: a path transmission of any other file is
--- answered with `EBADPNG:Not a PNG file` and nothing is drawn. A PNG is
--- therefore sent as its path, which the terminal reads at its own resolution,
--- and every other format is carried as data the engine encoded to PNG. The
--- bytes are read, not the name, because a `.png` that is not one would be
--- refused too.
function M.is_png(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then
    return false
  end
  local ok, head = pcall(vim.uv.fs_read, fd, #PNG_SIGNATURE, 0)
  vim.uv.fs_close(fd)
  return ok and type(head) == 'string' and head == PNG_SIGNATURE
end

--- How many graphics the module has described, so each gets its own id.
---
--- A Kitty placement is named by an image id and a placement id, and re-placing
--- with the same ids is a move rather than a duplicate; a new preview therefore
--- gets a new id, which is also what lets `M.remove` name exactly what it placed.
local next_id = 0

--- Everything needed to place `ref`'s file, or nil when it cannot be placed.
---
--- `tier` defaults to the transport in use. The work is done once per preview:
--- an OSC plan carries the base64 the terminal needs, so a resize re-places it
--- without touching the disk; a Kitty plan carries the path of a PNG, which the
--- terminal reads itself, and for any other file the path alone plus `encode`,
--- because the PNG it has to be carried as is sized to the popup and that is
--- not known until the window exists. A destination that is not a local file,
--- one that does not stat as a readable file, and one over `M.MAX_BYTES` all
--- mean nil — the popup keeps its artwork and says nothing.
function M.plan(ref, base, tier)
  tier = tier or M.tier()
  if not tier or not ref then
    return nil
  end
  local path = M.resolve(ref.target, base)
  if not path then
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size == 0 then
    return nil
  end
  if not vim.uv.fs_access(path, 'R') then
    return nil
  end

  local graphic = { tier = tier, path = path, size = stat.size }

  if tier == 'osc' then
    if stat.size > M.MAX_BYTES then
      return nil
    end
    local data = read_file(path, stat.size)
    if not data then
      return nil
    end
    graphic.data = vim.base64.encode(data)
  else
    next_id = next_id + 1
    graphic.id = next_id
    -- A path transmission is a PNG and nothing else; another format has to be
    -- carried as data, which means the engine's encode at the popup's own box.
    graphic.encode = not M.is_png(path)
  end

  return graphic
end

--------------------------------------------------------------------------------
-- Inline payloads: the file itself, or a thumbnail of it
--------------------------------------------------------------------------------

--- The most thumbnails held in memory at once.
---
--- Each entry is one encoded picture, sized for the block it was asked about
--- (a few hundred kilobytes at most), so the bound is about memory rather than
--- about counting anything a reader watches. A document with many distinct
--- pictures is read in a viewport's worth anyway; eviction is what keeps a long
--- session from accumulating every one it ever scrolled past.
M.THUMBNAIL_CACHE_LIMIT = 32

local thumbnails = {}
local thumbnail_order = {}

--- Run the engine's `thumbnail` mode, writing the picture to `out`.
---
--- Returns true, or false and the engine's own message. Replaced by the
--- headless suite, which has no engine and records the request instead: this is
--- the one side effect the cache exists to avoid repeating, so it is also the
--- one the checks count.
function M.run_thumbnail(exe, source, cols, rows, background, out, crop, format)
  local args = { exe, 'thumbnail', source, '--box', cols .. 'x' .. rows }
  if crop then
    args[#args + 1] = '--crop'
    args[#args + 1] = crop.top .. 'x' .. crop.rows
  end
  args[#args + 1] = '--out'
  args[#args + 1] = out
  args[#args + 1] = '--background'
  args[#args + 1] = background
  if format then
    args[#args + 1] = '--format'
    args[#args + 1] = format
  end
  local res = vim.system(args, { text = true }):wait()
  if res.code ~= 0 then
    return false, vim.trim(res.stderr or '')
  end
  return true
end

--- The identity a file is cached under.
---
--- The picture's own contents are left out: length and modification time are
--- what a file system reports for a rewrite, and stat'ing is what a paint can
--- afford.
local function file_key(path, stat)
  return table.concat({ path, stat.size, stat.mtime.sec, stat.mtime.nsec }, '\0')
end

--- The identity a thumbnail is cached under.
---
--- The box is part of it because the same picture at another size is another
--- encode, and so is the crop: the rows a half-scrolled block shows are another
--- picture, and scrolling a row is another request. The format is part of it
--- too, because the same picture as PNG and as JPEG are two encodings of it and
--- each transport can take one. The background is deliberately not: it is the
--- theme's, and a theme change re-renders the document through a path that is
--- not this cache.
local function thumbnail_key(path, stat, cols, rows, crop, format)
  local top = crop and crop.top or 0
  local height = crop and crop.rows or rows
  return file_key(path, stat) .. '\0' .. cols .. '\0' .. rows .. '\0' .. top .. '\0' .. height
    .. '\0' .. (format or 'auto')
end

--- Mark `key` as the most recently used entry of `order`.
local function touch(order, key)
  for i = #order, 1, -1 do
    if order[i] == key then
      table.remove(order, i)
      break
    end
  end
  order[#order + 1] = key
end

--- Keep `value` under `key`, dropping the least recently used past `limit`.
local function remember(store, order, limit, key, value)
  touch(order, key)
  store[key] = value
  while #order > limit do
    local oldest = table.remove(order, 1)
    store[oldest] = nil
  end
end

--- The encoded picture for `path` in a `cols` x `rows` cell box, or nil.
---
--- `background` is the `#rrggbb` the engine letterboxes with, so the placement
--- is a clean rectangle over the card rather than one with the card showing at
--- its edges. `path` should already be resolved: it is made absolute here only
--- because the cache is keyed on it, and two spellings of one file would
--- otherwise be two entries and two engine runs.
---
--- Every failure answers nil and says nothing: no engine, an unreadable file, a
--- refusal, an output that did not arrive. The card is already on screen, which
--- is exactly what a failed paint is supposed to cost.
---
--- `crop` asks for part of the box, as `{ top, rows }` in its cells: a block the
--- window cuts in half is painted with the rows still on screen, cut exactly
--- where the window's edge is, instead of squeezed or left as a card.
---
--- `format` forces the encoder, as the engine's `--format` names it: `'png'` is
--- what the Kitty transport's data transmission decodes. Nil leaves the engine's
--- own choice, which is the smallest encode the OSC clients read.
function M.thumbnail(path, cols, rows, background, crop, format)
  if not path or path == '' or not cols or not rows or cols < 1 or rows < 1 then
    return nil
  end
  if not link.is_absolute(path) then
    path = vim.fn.fnamemodify(path, ':p')
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size == 0 then
    return nil
  end

  local key = thumbnail_key(path, stat, cols, rows, crop, format)
  local cached = thumbnails[key]
  if cached then
    touch(thumbnail_order, key)
    return cached
  end

  local exe = require('md-render.engine').resolve(config.options.engine)
  if not exe then
    return nil
  end

  -- The engine writes a file rather than a stream: its stdout carries the
  -- document in every other mode, and a picture is not something a caller can
  -- tell apart from a broken document by looking at a prefix.
  local out = vim.fn.tempname()
  local ok = M.run_thumbnail(exe, path, cols, rows, background or '#000000', out, crop, format)
  local bytes
  if ok then
    local read_ok, blob = pcall(vim.fn.readblob, out)
    if read_ok and type(blob) == 'string' and #blob > 0 then
      bytes = blob
    end
  end
  pcall(vim.fn.delete, out)

  if not bytes then
    return nil
  end
  remember(thumbnails, thumbnail_order, M.THUMBNAIL_CACHE_LIMIT, key, bytes)
  return bytes
end

--- The most files kept for sending as they are, at once.
---
--- Bounded by count rather than by bytes: the option that lets a file through
--- is a byte count, so this is a handful of files of at most that size.
M.ORIGINAL_CACHE_LIMIT = 16

local originals = {}
local original_order = {}

--- True when `data` is a still picture the terminal draws by itself.
---
--- PNG and JPEG are the two formats every OSC 1337 client decodes. A PNG
--- carrying an `acTL` chunk is an APNG, which WezTerm and iTerm2 would play by
--- itself; the inline view is one still picture, so that one keeps its
--- thumbnail. Anything else is left to the engine, which decodes formats the
--- terminal may not and always writes a still frame.
local function still_picture(data)
  if data:sub(1, 8) == '\137PNG\r\n\26\n' then
    return not data:find('acTL', 1, true)
  end
  return data:sub(1, 3) == '\255\216\255'
end

--- The file's own bytes, when sending them as they are is the better trade, or
--- nil.
---
--- A file no larger than `image_inline_original_bytes` is sent unchanged: the
--- picture keeps the resolution it has, instead of the fixed-width thumbnail
--- the engine would encode, and the payload is small enough that a settle
--- re-sending it costs less than the engine run it replaces. Everything else —
--- a larger file, an animation, a nested format, a file that cannot be read —
--- answers nil and is left to `M.thumbnail`.
---
--- Cached like a thumbnail: a settle repaints blocks that did not change, and
--- re-reading the file each time would be the one cost this path exists to
--- avoid. `path` should already be resolved; it is made absolute here only
--- because the cache is keyed on it.
function M.original(path)
  if not path or path == '' then
    return nil
  end
  if not link.is_absolute(path) then
    path = vim.fn.fnamemodify(path, ':p')
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size == 0 then
    return nil
  end
  -- A value that is not a number is no reason for a paint to raise: the card is
  -- already on screen, and the thumbnail is the safe answer.
  local limit = math.min(tonumber(config.options.image_inline_original_bytes) or 0, M.MAX_BYTES)
  if limit <= 0 or stat.size > limit then
    return nil
  end

  local key = file_key(path, stat)
  local cached = originals[key]
  if cached then
    touch(original_order, key)
    return cached
  end

  local data = read_file(path, stat.size)
  if not data or not still_picture(data) then
    return nil
  end
  remember(originals, original_order, M.ORIGINAL_CACHE_LIMIT, key, data)
  return data
end

--- What is painted over a block on the byte-carrying transport.
---
--- The file itself when it is small enough to send unchanged, and otherwise the
--- thumbnail the engine encodes for exactly this box — scaled to about 640
--- pixels across and letterboxed with the card's own surface. Every failure
--- answers nil, which leaves the card.
---
--- `crop` is the part of the box the window is showing. A file's own bytes carry
--- the whole picture, so a crop always goes through the engine, which cuts the
--- rows out of the box: the terminal cannot crop what it is handed.
---
--- `format` is passed on to the engine. Nil is the byte-carrying transport's
--- choice; a caller whose terminal decodes one format names it and gets the
--- engine's encode rather than the file, because the file may be another.
function M.inline_bytes(path, cols, rows, background, crop, format)
  if not crop and not format then
    local data = M.original(path)
    if data then
      return data
    end
  end
  return M.thumbnail(path, cols, rows, background, crop, format)
end

--------------------------------------------------------------------------------
-- Where a block is
--------------------------------------------------------------------------------

--- The text of one wire line, its spans concatenated.
local function line_text(line)
  local parts = {}
  for _, span in ipairs(line.spans or {}) do
    parts[#parts + 1] = span[2]
  end
  return table.concat(parts)
end

--- The rectangle `source`'s block occupies in `doc`, as `{ top, height, width }`.
---
--- `top` is the first display row, 0-based as the document counts them, and
--- `height` is how many rows the block produced. The engine attributes every
--- row of a block to the block's source line and blocks are laid out in order,
--- so the run is found by walking out from the first matching row rather than
--- by looking for edges. `width` is the widest of those rows in display
--- columns: the paint is a rectangle, and a card's rows are not padded.
---
--- Empty rows are excluded from both ends. The engine attributes the blank
--- separator after a block to that block's source line — there is no other line
--- it could belong to — and it is not a cell of the picture: counting it would
--- make a block one row taller than the document shows, and a picture that
--- exactly fills the window could then never be placed at all.
---
--- A reference the engine could not draw has one row of alt text, which is the
--- same rectangle shape, so the caller does not have to know which it got.
function M.rect(doc, source)
  if not doc or not doc.lines or source == nil then
    return nil
  end
  local top, last, width
  for i, line in ipairs(doc.lines) do
    if line.source == source then
      local w = vim.fn.strdisplaywidth(line_text(line))
      if w > 0 then
        top = top or i - 1
        last = i - 1
        width = math.max(width or 0, w)
      end
    elseif top then
      break
    end
  end
  if not top then
    return nil
  end
  return { top = top, height = last - top + 1, width = width }
end

--- The part of `rect` the window is showing, as `{ top, rows, origin }`, or nil
--- when it shows none of it.
---
--- `top` is the first visible row, 0-based as the document counts rows; `rows`
--- is how many of the block's rows are inside the window; `origin` is the
--- screen cell that row starts at. All of the block gives `rect.top`,
--- `rect.height` and the block's own corner; a block the window cuts in half
--- gives the half that is on screen.
---
--- The visible rows are the window's own answer — `w0` and `w$` are the first
--- and last lines it displays — rather than a row count added to `topline`,
--- because `scrolloff` and a partly drawn last line are easy to get wrong by
--- arithmetic. `screenpos` then turns the row into a cell: it is the
--- independent measure of where a cell is, which is why the window's own
--- position is not used.
---
--- The cursor line and `scrolloff` are not consulted: what the window shows is
--- the question, not where the cursor is.
---
--- A window in another tab page shows nothing, and `screenpos` does not say so:
--- measured, a hidden window's first row comes back at the same row and column
--- as the current window's, because the position is computed from the layout
--- rather than from what is painted. Without the tab page being compared, a
--- settle scheduled while another tab was current put a document's picture over
--- that tab's content — `:checkhealth` opens its own tab, and the picture of the
--- document left behind covered the report.
function M.slice(win, rect)
  if not rect or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    return nil
  end
  local first, last = unpack(vim.api.nvim_win_call(win, function()
    return { vim.fn.line('w0'), vim.fn.line('w$') }
  end))
  local top = math.max(rect.top + 1, first)
  local bottom = math.min(rect.top + rect.height, last)
  if bottom < top then
    return nil
  end
  local position = vim.fn.screenpos(win, top, 1)
  if not position or position.row == 0 then
    return nil
  end
  return {
    top = top - 1,
    rows = bottom - top + 1,
    origin = { position.row - 1, position.col - 1 },
  }
end

--- The cells the window's border takes above and to the left of its text.
---
--- `nvim_win_get_position` names the window's *frame*, and a border is part of
--- the frame. Measured with `screenpos`: a float opened at `row = 5, col = 10`
--- with `border = 'rounded'` draws its first text cell at screen row 7, column
--- 12 (1-based) while the position reads `{ 5, 10 }`. Placing at the position
--- therefore covers the border's top and left and leaves the text area's last
--- column and row showing the artwork underneath — one cell of it beside and
--- below the image, which is what a hand check saw. A border with no cell in
--- that corner takes nothing: `'none'` reports the string, `'shadow'` an empty
--- string for its top-left entries.
local function frame_offset(win)
  local border = vim.api.nvim_win_get_config(win).border
  if type(border) ~= 'table' or border[1] == '' then
    return 0
  end
  return 1
end

--- Whether a floating window in `win`'s tabpage covers any cell of `rect`.
---
--- A placement is a paint over cells, and the terminal draws it wherever it was
--- told, in front of whatever is there. A float over the block hides the block,
--- so the picture has no business on screen — and on the cell-carrying
--- transport it is worse than useless: WezTerm keeps one cell grid and one
--- image layer for the whole tab, so a settle that re-placed the block after the
--- preview popup opened drew the inline picture *over* the popup's own, which is
--- what a hand check saw. Skipping the block leaves the popup's picture alone.
---
--- Every floating window counts, not only the preview: a hover, a completion
--- menu or a `:help` float takes the same cells for the same reason. The frame
--- is what a placement is a rectangle over, so the border is counted too.
---
--- Only the tabpage `win` is in is asked. A float in another tabpage is not on
--- screen with the block, and `nvim_win_get_position` would answer about a grid
--- nobody is looking at.
function M.occluded(win, rect, origin)
  if not rect or not origin or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local bottom = origin[1] + rect.height - 1
  local right = origin[2] + rect.width - 1
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    local config_other = vim.api.nvim_win_get_config(other)
    if other ~= win and config_other.relative ~= '' and not config_other.hide then
      local offset = frame_offset(other)
      local frame = vim.api.nvim_win_get_position(other)
      local top = frame[1] + offset
      local left = frame[2] + offset
      local other_bottom = top + vim.api.nvim_win_get_height(other) - 1
      local other_right = left + vim.api.nvim_win_get_width(other) - 1
      if top <= bottom and other_bottom >= origin[1]
        and left <= right and other_right >= origin[2]
      then
        return true
      end
    end
  end
  return false
end

--- The colour the picture is letterboxed with: the block's own background.
---
--- The card's first drawn row carries its surface in its span styles, which is
--- the same colour the engine will letterbox with, so the placeholder and the
--- picture agree without the plugin knowing any theme's palette. `nil` when the
--- block has no background of its own, which is every artwork encoding and none
--- of the cards.
local function block_background(doc, rect)
  local line = doc.lines[rect.top + 1]
  for _, span in ipairs(line and line.spans or {}) do
    local style = span[1] and doc.styles[span[1] + 1]
    if style and style.bg then
      return style.bg
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Inline placements
--------------------------------------------------------------------------------

--- The inline Kitty placements, per window and source line.
---
--- A Kitty placement is anchored to the cells it was drawn over and outlives
--- their being rewritten. That is what makes it have to be named when it should
--- go: a block scrolled out of the window would otherwise keep its picture over
--- whatever moved into those cells, and so would a window returning to the
--- source. An OSC placement lives in the cells themselves, which any rewrite
--- erases, so nothing is kept for it.
local inline = {}

--- The id `source`'s inline placement already has in `win`, or a new one.
---
--- Reusing the id is what makes a repaint a move rather than a second picture
--- laid over the first: the same image and placement id replaces what was
--- there, so a window that settles often costs one image, not a growing pile.
local function inline_id(win, source)
  local before = inline[win] and inline[win][source]
  if before and before.id then
    return before.id
  end
  next_id = next_id + 1
  return next_id
end

--- Take every inline placement off `win`.
---
--- Called when the window stops showing R — a toggle to S, another document
--- arriving in the window, the window closing — because the rewrite that
--- follows does not remove a Kitty placement by itself.
function M.clear(win)
  local records = inline[win]
  if not records then
    return
  end
  inline[win] = nil
  local sources = {}
  for source in pairs(records) do
    sources[#sources + 1] = source
  end
  -- Sorted so that a delete burst is in the same order whatever the hash table
  -- did, which keeps the wire and any test that pins it reproducible.
  table.sort(sources)
  for _, source in ipairs(sources) do
    M.send(M.kitty_delete(records[source].id))
  end
end

--- Paint each image block in `win`, over the rows the window shows.
---
--- `doc` is the document R is showing, `lines` its source, and `base` the
--- directory relative references resolve against. A block the window cuts in
--- half is painted over the half on screen, with the picture cut at the same
--- row: the byte-carrying transport has nothing that can crop, so the engine
--- encodes the rows (`M.thumbnail`'s crop) exactly as the artwork would have
--- shown them. The path-carrying transport hands the terminal a path and cannot
--- cut it, so there only a wholly visible block is painted; the rest keep their
--- card.
---
--- A block a floating window covers is left alone: the float is on top, and a
--- picture painted over its cells goes on top of the float. The comparison is
--- against the rows on screen, since the covered part is not being shown anyway.
---
--- One send per block, for the transport that needs one: the byte-carrying
--- transport sends the file itself while the block is wholly visible and the
--- file is small enough to send unchanged, and otherwise the engine's encode of
--- the block's box — cut to the rows on screen when the window cuts it. The
--- path-carrying one sends a PNG as its path, which the terminal reads itself,
--- and every other format as the engine's PNG encode carried as data, because
--- that transport decodes PNG alone.
--- A block that was placed and is not in this pass is deleted, because the
--- rewrite that stopped showing it does not remove a Kitty placement.
--- Nothing here waits, and nothing is reported: every failure — no transport, a
--- destination that is not a local file, an unreadable file, an engine refusal —
--- leaves the card, which is what the reader is already looking at.
function M.paint(win, doc, lines, base)
  local tier = M.tier()
  if not tier or not doc or not doc.lines or not lines then
    return
  end

  local wanted = {}
  local seen = {}
  for i = 1, #lines do
    local source = i - 1
    if not seen[source] then
      seen[source] = true
      local images = link.images(lines, source)
      if #images > 0 then
        local rect = M.rect(doc, source)
        local slice = rect and M.slice(win, rect)
        -- A floating window over the block owns those cells: the picture would
        -- be drawn in front of the float's own content, which is the popup's
        -- picture on the transport that keeps one image layer for the tab.
        if slice and M.occluded(win,
          { top = slice.top, height = slice.rows, width = rect.width },
          slice.origin) then
          slice = nil
        end
        local path = rect and M.resolve(images[1].target, base)
        local stat = path and vim.uv.fs_stat(path)
        if slice and stat and stat.type == 'file' and stat.size > 0 then
          local whole = slice.rows == rect.height
          if tier == 'osc' then
            local crop = not whole
              and { top = slice.top - rect.top, rows = slice.rows } or nil
            -- The box is the block's, not the slice's: the engine fits the
            -- picture in the whole card and then cuts the rows, so the part on
            -- screen is the same picture at the same scale, continuing above and
            -- below the window's edge. Handing it the slice's height would make
            -- the crop fall outside the box it was measured against.
            local bytes = M.inline_bytes(path, rect.width, rect.height,
              block_background(doc, rect) or '#000000', crop)
            if bytes then
              M.send(M.osc_sequence(slice.origin, rect.width, slice.rows,
                vim.base64.encode(bytes)))
            end
          elseif whole and M.is_png(path) then
            -- A PNG goes as its path, which the terminal reads at the file's
            -- own resolution and costs one write.
            local id = inline_id(win, source)
            M.send(M.kitty_path_sequence(slice.origin, rect.width, rect.height, id, path))
            wanted[source] = { id = id }
          elseif whole then
            -- Every other format goes as data: kitty decodes PNG alone, so the
            -- engine encodes the picture for this box and `f=100` says what
            -- arrived. A block the window cuts still keeps its card: the
            -- placement's box is the block's, and a path cannot be cropped.
            local bytes = M.inline_bytes(path, rect.width, rect.height,
              block_background(doc, rect) or '#000000', nil, 'png')
            if bytes then
              local id = inline_id(win, source)
              M.send(M.kitty_sequence(slice.origin, rect.width, rect.height, id, bytes))
              wanted[source] = { id = id }
            end
          end
        end
      end
    end
  end

  if tier == 'osc' then
    return
  end

  -- Whatever was placed and is not in this pass is off the screen now — the
  -- block scrolled out, lost its image, or the document no longer places one
  -- there — and a Kitty placement has to be deleted rather than overwritten.
  local previous = inline[win]
  if previous then
    local stale = {}
    for source in pairs(previous) do
      if not wanted[source] then
        stale[#stale + 1] = source
      end
    end
    table.sort(stale)
    for _, source in ipairs(stale) do
      M.send(M.kitty_delete(previous[source].id))
      previous[source] = nil
    end
  end
  inline[win] = next(wanted) == nil and nil or wanted
end

--------------------------------------------------------------------------------
-- The sequences
--------------------------------------------------------------------------------

--- The cursor move that puts the next write at 0-based `position`.
---
--- Always paired with `SAVE_CURSOR` and `RESTORE_CURSOR` by the sequences
--- below: the move exists for the placement to anchor at, not for the TUI.
local function move_to(position)
  return ESC .. '[' .. (position[1] + 1) .. ';' .. (position[2] + 1) .. 'H'
end

--- The OSC 1337 sequence showing `data` in a `cols` x `rows` cell box.
---
--- Both dimensions are given, which is what makes the file stretch to the box
--- rather than derive one side from the terminal's true cell size (measured: a
--- width-only placement overflows a popup whose cells are not exactly 2:1).
--- `preserveAspectRatio=0` is what actually makes it stretch: WezTerm defaults
--- the parameter to *true*, and with it the given height is ignored and derived
--- from the width, which left the image letterboxed and the popup's last rows
--- showing the character artwork underneath (measured by hand). The box is the
--- one the artwork was laid out in, so filling it puts the two drawings on the
--- same pixels.
--- `doNotMoveCursor=1` leaves the cursor at the placement's origin; the
--- save/restore around the whole sequence is what puts it back where the TUI
--- last left it, so the TUI's next write lands where it says it will.
function M.osc_sequence(position, cols, rows, data)
  return SAVE_CURSOR .. move_to(position)
    .. ESC .. ']1337;File=inline=1;width=' .. cols .. ';height=' .. rows
    .. ';preserveAspectRatio=0;doNotMoveCursor=1:' .. data .. ESC .. ST
    .. RESTORE_CURSOR
end

--- The largest payload one Kitty sequence may carry, in base64 characters.
---
--- The protocol's own bound on a single APC, so a larger picture travels as
--- chunks: every sequence but the last carries `m=1`, and only the first
--- carries the keys.
M.KITTY_CHUNK = 4096

--- The Kitty sequence carrying `data` as the picture and placing it as `id`.
---
--- `t=d` is a direct transmission, and its payload is base64 because the
--- sequence is binary-safe by definition. `f=100` is not optional: omitted,
--- kitty takes the payload for raw RGBA, whose width and height are zero when
--- unnamed, and refuses the whole transmission with `EINVAL:Zero width/height
--- not allowed` — measured against kitty 0.32, where a placement without it
--- draws nothing at all. PNG is the only format this transmission decodes, so
--- the caller hands it the engine's PNG encode (`M.thumbnail`'s `'png'`) rather
--- than the file, whatever the file is.
--- `C=1` is "do not move the cursor", the counterpart of `doNotMoveCursor`;
--- `q=2` suppresses both the OK and the error reply, because there is no reply
--- reader. The image id and the placement id are the same number: the sequence
--- places exactly the image it transmits, and `M.kitty_delete` can free both.
---
--- The save/restore around the sequence has the same reason as the OSC one:
--- the move is for the placement to anchor at, not for the editor to adopt. The
--- save is before the first chunk, so the chunks' own writes are covered too.
function M.kitty_sequence(position, cols, rows, id, data)
  local encoded = vim.base64.encode(data)
  local parts = {
    SAVE_CURSOR .. move_to(position)
      .. ESC .. '_Ga=T,t=d,f=100,i=' .. id .. ',p=' .. id
      .. ',c=' .. cols .. ',r=' .. rows .. ',C=1,q=2',
  }
  local first = true
  local at = 1
  repeat
    local chunk = encoded:sub(at, at + M.KITTY_CHUNK - 1)
    at = at + #chunk
    local more = at <= #encoded and 1 or 0
    if first then
      parts[#parts + 1] = ',m=' .. more .. ';' .. chunk .. ESC .. ST
      first = false
    else
      parts[#parts + 1] = ESC .. '_Gm=' .. more .. ';' .. chunk .. ESC .. ST
    end
  until at > #encoded
  parts[#parts + 1] = RESTORE_CURSOR
  return table.concat(parts)
end

--- The Kitty sequence transmitting `path` and placing it as image `id`.
---
--- `t=f` says the payload is a path rather than the file's bytes, and the path
--- itself is base64 because the payload is binary-safe by definition. The
--- terminal reads the file itself, so the picture keeps its own resolution and
--- one sequence carries it whatever its size. `f=100` is not optional here
--- either: PNG is the only format the path transmission decodes, and a path to
--- anything else is answered with `EBADPNG` — `M.is_png` is what callers check
--- before choosing this sequence instead of `M.kitty_sequence`.
--- `C=1`, `q=2`, the id and the save/restore are the data sequence's, for the
--- same reasons.
function M.kitty_path_sequence(position, cols, rows, id, path)
  return SAVE_CURSOR .. move_to(position)
    .. ESC .. '_Gi=' .. id .. ',a=T,t=f,f=100,p=' .. id
    .. ',c=' .. cols .. ',r=' .. rows .. ',C=1,q=2;'
    .. vim.base64.encode(path) .. ESC .. ST
    .. RESTORE_CURSOR
end

--- The Kitty sequence deleting image `id` and its placement.
---
--- Required, not defensive: a Kitty placement is attached to the cells it
--- covers and survives their being rewritten, so closing the popup would leave
--- it on screen. `d=I` deletes the image and every placement of it, which is
--- exactly the one `M.place` made.
function M.kitty_delete(id)
  return ESC .. '_Ga=d,d=I,i=' .. id .. ',q=2' .. ESC .. ST
end

--------------------------------------------------------------------------------
-- Placing and removing
--------------------------------------------------------------------------------

--- The colour a data-carried placement is letterboxed with.
---
--- The popup has no card to read a background from, so it uses the one its
--- artwork is drawn on: the configured image background when it names a colour,
--- and otherwise the editor's own, since that is what shows through.
local function placement_background()
  local background = config.options.image_background
  if type(background) == 'string' and background:match('^#%x%x%x%x%x%x$') then
    return background
  end
  return config.image_options().paper or '#000000'
end

--- Place `graphic` over `win`'s interior.
---
--- The box is the window's own, read now rather than stored, which is what makes
--- a resize a re-place and nothing else. The width and height are the text
--- area's already; the position has to be moved in past the frame, so that the
--- image covers exactly the cells the artwork was drawn in.
function M.place(win, graphic)
  if not graphic or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local offset = frame_offset(win)
  local frame = vim.api.nvim_win_get_position(win)
  local position = { frame[1] + offset, frame[2] + offset }
  local cols = vim.api.nvim_win_get_width(win)
  local rows = vim.api.nvim_win_get_height(win)
  if graphic.tier == 'osc' then
    M.send(M.osc_sequence(position, cols, rows, graphic.data))
  elseif graphic.encode then
    -- The data transmission carries PNG alone, so a file of another format is
    -- encoded for this box first. The box is the window's, read here rather
    -- than when the popup opened, so a resize re-encodes at the size the
    -- picture is about to take.
    local data = M.thumbnail(graphic.path, cols, rows, placement_background(), nil, 'png')
    if data then
      M.send(M.kitty_sequence(position, cols, rows, graphic.id, data))
    end
  else
    M.send(M.kitty_path_sequence(position, cols, rows, graphic.id, graphic.path))
  end
end

--- Take `graphic` off the screen, where the transport needs to be told.
---
--- An OSC placement lives in the cells it was drawn on, so the repaint that
--- closing the popup causes removes it and there is nothing to send. A Kitty
--- placement outlives cell rewrites and has to be deleted by id.
function M.remove(graphic)
  if graphic and graphic.tier == 'kitty' and graphic.id then
    M.send(M.kitty_delete(graphic.id))
  end
end

return M
