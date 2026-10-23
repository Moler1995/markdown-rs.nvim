-- The half of the interactive check that runs *inside* the Neovim under test.
--
-- Loaded by `tests/interactive/run.lua` into a server with
-- `:luafile tests/interactive/server.lua`. It exposes a `MD` table of steps the
-- driver sends as `:lua MD.<step>()<CR>`, and reports by writing files, because
-- `--remote-expr` prints nothing on this platform and a `:lua` call cannot
-- return a value to the driver.

local M = {}

local repo = vim.env.MDRN_REPO
if not repo or repo == '' then
  -- Fall back to this file's own location: <repo>/tests/interactive/server.lua.
  local src = debug.getinfo(1, 'S').source:sub(2)
  repo = vim.fn.fnamemodify(src, ':p:h:h:h')
end

local out = vim.env.MDRN_OUT
if not out or out == '' then
  error('MDRN_OUT must be set to a directory to write reports into')
end

vim.opt.runtimepath:prepend(repo)
vim.opt.swapfile = false
vim.opt.hidden = true
vim.cmd('filetype plugin indent on')
vim.cmd('syntax on')

-- Sourced by path, because the server runs with `-u NONE` and that skips plugin
-- loading entirely. Without it none of the plugin's autocmds exist — the attach
-- on a split, the refresh on a resize, the refresh on a text change — and the
-- checks that depend on them would be exercising nothing while looking green.
vim.cmd('source ' .. vim.fn.fnameescape(repo .. '/plugin/md-render.lua'))

local md = require('md-render')
local state = require('md-render.state')
local render = require('md-render.render')
local preview = require('md-render.preview')

local fixture = repo .. '/tests/fixtures/plugin.md'

--- The fixture whose blocks are wider than a narrow window: a table and a
--- diagram the engine has to clip, so a preview has something to recover.
local wide = repo .. '/tests/fixtures/wide.md'

--- One diagram wider than the popup's own inner width as well as wider than a
--- narrow window, so that the popup's content says which of the two budgets it
--- was laid out against (design D3).
local wide_diagram = repo .. '/tests/fixtures/wide-diagram.md'

--- The directory reports are written to, so the driver can check liveness with
--- a path it never has to spell out itself.
M.out = out

--- The window's plugin state.
local function st()
  return state.windows[vim.api.nvim_get_current_win()]
end

--- The engine's render, counted so a step can tell one is still coming.
---
--- A resize is not one event: the plugin coalesces the burst with a timer and
--- then renders asynchronously, so a step that follows a resize can arrive
--- while a render is still in flight. The document that render applies is a
--- new layout, and a display row is a property of the layout — which is how a
--- cursor placed a moment too early ended up a row above the table it was put
--- on. Counting what the plugin starts is the honest signal: the timer's delay
--- is only 100 ms, so no work can begin without being seen for that long.
local engine = require('md-render.engine')
local in_flight = 0
local engine_render = engine.render
engine.render = function(opts, text, view, cb)
  in_flight = in_flight + 1
  local ok, err = pcall(engine_render, opts, text, view, function(...)
    in_flight = in_flight - 1
    cb(...)
  end)
  if not ok then
    in_flight = in_flight - 1
    error(err)
  end
end

--- Wait until no render is in flight and none has started for `quiet` ms.
---
--- The wait is what makes the steps deterministic. Each one runs in the
--- server's own loop, so a render that lands afterwards is invisible to it and
--- its checks would be about a state the step never established.
local function quiescent(quiet)
  local calm = 0
  vim.wait(20000, function()
    if in_flight > 0 then
      calm = 0
    else
      calm = calm + 50
    end
    return calm >= (quiet or 250)
  end, 50)
end

--- Record the events that prove a mode was really entered.
---
--- `InsertEnter` is the whole point of this file. Under `nvim -l` it never
--- fires, which is why the insert-entry keys cannot be checked there.
function M.markers()
  local group = vim.api.nvim_create_augroup('MdRenderInteractive', { clear = true })
  vim.fn.writefile({}, out .. '/events.txt')
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    callback = function()
      vim.fn.writefile({ 'InsertEnter' }, out .. '/events.txt', 'a')
    end,
  })
end

--- Load the fixture and wait for R.
function M.reset()
  vim.cmd('edit! ' .. vim.fn.fnameescape(fixture))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  vim.wait(8000, function()
    local s = st()
    return s ~= nil and s.mode == 'R'
  end)
  quiescent()
  M.markers()
end

--- Put R's cursor on the display row for 0-based source line `src`, moved by
--- `offset` rows.
---
--- The offset is how a synthetic row is named: the border a construct is drawn
--- with sits one row above the line it belongs to, and the artwork of a diagram
--- sits on the fence's own row.
function M.goto(src, offset)
  local s = st()
  -- Placed, then checked: a debounced refresh can still be in flight when a
  -- step arrives — a resize is a burst of events that only the timer
  -- coalesces, and the render it asks for may land after this step has begun.
  -- A new document is a new layout, and a display row is a property of the
  -- layout, so a row placed against the old one no longer names `src`. The
  -- key pressed after this step resolves its block from the row it finds
  -- (`M.preview` does), which is how a press once landed on the row above the
  -- table and fell through to Vim's own `<CR>`.
  for _ = 1, 20 do
    local row = render.row_for_source(s.doc, src)
    if not row then
      error('no display row for source line ' .. src)
    end
    local doc = s.doc
    local line = row + 1 + (offset or 0)
    vim.api.nvim_win_set_cursor(s.win, { line, 0 })
    quiescent()
    if s.doc == doc and vim.api.nvim_win_get_cursor(s.win)[1] == line then
      break
    end
  end
  -- Named here as well as in `watch`, because every preview check moves the
  -- cursor to its block before pressing the key.
  M.watched = s.win
end

--- Write what the window looks like now, for the driver to read.
function M.report(tag)
  local s = st()
  vim.fn.writefile({
    'mode=' .. vim.api.nvim_get_mode().mode,
    'state=' .. tostring(s.mode),
    'showing_source=' .. tostring(vim.api.nvim_win_get_buf(s.win) == s.source),
    'cursor_line=' .. vim.api.nvim_win_get_cursor(s.win)[1],
    'lines=' .. vim.json.encode(vim.api.nvim_buf_get_lines(s.source, 5, 8, false)),
  }, string.format('%s/%s.txt', out, tag))
end

--- Split the window, with the new one showing S.
---
--- The window R was in keeps R, and the new one is put in S, so that typing
--- there edits the source while R is on screen. That is the arrangement the
--- change-triggered refresh exists for, and the one no other step here makes.
function M.split()
  -- Read before the split: after it the current window is the new one, which
  -- has no state yet. The plugin attaches a window split from R on `WinEnter`,
  -- but only deferred, so the new window would still be showing R when the
  -- next key arrives.
  local s = st()
  vim.cmd('split')
  local win = vim.api.nvim_get_current_win()
  md.attach(s.source, win)
  md.show_source(win)
end

--- Let the event loop run for `ms`, so a debounced refresh gets to happen.
---
--- Without this the report would be taken in the same breath as the keys, and
--- would say only that the render had not happened *yet*.
function M.settle(ms)
  vim.wait(ms)
end

--- What the window showing R looks like, from wherever the cursor is.
---
--- Not `M.report`: the report is about the window that is *not* current here,
--- because the whole point is that it catches up with an edit made in another.
function M.report_live(tag)
  local showing
  for _, s in pairs(state.windows) do
    if s.mode == 'R' and s.rendered and vim.api.nvim_buf_is_valid(s.rendered)
      and vim.api.nvim_win_get_buf(s.win) == s.rendered then
      showing = s
    end
  end

  local source = vim.api.nvim_get_current_buf()
  local rendered = showing and vim.api.nvim_buf_get_lines(showing.rendered, 0, -1, false) or {}
  vim.fn.writefile({
    'window_showing_r=' .. tostring(showing ~= nil),
    'showing_source=' .. tostring(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == source),
    'rendered=' .. vim.json.encode(rendered),
    'source=' .. vim.json.encode(vim.api.nvim_buf_get_lines(source, 0, -1, false)),
  }, string.format('%s/%s.txt', out, tag))
end

--------------------------------------------------------------------------------
-- The block preview
--------------------------------------------------------------------------------

--- The display width of a buffer's widest line, measured in `win`'s context.
---
--- Display columns rather than `#line`: the artwork is box-drawing characters,
--- several bytes each, so a byte count would overstate it.
---
--- `win` is not decoration, and the same measure for the popup and for the
--- window underneath is what makes the two compare. `strdisplaywidth` is not a
--- property of the string alone: it simulates the line's display in the current
--- window, so `'wrap'` and `'linebreak'` change it — measured against the same
--- 358-column artwork, `wrap` on gives 358 and `wrap` off gives 357, because
--- `'linebreak'` decides whether the space at a break counts. An open popup is
--- `wrap=false` and takes focus, so measuring its buffer as the current window
--- would report one or two columns fewer than the window's, for no reason but
--- the measurement. Naming the window the width is meant *for* removes that.
---
--- -1 rather than an error for a buffer that is gone: a report of a state the
--- checks did not expect is more useful than an exception that leaves no report
--- at all, and `-1` fails every comparison the checks make.
local function widest(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return -1
  end
  local function measure()
    local w = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      w = math.max(w, vim.fn.strdisplaywidth(line))
    end
    return w
  end
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_call(win, measure)
  end
  return measure()
end

--- `winsaveview()` of a window that is not the current one.
local function view_of(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

--- Load the wide fixture in a single window and wait for R.
---
--- `only` first: the checks below split the window, and a split left over from
--- an earlier one would change the width the next check starts from.
---
--- `which` names the fixture, because two of them are wide: the one with a table
--- and a diagram, and the one that is a single diagram wider than the popup.
function M.reset_wide(which)
  preview.close()
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd('only')
  end
  vim.cmd('edit! ' .. vim.fn.fnameescape(which or wide))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  vim.wait(8000, function()
    local s = st()
    return s ~= nil and s.mode == 'R' and s.doc ~= nil
  end)
  quiescent()
end

--- The same, for the fixture that is one diagram wider than the popup.
function M.reset_wide_diagram()
  M.reset_wide(wide_diagram)
end

--- Narrow the window showing R to `cols` columns, and wait for the re-render.
---
--- A split is the only way to make a window narrower than the editor, and that
--- is the arrangement the preview's budget floor exists for: with a single
--- full-width window a table's budget cannot exceed the window's (design D3).
--- A diagram's budget does not depend on the window at all, so the split is
--- needed only to keep the window from being the wider of the two.
---
--- The wait is not for the resize but for what it schedules. The width change
--- fires `WinResized`, which debounces a re-render; `goto` resolves a source
--- line against the document, so a `goto` before that render lands would be
--- reading the old layout. The rendered buffer having come in to the new width
--- is the signal that it did.
function M.narrow(cols)
  vim.cmd('vsplit')
  vim.cmd('wincmd p')
  vim.api.nvim_win_set_width(vim.api.nvim_get_current_win(), cols)
  local s = st()
  vim.wait(8000, function()
    return s.rendered ~= nil and widest(s.rendered, s.win) <= cols
  end)
  -- The width is one render; a burst of resize events can schedule another, so
  -- the step is not over when the first lands.
  quiescent()
end

--- Close the preview, if one is open.
function M.close_preview()
  preview.close()
end

--- Write what the popup, and the window it was opened over, look like now.
---
--- The popup is opened by the driver pressing the real key, so this only
--- observes — but it waits for `want_open` first, because opening one is a
--- render and a report taken in the same breath as the key would say only that
--- the engine had not answered *yet*. The wait times out rather than raising, so
--- a preview that never opens is reported as `open=false` and fails the check
--- that wanted it, rather than hanging the run.
---
--- Waiting here rather than in a step of its own is deliberate: a step that only
--- waits and a step that only reports are two chances for the queue to drain
--- between them, and the pair would be observing a state neither of them
--- established.
---
--- The window is the watched one rather than the current one, because an open
--- popup takes focus: at the moment this runs the current window may be the
--- popup, which has no state of its own.
function M.preview_report(tag, want_open)
  local win = M.watched or vim.api.nvim_get_current_win()
  local before = (state.windows[win] or {}).reported
  vim.wait(8000, function()
    if preview.is_open() == want_open then
      return true
    end
    -- A render that failed is never going to open a popup. Stop waiting for
    -- one: the report says so, and the check that wanted it open fails with
    -- the plugin's own message instead of an unexplained `open=false` eight
    -- seconds later.
    local s = state.windows[win]
    return want_open and s ~= nil and s.reported ~= nil and s.reported ~= before
  end)

  local s = state.windows[win]
  if not s then
    error('no md-render state for the watched window')
  end
  local view = view_of(s.win)
  local cursor = vim.api.nvim_win_get_cursor(s.win)
  local row = vim.api.nvim_buf_get_lines(s.rendered, cursor[1] - 1, cursor[1], false)[1]
  local lines = {
    'open=' .. tostring(preview.is_open()),
    'state=' .. tostring(s.mode),
    'columns=' .. vim.o.columns,
    'window_width=' .. vim.api.nvim_win_get_width(s.win),
    'window_widest=' .. widest(s.rendered, s.win),
    'showing_rendered=' .. tostring(vim.api.nvim_win_get_buf(s.win) == s.rendered),
    'buffer=' .. tostring(vim.api.nvim_win_get_buf(s.win)),
    'cursor_line=' .. tostring(cursor[1]),
    'cursor_col=' .. tostring(cursor[2]),
    'cursor_text=' .. vim.json.encode(row or ''),
    'topline=' .. tostring(view.topline),
    -- The popup's inner width as the plugin computes it, so that a check can say
    -- what the popup's own budget was without re-deriving the cap. `inner` does
    -- not depend on the kind; the budget does, and is what 5.4 is about.
    'popup_inner=' .. tostring(preview.geometry('table', 0).inner),
    -- The last error the plugin reported for this window, if any: a preview
    -- that did not open because the engine refused the block looks exactly
    -- like one that did not open yet, and only this tells them apart.
    'reported=' .. tostring(s.reported or ''),
    'popup_width=0',
    'popup_widest=0',
  }
  if preview.is_open() then
    local p = preview.popup
    lines[#lines] = 'popup_width=' .. vim.api.nvim_win_get_width(p.win)
    lines[#lines + 1] = 'popup_widest=' .. widest(p.buf, s.win)
    lines[#lines + 1] = 'popup_buf=' .. tostring(p.buf)
      .. ' valid=' .. tostring(vim.api.nvim_buf_is_valid(p.buf))
      .. ' shown=' .. tostring(vim.api.nvim_win_get_buf(p.win))
  end
  vim.fn.writefile(lines, string.format('%s/%s.txt', out, tag))
end

return M
