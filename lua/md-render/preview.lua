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
-- the block's own source and hands it back to the engine at a width chosen so
-- that nothing is lost, and shows the result in a float. The window underneath
-- is never touched — a float is an independent window, so the buffer, the
-- cursor and the view are all still there when it closes, with no bookkeeping.

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

--- The largest column budget the engine accepts.
---
--- `--width` is a `u16` (`engine/src/main.rs`), so this is the top of its range
--- rather than a tuned number. The point is not the number: it is that no
--- diagram is this wide, so laying one out at it clips nothing.
local MAX_BUDGET = 65535

--- How many zooms have been asked for.
---
--- A zoom is up to two engine round trips deep, so a second keypress can start
--- before the first has landed. Each chain carries the number it started with
--- and abandons itself once a newer one exists.
local zoom_generation = 0

--- The widest line `doc` was laid out at, or nil when the engine did not say.
---
--- Measured before the engine clips, so `width > budget` is exactly the
--- condition under which columns were discarded. `nil` is not zero and not
--- "fits": an engine older than the field may have dropped columns, and a reader
--- that takes a missing number for a small one would adopt a crop believing it
--- whole.
local function doc_layout_width(doc)
  local width = doc.layout_width
  if type(width) ~= 'number' then
    return nil
  end
  return width
end

--- What the popup calls itself: the block's kind, plus — once a diagram has been
--- zoomed out — the width it is laid out at and the width it opened with.
---
--- A zoomed diagram and a naturally narrow one look alike, and the difference
--- matters: one of them can be zoomed back in. These two numbers are what makes
--- the difference legible, and they are the numbers a reader could measure.
local function popup_label(popup)
  local natural, current = popup.natural_width, popup.layout_width
  if popup.kind ~= 'mermaid' or natural == nil or current == nil or current >= natural then
    return popup.kind
  end
  return string.format('%s %d/%d', popup.kind, current, natural)
end

--- The popup buffer's name, carrying the same label as the title.
---
--- Naming the buffer is not needed to find it — the popup holds the handle — but
--- it puts the zoom state where a reader can reach it without the frame: `:ls`,
--- `<C-g>`, and any statusline that shows the buffer name. The scheme keeps the
--- name from reading as a path relative to the editor's directory.
local function popup_buffer_name(popup)
  return string.format('md-render-preview://%d/%s', popup.win or 0, popup_label(popup))
end

--- How far one horizontal scroll keypress moves the popup's view, in display
--- columns.
---
--- Taken from the reader's own `'mousescroll'` — `hor:6` by default — so that the
--- keys move the view by what a horizontal wheel notch moves it by. A reader
--- with a tilt wheel and one without see the same block move the same distance,
--- and a reader who has tuned the option gets what they tuned. The fallback is
--- for a `'mousescroll'` that leaves the horizontal step out or at zero, which
--- would otherwise leave the keys silently doing nothing.
local function scroll_step()
  local step = tonumber(vim.o.mousescroll:match('hor%a*:(%d+)'))
  if not step or step < 1 then
    return 6
  end
  return step
end

--- The popup's geometry for a block of `kind`: the editor's size, the configured
--- caps, the popup's own inner width, and the budget the block is laid out at.
---
--- `window_budget` is the column budget the window showing R already has.
---
--- The budget is not the same question for the two kinds, and the difference is
--- what the engine does with content that does not fit.
---
--- A **diagram** is laid out against `MAX_BUDGET`. The engine *clips* artwork
--- that does not fit — `clip_to_width` drops the right-hand side of the line —
--- and the dropped columns are not in the buffer, so scrolling cannot reach
--- them. Opening a diagram at the popup's own inner width would therefore show
--- the reader a crop of it, and the reader asked to see the block.
---
--- The figures are measured from the sequence diagram in
--- `Wind.Traefik.LLM.Routing/docs/architecture.md` §2, named so that a later
--- reader can re-measure rather than wonder where they came from: 357 display
--- columns naturally, and 358 by `strdisplaywidth` in a window with `wrap` on.
--- That diagram at a budget of 200 is a diagram with 158 columns missing.
---
--- What has changed since those numbers were taken is that a finite budget no
--- longer *always* loses a sequence diagram's columns: the engine re-lays a
--- diagram out to fit before it clips (`render_with_width`, and the compaction
--- pass in `render/sequence.rs`). It still cannot promise not to — the layout is
--- clipped whenever the diagram's narrowest whole layout is wider than the
--- budget, which for that same diagram is 214 columns. So the popup opens at
--- `MAX_BUDGET`, where nothing can be lost, and a smaller budget is asked for
--- only deliberately, by the zoom key. See `M.zoom`.
---
--- A **table** needs no such thing. The engine wraps a cell that does not fit
--- rather than dropping it, so a table loses nothing at any budget, and a larger
--- budget would only make its columns wider and harder to read. It is therefore
--- laid out at the popup's inner width, **floored at the window's**: the cap is
--- a fraction of the *editor*, not of the window, so in a full-width window the
--- popup's inner width is the smaller of the two, and without the floor the
--- popup would lay the table out at a smaller budget than the window already
--- used and so show strictly less of it.
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
    budget = kind == 'table' and math.max(inner, window_budget or 0) or MAX_BUDGET,
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
--- `block` is the source block `doc` was laid out from. The popup keeps it, and
--- the budget it was laid out at, so that `M.zoom` can lay the same block out
--- again without going back to the window for its source.
---
--- Sized to content and only then clamped, so a small diagram gets a small popup
--- rather than a large empty frame. Returns the window.
function M.open(doc, geometry, block)
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

  -- What the popup is showing, and what it was laid out at. Neither can be
  -- recovered from the buffer once the clip has run — the buffer holds the
  -- layout, not the block it came from — and both are what a zoom needs.
  --
  -- `natural_width` is the width of the layout the popup opens with. The popup
  -- lays a diagram out at the largest budget the engine takes, so nothing was
  -- clipped at it and its `layout_width` *is* the diagram's natural width.
  --
  -- `rung` is which of the three budgets this layout sits on, and it is what
  -- lets a zoom key tell that it has nothing left to ask for. See `M.adopt`.
  local popup = {
    win = nil,
    buf = buf,
    kind = geometry.kind,
    geometry = geometry,
    block = block,
    budget = geometry.budget,
    layout_width = doc_layout_width(doc),
    natural_width = doc_layout_width(doc),
    rung = 'natural',
  }

  local function close()
    M.close()
  end
  for _, key in ipairs({ config.options.keymaps.preview, 'q', '<Esc>' }) do
    if key and key ~= '' and key ~= false then
      vim.keymap.set('n', key, close,
        { buffer = buf, desc = 'md-render: close the preview', nowait = true })
    end
  end

  -- The zoom keys are bound here rather than in R or S because they act on the
  -- block the popup is showing, and the popup is where the reader presses them.
  -- They are bound for a table's popup too, where they do nothing: leaving them
  -- unbound would let them fall through to the line motions, which is a
  -- different behaviour for the same key depending on what the block happens to
  -- be. See `M.zoom`.
  for _, entry in ipairs({
    { config.options.keymaps.zoom_in, 'in', 'md-render: zoom the diagram in' },
    { config.options.keymaps.zoom_out, 'out', 'md-render: zoom the diagram out' },
  }) do
    local key, direction, desc = entry[1], entry[2], entry[3]
    if key and key ~= '' and key ~= false then
      vim.keymap.set('n', key, function()
        M.zoom(direction)
      end, { buffer = buf, desc = desc, nowait = true })
    end
  end

  -- Sideways scrolling, on one key each. `zh` and `zl` are two keystrokes, so a
  -- reader who wants to cross a block wider than the popup has to alternate `z`
  -- and `l` — there is no key to hold down. Bound as a single key each, holding
  -- one repeats and the view keeps moving. The step is the reader's own
  -- horizontal wheel step, so the two ways of scrolling agree.
  --
  -- These are bound for a table's popup as well, and they do something there:
  -- a table is laid out at the popup's inner width floored at the window's, so
  -- it can be wider than the popup too, and its columns past the edge are
  -- reached the same way a diagram's are.
  for _, entry in ipairs({
    { config.options.keymaps.scroll_left, 'zh', 'md-render: scroll the block left' },
    { config.options.keymaps.scroll_right, 'zl', 'md-render: scroll the block right' },
  }) do
    local key, motion, desc = entry[1], entry[2], entry[3]
    if key and key ~= '' and key ~= false then
      vim.keymap.set('n', key, scroll_step() .. motion,
        { buffer = buf, desc = desc, nowait = true })
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
    title = ' ' .. popup_label(popup) .. ' ',
    title_pos = 'center',
  })

  -- `wrap` is a window option, not part of the config above, and setting it is
  -- not cosmetic: one row of artwork has to stay on one row, and it is what
  -- gives the popup horizontal scrolling for the columns past its edge.
  -- `style='minimal'` happens to turn it off too, but this is the requirement
  -- rather than a side effect of the style, so it is stated.
  vim.wo[win].wrap = false

  popup.win = win
  -- Guarded: the name is a convenience, and a failure to set it must not cost
  -- the reader the popup.
  pcall(vim.api.nvim_buf_set_name, buf, popup_buffer_name(popup))
  M.popup = popup

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

--- Lay the open popup's block out at `budget`, leaving the buffer alone.
---
--- `cb(err, doc)` is called with the result. The popup is captured now, and the
--- answer is dropped if it is no longer the popup on screen: a close, or a newer
--- preview, while the engine ran would otherwise write into a buffer nobody is
--- looking at.
---
--- Rendering and adopting are separate because a zoom has to *measure* a
--- candidate before it can decide whether to show it, and a layout it rejects
--- must leave the popup exactly as it was.
function M.render_at(budget, cb)
  local popup = M.popup
  if not popup or not popup.block then
    return
  end

  M.render_block(config.options, popup.block, budget, function(err, doc)
    if M.popup ~= popup then
      return
    end
    cb(err, doc)
  end)
end

--- Put `doc` in the popup's buffer, recorded as laid out at `budget` and sitting
--- on `rung`.
---
--- `rung` is one of `'natural'` (the layout the popup opened with, at
--- `MAX_BUDGET`), `'fits'` (the popup's inner width) or `'floor'` (the engine's
--- own narrowest whole layout). The caller knows which one it is asking for, and
--- saying so is what keeps `M.zoom` from having to infer it back out of
--- `budget` — an inference that would hold only as long as no two rungs happened
--- to be the same number, which is not a property this code can promise.
---
--- This is the only place the popup's content is replaced after it opens, and
--- the window is not touched: it keeps its size and its position, and only the
--- buffer behind it changes. That is deliberate rather than incidental — the
--- popup's inner width is the input to the next zoom decision, so a window that
--- resized with each zoom would make the ladder depend on its own output, and a
--- frame that moved under the reader's hands is worse than the dead space to
--- the right of a narrow layout.
---
--- It is also the only place that has to keep the buffer's name and the
--- window's title in step with what is on screen, since both report the zoom.
function M.adopt(doc, budget, rung)
  local popup = M.popup
  if not popup then
    return
  end

  -- Recorded together with the content, so they always describe the buffer.
  popup.budget = budget
  popup.layout_width = doc_layout_width(doc)
  popup.rung = rung
  render.apply(popup.buf, doc)

  local name = popup_buffer_name(popup)
  if vim.api.nvim_buf_is_valid(popup.buf)
    and vim.api.nvim_buf_get_name(popup.buf) ~= name then
    pcall(vim.api.nvim_buf_set_name, popup.buf, name)
  end
  if popup.win and vim.api.nvim_win_is_valid(popup.win) then
    pcall(vim.api.nvim_win_set_config, popup.win, { title = ' ' .. popup_label(popup) .. ' ' })
  end
end

--- Zoom the open popup's diagram. `direction` is `'in'` or `'out'`.
---
--- Both directions are the same shape: ask the engine for a layout at a budget,
--- check the answer, and adopt it or not. What differs is the budget and the
--- checking.
---
--- There are three budgets and no fourth, so one of the two keys is always spent
--- once the popup leaves the natural width, and the other is spent while it is
--- still there. Either key pressed with nothing to ask for returns without
--- reaching the engine, so holding it down costs nothing.
function M.zoom(direction)
  local popup = M.popup
  -- A table's popup binds these keys and does nothing with them. The engine
  -- wraps a cell that does not fit rather than discarding it, so a table has no
  -- clipped state to escape and a smaller budget only makes it harder to read.
  if not popup or popup.kind ~= 'mermaid' or not popup.block then
    return
  end

  -- The two ends of the ladder. Zooming in restores the layout the popup opened
  -- with, so while the popup is still on `'natural'` there is nothing to
  -- restore; zooming out lands on the popup's inner width or on the floor, and
  -- once it is on either there is no narrower whole layout left to ask for. Both
  -- keys are therefore spent after one effective press — the check is here
  -- rather than left to the engine so that a spent keypress is a no-op rather
  -- than a round trip that comes back with the layout already on screen.
  if direction == 'in' then
    if popup.rung == 'natural' then
      return
    end
  elseif popup.rung ~= 'natural' then
    return
  end

  -- A zoom is up to two engine round trips deep, so a second keypress can start
  -- before the first has landed. The older chain is abandoned rather than
  -- racing the newer one into the buffer.
  zoom_generation = zoom_generation + 1
  local generation = zoom_generation
  local function live()
    return generation == zoom_generation and M.popup == popup
  end

  -- Zooming in asks for the largest budget the engine takes. That is the layout
  -- the popup opened with, and nothing is clipped at that budget, so there is
  -- nothing to verify before showing it.
  if direction == 'in' then
    M.render_at(MAX_BUDGET, function(err, doc)
      if err or not live() then
        return
      end
      M.adopt(doc, MAX_BUDGET, 'natural')
    end)
    return
  end

  -- Zooming out asks first for the popup's own inner width: the most permissive
  -- budget that puts the whole diagram on screen at once, and the only one worth
  -- asking for, since a smaller budget is strictly harder to fit.
  local inner = popup.geometry.inner
  M.render_at(inner, function(err, doc)
    if err or not live() then
      return
    end

    local width = doc_layout_width(doc)
    -- An engine that does not report the field may have clipped this layout and
    -- there is no way to tell. Unknown is not "fits": the popup keeps what it
    -- has rather than adopt a crop it cannot recognise as one.
    if width == nil or popup.layout_width == nil then
      return
    end

    if width <= inner then
      -- Whole within the popup, which is what was asked for. The width check
      -- keeps a zoom *out* from ever landing on a wider layout than the one on
      -- screen, whatever the engine does at a budget it has not seen before.
      if width <= popup.layout_width then
        M.adopt(doc, inner, 'fits')
      end
      return
    end

    -- The engine cannot lay the diagram out whole within the popup. Its own
    -- report of the widest line it laid out is then a budget at which its layout
    -- is whole by construction, so asking for exactly that lands on the floor:
    -- the narrowest whole layout there is, and still narrower than the natural
    -- one for any diagram that reaches this branch.
    M.render_at(width, function(err2, doc2)
      if err2 or not live() then
        return
      end
      local floor = doc_layout_width(doc2)
      -- Only a whole layout is ever adopted. A `floor` above `width` would mean
      -- the second render clipped too, and one no narrower than what is already
      -- on screen is not worth the redraw.
      if floor == nil or floor > width or floor >= popup.layout_width then
        return
      end
      M.adopt(doc2, width, 'floor')
    end)
  end)
end

return M
