-- The block preview: one block, re-laid out at the popup's own width.
--
-- The engine lays every construct out against the window's column budget and
-- clips what does not fit — `push_mermaid` ends each artwork line with
-- `clip_to_width`, and table columns are sized from the same budget. The
-- columns the clip drops are not in the rendered buffer at all, so no amount of
-- horizontal scrolling brings them back: in a narrow window the right-hand side
-- of a wide diagram does not exist.
--
-- That is why the popup is a re-render and not a magnifier. This module finds
-- the block's own source, hands that source back to the engine at the popup's
-- width, and shows the result in a float. The window underneath is never
-- touched — a float is an independent window, so the buffer, the cursor and the
-- view are all still there when it closes, with no bookkeeping.

local config = require('md-render.config')
local engine = require('md-render.engine')
local render = require('md-render.render')

local M = {}

local augroup = vim.api.nvim_create_augroup('MdRenderPreview', { clear = true })

--- The open popup, or nil. At most one at a time.
M.popup = nil

--- CommonMark allows a fence at most three spaces in. More than that is an
--- indented code block, and the engine's own parser reads it as one.
local MAX_FENCE_INDENT = 3

--------------------------------------------------------------------------------
-- Finding the block
--------------------------------------------------------------------------------

--- The opening fence on line `s`, or nil.
---
--- CommonMark's rule, because it is the rule the engine's parser applies: at
--- most three spaces of indent, a run of at least three backticks or tildes,
--- and — for a backtick fence — an info string with no backtick in it.
local function fence_open(s)
  local indent, delim, rest = s:match('^(%s*)([`~]+)(.*)$')
  if not delim or #delim < 3 or #indent > MAX_FENCE_INDENT or indent:find('[^ ]') then
    return nil
  end
  local char = delim:sub(1, 1)
  if char == '`' and rest:find('`', 1, true) then
    return nil
  end
  return { char = char, len = #delim, info = rest }
end

--- True when `s` closes a fence opened by `open`: the same character, at least
--- as long, indented no further, and with nothing else on the line.
local function fence_close(s, open)
  local indent, delim, rest = s:match('^(%s*)([`~]+)(.*)$')
  return indent ~= nil
    and #indent <= MAX_FENCE_INDENT
    and not indent:find('[^ ]')
    and delim:sub(1, 1) == open.char
    and #delim >= open.len
    and vim.trim(rest) == ''
end

--- True when a fence's info string names mermaid.
---
--- Trimmed, lowercased and compared whole, which is exactly what the engine does
--- with it (`renderer.rs`: `lang.trim().to_lowercase()`). The two sides have to
--- agree on which fences are diagrams: being stricter here would mean a fence
--- the engine draws inline that the key then refuses to preview.
local function names_mermaid(info)
  return vim.trim(info):lower() == 'mermaid'
end

--- The `mermaid` fence containing 0-based source line `line`, or nil.
---
--- Returns the fence's first and last line (1-based) and its body. A fence is
--- the easy kind of block: its opener and its closer are unambiguous, so no
--- heuristic is needed — and only an explicitly tagged fence counts, so the
--- engine's untagged-fence guess (`looks_like_mermaid`) is deliberately not
--- mirrored here.
function M.find_fence(lines, line)
  local target = line + 1
  local i = 1
  while i <= #lines do
    local open = fence_open(lines[i])
    if not open then
      i = i + 1
    else
      local close = nil
      for j = i + 1, #lines do
        if fence_close(lines[j], open) then
          close = j
          break
        end
      end
      if not close then
        -- An unterminated fence runs to the end of the buffer and, per
        -- CommonMark, swallows everything after it. There is no block here.
        return nil
      end
      if names_mermaid(open.info) and target >= i and target <= close then
        return {
          kind = 'mermaid',
          first = i,
          last = close,
          lines = vim.list_slice(lines, i, close),
        }
      end
      -- Past the whole fence either way: a fence's body is not scanned for
      -- openers, which is what keeps a ``` inside a fence from opening another.
      i = close + 1
    end
  end
  return nil
end

--- True for a GFM delimiter row: cells of dashes with optional alignment colons,
--- with the outer pipes optional as everywhere else in the table.
local function is_delimiter_row(s)
  s = vim.trim(s)
  if s == '' then
    return false
  end
  s = s:gsub('^|', ''):gsub('|$', '')
  local cells = vim.split(s, '|', { plain = true })
  for _, cell in ipairs(cells) do
    if not vim.trim(cell):match('^:?%-+:?$') then
      return false
    end
  end
  return true
end

--- The GFM table containing 0-based source line `line`, or nil.
---
--- GFM's table syntax *is* "a run of pipe-bearing lines whose second line is a
--- delimiter row", so that is the rule applied rather than an approximation of
--- it, and the two sides agree on where a table is.
---
--- Known divergence: a table followed, with no blank line, by a pipe-bearing
--- paragraph — the run swallows that line too. The popup shows what the engine
--- makes of the slice, so a mis-detect is visible rather than silent, and the
--- alternative is a markdown parser in Lua.
function M.find_table(lines, line)
  local target = line + 1
  local function pipey(i)
    local s = lines[i]
    return s ~= nil and vim.trim(s) ~= '' and s:find('|', 1, true) ~= nil
  end
  if not pipey(target) then
    return nil
  end

  local first, last = target, target
  while first > 1 and pipey(first - 1) do
    first = first - 1
  end
  while last < #lines and pipey(last + 1) do
    last = last + 1
  end

  -- Two lines at least, and the delimiter row second — without which a
  -- paragraph that merely contains a pipe would be read as a table.
  if last - first < 1 or not is_delimiter_row(lines[first + 1]) then
    return nil
  end

  return {
    kind = 'table',
    first = first,
    last = last,
    lines = vim.list_slice(lines, first, last),
  }
end

--- The block under 0-based display row `row`, or nil.
---
--- Two sources, each authoritative for its half. The document says which source
--- line the row came from — it is the only thing that can resolve a synthetic
--- row like a table border — and the source buffer says where the block around
--- that line begins and ends, which is the only place both kinds have a
--- lexically obvious boundary.
function M.locate(doc, row, lines)
  local source = render.source_line_for(doc, row)
  if source == nil then
    return nil
  end
  return M.find_fence(lines, source) or M.find_table(lines, source)
end

--------------------------------------------------------------------------------
-- Rendering the block
--------------------------------------------------------------------------------

--- Render `block` at `width`, calling `cb(err, doc)`.
---
--- The block's own source lines, joined, are what the engine is given: a fence
--- slice is itself a fenced diagram and a table slice is itself a table, so the
--- existing `--width` contract covers both and nothing has to be wrapped. This
--- is what keeps the whole feature on the Lua side.
function M.render_block(opts, block, width, cb)
  engine.render(opts, table.concat(block.lines, '\n'), width, cb)
end

--------------------------------------------------------------------------------
-- The popup
--------------------------------------------------------------------------------

--- The popup's geometry for a block of `kind`: the editor's size, the configured
--- caps, the popup's own inner width, and the budget the block is laid out at.
---
--- `window_budget` is the column budget the window showing R already has. The
--- layout budget is the popup's inner width **floored at it**, and the floor is
--- not a detail: the cap is a fraction of the *editor*, not of the window, so in
--- a full-width window the popup's inner width is the smaller of the two. Without
--- the floor the engine would clip the block harder for the popup than it did for
--- the window, and because that clip happens inside the engine the lost columns
--- would not be in the popup's buffer for scrolling to reach either.
---
--- So in a full-width window the two budgets are equal and the popup is a
--- scrollable window onto the same layout; in a narrower window — a split — the
--- popup's budget is the larger, which is the point of the feature.
function M.geometry(kind, window_budget)
  local opts = config.options.preview
  local cols = vim.o.columns
  local rows = math.max(1, vim.o.lines - vim.o.cmdheight)
  local max_w = math.max(1, math.floor(cols * opts.max_width_pct))
  local max_h = math.max(1, math.floor(rows * opts.max_height_pct))
  local inner = math.max(1, max_w - 2)
  return {
    kind = kind,
    cols = cols,
    rows = rows,
    max_w = max_w,
    max_h = max_h,
    inner = inner,
    budget = math.max(inner, window_budget or 0),
  }
end

--- The text of one wire line, with its spans concatenated.
local function line_text(line)
  local parts = {}
  for _, span in ipairs(line.spans) do
    parts[#parts + 1] = span[2]
  end
  return table.concat(parts)
end

--- Close the popup, if one is open.
---
--- Clearing `M.popup` first is what makes this idempotent: the `WinClosed`
--- handler below then finds nothing to do, and closing an already-closed window
--- is not an error either way.
function M.close()
  local popup = M.popup
  if not popup then
    return
  end
  M.popup = nil
  if popup.win and vim.api.nvim_win_is_valid(popup.win) then
    pcall(vim.api.nvim_win_close, popup.win, true)
  end
  -- `bufhidden=wipe` has usually taken it already; this covers the case where
  -- the window was gone but the buffer was not.
  if popup.buf and vim.api.nvim_buf_is_valid(popup.buf) then
    pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
  end
end

--- True while a preview is on screen.
function M.is_open()
  return M.popup ~= nil
    and M.popup.win ~= nil
    and vim.api.nvim_win_is_valid(M.popup.win)
end

--- Open the popup showing `doc`, sized from `geometry`.
---
--- Sized to content and only then clamped, so a small diagram gets a small popup
--- rather than a large empty frame. Returns the window.
function M.open(doc, geometry)
  M.close()

  -- Measured in display columns rather than bytes: the artwork is box-drawing
  -- characters, which are several bytes each, so `#line` would overstate it.
  local widest, count = 0, 0
  for _, line in ipairs(doc.lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line_text(line)))
    count = count + 1
  end

  -- The window is clamped to the popup's own inner width, which may be narrower
  -- than the content: the content was laid out at `geometry.budget`, and the
  -- columns past the clamp are still in the buffer, reached by scrolling.
  local width = math.max(1, math.min(widest, geometry.inner))
  local height = math.max(1, math.min(count, math.max(1, geometry.max_h - 2)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  render.apply(buf, doc)

  local function close()
    M.close()
  end
  for _, key in ipairs({ config.options.keymaps.preview, 'q', '<Esc>' }) do
    if key and key ~= '' and key ~= false then
      vim.keymap.set('n', key, close,
        { buffer = buf, desc = 'md-render: close the preview', nowait = true })
    end
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((geometry.rows - (height + 2)) / 2)),
    col = math.max(0, math.floor((geometry.cols - (width + 2)) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. geometry.kind .. ' ',
    title_pos = 'center',
  })

  -- `wrap` is a window option, not part of the config above, and setting it is
  -- not cosmetic: one row of artwork has to stay on one row, and it is what
  -- gives the popup horizontal scrolling for the columns past its edge.
  -- `style='minimal'` happens to turn it off too, but this is the requirement
  -- rather than a side effect of the style, so it is stated.
  vim.wo[win].wrap = false

  M.popup = { win = win, buf = buf }

  -- A close by any other route — `:close`, a mouse click elsewhere — leaves the
  -- bookkeeping behind rather than the window. The buffer goes with the window
  -- through `bufhidden=wipe`.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if M.popup and M.popup.win == win then
        M.popup = nil
      end
    end,
  })

  return win
end

return M
