-- Headless verification for the plugin's tasks.
--
-- Run with:
--   MDRN_REPO=D:/projects/rust/markdown-rs.nvim nvim --headless -l tests/headless/run.lua
--
-- The checks are named after the task they verify, so a failure says which
-- task regressed. Everything here runs against the real engine binary; nothing
-- is stubbed, because the point is to verify the whole path rather than the
-- plugin's half of it.

local repo = assert(vim.env.MDRN_REPO, 'MDRN_REPO must be set to the repository root')

vim.opt.runtimepath:prepend(repo)
vim.opt.swapfile = false
vim.opt.hidden = true

-- A window short enough that the fixture does not fit in it. A buffer that
-- fits cannot be scrolled — Vim clamps the top line back to 1 — which would
-- make the scroll-restoration check pass without testing anything.
vim.o.columns = 80
vim.o.lines = 10
vim.wait(50)

-- `nvim -l` loads neither plugins nor filetype detection, so both have to be
-- turned on by hand. Without this nothing fires a FileType event and the whole
-- run would pass by doing nothing.
vim.cmd('filetype plugin indent on')
vim.cmd('syntax on')

-- Count engine spawns before anything can spawn one.
local engine_calls = 0
local real_system = vim.system
vim.system = function(cmd, opts, on_exit)
  engine_calls = engine_calls + 1
  return real_system(cmd, opts, on_exit)
end

-- Notifications are recorded rather than printed: `vim.notify` on a headless
-- instance writes to stderr, which would make the runner's own output noisy.
local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = msg, level = level or vim.log.levels.INFO }
end

-- Sourcing the plugin by path rather than `runtime!` keeps this independent of
-- how the file is found, and the plugin's own `loaded_md_render` guard makes a
-- second source a no-op.
vim.cmd('source ' .. vim.fn.fnameescape(repo .. '/plugin/md-render.lua'))

local md = require('md-render')
local config = require('md-render.config')
local preview = require('md-render.preview')
local render = require('md-render.render')
local state = require('md-render.state')
local style = require('md-render.style')

local fixture = repo .. '/tests/fixtures/plugin.md'
local plain = repo .. '/tests/fixtures/plain.txt'

--- A document whose table and diagram are both wider than this runner's 80
--- columns, which is what the preview checks need: a block that fits the window
--- has nothing for the popup to recover.
local wide = repo .. '/tests/fixtures/wide.md'

--------------------------------------------------------------------------------
-- The runner
--------------------------------------------------------------------------------

local results = {}

local function check(name, ok, detail)
  results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
end

local function expect(name, got, want)
  check(name, got == want, string.format('got %s, want %s', vim.inspect(got), vim.inspect(want)))
end

local function truthy(name, got, detail)
  check(name, got and true or false, detail or string.format('got %s', vim.inspect(got)))
end

local function eq_table(name, got, want)
  check(name, vim.deep_equal(got, want), string.format('got %s, want %s', vim.inspect(got), vim.inspect(want)))
end

--- A section of checks. A section that raises is reported as one failure and
--- the run continues, so one broken task does not hide the rest.
local function section(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    check(name .. ' (section raised)', false, err)
  end
end

--- Run the event loop until `fn` is true, or give up.
local function wait_until(fn, ms)
  return vim.wait(ms or 8000, fn, 10)
end

--- `lhs` with `<leader>` resolved, since `nvim_replace_termcodes` leaves it be.
local function with_leader(lhs)
  local leader = vim.g.mapleader
  if type(leader) ~= 'string' or leader == '' then
    leader = '\\'
  end
  return (lhs:gsub('<[Ll]eader>', function()
    return leader
  end))
end

--- Feed `keys` as if typed, then let the loop act on them.
---
--- Mode 'm' means "subject to remapping", which is what a real keypress is;
--- feeding with 'n' would skip the plugin's mappings and test Vim's built-in
--- keys in a read-only buffer, which is to say it would test nothing. Mode 'x'
--- executes the typeahead immediately, because `nvim -l` never enters the main
--- input loop, so queued keys would otherwise sit there until the process ends.
local function feed(keys)
  local keys_ = vim.api.nvim_replace_termcodes(with_leader(keys), true, false, true)
  vim.api.nvim_feedkeys(keys_, 'mx', false)
  vim.wait(50)
end

local function current_state()
  return state.get(vim.api.nvim_get_current_win())
end

--- True when the current window is really showing this window's rendered
--- buffer — not merely when the state says so.
local function showing_rendered()
  local win = vim.api.nvim_get_current_win()
  local st = state.windows[win]
  if not st or st.mode ~= 'R' or not st.rendered then
    return false
  end
  if not vim.api.nvim_buf_is_valid(st.rendered) then
    return false
  end
  return vim.api.nvim_win_get_buf(win) == st.rendered
end

local function showing_source()
  local win = vim.api.nvim_get_current_win()
  local st = state.windows[win]
  return st ~= nil and st.mode == 'S' and vim.api.nvim_win_get_buf(win) == st.source
end

--- Bring the window back to R on a freshly loaded fixture.
---
--- `:edit!` schedules the FileType handler rather than running it inline, so
--- the attach is issued here against the buffers that are current now; the
--- scheduled one that follows is a no-op.
local function reset_to_r()
  vim.cmd('edit! ' .. vim.fn.fnameescape(fixture))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  return wait_until(showing_rendered)
end

--- The same, for the wide fixture.
local function reset_to_wide()
  vim.cmd('edit! ' .. vim.fn.fnameescape(wide))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  return wait_until(showing_rendered)
end

--------------------------------------------------------------------------------
-- 8.1 Config and clean startup
--------------------------------------------------------------------------------

section('8.1', function()
  local errors = {}
  for _, n in ipairs(notifications) do
    if n.level >= vim.log.levels.ERROR then
      errors[#errors + 1] = n.msg
    end
  end
  eq_table('8.1 the plugin loaded without an error notification', errors, {})

  truthy('8.1 require("md-render").config is the config module', md.config == config)

  local d = config.defaults
  expect('8.1 default engine path is nil (meaning "resolve it")', d.engine, nil)
  expect('8.1 default theme', d.theme, 'catppuccin_mocha')
  eq_table('8.1 default filetypes', d.filetypes, { 'markdown' })
  eq_table('8.1 default keymaps', d.keymaps,
    { toggle = '<leader>mr', write = '<C-s>', preview = '<CR>' })
  eq_table('8.1 default preview caps', d.preview,
    { max_width_pct = 0.9, max_height_pct = 0.9 })
  expect('8.1 default resize debounce', d.resize_debounce, 100)

  -- The user's options must not mutate the defaults table.
  local resolved = config.setup({ theme = 'dracula' })
  expect('8.1 setup returns the resolved theme', resolved.theme, 'dracula')
  expect('8.1 setup leaves the defaults alone', config.defaults.theme, 'catppuccin_mocha')
  expect('8.1 setup keeps unmentioned defaults', resolved.resize_debounce, 100)
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 8.2 The R/S state machine
--------------------------------------------------------------------------------

section('8.2', function()
  vim.cmd('edit ' .. vim.fn.fnameescape(fixture))

  truthy('8.2 opening a markdown file reaches R', wait_until(showing_rendered))

  local st = current_state()
  truthy('8.2 R shows a buffer other than the source',
    vim.api.nvim_win_get_buf(st.win) ~= st.source)
  truthy('8.2 the rendered buffer belongs to this window',
    state.by_rendered[st.rendered] == st.win)

  md.toggle()
  truthy('8.2 the toggle returns to S', wait_until(showing_source))

  -- A position deep in the source, so a lost view would be obvious.
  vim.fn.winrestview({ lnum = 9, topline = 3, col = 0 })
  local before = vim.fn.winsaveview()

  md.toggle()
  truthy('8.2 the toggle returns to R', wait_until(showing_rendered))
  md.toggle()
  truthy('8.2 the toggle returns to S again', wait_until(showing_source))

  local after = vim.fn.winsaveview()
  expect('8.2 R->S->R restores the source cursor line', after.lnum, before.lnum)
  expect('8.2 R->S->R restores the source scroll position', after.topline, before.topline)

  -- A non-markdown buffer is not the plugin's business.
  local calls_before = engine_calls
  vim.cmd('edit ' .. vim.fn.fnameescape(plain))
  vim.wait(300)
  local plain_buf = vim.api.nvim_get_current_buf()
  local attached = 0
  for _, s in pairs(state.windows) do
    if s.source == plain_buf then
      attached = attached + 1
    end
  end
  expect('8.2 no window is attached to the non-markdown buffer', attached, 0)
  expect('8.2 a non-markdown buffer starts no engine', engine_calls, calls_before)
end)

--------------------------------------------------------------------------------
-- 8.3 The rendered buffer
--------------------------------------------------------------------------------

section('8.3', function()
  truthy('8.3 the window is back in R', reset_to_r())
  local st = current_state()
  local buf = st.rendered
  truthy('8.3 the rendered buffer exists', buf ~= nil)

  expect('8.3 buftype', vim.bo[buf].buftype, 'acwrite')
  expect('8.3 bufhidden', vim.bo[buf].bufhidden, 'wipe')
  expect('8.3 modifiable', vim.bo[buf].modifiable, false)
  expect('8.3 swapfile', vim.bo[buf].swapfile, false)
  expect('8.3 buflisted', vim.bo[buf].buflisted, false)

  truthy('8.3 the rendered buffer has a name, so `:w` can reach BufWriteCmd',
    vim.api.nvim_buf_get_name(buf) ~= '')

  local listed = {}
  for _, b in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    listed[b.bufnr] = true
  end
  truthy('8.3 the source is listed while in R', listed[st.source] == true)
  truthy('8.3 the rendered buffer is not listed', listed[buf] == nil)

  local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  pcall(vim.cmd, 'normal! dd')
  pcall(vim.cmd, 'normal! x')
  local lines_after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq_table('8.3 an edit command in R leaves the contents unchanged', lines_after, lines_before)
  expect('8.3 and the buffer is still not modifiable', vim.bo[buf].modifiable, false)
end)

--------------------------------------------------------------------------------
-- 8.4 Crossing from R into S
--------------------------------------------------------------------------------

section('8.4', function()
  -- `  - nested item` is source line 5, counted from zero. It is indented, which
  -- is what makes `i` and `I` distinguishable.
  local NESTED = 5

  -- The six insert-entry keys are checked in `tests/interactive/run.lua`, not
  -- here. They work by handing the key back to Vim with `nvim_feedkeys`, and
  -- `nvim -l` never enters the main input loop that reads such a key: it sits
  -- in the typeahead until the process ends. What a run here would measure is
  -- the normal-mode command each key happens to share a spelling with — `I` and
  -- `A` delete a character — which is worse than measuring nothing, because it
  -- looks like a pass.

  -- The toggle is an ordinary mapping that crosses in normal mode, so it can be
  -- checked here.
  truthy('8.4 toggle: reset to R', reset_to_r())
  local st = current_state()
  local row = render.row_for_source(st.doc, NESTED)
  truthy('8.4 source line ' .. NESTED .. ' has a display row', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })

  feed(config.options.keymaps.toggle)
  truthy('8.4 the toggle reaches S', wait_until(showing_source))
  expect('8.4 the toggle stays in normal mode', vim.api.nvim_get_mode().mode, 'n')
  expect('8.4 the toggle lands on the mapped source line',
    vim.api.nvim_win_get_cursor(st.win)[1], NESTED + 1)

  -- Esc must not bring R back. That it is Esc *from insert mode* that has to
  -- not, is checked interactively, where insert mode can be observed; what is
  -- left to check here is that nothing in S answers Esc at all.
  feed('<Esc>')
  vim.wait(200)
  expect('8.4 Esc leaves the window in S', current_state().mode, 'S')
  expect('8.4 Esc leaves the source buffer in the window',
    vim.api.nvim_win_get_buf(st.win), st.source)
end)

--------------------------------------------------------------------------------
-- 8.5 The documented keymaps exist
--------------------------------------------------------------------------------

section('8.5', function()
  truthy('8.5 in R for the map check', reset_to_r())
  local st = current_state()

  local function maps_in(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      out[m.lhs] = m.desc or ''
    end
    return out
  end

  local in_r = maps_in(st.rendered)
  local in_s = maps_in(st.source)

  -- Neovim stores the left-hand side with `<leader>` already resolved and the
  -- control-key letter uppercased, so the spelling the README uses has to be
  -- normalised the same way before it can be looked up.
  local function normalise(lhs)
    lhs = with_leader(lhs)
    return (lhs:gsub('<[Cc]%-(%a)>', function(c)
      return '<C-' .. c:upper() .. '>'
    end))
  end

  -- The README's own table is the list of keymaps to check, rather than a list
  -- restated here. A key added to the plugin and forgotten in the table, or
  -- removed from the plugin and left in it, then fails this rather than going
  -- unnoticed — which is the whole point of documenting them in one place.
  local readme = table.concat(vim.fn.readfile(repo .. '/README.md'), '\n')
  local marker = readme:find('<!%-%- keymaps %-%->', 1)
  truthy('8.5 the README marks its keymap table', marker ~= nil)
  if not marker then
    return
  end

  -- Rows up to the first line that is not one: the table, not the rest of the
  -- file. Every documented key is its own row, so one row means one keymap.
  local documented = {}
  for _, row in ipairs(vim.split(readme:sub(marker), '\n', { plain = true })) do
    if row:sub(1, 1) == '|' then
      local key, where = row:match('^|%s*`([^`]+)`%s*|%s*([^|]-)%s*|')
      if key then
        documented[#documented + 1] = { key = key, where = where }
      end
    elseif #documented > 0 then
      break
    end
  end

  truthy('8.5 the README documents some keymaps', #documented > 0)

  for _, entry in ipairs(documented) do
    local lhs = normalise(entry.key)
    truthy(string.format('8.5 R maps %s, as the README says', entry.key), in_r[lhs] ~= nil)
    if entry.where == 'R and S' then
      truthy(string.format('8.5 S maps %s too, as the README says', entry.key), in_s[lhs] ~= nil)
    else
      truthy(string.format('8.5 S leaves %s alone, as the README says', entry.key), in_s[lhs] == nil)
    end
  end
end)

--------------------------------------------------------------------------------
-- 9.1 Styling
--------------------------------------------------------------------------------

section('9.1', function()
  -- Counted, because "reuses the same highlight groups rather than redefining
  -- them" is a claim about not calling `nvim_set_hl` again, and a populated
  -- cache would not by itself show it. The plugin looks the function up on each
  -- call, so replacing it here sees every definition.
  local definitions = 0
  local real_set_hl = vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(...)
    definitions = definitions + 1
    return real_set_hl(...)
  end

  truthy('9.1 in R for the style check', reset_to_r())
  local st = current_state()
  local doc = st.doc

  --- The highlight groups on 0-based display row `row`, in order.
  local function groups_on(row)
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      st.rendered, render.ns, { row, 0 }, { row + 1, 0 }, { details = true }
    )) do
      out[#out + 1] = mark[4].hl_group
    end
    return out
  end

  --- The display row for a source line, found through the plugin's own map, so
  --- that this follows the fixture rather than naming display rows.
  local function row(src)
    local found = render.row_for_source(doc, src)
    if not found then
      error('no display row for source line ' .. src)
    end
    return found
  end

  local body = groups_on(row(2))[1]
  local heading = groups_on(row(0))[1]
  truthy('9.1 the paragraph body is styled', body ~= nil)
  truthy('9.1 the heading is not the body colour', heading ~= nil and heading ~= body)

  -- Source line 2 is the paragraph with `code` in it, so one of its spans is the
  -- inline code and must not be the colour of the prose around it.
  local inline = false
  for _, group in ipairs(groups_on(row(2))) do
    if group ~= body then
      inline = true
    end
  end
  truthy('9.1 inline code is coloured apart from the prose around it', inline)

  -- Source line 12 is the single line of the rust fence. Per-token colouring
  -- means several groups on one line: the keywords, the function name and the
  -- punctuation are not one colour.
  local seen = {}
  for _, group in ipairs(groups_on(row(12))) do
    seen[group] = true
  end
  local code_groups = 0
  for _ in pairs(seen) do
    code_groups = code_groups + 1
  end
  truthy('9.1 the code fence is coloured token by token', code_groups >= 3,
    string.format('%d distinct groups on that line', code_groups))

  -- The table's top border is drawn rather than echoed, and the map puts the
  -- header it opens one row below it.
  local border = groups_on(row(7) - 1)
  truthy('9.1 the table border is styled', #border > 0)
  truthy('9.1 the table border is not the body colour', border[1] ~= body)
  local through_table = false
  for _, group in ipairs(groups_on(row(7))) do
    if group == border[1] then
      through_table = true
    end
  end
  truthy('9.1 the border colour runs through the table', through_table)

  -- Cold: with the groups forgotten, the next render has to define them. This
  -- is what gives the warm case below its meaning — otherwise "no new
  -- definitions" is also what a render that defined nothing would report.
  style.forget()
  local cold = definitions
  st.doc = nil
  md.show_rendered(st.win)
  truthy('9.1 a render with the groups forgotten defines them', definitions > cold,
    string.format('%d definitions', definitions - cold))

  -- Warm: the same document again. `st.doc` is dropped so the apply really
  -- runs — a cache hit would skip it, and it is the apply that asks for the
  -- groups.
  local warm = definitions
  st.doc = nil
  md.show_rendered(st.win)
  expect('9.1 a second render defines no new groups', definitions, warm)
  truthy('9.1 and the buffer is styled again', #groups_on(row(0)) > 0)

  vim.api.nvim_set_hl = real_set_hl
end)

--------------------------------------------------------------------------------
-- 9.2 Crossing from S to R
--------------------------------------------------------------------------------

section('9.2', function()
  truthy('9.2 in R to start', reset_to_r())
  local st = current_state()

  md.toggle()
  truthy('9.2 the toggle reaches S', wait_until(showing_source))

  -- Deep enough into the file that the top of the document is many display
  -- lines away, so landing at the top would be unmistakable.
  local DEEP = 40
  vim.api.nvim_win_set_cursor(st.win, { DEEP + 1, 0 })

  md.toggle()
  truthy('9.2 the toggle reaches R', wait_until(showing_rendered))

  local want = render.row_for_source(st.doc, DEEP)
  truthy('9.2 source line ' .. DEEP .. ' has a display row', want ~= nil)
  if not want then
    return
  end
  expect('9.2 R lands on the display row for that source line',
    vim.api.nvim_win_get_cursor(st.win)[1], want + 1)
end)

--------------------------------------------------------------------------------
-- 9.3 Synthetic lines
--------------------------------------------------------------------------------

section('9.3', function()
  truthy('9.3 in R', reset_to_r())
  local doc = current_state().doc

  -- The table's header is source line 7. The border that opens it is drawn, not
  -- echoed, so it is a display row with no source line of its own.
  local header = render.row_for_source(doc, 7)
  local border = header - 1
  expect('9.3 the row above the table header is the border',
    doc.lines[border + 1].source, nil)
  expect('9.3 the border resolves to the source line of the table it opens',
    render.source_line_for(doc, border), 7)

  -- The diagram's artwork is the other case, and the easier one: the renderer
  -- gives every artwork row the fence's own source line, so nothing has to be
  -- walked outward to.
  local artwork = render.row_for_source(doc, 62)
  expect('9.3 the diagram artwork carries the fence\'s source line',
    doc.lines[artwork + 1].source, 62)
  expect('9.3 and resolves to it', render.source_line_for(doc, artwork), 62)
end)

--------------------------------------------------------------------------------
-- 10.1 A superseded render is dropped
--------------------------------------------------------------------------------

section('10.1', function()
  -- A resize while a render is in flight, answered out of order. That is the
  -- case the generation counter exists for, and one a real engine only reaches
  -- by accident, so the engine module is replaced rather than slowed: the order
  -- the answers arrive in is chosen here, not hoped for.
  local engine_mod = require('md-render.engine')
  local real_render = engine_mod.render

  --- A real document for `content` at `width`, from the real engine.
  local function document(content, width)
    local doc, done
    real_render(config.options, content, width, function(err, d)
      check(string.format('10.1 the engine rendered at width %d', width),
        err == nil, tostring(err))
      doc, done = d, true
    end)
    wait_until(function() return done end)
    return doc
  end

  truthy('10.1 in R to start', reset_to_r())
  local st = current_state()
  local source = st.source
  local content = '# 10.1 resize\n'
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '# 10.1 resize' })

  local wide = document(content, 80)
  local narrow = document(content, 40)
  truthy('10.1 both documents rendered',
    wide ~= nil and narrow ~= nil and wide.width == 80 and narrow.width == 40)

  local inflight = {}
  engine_mod.render = function(_, _, width, cb)
    inflight[#inflight + 1] = { width = width, cb = cb }
  end

  -- The first render is asked for at the width the window has now, and the stub
  -- never answers it, so it is still in flight when the window is narrowed.
  md.show_rendered()
  expect('10.1 one render is in flight', #inflight, 1)
  local stale = inflight[1]
  expect('10.1 at the width the window has', stale.width, 80)

  -- A vertical split is how this host can narrow a window at all — a headless
  -- instance ignores `vim.o.columns` after startup — and the event a real editor
  -- would raise is raised by hand. The refresh it causes is a second render of
  -- this window, at the new width, and it supersedes the one above.
  vim.cmd('vsplit')
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('10.1 the resize asks for a render at the new width', wait_until(function()
    return #inflight >= 3
  end))

  -- Everything answered first, then the stale one, which is what a slow engine
  -- and a fast reader would produce between them.
  for _, req in ipairs(inflight) do
    if req ~= stale then
      req.cb(nil, narrow)
    end
  end
  stale.cb(nil, wide)

  truthy('10.1 the document kept is the one for the width the window now has',
    st.doc ~= nil and st.doc.width == 40,
    string.format('R holds a document at width %s', st.doc and st.doc.width))
  local first = vim.api.nvim_buf_get_lines(st.rendered, 0, 1, false)[1]
  truthy('10.1 and the stale render was dropped, not applied',
    first ~= nil and first:find('10%.1 resize') ~= nil,
    string.format('first rendered line is %s', vim.inspect(first)))

  engine_mod.render = real_render

  -- The resize above armed the refresh timer. Letting it fire here, with the
  -- real engine back, spends it on a cache hit rather than on a surprise in
  -- whichever check runs next.
  vim.wait(300)
  vim.cmd('close')
end)

--------------------------------------------------------------------------------
-- 10.2 The render cache
--------------------------------------------------------------------------------

section('10.2', function()
  truthy('10.2 in R', reset_to_r())
  local st = current_state()
  local source = st.source
  local width = vim.api.nvim_win_get_width(st.win)
    - (vim.fn.getwininfo(st.win)[1].textoff or 0)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local theme = config.options.theme

  truthy('10.2 the render is cached under (buffer, tick, width, theme)',
    state.cached(source, tick, width, theme) ~= nil)
  expect('10.2 another width is a different render',
    state.cached(source, tick, width + 1, theme), nil)
  expect('10.2 another changedtick is a different render',
    state.cached(source, tick + 1, width, theme), nil)
  expect('10.2 another theme is a different render',
    state.cached(source, tick, width, 'nord'), nil)

  -- What the key is for: a round trip costs no process at all.
  local before = engine_calls
  md.toggle()
  truthy('10.2 in S', wait_until(showing_source))
  md.toggle()
  truthy('10.2 back in R', wait_until(showing_rendered))
  expect('10.2 R -> S -> R spawns no engine', engine_calls, before)

  -- And what it must not swallow: an edit moves the changedtick, so the next
  -- render is a fresh one.
  before = engine_calls
  md.toggle()
  wait_until(showing_source)
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '# 10.2 edit' })
  md.toggle()
  truthy('10.2 the edit reaches R', wait_until(showing_rendered))
  truthy('10.2 an edit costs a render', engine_calls > before)
  local first = vim.api.nvim_buf_get_lines(st.rendered, 0, 1, false)[1]
  truthy('10.2 and R shows it', first ~= nil and first:find('10%.2 edit') ~= nil,
    string.format('first rendered line is %s', vim.inspect(first)))

  -- The width half of the key, as a width really changes. A headless instance
  -- has no UI to resize it — measured: `vim.o.columns` is ignored after startup
  -- — so the change is made by splitting, which narrows this window to half,
  -- and the event a real editor would raise is raised by hand.
  local was = vim.api.nvim_win_get_width(st.win)
  vim.cmd('vsplit')
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('10.2 a narrower window is rendered at its new width', wait_until(function()
    local now = vim.api.nvim_win_get_width(st.win)
    return now < was and st.doc ~= nil and st.doc.width == now
  end))
  vim.cmd('close')
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('10.2 and back at the full width', wait_until(function()
    return st.doc ~= nil and st.doc.width == vim.api.nvim_win_get_width(st.win)
  end))
end)

--------------------------------------------------------------------------------
-- 10.3 A resize burst costs one render
--------------------------------------------------------------------------------

section('10.3', function()
  truthy('10.3 in R', reset_to_r())
  local st = current_state()
  local was = vim.api.nvim_win_get_width(st.win)

  -- A drag-resize, as Vim reports it: one `WinResized` per column. A headless
  -- instance raises none of them itself — measured: neither `vim.o.columns` nor
  -- `:vsplit` fires one — so they are fired by hand, and what is under test is
  -- the plugin's answer to them. The width they are about is a real one: the
  -- split below narrows this window.
  local before = engine_calls
  vim.cmd('vsplit')
  local split_cost = engine_calls - before
  local after_split = engine_calls
  for _ = 1, 8 do
    vim.api.nvim_exec_autocmds('WinResized', {})
  end
  expect('10.3 the burst itself renders nothing', engine_calls, after_split)
  truthy('10.3 the split\'s own window rendered for itself', split_cost == 1,
    string.format('%d renders', split_cost))

  truthy('10.3 the burst ends in one render', wait_until(function()
    return st.doc ~= nil and st.doc.width == vim.api.nvim_win_get_width(st.win)
  end))
  vim.wait(300)
  expect('10.3 eight events cost one render', engine_calls, after_split + 1)

  -- And it does not drag a window that has left R back into it, which is what
  -- makes a debounce safe to leave armed.
  vim.cmd('close')
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('10.3 back to one window', wait_until(function()
    return #vim.api.nvim_list_wins() == 1
  end))
  truthy('10.3 re-rendered at the full width', wait_until(function()
    return st.doc ~= nil and st.doc.width == vim.api.nvim_win_get_width(st.win)
  end))
  truthy('10.3 at a width the split had changed', vim.api.nvim_win_get_width(st.win) > was - 1)

  -- A user action must not be swallowed by a debounce left open. This is the
  -- failure the measured precedent has: a toggle issued immediately after a
  -- render, inside its gate, is dropped.
  vim.api.nvim_exec_autocmds('WinResized', {})
  md.toggle()
  truthy('10.3 a toggle right after a resize happens at once', showing_source())
  vim.wait(300)
  truthy('10.3 and the refresh that follows leaves it in S', showing_source())
end)

--------------------------------------------------------------------------------
-- 10.4 Unsaved edits
--------------------------------------------------------------------------------

section('10.4', function()
  truthy('10.4 in R', reset_to_r())
  local st = current_state()
  local path = vim.api.nvim_buf_get_name(st.source)
  local on_disk = vim.fn.readblob(path)

  md.toggle()
  truthy('10.4 in S', wait_until(showing_source))

  vim.api.nvim_buf_set_lines(st.source, 0, 0, false, { '# Inserted by 10.4' })
  truthy('10.4 the buffer is modified', vim.bo[st.source].modified)

  md.toggle()
  truthy('10.4 back in R', wait_until(showing_rendered))
  local first = vim.api.nvim_buf_get_lines(st.rendered, 0, 1, false)[1]
  truthy('10.4 R shows the unsaved edit', first ~= nil and first:find('Inserted by 10%.4') ~= nil,
    string.format('first rendered line is %s', vim.inspect(first)))
  truthy('10.4 and the file on disk is unchanged',
    vim.deep_equal(vim.fn.readblob(path), on_disk))

  -- The same edit while R is on screen, which is what the change-triggered
  -- refresh is for: two windows on one file, one reading R and one editing S.
  -- The event is fired by hand because `nvim -l` never raises one — measured, no
  -- edit route does, `:normal!` and `nvim_input` included — while a real server
  -- does. `tests/interactive/run.lua` drives the same path end to end with real
  -- keys, in a server, for that reason.
  local reading = st.win
  vim.cmd('split')
  local editing = vim.api.nvim_get_current_win()
  md.attach(st.source, editing)
  md.show_source(editing)
  truthy('10.4 the second window is in S', wait_until(function()
    return vim.api.nvim_win_get_buf(editing) == st.source
  end))

  local before = engine_calls
  vim.api.nvim_buf_set_lines(st.source, 0, 0, false, { '# From the other window' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = st.source })
  truthy('10.4 the reading window catches up', wait_until(function()
    local lines = vim.api.nvim_buf_get_lines(state.windows[reading].rendered, 0, -1, false)
    return table.concat(lines, '\n'):find('From the other window') ~= nil
  end))
  truthy('10.4 and that cost a render', engine_calls > before)
  truthy('10.4 the editing window is left in S',
    vim.api.nvim_win_get_buf(editing) == st.source)

  vim.cmd('close')
end)

--------------------------------------------------------------------------------
-- 10.5 Writing from R
--------------------------------------------------------------------------------

section('10.5', function()
  -- A private copy, because this section writes. A `:w` issued in R has to reach
  -- a file to be worth anything, and it must not be the repository's fixture.
  local copy = vim.fn.tempname() .. '.md'
  vim.fn.writefile(vim.fn.readfile(fixture), copy)

  vim.cmd('edit! ' .. vim.fn.fnameescape(copy))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  truthy('10.5 the copy reaches R', wait_until(showing_rendered))
  local st = current_state()
  truthy('10.5 the window is showing the rendered buffer',
    vim.api.nvim_win_get_buf(st.win) == st.rendered)

  -- Nothing is pending, so the write is a no-op: R is a view, and writing from
  -- it must not rewrite the file with the view.
  local before = vim.fn.readblob(copy)
  vim.cmd('write')
  truthy('10.5 a write in R with nothing pending leaves the file byte-identical',
    vim.deep_equal(vim.fn.readblob(copy), before))

  -- An edit made in S and written from R. The write is issued while R is the
  -- buffer in the window, so it is `BufWriteCmd` on the rendered buffer that has
  -- to reach the source.
  md.toggle()
  truthy('10.5 in S', wait_until(showing_source))
  vim.api.nvim_buf_set_lines(st.source, 0, 0, false, { '<!-- written from R -->' })
  md.toggle()
  truthy('10.5 back in R', wait_until(showing_rendered))
  vim.cmd('write')
  local after = vim.fn.readfile(copy)
  expect('10.5 the edit made in S is what was written', after[1], '<!-- written from R -->')
  truthy('10.5 and the rendered view is not what was written',
    table.concat(after, '\n'):find('█') == nil)

  -- The write key is the same route by another door.
  md.toggle()
  wait_until(showing_source)
  vim.api.nvim_buf_set_lines(st.source, 0, 0, false, { '<!-- written with the key -->' })
  md.toggle()
  truthy('10.5 in R again', wait_until(showing_rendered))
  feed(config.options.keymaps.write)
  expect('10.5 the write key writes the source', vim.fn.readfile(copy)[1],
    '<!-- written with the key -->')

  vim.fn.delete(copy)
end)

--------------------------------------------------------------------------------
-- 10.6 Engine failure
--------------------------------------------------------------------------------

section('10.6', function()
  truthy('10.6 in R to start', reset_to_r())

  -- Stand-in engines, written here rather than committed: what the plugin has to
  -- do about a broken engine does not depend on what the engine is, and a script
  -- that fails on demand is a better test than a real engine broken on purpose.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ '@echo md-render: this engine is broken 1>&2', '@exit /b 3' },
    dir .. '/fail.bat')
  vim.fn.writefile({ '@echo not json at all', '@exit /b 0' }, dir .. '/garbage.bat')

  --- Load the fixture afresh with the engine pointed somewhere else, and return
  --- the notification that arrives.
  ---
  --- The theme is named every time, and differently each time, because the theme
  --- is part of the cache key: without a difference in one of its four parts the
  --- render would be answered from the cache and the engine never consulted at
  --- all, which is exactly the state these checks have to be in.
  local function with_engine(exe, theme)
    local count = #notifications
    config.setup({ engine = exe, theme = theme })
    vim.cmd('edit! ' .. vim.fn.fnameescape(fixture))
    md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
    wait_until(function() return #notifications > count end)
    return notifications[#notifications]
  end

  --- Whether the window is showing the source, which is where a failure has to
  --- leave it.
  local function in_s()
    local st = current_state()
    return st.mode == 'S' and vim.api.nvim_win_get_buf(st.win) == st.source
  end

  -- A path that is not there. `vim.system` raises for this rather than reporting
  -- a status, so it is the case that has to be caught rather than read, and an
  -- uncaught raise would escape into the autocmd that asked for the render.
  local seen = with_engine(repo .. '/bin/not-here.exe', 'nord')
  expect('10.6 a missing engine is reported as an error', seen.level, vim.log.levels.ERROR)
  truthy('10.6 the report names the path', seen.msg:find('not%-here%.exe') ~= nil, seen.msg)
  truthy('10.6 and the window shows the source', in_s())

  -- An engine that runs and fails, with something to say about it.
  local failed = with_engine(dir .. '/fail.bat', 'dracula')
  expect('10.6 an engine that exits non-zero is reported as an error',
    failed.level, vim.log.levels.ERROR)
  truthy('10.6 with the engine\'s own diagnostic',
    failed.msg:find('this engine is broken') ~= nil, failed.msg)
  truthy('10.6 and the window shows the source', in_s())

  -- And an engine that succeeds at producing nothing usable.
  local garbage = with_engine(dir .. '/garbage.bat', 'gruvbox_dark')
  expect('10.6 an engine whose output is not a document is reported as an error',
    garbage.level, vim.log.levels.ERROR)
  truthy('10.6 naming what was wrong with it', garbage.msg:find('not JSON') ~= nil, garbage.msg)
  truthy('10.6 and the window shows the source', in_s())

  vim.fn.delete(dir, 'rf')
  config.setup({})
  truthy('10.6 with the engine back, R works again', reset_to_r())
end)

--------------------------------------------------------------------------------
-- 10.7 Two windows on one file
--------------------------------------------------------------------------------

section('10.7', function()
  truthy('10.7 in R', reset_to_r())
  local reading = current_state()

  -- A split of a window showing R. Both windows are on the same rendered buffer
  -- at first, and the new one has to end up with a state and a buffer of its
  -- own: without the state its toggle would do nothing, and without the buffer
  -- the two windows would be sharing the one that `bufhidden=wipe` discards the
  -- moment either of them leaves R.
  local before = engine_calls
  vim.cmd('split')
  local second = vim.api.nvim_get_current_win()
  truthy('10.7 the second window is attached', wait_until(function()
    return state.windows[second] ~= nil
  end))
  local other = state.windows[second]
  truthy('10.7 and reaches R', wait_until(function()
    return other.mode == 'R' and vim.api.nvim_win_get_buf(second) == other.rendered
  end))

  truthy('10.7 with a rendered buffer of its own', other.rendered ~= reading.rendered)
  expect('10.7 from the cache, with no engine spawned', engine_calls, before)

  local lines = vim.api.nvim_buf_get_lines(other.rendered, 0, 3, false)
  eq_table('10.7 and the same content as the window it was split from',
    lines, vim.api.nvim_buf_get_lines(reading.rendered, 0, 3, false))

  -- One window back to S. Its own rendered buffer is wiped — that is what
  -- `bufhidden=wipe` is for — but the other window's is not, because the other
  -- window is still showing it.
  vim.api.nvim_set_current_win(reading.win)
  md.toggle()
  truthy('10.7 the first window shows the source',
    vim.api.nvim_win_get_buf(reading.win) == reading.source)
  truthy('10.7 the second window still shows its rendered buffer',
    vim.api.nvim_win_get_buf(second) == other.rendered)
  truthy('10.7 and that buffer is still valid',
    vim.api.nvim_buf_is_valid(other.rendered))
  eq_table('10.7 with its content intact',
    vim.api.nvim_buf_get_lines(other.rendered, 0, 3, false), lines)

  -- And back, which must not disturb the window that stayed in R.
  md.toggle()
  truthy('10.7 the first window is back in R', wait_until(function()
    return vim.api.nvim_win_get_buf(reading.win) == reading.rendered
  end))
  truthy('10.7 with a fresh rendered buffer', reading.rendered ~= other.rendered)
  truthy('10.7 and the second window is untouched',
    vim.api.nvim_win_get_buf(second) == other.rendered
      and vim.api.nvim_buf_is_valid(other.rendered))
  eq_table('10.7 still with its content intact',
    vim.api.nvim_buf_get_lines(other.rendered, 0, 3, false), lines)

  vim.cmd('close')
end)

--------------------------------------------------------------------------------
-- 11.1 Locating the block
--------------------------------------------------------------------------------

--- The widest display column of any line in `doc`.
local function widest_line(doc)
  local widest = 0
  for _, line in ipairs(doc.lines) do
    local text = ''
    for _, span in ipairs(line.spans) do
      text = text .. span[2]
    end
    widest = math.max(widest, vim.fn.strdisplaywidth(text))
  end
  return widest
end

--- The widest display column of any line in `buf`.
local function widest_buffer(buf)
  local widest = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  return widest
end

section('11.1', function()
  -- Whatever the earlier sections left behind, start from one window on the wide
  -- fixture.
  pcall(vim.cmd, 'only')

  -- 1.1 find_fence. The blocks here are hand-written rather than read from a
  -- file, because what is under test is the scan, not the fixture.
  local fenced = { 'prose', '', '```mermaid', 'graph LR', '  A --> B', '```', '', 'prose' }
  local block = preview.find_fence(fenced, 3)
  truthy('11.1 a mermaid fence is found from its body', block ~= nil)
  expect('11.1 its first line', block and block.first, 3)
  expect('11.1 its last line', block and block.last, 6)
  expect('11.1 its kind', block and block.kind, 'mermaid')
  -- The whole fence, delimiters included: that slice is itself a fenced diagram,
  -- which is what lets it go back to the engine unwrapped.
  eq_table('11.1 its source lines are the whole fence', block and block.lines,
    { '```mermaid', 'graph LR', '  A --> B', '```' })

  expect('11.1 an anchor on the opening fence matches',
    (preview.find_fence(fenced, 2) or {}).first, 3)
  expect('11.1 an anchor on the closing fence matches',
    (preview.find_fence(fenced, 5) or {}).first, 3)
  expect('11.1 an anchor above the fence does not match', preview.find_fence(fenced, 0), nil)
  expect('11.1 an anchor below the fence does not match', preview.find_fence(fenced, 7), nil)

  truthy('11.1 a tilde fence is found',
    preview.find_fence({ '~~~mermaid', 'graph LR', '~~~' }, 1) ~= nil)
  truthy('11.1 an indented fence is found',
    preview.find_fence({ '  ```mermaid', '  graph LR', '  ```' }, 1) ~= nil)
  expect('11.1 a fence four spaces in is an indented code block, not a fence',
    preview.find_fence({ '    ```mermaid', '    graph LR', '    ```' }, 1), nil)

  expect('11.1 a non-mermaid fence is not found',
    preview.find_fence({ '```rust', 'fn main() {}', '```' }, 1), nil)
  expect('11.1 a differently-cased tag is found, as the engine reads it',
    (preview.find_fence({ '```Mermaid', 'graph LR', '```' }, 1) or {}).kind, 'mermaid')
  expect('11.1 a tag with other words on it is not mermaid',
    preview.find_fence({ '```mermaid extra', 'graph LR', '```' }, 1), nil)
  expect('11.1 an unterminated fence is not found',
    preview.find_fence({ '```mermaid', 'graph LR' }, 1), nil)
  -- A fence's body is not scanned for openers, which is what keeps the inner
  -- delimiter here from opening a second fence.
  expect('11.1 a fence inside a fence is not an opener',
    preview.find_fence({ '````', '```', 'inside', '```', '````', 'after' }, 2), nil)

  -- 1.2 find_table
  local tab = { 'prose', '', '| a | b |', '| - | - |', '| 1 | 2 |', '', 'prose' }
  local found = preview.find_table(tab, 4)
  truthy('11.1 a table is found from a body row', found ~= nil)
  expect('11.1 its first line', found and found.first, 3)
  expect('11.1 its last line', found and found.last, 5)
  expect('11.1 its kind', found and found.kind, 'table')
  expect('11.1 an anchor on the header row matches',
    (preview.find_table(tab, 2) or {}).first, 3)
  expect('11.1 an anchor on the delimiter row matches',
    (preview.find_table(tab, 3) or {}).first, 3)
  expect('11.1 an anchor on prose does not match', preview.find_table(tab, 0), nil)

  truthy('11.1 a table without outer pipes is found',
    preview.find_table({ 'a | b', '- | -', '1 | 2' }, 2) ~= nil)
  truthy('11.1 an aligned delimiter row is accepted',
    preview.find_table({ '| a | b |', '| :-- | --: |', '| 1 | 2 |' }, 2) ~= nil)
  expect('11.1 a pipe-bearing paragraph is not a table',
    preview.find_table({ 'a | b in prose', 'and more prose' }, 0), nil)

  -- The divergence design D5 names, asserted so it is pinned rather than
  -- discovered later: a table followed with no blank line by a pipe-bearing
  -- paragraph swallows that paragraph's line.
  expect('11.1 the D5 divergence: a following pipe-bearing line is swallowed',
    (preview.find_table({ '| a | b |', '| - | - |', '| 1 | 2 |', 'a | b in prose' }, 0) or {}).last, 4)

  -- 1.3 locate, against the real document
  truthy('11.1 in R on the wide fixture', reset_to_wide())
  local st = current_state()
  local lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)

  -- The wide fixture's table header is source line 6, counted from zero, and the
  -- border that opens it is drawn rather than echoed, so it is a display row with
  -- no source line of its own.
  local header = render.row_for_source(st.doc, 6)
  truthy('11.1 the table header has a display row', header ~= nil)
  local border = preview.locate(st.doc, header - 1, lines)
  truthy('11.1 a table border resolves to its table', border ~= nil)
  expect('11.1 and to the table kind', border and border.kind, 'table')

  -- The diagram's fence is source line 12, and every artwork row carries it.
  local art = render.row_for_source(st.doc, 12)
  local diagram = preview.locate(st.doc, art, lines)
  truthy('11.1 diagram artwork resolves to its fence', diagram ~= nil)
  expect('11.1 and to the mermaid kind', diagram and diagram.kind, 'mermaid')

  expect('11.1 prose resolves to no block', preview.locate(st.doc, 1, lines), nil)
end)

--------------------------------------------------------------------------------
-- 11.2 Rendering one block at a given width
--------------------------------------------------------------------------------

section('11.2', function()
  -- 2.1 render_block
  truthy('11.2 in R on the wide fixture', reset_to_wide())
  local st = current_state()
  local lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  local block = preview.find_table(lines, 6)
  truthy('11.2 the wide table was found', block ~= nil)

  local function render_at(width)
    local doc, err, done
    preview.render_block(config.options, block, width, function(e, d)
      err, doc, done = e, d, true
    end)
    wait_until(function() return done end)
    return doc, err
  end

  local narrow, narrow_err = render_at(40)
  local roomy, roomy_err = render_at(120)
  truthy('11.2 the table rendered at width 40', narrow ~= nil, tostring(narrow_err))
  truthy('11.2 the table rendered at width 120', roomy ~= nil, tostring(roomy_err))
  truthy('11.2 the 120-wide render is wider than the 40-wide one',
    narrow ~= nil and roomy ~= nil and widest_line(roomy) > widest_line(narrow),
    string.format('%s vs %s', roomy and widest_line(roomy), narrow and widest_line(narrow)))

  -- 2.2 an engine failure
  truthy('11.2 in R to start', reset_to_wide())
  local st2 = current_state()
  vim.api.nvim_win_set_cursor(st2.win, { render.row_for_source(st2.doc, 6) + 1, 0 })

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ '@echo md-render: broken for 11.2 1>&2', '@exit /b 3' }, dir .. '/fail.bat')

  -- The engine is pointed elsewhere only after R is on screen, so the document
  -- the preview would render is already in hand: what is under test is the
  -- preview's own failure path, not the attach's.
  local before = #notifications
  config.setup({ engine = dir .. '/fail.bat' })
  feed(config.options.keymaps.preview)
  truthy('11.2 the failure is reported',
    wait_until(function() return #notifications > before end))
  expect('11.2 and as an error', notifications[#notifications].level, vim.log.levels.ERROR)
  truthy('11.2 naming the engine\'s own diagnostic',
    notifications[#notifications].msg:find('broken for 11%.2') ~= nil,
    notifications[#notifications].msg)
  expect('11.2 no popup was opened', preview.is_open(), false)

  config.setup({})
  vim.fn.delete(dir, 'rf')
end)

--------------------------------------------------------------------------------
-- 11.3 The popup window
--------------------------------------------------------------------------------

section('11.3', function()
  -- 3.3 geometry: the budget floor. `vim.o.columns` is 80 here, so the cap is 72
  -- and the popup's inner width 70.
  local full = preview.geometry('table', 80)
  expect('11.3 in a window as wide as the cap, the budget is the window\'s',
    full.budget, 80)
  expect('11.3 and the popup\'s inner width is the smaller of the two', full.inner, 70)
  expect('11.3 in a narrower window the budget is the popup\'s inner width',
    preview.geometry('table', 40).budget, 70)
  expect('11.3 a window narrower still is still floored at the inner width',
    preview.geometry('table', 10).budget, 70)

  -- 3.1 open
  truthy('11.3 in R on the wide fixture', reset_to_wide())
  local st = current_state()

  local header = render.row_for_source(st.doc, 6)
  vim.api.nvim_win_set_cursor(st.win, { header + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy('11.3 the preview key opens a popup on a table', wait_until(preview.is_open))

  local popup = preview.popup
  truthy('11.3 the popup is a window of its own', popup.win ~= st.win)

  local cfg = vim.api.nvim_win_get_config(popup.win)
  expect('11.3 relative', cfg.relative, 'editor')
  expect('11.3 style', cfg.style, 'minimal')
  -- A window option rather than part of the open config, so it is read from the
  -- window. Without it a row of artwork would soft-wrap and the block would stop
  -- being scrollable.
  expect('11.3 wrap is off, so a row of artwork stays on one row',
    vim.wo[popup.win].wrap, false)
  truthy('11.3 it has a border', cfg.border ~= nil and #cfg.border > 0)

  --- The title's chunks, concatenated.
  local title = ''
  if type(cfg.title) == 'table' then
    for _, chunk in ipairs(cfg.title) do
      title = title .. (type(chunk) == 'table' and chunk[1] or tostring(chunk))
    end
  end
  truthy('11.3 the title names the block kind', title:find('table', 1, true) ~= nil, title)

  expect('11.3 the popup buffer is a scratch buffer', vim.bo[popup.buf].buftype, 'nofile')
  expect('11.3 the popup buffer is not modifiable', vim.bo[popup.buf].modifiable, false)
  expect('11.3 the popup buffer is not listed', vim.bo[popup.buf].buflisted, false)
  expect('11.3 the popup buffer has no swap file', vim.bo[popup.buf].swapfile, false)

  local popup_widest = widest_buffer(popup.buf)

  -- Sized to the content and then clamped to the popup's own inner width, which
  -- is what makes the overflow scrollable rather than lost.
  expect('11.3 the window is sized to the content, clamped to the inner width',
    cfg.width, math.min(popup_widest, full.inner))
  truthy('11.3 the table is wider than the popup, so the rest is scrolled to',
    popup_widest > full.inner, string.format('%d vs %d', popup_widest, full.inner))
  expect('11.3 the window is centred',
    cfg.col, math.floor((vim.o.columns - (cfg.width + 2)) / 2))
  truthy('11.3 the popup content holds no less than the window showed',
    popup_widest >= widest_line(st.doc),
    string.format('popup %d, window %d', popup_widest, widest_line(st.doc)))

  -- A block smaller than the cap gets a popup no larger than the block.
  preview.close()
  truthy('11.3 in R on the small fixture', reset_to_r())
  local small_st = current_state()
  local small_header = render.row_for_source(small_st.doc, 7)
  vim.api.nvim_win_set_cursor(small_st.win, { small_header + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy('11.3 the preview key opens a popup on the small table', wait_until(preview.is_open))
  local small_cfg = vim.api.nvim_win_get_config(preview.popup.win)
  truthy('11.3 a small block gets a popup narrower than the cap',
    small_cfg.width < full.inner,
    string.format('width %d, cap %d', small_cfg.width, full.inner))
  truthy('11.3 and no taller than the block',
    small_cfg.height <= vim.api.nvim_buf_line_count(preview.popup.buf))

  -- 3.2 the close paths. The popup has focus while it is open, so the key that
  -- closes it is the one the popup's own buffer maps.
  local function reopen_on_wide()
    preview.close()
    truthy('11.3 reset to the wide fixture', reset_to_wide())
    local s = current_state()
    vim.api.nvim_win_set_cursor(s.win, { render.row_for_source(s.doc, 6) + 1, 0 })
    feed(config.options.keymaps.preview)
    return wait_until(preview.is_open) and preview.popup
  end

  local p1 = reopen_on_wide()
  truthy('11.3 reopened for the key-close check', p1 ~= nil)
  feed(config.options.keymaps.preview)
  truthy('11.3 the preview key closes the popup',
    wait_until(function() return not preview.is_open() end))
  truthy('11.3 and its buffer is gone', not vim.api.nvim_buf_is_valid(p1.buf))

  local p2 = reopen_on_wide()
  truthy('11.3 reopened for the q check', p2 ~= nil)
  feed('q')
  truthy('11.3 q closes the popup', wait_until(function() return not preview.is_open() end))

  local p3 = reopen_on_wide()
  truthy('11.3 reopened for the Esc check', p3 ~= nil)
  feed('<Esc>')
  truthy('11.3 Esc closes the popup', wait_until(function() return not preview.is_open() end))

  -- And a close by a route the plugin does not own: the bookkeeping has to
  -- follow the window out.
  local p4 = reopen_on_wide()
  truthy('11.3 reopened for the WinClosed check', p4 ~= nil)
  vim.api.nvim_win_close(p4.win, true)
  truthy('11.3 a close by another route clears the state',
    wait_until(function() return not preview.is_open() end))
  truthy('11.3 and leaves no buffer behind',
    wait_until(function() return not vim.api.nvim_buf_is_valid(p4.buf) end))

  -- The view underneath survives the round trip untouched. The snapshot has to
  -- be taken immediately before *this* popup opens rather than once at the top
  -- of the section: every `reset_to_wide` above makes a new buffer, so an older
  -- snapshot would be compared against a buffer that has since been replaced.
  truthy('11.3 reset to the wide fixture for the untouched-view check', reset_to_wide())
  local under = current_state()
  local under_buf = vim.api.nvim_win_get_buf(under.win)
  vim.api.nvim_win_set_cursor(under.win, { render.row_for_source(under.doc, 6) + 1, 0 })
  local under_view = vim.fn.winsaveview()

  feed(config.options.keymaps.preview)
  truthy('11.3 opened for the untouched-view check', wait_until(preview.is_open))
  preview.close()
  truthy('11.3 closed', wait_until(function() return not preview.is_open() end))

  local after = current_state()
  expect('11.3 the window underneath still holds the same buffer',
    vim.api.nvim_win_get_buf(after.win), under_buf)
  expect('11.3 and the same cursor line',
    vim.fn.winsaveview().lnum, under_view.lnum)
  expect('11.3 and the same top line',
    vim.fn.winsaveview().topline, under_view.topline)
  expect('11.3 and it is still in R', after.mode, 'R')

  -- A float opened over R must not be taken for a split of it.
  --
  -- `nvim_open_win` fires `WinEnter` for the new float *before* swapping its own
  -- buffer in, so at that moment the float still holds the buffer it was opened
  -- over — R's rendered one. The split-inheritance handler reads exactly that,
  -- and without a guard it attaches the float as an md-render window: the float
  -- is given a rendered buffer of its own and stops showing what it was opened
  -- to show. That is what the preview was doing to itself, and it is the same
  -- thing any other plugin's hover or completion float would have had done to
  -- it, so it is checked here rather than only through the preview.
  truthy('11.3 in R on the wide fixture, for the float check', reset_to_wide())
  local float_st = current_state()

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].bufhidden = 'wipe'
  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = 'editor', row = 1, col = 1, width = 10, height = 1, style = 'minimal',
  })

  expect('11.3 a float opened over R still shows its own buffer',
    vim.api.nvim_win_get_buf(float_win), float_buf)
  truthy('11.3 and is not attached as a window of its own',
    state.windows[float_win] == nil)
  truthy('11.3 and R is untouched by it',
    vim.api.nvim_win_get_buf(float_st.win) == float_st.rendered)

  vim.api.nvim_win_close(float_win, true)
  truthy('11.3 and closing the float leaves R in R', current_state().mode == 'R')
end)

--------------------------------------------------------------------------------
-- 11.4 Wiring and configuration
--------------------------------------------------------------------------------

section('11.4', function()
  -- 4.1 the config
  expect('11.4 the default preview key', config.defaults.keymaps.preview, '<CR>')
  eq_table('11.4 the default preview caps', config.defaults.preview,
    { max_width_pct = 0.9, max_height_pct = 0.9 })

  -- The merge is deep, so naming one cap keeps the other.
  local resolved = config.setup({ preview = { max_width_pct = 0.5 } })
  expect('11.4 a partial preview table takes the width given',
    resolved.preview.max_width_pct, 0.5)
  expect('11.4 and keeps the height default', resolved.preview.max_height_pct, 0.9)
  config.setup({})

  -- The README's documented defaults have to match the code's, which is what
  -- stops the two drifting apart.
  local readme = table.concat(vim.fn.readfile(repo .. '/README.md'), '\n')
  truthy('11.4 the README documents the preview key default',
    readme:find("preview = '<CR>'", 1, true) ~= nil)
  truthy('11.4 the README documents the width cap default',
    readme:find('max_width_pct = 0.9', 1, true) ~= nil)
  truthy('11.4 the README documents the height cap default',
    readme:find('max_height_pct = 0.9', 1, true) ~= nil)

  local function maps_cr(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == '<CR>' then
        return true
      end
    end
    return false
  end

  -- 4.2 the mapping is in R and not in S
  truthy('11.4 in R on the wide fixture', reset_to_wide())
  local st = current_state()
  truthy('11.4 R maps the preview key', maps_cr(st.rendered))
  truthy('11.4 S does not map it', not maps_cr(st.source))

  -- `keymaps.preview = false` leaves the key alone, as the other keys' `false`
  -- does. A fresh rendered buffer is made, because the mapping is set on the
  -- buffer rather than looked up at press time.
  config.setup({ keymaps = { preview = false } })
  truthy('11.4 in R with the key disabled', reset_to_wide())
  truthy('11.4 keymaps.preview = false leaves <CR> alone in R',
    not maps_cr(current_state().rendered))
  config.setup({})
  truthy('11.4 and it comes back when the option does', reset_to_wide())
  truthy('11.4 R maps the preview key again', maps_cr(current_state().rendered))
end)

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local failed = 0
for _, r in ipairs(results) do
  if r.ok then
    io.stdout:write(string.format('ok   %s\n', r.name))
  else
    failed = failed + 1
    io.stdout:write(string.format('FAIL %s\n       %s\n', r.name, r.detail or ''))
  end
end

io.stdout:write(string.format('\n%d checks, %d failed, %d engine spawns\n', #results, failed, engine_calls))
if failed > 0 then
  io.stdout:write('\nnotifications seen:\n')
  for _, n in ipairs(notifications) do
    io.stdout:write(string.format('  [%d] %s\n', n.level, n.msg))
  end
end

os.exit(failed == 0 and 0 or 1)
