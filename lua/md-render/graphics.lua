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
--   kitty   The Kitty graphics protocol, `ESC _ G ... ESC \`. The payload is the
--           file's path, so the terminal reads the file and almost nothing
--           crosses the pty. The protocol has no file playback; see
--           `design.md` D7 for what the popup does with an animated image here.
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

--- The largest file an OSC placement carries, in bytes.
---
--- The whole file is base64-encoded into one sequence, so this bounds a single
--- write to the pty at about 11 MiB of text. A preview is not worth an unbounded
--- one; a file over the cap simply keeps its artwork. The Kitty transport sends
--- a path and is not capped.
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
--- without touching the disk; a Kitty plan carries the path, because that is
--- all its transport ever sends. A destination that is not a local file, one
--- that does not stat as a readable file, and one over `M.MAX_BYTES` on the
--- byte-carrying transport all mean nil — the popup keeps its artwork and says
--- nothing.
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
  end

  return graphic
end

--------------------------------------------------------------------------------
-- The sequences
--------------------------------------------------------------------------------

--- The cursor move that puts the next write at 0-based `position`.
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
--- `doNotMoveCursor=1` leaves the cursor where Neovim put it; the placement is a
--- paint, not a move.
function M.osc_sequence(position, cols, rows, data)
  return move_to(position)
    .. ESC .. ']1337;File=inline=1;width=' .. cols .. ';height=' .. rows
    .. ';preserveAspectRatio=0;doNotMoveCursor=1:' .. data .. ESC .. ST
end

--- The Kitty sequence transmitting `path` and placing it as image `id`.
---
--- `t=f` says the payload is a path rather than the file's bytes, and the path
--- itself is base64 because the payload is binary-safe by definition. `C=1` is
--- "do not move the cursor", the counterpart of `doNotMoveCursor`; `q=2`
--- suppresses both the OK and the error reply, because there is no reply reader.
--- The image id and the placement id are the same number: the sequence places
--- exactly the image it transmits, and `M.kitty_delete` can free both.
function M.kitty_sequence(position, cols, rows, id, path)
  return move_to(position)
    .. ESC .. '_Gi=' .. id .. ',a=T,t=f,p=' .. id
    .. ',c=' .. cols .. ',r=' .. rows .. ',C=1,q=2;'
    .. vim.base64.encode(path) .. ESC .. ST
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
  else
    M.send(M.kitty_sequence(position, cols, rows, graphic.id, graphic.path))
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
