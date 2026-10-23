-- Turning the wire format's style table into highlight groups.
--
-- The engine deduplicates styles across the whole document, so a document has
-- a handful of distinct styles however many spans it has. Each one becomes one
-- `nvim_set_hl` group, named after a hash of the style itself — which means a
-- second render of the same document, or a render of a different document with
-- the same theme, reuses the groups already defined instead of redefining them
-- (redefining invalidates every window and forces a redraw).

local M = {}

--- Group name per style key, so the same style is defined once per session.
M.cache = {}

--- The group laid on top of a line's span styling for a link the engine laid
--- into it — a mermaid node named by a `click` directive.
---
--- It sets only an attribute, never a colour, so it merges with whatever style
--- the artwork has underneath: the node keeps the theme's colour and gains an
--- underline saying it can be followed. Linking to `Underlined` instead would
--- repaint the run in the link colour, which on diagram artwork means a node
--- that no longer matches its neighbours.
---
--- `default` leaves the name to the user: a colourscheme or config that defines
--- `MdRenderLink` itself is not overwritten.
M.link_group = 'MdRenderLink'
vim.api.nvim_set_hl(0, M.link_group, { underline = true, default = true })

--- The sixteen system colours of the xterm 256-colour palette.
---
--- These are the conventional values, not the terminal's actual ones. A style
--- naming an indexed colour is asking for slot N of a palette the engine
--- cannot see; these are the values that palette holds unless the terminal has
--- been reconfigured, which is the best answer available without asking the
--- terminal.
local SYSTEM = {
  { 0x00, 0x00, 0x00 },
  { 0x80, 0x00, 0x00 },
  { 0x00, 0x80, 0x00 },
  { 0x80, 0x80, 0x00 },
  { 0x00, 0x00, 0x80 },
  { 0x80, 0x00, 0x80 },
  { 0x00, 0x80, 0x80 },
  { 0xc0, 0xc0, 0xc0 },
  { 0x80, 0x80, 0x80 },
  { 0xff, 0x00, 0x00 },
  { 0x00, 0xff, 0x00 },
  { 0xff, 0xff, 0x00 },
  { 0x00, 0x00, 0xff },
  { 0xff, 0x00, 0xff },
  { 0x00, 0xff, 0xff },
  { 0xff, 0xff, 0xff },
}

--- The RGB value of xterm 256-colour index `n`.
local function indexed_to_hex(n)
  local r, g, b
  if n < 16 then
    r, g, b = SYSTEM[n + 1][1], SYSTEM[n + 1][2], SYSTEM[n + 1][3]
  elseif n < 232 then
    -- A 6x6x6 cube. Each level is 0, or 55 plus 40 per step above the first.
    local i = n - 16
    local function level(v)
      return v == 0 and 0 or 55 + v * 40
    end
    r, g, b = level(math.floor(i / 36)), level(math.floor(i / 6) % 6), level(i % 6)
  else
    -- A 24-step greyscale ramp starting at 8 and stepping by 10.
    r = 8 + (n - 232) * 10
    g, b = r, r
  end
  return string.format('#%02x%02x%02x', r, g, b)
end

--- A wire colour as something `nvim_set_hl` accepts, or nil for "unset".
---
--- The wire format has four forms — `#rrggbb`, a lowercase colour name,
--- `indexed:N`, and null — and `nvim_set_hl` takes the first two directly.
--- The indexed form has to be resolved here, because a group's colour cannot
--- be "slot 12 of whatever palette you have".
local function to_hl_color(value)
  if value == nil then
    return nil
  end
  if type(value) == 'number' then
    return value
  end
  local index = value:match('^indexed:(%d+)$')
  if index then
    return indexed_to_hex(tonumber(index))
  end
  return value
end

--- The highlight group for `style`, defining it if this is the first sighting.
---
--- `index` is the wire style-table index, used only to keep the generated name
--- readable; the cache is keyed on the style itself, so two documents that
--- share a style share a group.
function M.group(style, index)
  style = style or {}
  local key = table.concat({
    tostring(style.fg),
    tostring(style.bg),
    style.bold and 'b' or '',
    style.italic and 'i' or '',
    style.underline and 'u' or '',
    style.strikethrough and 's' or '',
    style.dim and 'd' or '',
    style.reverse and 'r' or '',
  }, '|')

  local name = M.cache[key]
  if name then
    return name
  end

  name = string.format('MdRender_%d_%s', index or 0, vim.fn.sha256(key):sub(1, 8))
  vim.api.nvim_set_hl(0, name, {
    fg = to_hl_color(style.fg),
    bg = to_hl_color(style.bg),
    bold = style.bold or nil,
    italic = style.italic or nil,
    underline = style.underline or nil,
    strikethrough = style.strikethrough or nil,
    dim = style.dim or nil,
    reverse = style.reverse or nil,
  })
  M.cache[key] = name
  return name
end

--- Forget every group this session defined.
---
--- Only for tests and for `:MdRenderReset`; nothing in the normal path needs
--- it, because a style always maps to the same group.
function M.forget()
  for _, name in pairs(M.cache) do
    pcall(vim.api.nvim_set_hl, 0, name, {})
  end
  M.cache = {}
end

return M
