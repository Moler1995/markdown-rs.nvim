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

-- Unbuffered, so a run that dies (a crash in Neovim itself, a `cquit`) still
-- says which check it reached. Redirected output is otherwise block-buffered
-- and the last section's checks are lost with the process.
io.stdout:setvbuf('no')

local is_windows = vim.fn.has('win32') == 1

--- Write a stand-in engine the host platform can execute.
---
--- A batch file is the only script Windows will run by name, and a POSIX shell
--- script needs its executable bit set before `vim.fn.executable` will accept
--- it. Taking both bodies keeps the call sites about the engine's behaviour
--- rather than about the host's shell.
local function stand_in_engine(dir, name, windows_lines, posix_lines)
  local path = dir .. '/' .. name .. (is_windows and '.bat' or '')
  if is_windows then
    vim.fn.writefile(windows_lines, path)
  else
    local script = { '#!/bin/sh' }
    vim.list_extend(script, posix_lines)
    vim.fn.writefile(script, path)
    vim.fn.setfperm(path, 'rwx------')
  end
  return path
end

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
local engine_mod = require('md-render.engine')
local graphics = require('md-render.graphics')
local link = require('md-render.link')
local preview = require('md-render.preview')
local render = require('md-render.render')
local state = require('md-render.state')
local style = require('md-render.style')

local fixture = repo .. '/tests/fixtures/plugin.md'
local plain = repo .. '/tests/fixtures/plain.txt'

--- A document whose lines are links, one form per line, so that a check can
--- name the line and the column it means. `links.md` links to `linked.md` and
--- `other.md`, both of which are in the same directory.
local links_fixture = repo .. '/tests/fixtures/links.md'

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
  -- On stdout as the section starts, so a run killed by a crash in Neovim
  -- itself still names the section it died in; the checks are printed at the
  -- end and never get there.
  io.write('== section ' .. name .. '\n')
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

--- Compare two paths as files, not as strings.
---
--- The plugin builds some paths from `debug.getinfo` (a native path, with the
--- host's separators) and the test builds its from `MDRN_REPO`; the same file
--- must not fail a check because one side wrote `\` and the other `/`.
local function same_path(got, want)
  if not got then
    return false
  end
  return vim.fs.normalize(vim.fn.fnamemodify(got, ':p'))
    == vim.fs.normalize(vim.fn.fnamemodify(want, ':p'))
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

--- The height bound the plugin sends to the engine for `win`.
---
--- The window's text height unless `image_max_height` asks for less; `false`
--- (or a non-positive number) means no cap.
local function image_height(win)
  local height = vim.api.nvim_win_get_height(win)
  local cap = config.options.image_max_height
  if type(cap) == 'number' and cap > 0 then
    height = math.min(height, cap)
  end
  return height
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

--- The same, for the fixture of links.
local function reset_to_links()
  vim.cmd('edit! ' .. vim.fn.fnameescape(links_fixture))
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
    { toggle = '<leader>mr', write = '<C-s>', preview = '<CR>', follow = 'gf',
      follow_tab = 'gF',
      open_image = 'gx', frame_next = '<C-n>', pause = '<Space>',
      zoom_in = '+', zoom_out = '-', scroll_left = '<C-h>', scroll_right = '<C-l>' })
  eq_table('8.1 default preview caps', d.preview,
    { max_width_pct = 0.9, max_height_pct = 0.9 })
  expect('8.1 default resize debounce', d.resize_debounce, 100)
  expect('8.1 default graphics mode', d.graphics, 'auto')

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

  -- A window that cannot hold a scroll position cannot show one being
  -- restored. Neovim v0.10.4 under `-l` reports a 22-line window but scrolls
  -- every command to the cursor's line (`zt` included), so `winrestview` there
  -- is not observable. Probing beats naming a version: whether the window holds
  -- the position is exactly the property the check needs.
  vim.cmd('redraw')
  local before = vim.fn.winsaveview()
  local holds_scroll = before.topline == 3

  md.toggle()
  truthy('8.2 the toggle returns to R', wait_until(showing_rendered))
  md.toggle()
  truthy('8.2 the toggle returns to S again', wait_until(showing_source))

  local after = vim.fn.winsaveview()
  expect('8.2 R->S->R restores the source cursor line', after.lnum, before.lnum)
  if holds_scroll then
    expect('8.2 R->S->R restores the source scroll position', after.topline, before.topline)
  end

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
    real_render(config.options, content, { width = width, encoding = 'off' }, function(err, d)
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
  engine_mod.render = function(_, _, view, cb)
    inflight[#inflight + 1] = { width = view.width, cb = cb }
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
  local height = image_height(st.win)
  -- What the render was keyed on: the presentation, not `image_mode` on its
  -- own. With the default `image_inline` that is the card, and a key built from
  -- `image_encoding()` would fail to find the document it just cached.
  local encoding = config.image_inline_encoding()
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local theme = config.options.theme
  -- Built the way the render builds it, card shape included: this runner has
  -- no UI, so a card here is the compact one.
  local image = config.image_options(graphics.available())

  truthy('10.2 the render is cached under its whole key',
    state.cached(source, tick, width, height, encoding, theme, false, image) ~= nil)
  expect('10.2 another width is a different render',
    state.cached(source, tick, width + 1, height, encoding, theme, false, image), nil)
  expect('10.2 another height is a different render',
    state.cached(source, tick, width, height + 1, encoding, theme, false, image), nil)
  expect('10.2 another encoding is a different render',
    state.cached(source, tick, width, height, 'off', theme, false, image), nil)
  expect('10.2 another changedtick is a different render',
    state.cached(source, tick + 1, width, height, encoding, theme, false, image), nil)
  expect('10.2 another theme is a different render',
    state.cached(source, tick, width, height, encoding, 'nord', false, image), nil)
  for _, field in ipairs({
    'palette', 'background', 'dither', 'min_rows', 'sharpen', 'card_rows', 'card_min_width',
  }) do
    local changed = vim.deepcopy(image)
    if type(changed[field]) == 'boolean' then
      changed[field] = not changed[field]
    elseif type(changed[field]) == 'number' then
      changed[field] = changed[field] + 1
    else
      changed[field] = 'other'
    end
    expect('10.2 another image ' .. field .. ' is a different render',
      state.cached(source, tick, width, height, encoding, theme, false, changed), nil)
  end

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
  local split = vim.api.nvim_get_current_win()
  -- The attach is deferred by a tick — see the `WinEnter` handler — so the
  -- split's own render is counted after waiting for it rather than at the
  -- moment `:vsplit` returns.
  truthy('10.3 the split\'s own window is attached', wait_until(function()
    local split_st = state.windows[split]
    return split_st ~= nil and split_st.mode == 'R'
  end))
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
  local fail_engine = stand_in_engine(dir, 'fail',
    { '@echo md-render: this engine is broken 1>&2', '@exit /b 3' },
    { 'echo "md-render: this engine is broken" >&2', 'exit 3' })
  local garbage_engine = stand_in_engine(dir, 'garbage',
    { '@echo not json at all', '@exit /b 0' },
    { "echo 'not json at all'", 'exit 0' })

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
  local failed = with_engine(fail_engine, 'dracula')
  expect('10.6 an engine that exits non-zero is reported as an error',
    failed.level, vim.log.levels.ERROR)
  truthy('10.6 with the engine\'s own diagnostic',
    failed.msg:find('this engine is broken') ~= nil, failed.msg)
  truthy('10.6 and the window shows the source', in_s())

  -- And an engine that succeeds at producing nothing usable.
  local garbage = with_engine(garbage_engine, 'gruvbox_dark')
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
  -- The split halves the window, and the page height is part of what a render
  -- is: an image has to fit the window that shows it, so the cache key carries
  -- the height. The split therefore costs one render at the new height rather
  -- than a cache hit — and the check below is that it produced the same
  -- document, which is the promise that matters for an image-free file.
  expect('10.7 one render for the new page height', engine_calls, before + 1)

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
-- 10.8 A window another plugin fills
--------------------------------------------------------------------------------

section('10.8', function()
  truthy('10.8 in R', reset_to_r())
  local reading = current_state()

  -- Reaching netrw under `nvim -l`, which loads no plugins of its own.
  vim.cmd('runtime plugin/netrwPlugin.vim')

  -- What `<leader>e` does in a typical config. Netrw splits the window first —
  -- inheriting R — and only then puts its tree in the new one, which is exactly
  -- the moment the split handler fires. That made the handler attach the new
  -- window as a second md-render window: it got a rendered buffer of its own,
  -- and the tree was never seen.
  vim.cmd('Lexplore')
  local tree
  truthy('10.8 :Lexplore opens a netrw window', wait_until(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'netrw' then
        tree = w
        return true
      end
    end
    return false
  end))
  expect('10.8 the tree window is not attached to md-render', state.windows[tree], nil)
  expect('10.8 and the window is showing the tree',
    vim.bo[vim.api.nvim_win_get_buf(tree)].filetype, 'netrw')

  -- A refresh walks every attached window; the tree's is not one of them.
  vim.cmd('doautocmd VimResized')
  vim.wait(config.options.resize_debounce + 100)
  expect('10.8 a refresh leaves the tree window alone', state.windows[tree], nil)
  expect('10.8 and the tree is still what it shows',
    vim.bo[vim.api.nvim_win_get_buf(tree)].filetype, 'netrw')

  vim.api.nvim_win_close(tree, true)
  truthy('10.8 closing the tree leaves R in R', current_state().mode == 'R')

  -- The same rule without a plugin: an ordinary `:edit` can hand the window a
  -- buffer that is not this state's, and the next refresh must not take it
  -- back. This used to swap R in over whatever had been edited into the window.
  truthy('10.8 back in R for the :edit check', reset_to_r())
  local edited = current_state()
  vim.cmd('edit ' .. vim.fn.fnameescape(plain))
  vim.cmd('doautocmd VimResized')
  vim.wait(config.options.resize_debounce + 100)
  expect('10.8 :edit keeps the file it opened', vim.api.nvim_buf_get_name(0), plain)
  expect('10.8 and the abandoned state is dropped', state.windows[edited.win], nil)
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
    preview.render_block(config.options, block, { width = width, encoding = 'off' }, function(e, d)
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
  local fail_engine = stand_in_engine(dir, 'fail',
    { '@echo md-render: broken for 11.2 1>&2', '@exit /b 3' },
    { 'echo "md-render: broken for 11.2" >&2', 'exit 3' })

  -- The engine is pointed elsewhere only after R is on screen, so the document
  -- the preview would render is already in hand: what is under test is the
  -- preview's own failure path, not the attach's.
  local before = #notifications
  config.setup({ engine = fail_engine })
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
  -- 3.3 geometry: the budget. `vim.o.columns` is 80 here, so the cap is 72 and
  -- the popup's inner width 70.
  local full = preview.geometry('table', 80)
  expect('11.3 in a window as wide as the cap, the budget is the window\'s',
    full.budget, 80)
  expect('11.3 and the popup\'s inner width is the smaller of the two', full.inner, 70)
  expect('11.3 in a narrower window the budget is the popup\'s inner width',
    preview.geometry('table', 40).budget, 70)
  expect('11.3 a window narrower still is still floored at the inner width',
    preview.geometry('table', 10).budget, 70)

  -- A diagram is the other half of the same decision: the engine clips what does
  -- not fit, so no finite budget is safe for one, and the popup lays it out at
  -- the largest budget the engine takes whatever the window's own budget is.
  -- The three window budgets below are the table's three cases, and the answer
  -- has to be the same for all of them.
  for _, window_budget in ipairs({ 80, 40, 10 }) do
    expect('11.3 a diagram is not laid out against the window\'s budget (' ..
      window_budget .. ')', preview.geometry('mermaid', window_budget).budget, 65535)
  end
  expect('11.3 and the popup\'s inner width is unchanged by the kind',
    preview.geometry('mermaid', 80).inner, full.inner)

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
  -- `nvim_win_get_config` only answers `style` from 0.11 on; in 0.10 a float is
  -- minimal and the key is absent, so read the absence as the minimal style.
  expect('11.3 style', cfg.style or 'minimal', 'minimal')
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
-- 12.1 Link resolution
--------------------------------------------------------------------------------

-- The line numbers here are the fixture's own, counted from zero, and the
-- columns are 0-based byte columns. A check names the line and the column it
-- means rather than describing the text, because the point of most of them is
-- the boundary: one column past a link is not the link.

section('12.1', function()
  local lines = vim.fn.readfile(links_fixture)

  local function at(lnum, col)
    return link.at(lines, lnum, col)
  end

  local function target(lnum, col)
    local found = at(lnum, col)
    return found and found.target or nil
  end

  -- Line 2 is `An inline link to [the target](./linked.md).` — the link's own
  -- text, either bracket, and the destination all resolve to the same link.
  expect('12.1 the cursor on the link text', target(2, 25), './linked.md')
  expect('12.1 the cursor on the opening bracket', target(2, 18), './linked.md')
  expect('12.1 the cursor on the closing bracket', target(2, 42), './linked.md')
  expect('12.1 the cursor inside the destination', target(2, 35), './linked.md')
  expect('12.1 the cursor one column past the link', target(2, 43), nil)
  expect('12.1 the cursor in the prose before it', target(2, 5), nil)

  -- The image form, which a scan that only looked for `[` would still find but
  -- a scan that stopped at `]` would not.
  local image = at(4, 15)
  truthy('12.1 an image resolves', image ~= nil)
  expect('12.1 an image is a file link', image and image.kind, 'file')
  expect('12.1 an image target', image and image.target, './linked.md')

  -- A fragment is split off the destination, and what is left is still a file.
  local fragment = at(6, 30)
  truthy('12.1 a fragment link resolves', fragment ~= nil)
  expect('12.1 a fragment link target', fragment and fragment.target, './linked.md')
  expect('12.1 a fragment link fragment', fragment and fragment.fragment, 'target-section')
  expect('12.1 a fragment link is still a file', fragment and fragment.kind, 'file')

  -- A reference link, resolved from a definition further down the buffer, and
  -- the shortcut form that names a definition without repeating it.
  expect('12.1 a reference link', target(10, 25), './linked.md')
  expect('12.1 a shortcut reference', target(12, 26), './linked.md')

  -- A URL is neither a file nor an anchor, and keeps its whole text.
  local url = at(8, 20)
  truthy('12.1 a bare URL resolves', url ~= nil)
  expect('12.1 a bare URL kind', url and url.kind, 'url')
  expect('12.1 a bare URL target', url and url.raw, 'https://example.com/docs')

  local auto = at(22, 25)
  truthy('12.1 an autolink resolves', auto ~= nil)
  expect('12.1 an autolink is a URL', auto and auto.kind, 'url')
  expect('12.1 an autolink target', auto and auto.raw, 'https://example.com/auto')
  -- Found once, not twice: the bare-URL pattern also sees the URL inside the
  -- brackets, and only the bracketed one is the link.
  expect('12.1 an autolink is one link, not two', #link.links(lines, 22), 1)

  -- `#tail` alone names a heading rather than a file.
  local anchor = at(24, 30)
  truthy('12.1 an anchor-only link resolves', anchor ~= nil)
  expect('12.1 an anchor-only kind', anchor and anchor.kind, 'anchor')
  expect('12.1 an anchor-only target is empty', anchor and anchor.target, '')
  expect('12.1 an anchor-only fragment', anchor and anchor.fragment, 'tail')

  -- Two links on one line are two links, and the cursor's column picks one.
  expect('12.1 the first of two links', target(18, 15), './linked.md')
  expect('12.1 the second of two links', target(18, 50), './other.md')
  expect('12.1 between two links', target(18, 34), nil)

  -- Text about a link is not a link.
  expect('12.1 a link in a code span', target(26, 35), nil)
  expect('12.1 an escaped bracket', target(28, 35), nil)

  -- A destination's title and its angle-bracket quoting are decoration.
  expect('12.1 a title is stripped',
    link.at({ '[a](./b.md "Title")' }, 0, 2).target, './b.md')
  expect('12.1 angle brackets are stripped',
    link.at({ '[a](<./b c.md>)' }, 0, 2).target, './b c.md')

  -- The heading an anchor names, and the slug it is matched by.
  expect('12.1 a slug', link.slug('Target Section'), 'target-section')
  expect('12.1 punctuation is dropped from a slug', link.slug('A, B!'), 'a-b')
  -- GitHub keeps a hyphen and an underscore in the anchor it generates, so a
  -- heading that has one must be found by the anchor the document links to.
  expect('12.1 a hyphen survives a slug', link.slug('使用 deepseek-recipe'),
    '使用-deepseek-recipe')
  expect('12.1 an underscore survives a slug', link.slug('snake_case'), 'snake_case')
  expect('12.1 a hyphenated heading matches its anchor',
    link.anchor_line({ '# Top', '## 使用 deepseek-recipe' }, '使用-deepseek-recipe'), 1)
  expect('12.1 the line of an anchor', link.anchor_line(lines, 'tail'), 30)
  expect('12.1 an anchor no heading matches', link.anchor_line(lines, 'nope'), nil)

  -- Absolute destinations in every form the plugin accepts. A leading
  -- separator covers POSIX and UNC; the drive form covers either separator.
  truthy('12.1 is_absolute accepts a POSIX path', link.is_absolute('/x'))
  truthy('12.1 is_absolute accepts a drive path with a forward slash',
    link.is_absolute('C:/x'))
  truthy('12.1 is_absolute accepts a drive path with a backslash',
    link.is_absolute('C:\\x'))
  truthy('12.1 is_absolute accepts a UNC path', link.is_absolute('\\\\server\\share'))
  truthy('12.1 is_absolute rejects a relative path', not link.is_absolute('docs/x.md'))
end)

--------------------------------------------------------------------------------
-- 12.2 Following a link
--------------------------------------------------------------------------------

section('12.2', function()
  local opened = {}
  local real_ui_open = vim.ui.open
  -- Stubbed rather than called: a real `vim.ui.open` on a URL would try to
  -- start a browser, and this runner is not here to start one.
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end

  local function maps(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  --- The plugin state of the window, once its source is `name`.
  local function wait_for_source(name)
    return wait_until(function()
      local s = state.windows[vim.api.nvim_get_current_win()]
      return s ~= nil and s.source ~= nil and vim.api.nvim_buf_is_valid(s.source)
        and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.source), ':t') == name
    end)
  end

  --- Put R's cursor on the display row for 0-based source line `src`.
  local function goto_source(src)
    local st = current_state()
    local row = render.row_for_source(st.doc, src)
    if row == nil then
      return false
    end
    vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })
    return true
  end

  --- Put R's cursor on `label` in the display row for source line `src`.
  local function goto_label(src, label)
    local st = current_state()
    local row = render.row_for_source(st.doc, src)
    local line = row and st.doc.lines[row + 1]
    if not line then
      return false
    end
    local parts = {}
    for _, span in ipairs(line.spans) do
      parts[#parts + 1] = span[2]
    end
    local at = table.concat(parts):find(label, 1, true)
    if not at then
      return false
    end
    vim.api.nvim_win_set_cursor(st.win, { row + 1, at - 1 })
    return true
  end

  truthy('12.2 in R on the links fixture', reset_to_links())
  local st = current_state()
  truthy('12.2 R maps gf', maps(st.rendered, 'gf'))
  truthy('12.2 S maps gf', maps(st.source, 'gf'))

  -- `keymaps.follow = false` leaves the key alone, as the other keys' `false`
  -- does. Checked on R, whose buffer is made afresh: a mapping set on a buffer
  -- survives an `:edit!` of it, so only a new buffer can show the difference.
  config.setup({ keymaps = { follow = false } })
  truthy('12.2 in R with the key disabled', reset_to_links())
  truthy('12.2 keymaps.follow = false leaves gf alone in R',
    not maps(current_state().rendered, 'gf'))
  config.setup({})
  truthy('12.2 and it comes back when the option does', reset_to_links())
  truthy('12.2 R maps gf again', maps(current_state().rendered, 'gf'))

  -- From R, the display row is mapped back to its source line and the link is
  -- read there. Source line 2 carries the inline link.
  truthy('12.2 in R for the inline link', reset_to_links())
  truthy('12.2 the inline link has a display row', goto_source(2))
  md.follow()
  truthy('12.2 following from R opens the linked file', wait_for_source('linked.md'))

  -- A fragment takes the reader to the heading, not to line 1. Source line 6
  -- carries the link to `linked.md#target-section`.
  truthy('12.2 in R for the fragment link', reset_to_links())
  truthy('12.2 the fragment link has a display row', goto_source(6))
  md.follow()
  truthy('12.2 following the fragment link opens the file', wait_for_source('linked.md'))
  truthy('12.2 and the view is in R', wait_until(showing_rendered))
  -- Also the check that catches a render arriving for a state the window has
  -- already dropped. This is the second follow in a row to the same file, so a
  -- request left over from the first one is still in flight; if it were applied
  -- it would put its own rendered buffer on screen first, and this follow would
  -- then find the window already showing R and leave the cursor on line 1.
  local landed = current_state()
  expect('12.2 and it opens on the heading the fragment names',
    render.source_line_for(landed.doc, vim.api.nvim_win_get_cursor(landed.win)[1] - 1), 4)

  -- An anchor with no path stays in this document. Source line 16 carries
  -- `[the tail](#tail)`, and the heading it names is source line 30.
  truthy('12.2 in R for the anchor', reset_to_links())
  truthy('12.2 the anchor has a display row', goto_source(16))
  md.follow()
  st = current_state()
  expect('12.2 an anchor moves R to its heading\'s display row',
    render.source_line_for(st.doc, vim.api.nvim_win_get_cursor(st.win)[1] - 1), 30)

  -- From S the cursor's own column decides, which is the case R cannot resolve:
  -- a display column has no byte column in the source to be compared against.
  -- Source line 18 holds two links, to `linked.md` and to `other.md`.
  truthy('12.2 in R before the two-link line', reset_to_links())
  md.show_source()
  truthy('12.2 and in S for the two-link line', wait_until(showing_source))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { 19, 50 })
  md.follow()
  truthy('12.2 the cursor on the second link follows the second link',
    wait_for_source('other.md'))

  truthy('12.2 in R before the first link', reset_to_links())
  md.show_source()
  truthy('12.2 and in S for the first link', wait_until(showing_source))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { 19, 15 })
  md.follow()
  truthy('12.2 the cursor on the first link follows the first link',
    wait_for_source('linked.md'))

  -- The same line from R, where there is no source byte column to compare
  -- against: the label under the cursor decides. This is what makes a line of
  -- links — a README's badge row, say — followable from the reading view.
  truthy('12.2 in R on the two-link line', reset_to_links())
  truthy('12.2 the second label has a place in R', goto_label(18, 'second'))
  md.follow()
  truthy('12.2 from R the second label follows the second link',
    wait_for_source('other.md'))

  truthy('12.2 in R on the two-link line again', reset_to_links())
  truthy('12.2 the first label has a place in R', goto_label(18, 'first'))
  md.follow()
  truthy('12.2 from R the first label follows the first link',
    wait_for_source('linked.md'))

  -- And from S an anchor moves the cursor within this document, to source line
  -- 30 — the `## Tail` heading — with no file opened at all.
  truthy('12.2 in R before the anchor in S', reset_to_links())
  md.show_source()
  truthy('12.2 and in S for the anchor', wait_until(showing_source))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { 17, 27 })
  md.follow()
  expect('12.2 an anchor in S moves the cursor to its heading',
    vim.api.nvim_win_get_cursor(st.win)[1], 31)

  -- A URL goes to `vim.ui.open` rather than to a file open.
  truthy('12.2 in R for the URL', reset_to_links())
  truthy('12.2 the bare URL has a display row', goto_source(8))
  md.follow()
  eq_table('12.2 a URL goes to vim.ui.open', opened, { 'https://example.com/docs' })

  -- An absolute destination is used as given rather than joined to the
  -- document's directory. Both files are temporary: on Unix the target is a
  -- POSIX absolute path, on Windows it is a drive path. Angle brackets keep a
  -- temp directory with a space in its name a single destination.
  local abs_target = vim.fn.tempname() .. '.md'
  local abs_source = vim.fn.tempname() .. '.md'
  vim.fn.writefile({ '# Absolute target' }, abs_target)
  vim.fn.writefile({ '[absolute](<' .. abs_target .. '>)' }, abs_source)
  vim.cmd('edit! ' .. vim.fn.fnameescape(abs_source))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  truthy('12.2 in R on the absolute-link fixture', wait_until(showing_rendered))
  md.follow()
  truthy('12.2 an absolute destination opens as given', wait_until(function()
    local s = state.windows[vim.api.nvim_get_current_win()]
    return s ~= nil and s.source ~= nil
      and vim.fs.normalize(vim.api.nvim_buf_get_name(s.source))
        == vim.fs.normalize(abs_target)
  end))

  vim.ui.open = real_ui_open
end)

--------------------------------------------------------------------------------
-- 12.3 Following a diagram node link
--------------------------------------------------------------------------------

section('12.3', function()
  local diagram_links_fixture = repo .. '/tests/fixtures/diagram_links.md'
  local opened = {}
  local real_ui_open = vim.ui.open
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end

  local function reset_to_diagram_links()
    vim.cmd('edit! ' .. vim.fn.fnameescape(diagram_links_fixture))
    md.attach(vim.api.nvim_get_current_buf())
    return wait_until(showing_rendered)
  end

  local function wait_for_source(name)
    return wait_until(function()
      local s = state.windows[vim.api.nvim_get_current_win()]
      return s ~= nil and s.source ~= nil and vim.api.nvim_buf_is_valid(s.source)
        and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.source), ':t') == name
    end)
  end

  truthy('12.3 in R with the diagram fixture', reset_to_diagram_links())
  local st = current_state()
  local row, alpha, beta
  for i, line in ipairs(st.doc.lines) do
    for _, l in ipairs(line.links or {}) do
      if l[3] == './linked.md' then
        row, alpha = i - 1, l
      elseif l[3] == 'https://example.com/diagram' then
        beta = l
      end
    end
  end
  truthy('12.3 the engine reports both click targets', row ~= nil and alpha ~= nil and beta ~= nil)
  truthy('12.3 the artwork carries no terminal escapes',
    not table.concat(vim.tbl_map(function(l)
      return table.concat(vim.tbl_map(function(s) return s[2] end, l.spans))
    end, st.doc.lines), ''):find('\27', 1, true))

  -- The label is underlined, on top of the artwork's own style, so a reader
  -- who has not read the manual can see the node is followable.
  local hinted = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.rendered, render.ns,
      { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    if d.hl_group == 'MdRenderLink' and m[3] == alpha[1] and d.end_col == alpha[2] then
      hinted = true
    end
  end
  truthy('12.3 the node label carries the link hint', hinted)

  -- The plugin resolves a rendered link by byte column, so the boundaries are
  -- exclusive on both sides: a cursor one byte before the label is not on it,
  -- and neither is one on the byte just past it.
  local at = link.rendered_at(st.doc, row, alpha[1])
  expect('12.3 the first byte of the label resolves the link', at and at.raw, './linked.md')
  expect('12.3 one byte before the label does not', link.rendered_at(st.doc, row, alpha[1] - 1), nil)
  expect('12.3 the exclusive end does not', link.rendered_at(st.doc, row, alpha[2]), nil)
  expect('12.3 a local target is a file link', at and at.kind, 'file')
  expect('12.3 the row before carries no link', link.rendered_at(st.doc, row - 1, alpha[1]), nil)

  -- A URL node goes to `vim.ui.open`; a file node opens the target in the
  -- window, exactly as a source-level link does.
  vim.api.nvim_win_set_cursor(st.win, { row + 1, beta[1] })
  md.follow()
  eq_table('12.3 a URL node goes to vim.ui.open', opened, { 'https://example.com/diagram' })

  vim.api.nvim_win_set_cursor(st.win, { row + 1, alpha[1] })
  md.follow()
  truthy('12.3 a file node opens its target', wait_for_source('linked.md'))
  truthy('12.3 and the target is rendered', wait_until(showing_rendered))

  -- `<C-o>` returns through the jumplist, which holds the first document but
  -- not its rendered view: R is `bufhidden=wipe` and the plugin's own swaps are
  -- `keepjumps`, so the jump restores the first document's *source* buffer. The
  -- window has to notice a managed buffer it did not ask for — here, because
  -- its state names the document it left — or it stays on source while every
  -- key still acts on the other document.
  feed('<C-o>')
  truthy('12.3 <C-o> returns to the first document', wait_until(function()
    local s = state.windows[vim.api.nvim_get_current_win()]
    return s ~= nil and s.source ~= nil
      and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.source), ':t') == 'diagram_links.md'
  end))
  truthy('12.3 and the return is rendered, not source', wait_until(showing_rendered))
  md.toggle()
  truthy('12.3 and the toggle still reaches S', wait_until(showing_source))
  md.toggle()
  truthy('12.3 and back to R', wait_until(showing_rendered))

  -- `gF` opens a file in a new tab and leaves the reading view alone. The
  -- window that follows is not the one the reader is looking at, so the tab
  -- count is the evidence, and the old window must still be showing R when the
  -- new tab's render answers.
  local tabs = vim.fn.tabpagenr('$')
  local reading_win = vim.api.nvim_get_current_win()
  local reading_buf = vim.api.nvim_win_get_buf(reading_win)
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { row + 1, alpha[1] })
  md.follow(nil, { tab = true })
  expect('12.3 gF opens the target in a new tab', vim.fn.tabpagenr('$'), tabs + 1)
  truthy('12.3 and the new tab is rendered', wait_until(showing_rendered))
  truthy('12.3 and the link target is the tab\'s document', wait_for_source('linked.md'))
  truthy('12.3 and the reading view keeps its window',
    vim.api.nvim_win_is_valid(reading_win)
      and vim.api.nvim_win_get_buf(reading_win) == reading_buf)
  vim.cmd('tabclose')
  expect('12.3 closing the tab comes back to the reading view',
    vim.fn.tabpagenr('$'), tabs)
  truthy('12.3 and that view is still R',
    vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == reading_buf)

  -- A URL is not a file, so there is no tab to open; it still goes to the
  -- system opener. An anchor is the same: it scrolls in place.
  opened = {}
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { row + 1, beta[1] })
  md.follow(nil, { tab = true })
  eq_table('12.3 gF on a URL still goes to vim.ui.open', opened,
    { 'https://example.com/diagram' })
  expect('12.3 and opens no tab', vim.fn.tabpagenr('$'), tabs)

  vim.ui.open = real_ui_open
end)

--------------------------------------------------------------------------------
-- 13. Zoom
--------------------------------------------------------------------------------

--- The fixture whose diagram is wider than the popup's inner width and *can* be
--- laid out whole inside it: 166 columns naturally, 69 at a 70-column budget.
local zoom_diagram = repo .. '/tests/fixtures/zoom-diagram.md'

--- The fixture whose diagram is wider than the popup and *cannot* be laid out
--- whole inside it: 113 columns naturally, and no narrower than 108 at any
--- budget. This is the case the floor fallback exists for.
local floor_diagram = repo .. '/tests/fixtures/wide-diagram.md'

--- Load `path` and wait for R.
local function reset_to(path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  return wait_until(showing_rendered)
end

--- The 0-based source line of the first `mermaid` fence in `st`'s document.
---
--- Scanned rather than hardcoded: a fixture's line numbers move whenever its
--- prose does, and a check that names the wrong line fails for the wrong reason.
local function fence_line(st)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
    if line:match('^%s*```mermaid%s*$') then
      return i - 1
    end
  end
  return nil
end

--- Open the preview on `path`'s first diagram, and return the popup.
local function open_diagram(path, tag)
  preview.close()
  truthy(tag .. ' reset to ' .. vim.fn.fnamemodify(path, ':t'), reset_to(path))
  local st = current_state()
  local source = fence_line(st)
  truthy(tag .. ' the fixture has a diagram', source ~= nil)
  local row = source and render.row_for_source(st.doc, source)
  truthy(tag .. ' the diagram has a display row', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { (row or 0) + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy(tag .. ' the preview key opens a popup', wait_until(preview.is_open))
  return preview.popup
end

--- The popup buffer's text, so that "the content did not change" is a comparison
--- of the whole block rather than of one line of it.
local function popup_text()
  local popup = preview.popup
  return popup and table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false), '\n')
end

--- The mapping for `key` in the current buffer, as `maparg`'s dictionary.
local function mapping(key)
  return vim.fn.maparg(key, 'n', false, true)
end

--- A window's title, with its chunks concatenated.
local function window_title(win)
  local cfg = vim.api.nvim_win_get_config(win)
  if type(cfg.title) == 'string' then
    return cfg.title
  end
  local text = ''
  if type(cfg.title) == 'table' then
    for _, chunk in ipairs(cfg.title) do
      text = text .. (type(chunk) == 'table' and chunk[1] or tostring(chunk))
    end
  end
  return text
end

--- A popup window's frame, for comparing it across a zoom.
local function frame(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return { width = cfg.width, height = cfg.height, row = cfg.row, col = cfg.col }
end

local function eq_frame(name, got, want)
  check(name, vim.deep_equal(got, want),
    string.format('got %s, want %s', vim.inspect(got), vim.inspect(want)))
end

--- How far `win`'s view is scrolled to the right, in display columns.
local function leftcol(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
end

section('13.1', function()
  -- 3.2 the popup's state, and the re-render path
  pcall(vim.cmd, 'only')

  local popup = open_diagram(zoom_diagram, '13.1')
  truthy('13.1 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  -- The popup keeps the block it is showing and the budget it was laid out at.
  -- Neither can be read back out of the buffer once the engine has clipped: the
  -- buffer holds the layout, not the block it came from.
  truthy('13.1 the popup holds the block it is showing',
    popup.block ~= nil and popup.block.kind == 'mermaid')
  expect('13.1 and the budget it was laid out at', popup.budget, 65535)
  expect('13.1 and the width the engine laid it out at', popup.layout_width, 166)
  expect('13.1 and that width as the diagram\'s natural width', popup.natural_width, 166)

  local before_frame = frame(popup.win)
  local before_text = popup_text()

  -- A re-render at another budget replaces the buffer's content in place. The
  -- window is the thing that must not move: it keeps its id, its size and its
  -- position, so the popup's inner width stays a constant for the life of the
  -- popup and the next zoom decision cannot depend on the last one's output.
  local done = false
  preview.render_at(70, function(err, doc)
    truthy('13.1 rendering at another budget succeeds', err == nil, err)
    if doc then
      preview.adopt(doc, 70, 'fits')
    end
    done = true
  end)
  truthy('13.1 the re-render lands', wait_until(function() return done end))

  expect('13.1 the popup records the budget it was re-rendered at', popup.budget, 70)
  truthy('13.1 and the content changed', popup_text() ~= before_text)
  truthy('13.1 and the buffer still holds the same buffer',
    vim.api.nvim_win_get_buf(popup.win) == popup.buf)
  eq_frame('13.1 the window keeps its size and position across the re-render',
    frame(popup.win), before_frame)

  preview.close()
end)

section('13.2', function()
  -- 3.3 the zoom keys
  local popup = open_diagram(zoom_diagram, '13.2')
  truthy('13.2 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  -- Both keys are bound in the popup's own buffer, alongside the close keys:
  -- they act on the block the popup is showing, and the popup is where the
  -- reader presses them.
  local zoom_in = mapping(config.options.keymaps.zoom_in)
  local zoom_out = mapping(config.options.keymaps.zoom_out)
  truthy('13.2 the zoom-in key is bound in the popup', next(zoom_in) ~= nil)
  truthy('13.2 the zoom-out key is bound in the popup', next(zoom_out) ~= nil)
  expect('13.2 and it is a buffer-local mapping', zoom_out.buffer, 1)
  truthy('13.2 and it is described as the zoom',
    (zoom_out.desc or ''):find('zoom', 1, true) ~= nil, zoom_out.desc)

  local opened = popup_text()
  feed(config.options.keymaps.zoom_out)
  truthy('13.2 the zoom-out key re-renders the diagram',
    wait_until(function() return popup_text() ~= opened end))

  -- A table's popup binds the same keys and does nothing with them. The engine
  -- wraps a cell that does not fit rather than discarding it, so a table has no
  -- clipped state to escape and a smaller budget only makes it harder to read.
  preview.close()
  truthy('13.2 reset to the wide fixture for the table', reset_to_wide())
  local tst = current_state()
  vim.api.nvim_win_set_cursor(tst.win, { render.row_for_source(tst.doc, 6) + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy('13.2 the preview key opens a popup on a table', wait_until(preview.is_open))

  local table_popup = preview.popup
  local table_text = popup_text()
  local table_frame = frame(table_popup.win)
  truthy('13.2 the zoom-out key is bound in a table\'s popup too',
    next(mapping(config.options.keymaps.zoom_out)) ~= nil)

  -- Waited out rather than merely fed: a zoom that wrongly fired would answer
  -- from the engine a few milliseconds later, and the check has to outlive it.
  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  expect('13.2 zooming a table leaves its content unchanged', popup_text(), table_text)
  expect('13.2 and leaves it laid out at its own budget',
    table_popup.budget, table_popup.geometry.budget)
  eq_frame('13.2 and leaves its window where it was', frame(table_popup.win), table_frame)
  truthy('13.2 and leaves the popup open', preview.is_open())
  preview.close()

  -- 3.3 the keys are configurable, and the default stops working when they are.
  local defaults = {
    zoom_in = config.options.keymaps.zoom_in,
    zoom_out = config.options.keymaps.zoom_out,
  }
  config.options.keymaps.zoom_in = '<C-p>'
  config.options.keymaps.zoom_out = '<C-n>'

  local rebound = open_diagram(zoom_diagram, '13.2')
  truthy('13.2 a popup is open on the rebound keys', rebound ~= nil)
  truthy('13.2 the configured zoom-out key is bound', next(mapping('<C-n>')) ~= nil)
  truthy('13.2 and the default zoom-out key is not', next(mapping('-')) == nil)

  local rebound_before = popup_text()
  feed('<C-n>')
  truthy('13.2 the configured key zooms out',
    wait_until(function() return popup_text() ~= rebound_before end))
  truthy('13.2 and the default key no longer does',
    (function()
      local at = popup_text()
      feed(defaults.zoom_out)
      vim.wait(400)
      return popup_text() == at
    end)())

  preview.close()
  config.options.keymaps.zoom_in = defaults.zoom_in
  config.options.keymaps.zoom_out = defaults.zoom_out
end)

section('13.3', function()
  -- 3.4 the zoom-out decision, against a diagram the engine can fit
  local popup = open_diagram(zoom_diagram, '13.3')
  truthy('13.3 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  local natural = popup.layout_width
  local opened = popup_text()
  local opened_frame = frame(popup.win)
  truthy('13.3 the diagram opens wider than the popup\'s inner width',
    natural > popup.geometry.inner, string.format('%d vs %d', natural, popup.geometry.inner))

  feed(config.options.keymaps.zoom_out)
  truthy('13.3 zooming out re-renders the diagram',
    wait_until(function() return popup_text() ~= opened end))

  -- The whole diagram, on screen at once: the popup asked for its own inner
  -- width and the engine met it, so the content is now narrower than the frame
  -- and no sideways scrolling is needed. The engine lands below the budget it
  -- was asked for rather than on it — it sizes the wrap target proportionally —
  -- so what "laid out within the popup" means is the budget it was given and a
  -- width no greater than that.
  expect('13.3 the diagram is laid out against the popup\'s inner width',
    popup.budget, popup.geometry.inner)
  truthy('13.3 and is whole within it',
    popup.layout_width <= popup.geometry.inner,
    string.format('%d vs %d', popup.layout_width, popup.geometry.inner))
  truthy('13.3 which is narrower than it opened',
    popup.layout_width < natural, string.format('%d vs %d', popup.layout_width, natural))
  truthy('13.3 and the content fits the window it is in',
    widest_buffer(popup.buf) <= opened_frame.width,
    string.format('%d vs %d', widest_buffer(popup.buf), opened_frame.width))
  eq_frame('13.3 and the window has not moved', frame(popup.win), opened_frame)
  local zoomed_width = popup.layout_width

  -- No participant is missing: the zoom narrowed the layout, it did not crop it.
  local zoomed_text = popup_text()
  for _, name in ipairs({ 'Client', 'Application', 'Gateway', 'Router', 'Response', 'Assembler' }) do
    truthy('13.3 ' .. name .. ' survives the zoom',
      zoomed_text:find(name, 1, true) ~= nil, zoomed_text)
  end

  -- Already within the popup, so asking again changes nothing.
  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  expect('13.3 zooming out a diagram that already fits leaves the content alone',
    popup_text(), zoomed_text)
  expect('13.3 and leaves the recorded width alone', popup.layout_width, zoomed_width)

  -- Zooming back in asks for the engine's largest budget, which is the layout
  -- the popup opened with.
  feed(config.options.keymaps.zoom_in)
  truthy('13.3 zooming in restores the layout the popup opened with',
    wait_until(function() return popup_text() == opened end))
  expect('13.3 and records the largest budget again', popup.budget, 65535)
  expect('13.3 and the natural width again', popup.layout_width, natural)
  preview.close()

  -- A diagram whose narrowest whole layout is still wider than the popup. The
  -- floor is measured: `wide-diagram.md` is 113 columns naturally and 108 is the
  -- narrowest budget at which the engine lays it out whole (107 clips it). The
  -- assertions around the number are the spec's claims; the number itself is
  -- what makes "narrowest whole layout" checkable, so it is pinned here and has
  -- to be re-measured if the engine's compaction changes.
  local floor_popup = open_diagram(floor_diagram, '13.3')
  truthy('13.3 the floor fixture opened', floor_popup ~= nil)
  if not floor_popup then
    return
  end

  local floor_natural = floor_popup.layout_width
  local floor_opened = popup_text()
  expect('13.3 the floor fixture opens at its natural width', floor_natural, 113)

  feed(config.options.keymaps.zoom_out)
  truthy('13.3 zooming out the floor diagram re-renders it',
    wait_until(function() return popup_text() ~= floor_opened end))

  expect('13.3 the fallback lands on the narrowest whole layout',
    floor_popup.layout_width, 108)
  truthy('13.3 which is narrower than it opened',
    floor_popup.layout_width < floor_natural)
  truthy('13.3 and still wider than the popup\'s inner width',
    floor_popup.layout_width > floor_popup.geometry.inner,
    string.format('%d vs %d', floor_popup.layout_width, floor_popup.geometry.inner))

  -- Whole rather than cropped, which is the one thing the fallback must not get
  -- wrong: the engine measures `layout_width` before it clips, so a layout no
  -- wider than the budget it was asked for is a layout nothing was dropped from.
  truthy('13.3 the layout it lands on is whole',
    floor_popup.layout_width <= floor_popup.budget,
    string.format('%d vs %d', floor_popup.layout_width, floor_popup.budget))

  local floor_text = popup_text()
  for _, name in ipairs({ 'Client', 'Gateway', 'Steering', 'Backend' }) do
    truthy('13.3 ' .. name .. ' survives the floor fallback',
      floor_text:find(name, 1, true) ~= nil, floor_text)
  end

  -- At the floor, another zoom-out changes nothing: the diagram is already at
  -- the narrowest whole layout there is.
  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  expect('13.3 zooming out at the floor leaves the content byte-identical',
    popup_text(), floor_text)
  expect('13.3 and leaves the recorded width alone', floor_popup.layout_width, 108)

  feed(config.options.keymaps.zoom_in)
  truthy('13.3 and zooming in from the floor restores the opening layout',
    wait_until(function() return popup_text() == floor_opened end))
  preview.close()
end)

section('13.4', function()
  -- 3.5 an engine that does not report `layout_width`
  local popup = open_diagram(zoom_diagram, '13.4')
  truthy('13.4 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  local before = popup_text()
  local before_frame = frame(popup.win)

  -- An engine older than the field: it answers, but it does not say how wide it
  -- laid the document out. The popup cannot tell whether that answer is whole,
  -- and unknown is not "fits" — a missing number read as a small one would adopt
  -- a crop believing it whole.
  local real = preview.render_block
  preview.render_block = function(_, _, _, cb)
    cb(nil, { lines = { { spans = {} } }, styles = {}, source_map = {} })
  end

  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  preview.render_block = real

  expect('13.4 a zoom-out against an engine with no layout_width changes nothing',
    popup_text(), before)
  expect('13.4 and leaves the recorded width alone', popup.layout_width, 166)
  expect('13.4 and leaves the budget alone', popup.budget, 65535)
  eq_frame('13.4 and leaves the window alone', frame(popup.win), before_frame)
  truthy('13.4 and leaves the popup open', preview.is_open())
  preview.close()
end)

section('13.5', function()
  -- 3.6 the zoom state is visible
  local popup = open_diagram(floor_diagram, '13.5')
  truthy('13.5 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  local unzoomed_name = vim.api.nvim_buf_get_name(popup.buf)
  local unzoomed_title = window_title(popup.win)
  truthy('13.5 the buffer is named after the popup', unzoomed_name ~= '', unzoomed_name)
  truthy('13.5 an unzoomed popup names the block kind',
    unzoomed_title:find('mermaid', 1, true) ~= nil, unzoomed_title)
  truthy('13.5 and reports no width, because none has changed',
    unzoomed_title:find('%d') == nil, unzoomed_title)

  feed(config.options.keymaps.zoom_out)
  truthy('13.5 zooming out re-renders the diagram',
    wait_until(function()
      return vim.api.nvim_buf_get_name(popup.buf) ~= unzoomed_name
    end))

  local zoomed_name = vim.api.nvim_buf_get_name(popup.buf)
  local zoomed_title = window_title(popup.win)
  truthy('13.5 the buffer name changes when the diagram is zoomed',
    zoomed_name ~= unzoomed_name, zoomed_name)
  truthy('13.5 and carries the width it is laid out at',
    zoomed_name:find('108', 1, true) ~= nil, zoomed_name)
  truthy('13.5 and the width it opened with',
    zoomed_name:find('113', 1, true) ~= nil, zoomed_name)
  truthy('13.5 the title carries both numbers too',
    zoomed_title:find('108', 1, true) ~= nil and zoomed_title:find('113', 1, true) ~= nil,
    zoomed_title)
  truthy('13.5 and still names the block kind',
    zoomed_title:find('mermaid', 1, true) ~= nil, zoomed_title)

  -- Zooming back in takes the label back to the plain one: a diagram that is
  -- simply that wide must not be described as zoomed.
  feed(config.options.keymaps.zoom_in)
  truthy('13.5 zooming in takes the name back',
    wait_until(function()
      return vim.api.nvim_buf_get_name(popup.buf) == unzoomed_name
    end))
  expect('13.5 and the title back', window_title(popup.win), unzoomed_title)
  preview.close()
end)

section('13.6', function()
  -- A zoom key with nothing left to ask for does not reach the engine.
  --
  -- The popup has three budgets and no fourth, so one effective press spends one
  -- of the two keys and leaves the other live. The spent one must cost nothing:
  -- a reader holding it down is asking the same question over and over, and an
  -- engine round trip that comes back with the layout already on screen is a
  -- process spawned to answer it.
  local popup = open_diagram(floor_diagram, '13.6')
  truthy('13.6 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  -- The floor rung: the first press lands on the narrowest whole layout, and
  -- there is no narrower one to ask for.
  local opened = popup_text()
  feed(config.options.keymaps.zoom_out)
  truthy('13.6 the first zoom-out re-renders the diagram',
    wait_until(function() return popup_text() ~= opened end))

  local floor_text = popup_text()
  local before = engine_calls
  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  expect('13.6 a second zoom-out spawns no engine', engine_calls, before)
  expect('13.6 and leaves the content alone', popup_text(), floor_text)

  -- Zooming in is the live key now, and it is spent in turn.
  feed(config.options.keymaps.zoom_in)
  truthy('13.6 zooming in restores the opening layout',
    wait_until(function() return popup_text() == opened end))

  before = engine_calls
  feed(config.options.keymaps.zoom_in)
  vim.wait(400)
  expect('13.6 a second zoom-in spawns no engine', engine_calls, before)
  expect('13.6 and leaves the content alone', popup_text(), opened)
  preview.close()

  -- The same at the other rung, where the engine met the popup's inner width
  -- rather than falling back to its floor.
  local fitting = open_diagram(zoom_diagram, '13.6')
  truthy('13.6 the fitting fixture opened', fitting ~= nil)
  if not fitting then
    return
  end

  local fitting_opened = popup_text()
  feed(config.options.keymaps.zoom_out)
  truthy('13.6 zooming the fitting diagram out re-renders it',
    wait_until(function() return popup_text() ~= fitting_opened end))

  local fitting_zoomed = popup_text()
  before = engine_calls
  feed(config.options.keymaps.zoom_out)
  vim.wait(400)
  expect('13.6 zooming out at the popup\'s own width spawns no engine',
    engine_calls, before)
  expect('13.6 and leaves the content alone', popup_text(), fitting_zoomed)
  preview.close()
end)

section('13.7', function()
  -- 3.11 the scroll keys
  local popup = open_diagram(floor_diagram, '13.7')
  truthy('13.7 a diagram popup is open', popup ~= nil)
  if not popup then
    return
  end

  local scroll_left = mapping(config.options.keymaps.scroll_left)
  local scroll_right = mapping(config.options.keymaps.scroll_right)
  truthy('13.7 the scroll-left key is bound in the popup', next(scroll_left) ~= nil)
  truthy('13.7 the scroll-right key is bound in the popup', next(scroll_right) ~= nil)
  expect('13.7 and it is a buffer-local mapping', scroll_right.buffer, 1)
  truthy('13.7 and it is described as scrolling',
    (scroll_right.desc or ''):find('scroll', 1, true) ~= nil, scroll_right.desc)

  -- The step is the reader's own horizontal wheel step, so that the key and a
  -- tilt wheel move the view by the same amount.
  local step = tonumber(vim.o.mousescroll:match('hor%a*:(%d+)')) or 6
  truthy('13.7 the fixture\'s diagram is wider than the popup',
    widest_buffer(popup.buf) > frame(popup.win).width,
    string.format('%d vs %d', widest_buffer(popup.buf), frame(popup.win).width))
  expect('13.7 the popup opens at its left edge', leftcol(popup.win), 0)

  local opened = popup_text()
  local opened_frame = frame(popup.win)
  local before = engine_calls

  feed(config.options.keymaps.scroll_right)
  expect('13.7 the scroll-right key moves the view by the wheel step',
    leftcol(popup.win), step)

  -- Held down, the key repeats, and each repeat is one more step: this is what
  -- the two-key `zl` cannot do, since there is no single key to hold.
  feed(config.options.keymaps.scroll_right)
  expect('13.7 and repeated presses accumulate', leftcol(popup.win), step * 2)

  feed(config.options.keymaps.scroll_left)
  expect('13.7 the scroll-left key moves it back', leftcol(popup.win), step)

  feed(config.options.keymaps.scroll_left)
  feed(config.options.keymaps.scroll_left)
  expect('13.7 and stops at the left edge', leftcol(popup.win), 0)

  -- Scrolling is not a re-render: the block is the one the popup already held,
  -- moved under the window rather than laid out again.
  expect('13.7 scrolling leaves the content alone', popup_text(), opened)
  expect('13.7 and spawns no engine', engine_calls, before)
  eq_frame('13.7 and leaves the window where it was', frame(popup.win), opened_frame)
  preview.close()

  -- Bound in a table's popup as well, and not inert there: a table is laid out
  -- at a budget floored at the window's, so it can be wider than the popup too.
  truthy('13.7 reset to the wide fixture for the table', reset_to_wide())
  local tst = current_state()
  vim.api.nvim_win_set_cursor(tst.win, { render.row_for_source(tst.doc, 6) + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy('13.7 the preview key opens a popup on a table', wait_until(preview.is_open))

  local table_popup = preview.popup
  truthy('13.7 the scroll keys are bound in a table\'s popup too',
    next(mapping(config.options.keymaps.scroll_right)) ~= nil)
  truthy('13.7 and that table is wider than its popup',
    widest_buffer(table_popup.buf) > frame(table_popup.win).width,
    string.format('%d vs %d',
      widest_buffer(table_popup.buf), frame(table_popup.win).width))
  feed(config.options.keymaps.scroll_right)
  expect('13.7 so the key scrolls a table\'s popup too', leftcol(table_popup.win), step)
  preview.close()

  -- 3.11 the keys are configurable, and the default stops working when they are.
  local defaults = {
    scroll_left = config.options.keymaps.scroll_left,
    scroll_right = config.options.keymaps.scroll_right,
  }
  config.options.keymaps.scroll_left = '<C-b>'
  config.options.keymaps.scroll_right = '<C-f>'

  local rebound = open_diagram(floor_diagram, '13.7')
  truthy('13.7 a popup is open on the rebound scroll keys', rebound ~= nil)
  truthy('13.7 the configured scroll-right key is bound', next(mapping('<C-f>')) ~= nil)

  feed('<C-f>')
  expect('13.7 the configured key scrolls', leftcol(rebound.win), step)

  -- The default key has to be checked by what it does rather than by `maparg`:
  -- Neovim maps `<C-l>` globally to `nohlsearch` and a redraw, so it is never
  -- absent. What the rebinding takes away is the scrolling, and that is what is
  -- asserted — the popup keeps the position the configured key left it at.
  local scrolled_to = leftcol(rebound.win)
  feed(defaults.scroll_right)
  expect('13.7 and the default key no longer scrolls', leftcol(rebound.win), scrolled_to)
  preview.close()

  config.options.keymaps.scroll_left = defaults.scroll_left
  config.options.keymaps.scroll_right = defaults.scroll_right
end)

--------------------------------------------------------------------------------
-- 14. Images
--------------------------------------------------------------------------------

section('14.1', function()
  -- The arguments the plugin builds. The engine is *wrapped* rather than
  -- stubbed: the command line is what is under test, and the real render that
  -- follows proves the arguments are ones the engine accepts.
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local image_dir = vim.fn.fnamemodify(image_fixture, ':p:h')
  local commands = {}
  local wrapped = vim.system
  vim.system = function(cmd, opts_, on_exit)
    commands[#commands + 1] = cmd
    return wrapped(cmd, opts_, on_exit)
  end

  local function find_arg(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return cmd[i + 1]
      end
    end
    return nil
  end

  local termguicolors = vim.o.termguicolors

  -- 5.4: `auto` follows 'termguicolors' at request time. `art` because the
  -- encoding it resolves to is what this section is about; the default
  -- presentation would be a card on either kind of terminal.
  vim.o.termguicolors = false
  config.setup({ image_inline = 'art' })
  truthy('14.1 in R on a document with an image', reset_to(image_fixture))
  local win = vim.api.nvim_get_current_win()
  local cmd = commands[#commands]
  truthy('14.1 the engine was asked to render', cmd ~= nil)
  expect('14.1 without true colour, auto resolves to ascii',
    find_arg(cmd, '--image-encoding'), 'ascii')
  expect('14.1 the height bound is the page, capped by image_max_height',
    find_arg(cmd, '--image-max-height'), tostring(image_height(win)))
  expect('14.1 relative images resolve from the document\'s directory',
    find_arg(cmd, '--base'), image_dir)

  -- The same request with true colour on is a different cache key, so the next
  -- render reaches the engine and the encoding switches.
  vim.o.termguicolors = true
  local before = #commands
  md.show_rendered()
  truthy('14.1 with true colour, a new render is asked for',
    wait_until(function() return #commands > before end))
  expect('14.1 with true colour, auto resolves to braille',
    find_arg(commands[#commands], '--image-encoding'), 'braille')

  -- 5.2: an unnamed buffer has no directory to resolve against, so the flag is
  -- left out and the engine falls back to its working directory.
  local engine = require('md-render.engine')
  local answered = false
  engine.render(config.options, 'plain\n', { width = 20, encoding = 'off' }, function()
    answered = true
  end)
  truthy('14.1 the unnamed-buffer render finished', wait_until(function() return answered end))
  expect('14.1 without a file, --base is omitted',
    find_arg(commands[#commands], '--base'), nil)

  vim.o.termguicolors = termguicolors
  vim.system = wrapped
  config.setup({})
end)

section('14.2', function()
  -- 5.3: the height is part of the cache key, so a height-only change reaches
  -- the engine instead of being answered from a document laid out for another
  -- page.
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local height = vim.api.nvim_win_get_height(vim.api.nvim_get_current_win())
  config.setup({ image_mode = 'blocks' })
  truthy('14.2 in R on a document with an image', reset_to(image_fixture))
  local st = current_state()

  local before = engine_calls
  vim.cmd(string.format('resize %d', height - 3))
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('14.2 a height-only change asks the engine again',
    wait_until(function() return engine_calls > before end))
  -- `:resize` counts the statusline in its number, so the text height it
  -- leaves is one row less than asked for; what matters here is only that the
  -- window changed at all.
  truthy('14.2 the window really is shorter',
    vim.api.nvim_win_get_height(st.win) < height,
    string.format('height %d, was %d', vim.api.nvim_win_get_height(st.win), height))

  vim.cmd(string.format('resize %d', height))
  config.setup({})
end)

section('14.3', function()
  -- 5.6: `off` reproduces the old output exactly — alt text, no artwork.
  local image_fixture = repo .. '/tests/fixtures/image.md'
  config.setup({ image_mode = 'off' })
  truthy('14.3 in R with images off', reset_to(image_fixture))

  local text = table.concat(
    vim.api.nvim_buf_get_lines(current_state().rendered, 0, -1, false), '\n')
  truthy('14.3 the alt text is shown', text:find('a sample image', 1, true) ~= nil, text)
  truthy('14.3 no artwork is drawn',
    text:find('▀', 1, true) == nil and text:find('▄', 1, true) == nil)

  config.setup({})
end)

section('14.4', function()
  -- 5.6: an image the engine cannot draw is not an error. The document around
  -- it renders, its alt text stands in, and nothing is reported.
  local missing_fixture = repo .. '/tests/fixtures/missing-image.md'
  local function errors()
    local n = 0
    for _, note in ipairs(notifications) do
      if note.level >= vim.log.levels.ERROR then
        n = n + 1
      end
    end
    return n
  end

  config.setup({ image_mode = 'blocks' })
  local before_errors = errors()
  truthy('14.4 in R on a document with a missing image', reset_to(missing_fixture))

  local text = table.concat(
    vim.api.nvim_buf_get_lines(current_state().rendered, 0, -1, false), '\n')
  truthy('14.4 the prose before it is there',
    text:find('Before the missing picture', 1, true) ~= nil, text)
  truthy('14.4 the alt text stands in for the image',
    text:find('a missing image', 1, true) ~= nil, text)
  truthy('14.4 the prose after it is there',
    text:find('After the missing picture', 1, true) ~= nil, text)
  expect('14.4 and nothing was reported', errors(), before_errors)

  config.setup({})
end)

section('14.5', function()
  -- 5.6: a shorter window means a shorter image, and the picture keeps its
  -- shape rather than being cropped.
  local image_fixture = repo .. '/tests/fixtures/image.md'
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('14.5 in R on a document with an image', reset_to(image_fixture))
  local st = current_state()
  local height = vim.api.nvim_win_get_height(st.win)

  local function artwork_rows()
    local n = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)) do
      if line:find('▀', 1, true) or line:find('▄', 1, true) then
        n = n + 1
      end
    end
    return n
  end

  local tall = artwork_rows()
  truthy('14.5 the artwork is drawn', tall > 0, string.format('%d rows', tall))
  truthy('14.5 and fits the page', tall <= height,
    string.format('%d rows in a %d-row page', tall, height))

  vim.cmd(string.format('resize %d', height - 3))
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('14.5 a shorter window redraws it shorter',
    wait_until(function() return artwork_rows() < tall end),
    string.format('still %d rows', artwork_rows()))

  vim.cmd(string.format('resize %d', height))
  config.setup({})
end)

section('14.6', function()
  -- The inline height cap. The harness window is 8 rows (set at the top of this
  -- file), so the default of 20 cannot bind here: the default is asserted on
  -- the option itself and the bound with a cap small enough to bite.
  local image_fixture = repo .. '/tests/fixtures/image.md'
  expect('14.6 the cap defaults to 20 rows', config.defaults.image_max_height, 20)

  local inner = vim.system
  local commands = {}
  vim.system = function(cmd, opts, on_exit)
    commands[#commands + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local function find_arg(cmd, flag)
    for i, arg in ipairs(cmd or {}) do
      if arg == flag then
        return cmd[i + 1]
      end
    end
    return nil
  end

  -- The 16×16 fixture is 16 columns by 8 rows uncapped; a cap of 4 halves it.
  local function artwork()
    local rows, widest = 0, 0
    for _, line in ipairs(
      vim.api.nvim_buf_get_lines(current_state().rendered, 0, -1, false)) do
      if line:find('▀', 1, true) or line:find('▄', 1, true) then
        rows = rows + 1
        widest = math.max(widest, vim.fn.strdisplaywidth(line))
      end
    end
    return rows, widest
  end

  config.setup({ image_mode = 'blocks', image_inline = 'art', image_max_height = 4 })
  truthy('14.6 in R with a 4-row cap', reset_to(image_fixture))
  local height = vim.api.nvim_win_get_height(current_state().win)
  truthy('14.6 the window is taller than the cap', height > 4,
    string.format('window %d rows', height))
  expect('14.6 the engine is asked for the cap',
    find_arg(commands[#commands], '--image-max-height'), '4')

  local rows, widest = artwork()
  truthy('14.6 the artwork is at most 4 rows tall', rows > 0 and rows <= 4,
    string.format('%d rows', rows))
  truthy('14.6 and correspondingly narrower than 16 columns', widest < 16,
    string.format('%d columns', widest))

  -- `false` means no cap. nil could not: `setup` merges tables, and a nil value
  -- is indistinguishable from a missing key.
  config.setup({ image_mode = 'blocks', image_inline = 'art', image_max_height = false })
  truthy('14.6 in R with the cap off', reset_to(image_fixture))
  expect('14.6 without the cap the engine gets the page height',
    find_arg(commands[#commands], '--image-max-height'),
    tostring(vim.api.nvim_win_get_height(current_state().win)))
  rows = artwork()
  expect('14.6 and the artwork keeps its natural 8 rows', rows, 8)

  vim.system = inner
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 6.1 The image quality options
--------------------------------------------------------------------------------

section('6.1', function()
  config.setup({})
  expect('6.1 image_mode defaults to auto', config.defaults.image_mode, 'auto')
  expect('6.1 image_palette defaults to auto', config.defaults.image_palette, 'auto')
  expect('6.1 image_background defaults to terminal',
    config.defaults.image_background, 'terminal')
  expect('6.1 image_dither defaults to auto', config.defaults.image_dither, 'auto')
  expect('6.1 image_min_rows defaults to 0', config.defaults.image_min_rows, 0)
  expect('6.1 image_sharpen defaults to false', config.defaults.image_sharpen, false)

  local resolved = config.setup({
    image_palette = 'adaptive',
    image_background = '#102030',
    image_dither = false,
    image_min_rows = 8,
    image_sharpen = true,
  })
  expect('6.1 setup overrides image_palette', resolved.image_palette, 'adaptive')
  expect('6.1 setup overrides image_background', resolved.image_background, '#102030')
  expect('6.1 setup overrides image_dither', resolved.image_dither, false)
  expect('6.1 setup overrides image_min_rows', resolved.image_min_rows, 8)
  expect('6.1 setup overrides image_sharpen', resolved.image_sharpen, true)
  expect('6.1 and the defaults are not mutated', config.defaults.image_palette, 'auto')

  -- `braille` is a mode in its own right, not only the `auto` result.
  config.setup({ image_mode = 'braille' })
  expect('6.1 braille is selectable', config.image_encoding(), 'braille')
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 6.2 The options reach the engine
--------------------------------------------------------------------------------

section('6.2', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local inner = vim.system
  local commands = {}
  vim.system = function(cmd, opts, on_exit)
    commands[#commands + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local function flag(name, cmd)
    cmd = cmd or commands[#commands] or {}
    for i, arg in ipairs(cmd) do
      if arg == name then
        return cmd[i + 1]
      end
    end
    return nil
  end

  local function has(name, cmd)
    return flag(name, cmd) ~= nil or vim.tbl_contains(cmd or commands[#commands] or {}, name)
  end

  config.setup({
    image_mode = 'quads',
    image_palette = 'theme',
    image_background = '#102030',
    image_dither = true,
    image_min_rows = 8,
    image_sharpen = true,
  })
  truthy('6.2 in R on a document with an image', reset_to(image_fixture))
  expect('6.2 palette is passed', flag('--image-palette'), 'theme')
  expect('6.2 background is passed', flag('--image-background'), '#102030')
  expect('6.2 dither true becomes on', flag('--image-dither'), 'on')
  expect('6.2 minimum height is passed', flag('--image-min-rows'), '8')
  truthy('6.2 sharpening is passed', has('--image-sharpen'))
  -- A named background already is the page braille is drawn on, so the plugin
  -- does not name a second one.
  expect('6.2 no page is sent when the background is named',
    has('--image-paper'), false)

  -- With transparency left to the terminal the plugin is the only one that
  -- knows the page, and braille inks the side away from it.
  local termguicolors = vim.o.termguicolors
  vim.o.termguicolors = true
  vim.api.nvim_set_hl(0, 'Normal', { bg = 0x1e1e2e })
  config.setup({
    image_mode = 'quads',
    image_background = 'terminal',
  })
  truthy('6.2 a terminal page asks the engine again',
    reset_to(image_fixture))
  expect('6.2 the terminal background is passed as the page',
    flag('--image-paper'), '#1e1e2e')
  vim.o.termguicolors = termguicolors
  vim.api.nvim_set_hl(0, 'Normal', {})
  config.setup({ image_background = '#102030' })

  -- Each of the five is in the cache key: changing one re-renders rather than
  -- reusing a document drawn with the old value.
  local before = engine_calls
  config.setup({
    image_mode = 'quads',
    image_palette = 'theme',
    image_background = '#102030',
    image_dither = false,
    image_min_rows = 8,
    image_sharpen = true,
  })
  md.show_rendered()
  truthy('6.2 a changed option asks the engine again',
    wait_until(function() return engine_calls > before end))
  expect('6.2 dither false becomes off', flag('--image-dither'), 'off')

  vim.system = inner
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 6.3 `auto` resolution
--------------------------------------------------------------------------------

section('6.3', function()
  local termguicolors = vim.o.termguicolors

  config.setup({ image_mode = 'auto', image_palette = 'auto' })
  vim.o.termguicolors = true
  expect('6.3 auto with true colour is braille', config.image_encoding(), 'braille')
  expect('6.3 and the palette is full', config.image_palette(), 'full')
  vim.o.termguicolors = false
  expect('6.3 auto without true colour is ascii', config.image_encoding(), 'ascii')
  expect('6.3 and the palette is still full', config.image_palette(), 'full')

  for _, mode in ipairs({ 'quads', 'blocks' }) do
    config.setup({ image_mode = mode, image_palette = 'auto' })
    expect('6.3 ' .. mode .. ' keeps its encoding', config.image_encoding(), mode)
    expect('6.3 ' .. mode .. ' resolves the palette to adaptive',
      config.image_palette(), 'adaptive')
  end

  config.setup({ image_mode = 'quads', image_palette = 'theme' })
  expect('6.3 an explicit palette wins over auto', config.image_palette(), 'theme')

  vim.o.termguicolors = termguicolors
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 2.1 Options and keys
--------------------------------------------------------------------------------

section('2.1', function()
  config.setup({})
  expect('2.1 image_animation defaults on', config.options.image_animation, true)
  expect('2.1 frame_next defaults to <C-n>', config.options.keymaps.frame_next, '<C-n>')
  expect('2.1 open_image defaults to gx', config.options.keymaps.open_image, 'gx')
  expect('2.1 pause defaults to <Space>', config.options.keymaps.pause, '<Space>')

  local resolved = config.setup({
    image_animation = false,
    keymaps = { frame_next = '<C-p>' },
  })
  expect('2.1 setup overrides image_animation', resolved.image_animation, false)
  expect('2.1 setup overrides frame_next', resolved.keymaps.frame_next, '<C-p>')
  expect('2.1 setup keeps the other new keys', resolved.keymaps.open_image, 'gx')
  expect('2.1 and the defaults are not mutated', config.defaults.image_animation, true)
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 2.2 The engine's animation flag
--------------------------------------------------------------------------------

section('2.2', function()
  local engine = require('md-render.engine')

  local inner = vim.system
  local calls = {}
  vim.system = function(cmd, opts, on_exit)
    calls[#calls + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local function has_flag(argv, flag)
    for _, a in ipairs(argv or {}) do
      if a == flag then
        return true
      end
    end
    return false
  end

  local function render_with(animation)
    calls = {}
    local done = false
    local err
    engine.render(config.options, 'plain text\n', {
      width = 20,
      encoding = 'off',
      animation = animation,
    }, function(e)
      err = e
      done = true
    end)
    truthy('2.2 the engine answers', wait_until(function() return done end),
      tostring(err or 'no answer'))
    return calls[1]
  end

  local animated = render_with(true)
  truthy('2.2 an animated request passes --image-animation', has_flag(animated, '--image-animation'),
    vim.inspect(animated))

  local plain = render_with(false)
  truthy('2.2 an ordinary request passes no flag', plain and not has_flag(plain, '--image-animation'),
    vim.inspect(plain))

  vim.system = inner
end)

--------------------------------------------------------------------------------
-- 2.3 The cache key knows about frames
--------------------------------------------------------------------------------

section('2.3', function()
  -- A key that stands apart from any real buffer: the cache is a plain table.
  local buf = {}
  local doc = { width = 20, styles = {}, lines = {} }
  local theme = 'catppuccin_mocha'

  local image = {
    palette = 'theme',
    background = 'terminal',
    dither = false,
    min_rows = 0,
    sharpen = false,
  }

  state.store(buf, 7, 80, 10, 'quads', theme, false, image, doc)
  truthy('2.3 a plain render is found for a plain request',
    state.cached(buf, 7, 80, 10, 'quads', theme, false, image) == doc)
  expect('2.3 the same render is not returned for an animated request',
    state.cached(buf, 7, 80, 10, 'quads', theme, true, image), nil)

  state.store(buf, 7, 80, 10, 'quads', theme, true, image, doc)
  expect('2.3 an animated render is not returned for a plain request',
    state.cached(buf, 7, 80, 10, 'quads', theme, false, image), nil)
  truthy('2.3 and it is found for an animated one',
    state.cached(buf, 7, 80, 10, 'quads', theme, true, image) == doc)

  state.forget_cache(buf)
end)

--------------------------------------------------------------------------------
-- 2.4 Finding the image under the cursor
--------------------------------------------------------------------------------

section('2.4', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local svg_fixture = repo .. '/tests/fixtures/image-svg.md'

  local function rows()
    local st = current_state()
    return vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false), st
  end

  local function row_where(text)
    local rendered = rows()
    for i, line in ipairs(rendered) do
      if line:find(text, 1, true) then
        return i - 1
      end
    end
    return nil
  end

  -- The artwork itself: `art` keeps the dots these checks look for. The
  -- default presentation is the subject of 3.1-3.6 of the inline-image change.
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('2.4 in R on a document with a drawn image', reset_to(image_fixture))

  local rendered, st = rows()
  local artwork
  for i, line in ipairs(rendered) do
    if line:find('▀', 1, true) or line:find('▄', 1, true) then
      artwork = i - 1
      break
    end
  end
  truthy('2.4 the artwork is drawn', artwork ~= nil)
  local source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  local found = artwork and link.image_at_row(source_lines, st.doc, artwork)
  truthy('2.4 the artwork row finds the image', found ~= nil)
  expect('2.4 with its destination', found and found.raw, 'images/image_sample.png')
  truthy('2.4 and it is flagged as an image', found and found.image == true)

  local prose = row_where('Before the picture')
  truthy('2.4 the prose row exists', prose ~= nil)
  expect('2.4 a prose row finds no image', link.image_at_row(source_lines, st.doc, prose), nil)

  truthy('2.4 in R on a document with an undrawable image', reset_to(svg_fixture))
  rendered, st = rows()
  local alt = row_where('an svg icon')
  truthy('2.4 the alt text is shown', alt ~= nil)
  source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  found = alt and link.image_at_row(source_lines, st.doc, alt)
  truthy('2.4 the alt-text row finds the image', found ~= nil)
  expect('2.4 with the SVG destination', found and found.raw, 'images/icon.svg')
  truthy('2.4 and it is flagged as an image', found and found.image == true)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.1 Applying one frame touches only the artwork
--------------------------------------------------------------------------------

--- The fixture with an animated GIF of three flat-coloured frames.
local animated_fixture = repo .. '/tests/fixtures/animated.md'

--- The 0-based display row the animated fixture's artwork starts on.
local function artwork_row(st)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)) do
    if line:find('▀', 1, true) or line:find('▄', 1, true) then
      return i - 1
    end
  end
  return nil
end

--- The 0-based display row whose text contains `text`, or nil.
local function rendered_row(st, text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)) do
    if line:find(text, 1, true) then
      return i - 1
    end
  end
end

--- Every extmark in `buf`, as `{ row, col, end_col, group }`.
local function extmarks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    out[#out + 1] = { m[2], m[3], m[4].end_col, m[4].hl_group }
  end
  return out
end

--- Render `source`'s contents, resolving relative images against `path`'s
--- directory, and wait for the answer.
local function render_doc(source, path, view)
  local engine = require('md-render.engine')
  local content = table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n')
  local ok, doc, err = pcall(function()
    local got, got_err, done
    engine.render(config.options, content, vim.tbl_extend('force', {
      base = vim.fn.fnamemodify(path, ':p:h'),
      encoding = 'blocks',
    }, view), function(e, d)
      got, got_err, done = d, e, true
    end)
    wait_until(function() return done end)
    return got, got_err
  end)
  return ok and doc, ok and err or doc
end

section('3.1', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('3.1 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local first = artwork_row(st)
  truthy('3.1 the artwork is drawn', first ~= nil)

  local static = st.doc
  local before_lines = vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)
  local before_marks = extmarks(st.rendered)

  local doc, err = render_doc(st.source, animated_fixture, {
    width = static.width,
    height = vim.api.nvim_win_get_height(st.win),
    animation = true,
  })
  truthy('3.1 the engine returns an animated document', doc ~= nil, tostring(err))
  local animation = doc and doc.animations and doc.animations[1]
  truthy('3.1 with an animation', animation ~= nil)
  expect('3.1 at the artwork row', animation and animation.start, first)
  expect('3.1 one row tall', animation and animation.rows, 1)

  local span = animation and animation.frames[2].lines[1][1]
  truthy('3.1 it has a second frame', span ~= nil)
  truthy('3.1 the frame is applied', render.frame(st.rendered, doc, animation, 1))

  local after_lines = vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)
  local mismatched = {}
  for i, line in ipairs(before_lines) do
    if i - 1 < animation.start or i - 1 >= animation.start + animation.rows then
      if after_lines[i] ~= line then
        mismatched[#mismatched + 1] = i - 1
      end
    end
  end
  eq_table('3.1 no other line changed', mismatched, {})

  local function outside(marks)
    local kept = {}
    for _, m in ipairs(marks) do
      if m[1] < animation.start or m[1] >= animation.start + animation.rows then
        kept[#kept + 1] = m
      end
    end
    return kept
  end
  eq_table('3.1 no other extmark changed', outside(extmarks(st.rendered)), outside(before_marks))

  local marks = vim.api.nvim_buf_get_extmarks(st.rendered, render.ns,
    { animation.start, 0 }, { animation.start + animation.rows - 1, -1 }, { details = true })
  expect('3.1 the artwork is one span', #marks, 1)
  expect('3.1 showing the requested frame',
    marks[1] and marks[1][4].hl_group, style.group(doc.styles[span[1] + 1], span[1]))
  expect('3.1 with the frame\'s text', after_lines[animation.start + 1], span[2])

  truthy('3.1 and the buffer is left unmodifiable', not vim.bo[st.rendered].modifiable)
  truthy('3.1 and unmodified', not vim.bo[st.rendered].modified)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.2 The first press fetches, the rest are immediate
--------------------------------------------------------------------------------

section('3.2', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('3.2 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.2 the artwork is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })

  local inner = vim.system
  local calls = {}
  vim.system = function(cmd, opts, on_exit)
    calls[#calls + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local function has_flag(argv, flag)
    for _, a in ipairs(argv or {}) do
      if a == flag then
        return true
      end
    end
    return false
  end

  -- Nothing is fetched until the key is pressed.
  expect('3.2 no frames before the key', st.doc and st.doc.animations, nil)
  expect('3.2 and no engine call', #calls, 0)

  md.frame_next(st.win)
  truthy('3.2 the first press fetches the frames',
    wait_until(function() return st.doc and st.doc.animations and st.doc.animations[1] end))
  expect('3.2 with exactly one engine call', #calls, 1)
  truthy('3.2 asking for animation', has_flag(calls[1], '--image-animation'), vim.inspect(calls[1]))

  local animation = st.doc.animations[1]
  expect('3.2 and shows the second frame', st.frames[animation.source], 1)
  local rendered = vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(st.rendered, render.ns,
    { animation.start, 0 }, { animation.start + animation.rows - 1, -1 }, { details = true })
  local span = animation.frames[2].lines[1][1]
  expect('3.2 the frame on screen is the second one',
    marks[1] and marks[1][4].hl_group, style.group(st.doc.styles[span[1] + 1], span[1]))
  expect('3.2 with its text', rendered[animation.start + 1], span[2])

  -- Later presses are answered from memory.
  md.frame_next(st.win)
  expect('3.2 the second press advances', st.frames[animation.source], 2)
  expect('3.2 with no engine call', #calls, 1)
  md.frame_next(st.win)
  expect('3.2 the third wraps to the first frame', st.frames[animation.source], 0)

  vim.system = inner
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.3 Off an animated image the key is Vim's
--------------------------------------------------------------------------------

section('3.3', function()
  -- A motion stands in for "the key's ordinary editor action": `nvim -l` never
  -- enters the main loop, so a pending operator (`g@`) is flushed by the time
  -- the feed returns and cannot be observed. A `w` that moves the cursor is the
  -- same proof — the key reached Vim rather than being swallowed.
  config.setup({ image_mode = 'blocks', image_inline = 'art', keymaps = { frame_next = 'w' } })
  truthy('3.3 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.3 the artwork is drawn', row ~= nil)

  local function prose_row()
    for i, line in ipairs(vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)) do
      if line:find('Before the picture', 1, true) then
        return i - 1
      end
    end
  end

  vim.api.nvim_win_set_cursor(st.win, { prose_row() + 1, 0 })
  local before = vim.api.nvim_win_get_cursor(st.win)
  feed('w')
  truthy('3.3 on prose the key reaches Vim',
    not vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), before))

  -- Even on the artwork it is fetched, not consumed. `image_animation = false`
  -- takes the key out of the plugin's hands entirely.
  config.setup({ image_mode = 'blocks', image_inline = 'art', keymaps = { frame_next = 'w' },
    image_animation = false })
  truthy('3.3 in R with animation off', reset_to(animated_fixture))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { artwork_row(st) + 1, 0 })
  before = vim.api.nvim_win_get_cursor(st.win)
  feed('w')
  truthy('3.3 with animation off the key reaches Vim',
    not vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), before))
  truthy('3.3 and no frames were fetched', st.doc and st.doc.animations == nil)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.4 Stepping keeps the cursor and the source mapping
--------------------------------------------------------------------------------

section('3.4', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('3.4 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.4 the artwork is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })

  local before = vim.api.nvim_win_get_cursor(st.win)
  local lnum = render.source_line_for(st.doc, row)
  truthy('3.4 the artwork maps to a source line', lnum ~= nil)

  md.frame_next(st.win)
  truthy('3.4 the first press fetches the frames',
    wait_until(function() return st.doc and st.doc.animations and st.doc.animations[1] end))
  md.frame_next(st.win)

  eq_table('3.4 the cursor did not move', vim.api.nvim_win_get_cursor(st.win), before)
  expect('3.4 the artwork still maps to the same source line',
    render.source_line_for(st.doc, row), lnum)
  expect('3.4 and the source line still maps to the artwork',
    render.row_for_source(st.doc, lnum), row)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.5 A re-render puts the image back on its first frame
--------------------------------------------------------------------------------

section('3.5', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('3.5 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.5 the artwork is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })

  md.frame_next(st.win)
  truthy('3.5 frames arrive',
    wait_until(function() return st.doc and st.doc.animations and st.doc.animations[1] end))
  local animation = st.doc.animations[1]
  local source = animation.source
  expect('3.5 showing a later frame', st.frames[source], 1)

  -- A height change is a re-render: the page changed, so the engine is asked
  -- again and the answer is a new document with no frame on screen.
  local height = vim.api.nvim_win_get_height(st.win)
  vim.cmd(string.format('resize %d', height - 3))
  vim.api.nvim_exec_autocmds('WinResized', {})
  truthy('3.5 a resize re-renders',
    wait_until(function() return st.frames ~= nil and st.frames[source] == nil end))
  truthy('3.5 and the document is no longer the animated one',
    st.doc ~= nil and st.doc.animations == nil)

  vim.cmd(string.format('resize %d', height))
  truthy('3.5 the window is restored', wait_until(function()
    return vim.api.nvim_win_get_height(st.win) == height
  end))

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.6 An animation over the caps is reported, not silently still
--------------------------------------------------------------------------------

section('3.6', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local path = repo .. '/tests/fixtures/too-large-animation.md'
  truthy('3.6 in R on the over-cap fixture', reset_to(path))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.6 the first frame is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })
  local cursor = vim.api.nvim_win_get_cursor(st.win)

  local before = #notifications
  md.frame_next(st.win)
  truthy('3.6 the engine names the reference as refused',
    wait_until(function()
      return st.doc and st.doc.animations_limited and #st.doc.animations_limited > 0
    end))
  truthy('3.6 and the reader is told', wait_until(function()
    return #notifications > before
  end), vim.inspect(notifications[#notifications]))
  expect('3.6 as a warning', notifications[#notifications].level, vim.log.levels.WARN)
  truthy('3.6 naming the file',
    notifications[#notifications].msg:find('image_4097.gif', 1, true) ~= nil,
    notifications[#notifications].msg)
  expect('3.6 with no frames carried', st.doc.animations, nil)
  truthy('3.6 and the key is not passed on to Vim',
    vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))

  -- Pressing again is answered from the state already on screen: the same
  -- message is not repeated, and no second request is made.
  local notes = #notifications
  md.frame_next(st.win)
  vim.wait(100)
  expect('3.6 a second press does not repeat the warning', #notifications, notes)
  truthy('3.6 or move the cursor',
    vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.7 Presses during the fetch are remembered
--------------------------------------------------------------------------------

section('3.7', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local path = repo .. '/tests/fixtures/animated.md'
  truthy('3.7 in R on the animated fixture', reset_to(path))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.7 the artwork is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })
  local cursor = vim.api.nvim_win_get_cursor(st.win)

  -- An animated render cached by an earlier section would answer this request
  -- immediately, and the in-flight state is exactly what is under test.
  state.forget_cache(st.source)

  local engine_mod = require('md-render.engine')
  local real_render = engine_mod.render
  local calls = 0
  engine_mod.render = function(opts, content, view, cb)
    calls = calls + 1
    vim.defer_fn(function()
      real_render(opts, content, view, cb)
    end, 250)
  end

  local echoes = {}
  local real_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, history, opts)
    echoes[#echoes + 1] = chunks[1] and chunks[1][1] or ''
    return real_echo(chunks, history, opts)
  end

  -- Both presses land before the answer: one fetch, and the image moves two
  -- frames — the fixture has three, so two steps is the third frame.
  md.frame_next(st.win)
  md.frame_next(st.win)
  expect('3.7 two presses issue one fetch', calls, 1)
  truthy('3.7 the fetch is announced at the bottom',
    echoes[1] and echoes[1]:find('decoding', 1, true) ~= nil, vim.inspect(echoes))

  truthy('3.7 the frames arrive', wait_until(function()
    return st.doc and st.doc.animations ~= nil
  end))
  local animation = st.doc.animations[1]
  expect('3.7 two presses land the third frame', st.frames[animation.source], 2)
  expect('3.7 and the hint is cleared', echoes[#echoes], '')
  expect('3.7 with no second fetch', calls, 1)
  truthy('3.7 and the cursor has not moved',
    vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))

  -- Frames in memory: one press, one frame, still no request.
  md.frame_next(st.win)
  expect('3.7 the next press steps one frame', st.frames[animation.source], 0)
  expect('3.7 and still no engine call', calls, 1)

  engine_mod.render = real_render
  vim.api.nvim_echo = real_echo
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.8 An animation over the carried-frame budget is sampled, not refused
--------------------------------------------------------------------------------

section('3.8', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local path = repo .. '/tests/fixtures/sampled-animation.md'
  truthy('3.8 in R on the sampled fixture', reset_to(path))
  local st = current_state()
  local row = artwork_row(st)
  truthy('3.8 the artwork is drawn', row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  expect('3.8 the engine does not name it as refused', st.doc.animations_limited, nil)

  local before = #notifications
  md.frame_next(st.win)
  truthy('3.8 the first press fetches the frames', wait_until(function()
    return st.doc and st.doc.animations and st.doc.animations[1] ~= nil
  end))
  local animation = st.doc.animations[1]
  expect('3.8 and shows the second frame', st.frames[animation.source], 1)
  expect('3.8 without warning the reader', #notifications, before)
  truthy('3.8 and the cursor has not moved',
    vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))

  -- The sampled set is carried, so later presses are answered from memory.
  md.frame_next(st.win)
  expect('3.8 a later press advances', st.frames[animation.source], 2)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 4.1 Opening an image with the system application
--------------------------------------------------------------------------------

section('4.1', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })

  local opened = {}
  local real_open = vim.ui.open
  vim.ui.open = function(path)
    opened[#opened + 1] = path
    return {}
  end

  local function latest()
    return notifications[#notifications] or {}
  end

  -- Relative: resolved against the document's directory.
  truthy('4.1 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { artwork_row(st) + 1, 0 })
  md.open_image()
  expect('4.1 a relative reference opens one file', #opened, 1)
  truthy('4.1 resolved beside the document',
    same_path(opened[1], repo .. '/tests/fixtures/images/image_animation.gif'), opened[1])

  -- Absolute: used as given.
  local abs = repo .. '/tests/fixtures/images/image_sample.png'
  local tmp = vim.fn.tempname() .. '.md'
  vim.fn.writefile({ '![absolute](' .. abs .. ')' }, tmp)
  truthy('4.1 in R on an absolute reference', reset_to(tmp))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { artwork_row(st) + 1, 0 })
  md.open_image()
  expect('4.1 an absolute reference opens one file', #opened, 2)
  truthy('4.1 used as written', same_path(opened[2], abs), opened[2])
  vim.fn.delete(tmp)

  -- Remote: reported, never fetched.
  truthy('4.1 in R on a remote reference', reset_to(repo .. '/tests/fixtures/remote-image.md'))
  st = current_state()
  local remote_row = rendered_row(st, 'a remote picture')
  truthy('4.1 the remote alt text is shown', remote_row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { remote_row + 1, 0 })
  local before = #notifications
  md.open_image()
  expect('4.1 a remote reference opens nothing', #opened, 2)
  truthy('4.1 and is reported', #notifications > before
    and latest().msg:find('is not a local file', 1, true) ~= nil, latest().msg)
  expect('4.1 as a warning', latest().level, vim.log.levels.WARN)

  -- Missing: reported, nothing launched.
  truthy('4.1 in R on a missing reference', reset_to(repo .. '/tests/fixtures/missing-image.md'))
  st = current_state()
  local missing_row = rendered_row(st, 'a missing image')
  truthy('4.1 the missing image alt text is shown', missing_row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { missing_row + 1, 0 })
  before = #notifications
  md.open_image()
  expect('4.1 a missing file opens nothing', #opened, 2)
  truthy('4.1 and is reported', latest().msg:find('no such file', 1, true) ~= nil, latest().msg)

  -- Not a file: reported, nothing launched.
  truthy('4.1 in R on a directory reference', reset_to(repo .. '/tests/fixtures/directory-image.md'))
  st = current_state()
  local dir_row = rendered_row(st, 'a directory')
  truthy('4.1 the directory alt text is shown', dir_row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { dir_row + 1, 0 })
  before = #notifications
  md.open_image()
  expect('4.1 a directory opens nothing', #opened, 2)
  truthy('4.1 and is reported', latest().msg:find('not a file', 1, true) ~= nil, latest().msg)

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 4.2 Alt text of an image the engine cannot draw
--------------------------------------------------------------------------------

section('4.2', function()
  config.setup({ image_mode = 'blocks' })

  local opened = {}
  local real_open = vim.ui.open
  vim.ui.open = function(path)
    opened[#opened + 1] = path
    return {}
  end

  truthy('4.2 in R on the SVG fixture', reset_to(repo .. '/tests/fixtures/image-svg.md'))
  local st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { rendered_row(st, 'an svg icon') + 1, 0 })
  md.open_image()
  expect('4.2 the alt text opens the SVG', #opened, 1)
  truthy('4.2 the file the reference names',
    opened[1] and opened[1]:match('icon%.svg$') ~= nil, opened[1])

  -- On prose the key is Vim's. A `w` stands in for "the ordinary action", since
  -- a pending operator is flushed before `nvim -l` can observe it.
  config.setup({ image_mode = 'blocks', keymaps = { open_image = 'w' } })
  truthy('4.2 in R with a motion as the key', reset_to(repo .. '/tests/fixtures/image-svg.md'))
  st = current_state()
  local prose_row = rendered_row(st, 'Before the picture')
  truthy('4.2 the prose row exists', prose_row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { prose_row + 1, 0 })
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  feed('w')
  truthy('4.2 on prose the key reaches Vim',
    not vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 4.3 A failed launch is reported
--------------------------------------------------------------------------------

section('4.3', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })

  local real_open = vim.ui.open
  vim.ui.open = function()
    return nil, 'no handler on this desktop'
  end

  truthy('4.3 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { artwork_row(st) + 1, 0 })
  local before = #notifications
  md.open_image()
  truthy('4.3 the failure is reported to the user', #notifications > before)
  truthy('4.3 with what the handler said',
    notifications[#notifications].msg:find('no handler on this desktop', 1, true) ~= nil,
    notifications[#notifications].msg)
  expect('4.3 as a warning', notifications[#notifications].level, vim.log.levels.WARN)

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.1 The popup shows the image alone
--------------------------------------------------------------------------------

--- A document whose only image is inline, in the middle of a paragraph.
local inline_fixture = repo .. '/tests/fixtures/inline-image.md'

section('5.1', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('5.1 in R on a document with an inline image', reset_to(inline_fixture))
  local st = current_state()
  -- The engine draws an inline image too, so the paragraph is a run of artwork
  -- rows between the prose before and after it, all mapped to the same source
  -- line. The cursor can be on any of them; the first artwork row is one.
  local row = artwork_row(st)
  truthy('5.1 the inline artwork is drawn', row ~= nil)
  expect('5.1 and maps to the paragraph\'s line', render.source_line_for(st.doc, row), 2)
  local lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)

  local block = preview.locate(st.doc, row, lines)
  truthy('5.1 the paragraph row resolves to a block', block ~= nil)
  expect('5.1 and to the image kind', block and block.kind, 'image')
  eq_table('5.1 carrying the reference alone', block and block.lines,
    { '![a small image](images/image_sample.png)' })

  -- The geometry and view agree with design D6: the popup's inner width and
  -- height are the budget, and the image is drawn rather than asked for at
  -- `off` — task 5.1's "off-encoding render" is the one line of it the design
  -- overrides, since `off` would show the alt text and not the image.
  local geometry = preview.geometry('image', 80)
  expect('5.1 the image budget is the popup\'s inner width', geometry.budget, geometry.inner)

  local base = vim.fn.fnamemodify(inline_fixture, ':p:h')
  local view = preview.view(block, geometry, base)
  expect('5.1 at the popup\'s inner width', view.width, geometry.inner)
  expect('5.1 bounded by the popup\'s inner height', view.height, geometry.max_h - 2)
  -- The inline height cap is read only by `request`. The popup keeps its own
  -- geometry, which is what lets the preview show an image larger than the page
  -- does at all.
  config.setup({ image_mode = 'blocks', image_max_height = 3 })
  expect('5.1 the inline height cap does not reach the popup',
    preview.view(block, geometry, base).height, geometry.max_h - 2)
  config.setup({ image_mode = 'blocks' })
  expect('5.1 at the document\'s encoding, not off', view.encoding, 'blocks')
  expect('5.1 with the document\'s base', view.base, base)

  local inner = vim.system
  local calls = {}
  vim.system = function(cmd, opts, on_exit)
    calls[#calls + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local doc, err, done
  preview.render_block(config.options, block, view, function(e, d)
    err, doc, done = e, d, true
  end)
  truthy('5.1 the popup render answers', wait_until(function() return done end), tostring(err))
  vim.system = inner

  local function flag(name)
    for i, a in ipairs(calls[1] or {}) do
      if a == name then
        return calls[1][i + 1]
      end
    end
  end
  expect('5.1 asked for the popup\'s width', flag('--width'), tostring(geometry.inner))
  expect('5.1 asked for the popup\'s inner height', flag('--image-max-height'),
    tostring(geometry.max_h - 2))
  expect('5.1 asked for a real encoding', flag('--image-encoding'), 'blocks')
  expect('5.1 asked for the document\'s base',
    flag('--base') and vim.fs.normalize(flag('--base')),
    vim.fs.normalize(vim.fn.fnamemodify(base, ':p')))
  -- 6.4: the popup's request is built by the same code as the inline render's,
  -- so it carries the same resolved image options rather than a second copy.
  expect('6.4 the popup asks for the resolved palette',
    flag('--image-palette'), 'adaptive')
  expect('6.4 the popup asks for the background',
    flag('--image-background'), 'terminal')
  expect('6.4 the popup asks for dithering', flag('--image-dither'), 'auto')

  local text = {}
  for _, line in ipairs(doc and doc.lines or {}) do
    local parts = {}
    for _, span in ipairs(line.spans) do
      parts[#parts + 1] = span[2]
    end
    text[#text + 1] = table.concat(parts)
  end
  local joined = table.concat(text, '\n')
  truthy('5.1 the popup shows the artwork',
    joined:find('▀', 1, true) ~= nil or joined:find('▄', 1, true) ~= nil, joined)
  truthy('5.1 and not the prose before the reference', not joined:find('Some text', 1, true))
  truthy('5.1 and not the prose after it', not joined:find('more text', 1, true))

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.2 The preview key on an image
--------------------------------------------------------------------------------

--- Pretend this runner is a terminal the plugin can draw in.
---
--- An *image's* popup is the picture the terminal draws; where the terminal
--- cannot draw, the preview key takes the file to its own viewer instead. A
--- headless runner can do neither, so the sections whose subject is the popup
--- itself run as if a graphic were possible. Kitty rather than OSC 1337,
--- because these sections are about the artwork's playback and only the
--- path-reading transport asks the engine for frames. `send` is captured
--- rather than written, so no sequence reaches the runner's own output.
local function drawing_terminal()
  local real = {
    has_send = graphics.has_send,
    uis = graphics.uis,
    env = graphics.env,
    send = graphics.send,
  }
  graphics.has_send = function() return true end
  graphics.uis = function() return { {} } end
  graphics.env = function() return { TERM = 'xterm-kitty' } end
  graphics.send = function() end
  return function()
    graphics.has_send, graphics.uis, graphics.env, graphics.send =
      real.has_send, real.uis, real.env, real.send
  end
end

section('5.2', function()
  -- A motion stands in for the key so that "falls through" is observable under
  -- `nvim -l`, which never enters the main loop.
  local restore = drawing_terminal()
  local ok, err = pcall(function()
    config.setup({ image_mode = 'blocks', image_inline = 'art', keymaps = { preview = 'w' } })
    truthy('5.2 in R on the animated fixture', reset_to(animated_fixture))
    local st = current_state()
    local art = artwork_row(st)
    truthy('5.2 the artwork is drawn', art ~= nil)
    vim.api.nvim_win_set_cursor(st.win, { art + 1, 0 })

    feed('w')
    truthy('5.2 the key on the artwork opens a popup', wait_until(preview.is_open))
    local popup = preview.popup
    expect('5.2 with the image kind', popup and popup.kind, 'image')
    local shown = popup and table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false), '\n') or ''
    truthy('5.2 showing the artwork',
      shown:find('▀', 1, true) ~= nil or shown:find('▄', 1, true) ~= nil, shown)
    truthy('5.2 and not the document around it', not shown:find('Before the picture', 1, true))
    preview.close()

    -- Off the artwork the key is Vim's again.
    local prose = rendered_row(st, 'Before the picture')
    truthy('5.2 the prose row exists', prose ~= nil)
    vim.api.nvim_win_set_cursor(st.win, { prose + 1, 0 })
    local cursor = vim.api.nvim_win_get_cursor(st.win)
    feed('w')
    truthy('5.2 on prose the key reaches Vim',
      not vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))
    expect('5.2 and no popup was opened', preview.is_open(), false)
  end)
  restore()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 5.3 Playback in the popup
--------------------------------------------------------------------------------

--- Open the preview on the artwork row of `path` and return the popup, or nil.
local function open_image_popup(path)
  local restore = drawing_terminal()
  local ok, popup = pcall(function()
    truthy('in R on ' .. vim.fn.fnamemodify(path, ':t'), reset_to(path))
    local st = current_state()
    local art = artwork_row(st)
    if not art then
      return nil
    end
    vim.api.nvim_win_set_cursor(st.win, { art + 1, 0 })
    feed(config.options.keymaps.preview)
    if not wait_until(preview.is_open) then
      return nil
    end
    return preview.popup
  end)
  restore()
  if not ok then
    error(popup, 0)
  end
  return popup
end

--- The popup's artwork rows, joined.
local function popup_artwork(popup)
  local animation = popup.animation
  if not animation then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(popup.buf, animation.start,
    animation.start + animation.rows, false), '\n')
end

--- The text of frame `index`'s artwork rows.
local function frame_text(animation, index)
  local frame = animation.frames[index + 1]
  local rows = {}
  for _, spans in ipairs(frame.lines) do
    local parts = {}
    for _, span in ipairs(spans) do
      parts[#parts + 1] = span[2]
    end
    rows[#rows + 1] = table.concat(parts)
  end
  return table.concat(rows, '\n')
end

section('5.3', function()
  -- The clamp is a property of a number, so it is asserted as one.
  local delays = { frames = {
    { delay = 0 }, { delay = 19 }, { delay = 20 }, { delay = 120 },
  } }
  expect('5.3 a zero delay is played at 100 ms', preview.frame_delay(delays, 0), 100)
  expect('5.3 a 19 ms delay is played at 100 ms', preview.frame_delay(delays, 1), 100)
  expect('5.3 a 20 ms delay is kept', preview.frame_delay(delays, 2), 20)
  expect('5.3 a 120 ms delay is kept', preview.frame_delay(delays, 3), 120)

  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local popup = open_image_popup(animated_fixture)
  truthy('5.3 the popup opens', popup ~= nil)
  if not popup then
    return
  end
  truthy('5.3 with the animation', popup.animation ~= nil)
  expect('5.3 three frames', popup.animation and #popup.animation.frames, 3)
  truthy('5.3 playing by itself', popup.playing)
  truthy('5.3 with a timer', popup.timer ~= nil)

  -- The fixture's delays are 40/80/120 ms, so a full loop is 240 ms. A generous
  -- deadline keeps a loaded machine from failing the check while still bounding
  -- it: the loop must be seen through, not merely entered.
  local advances, last, wrapped = 0, popup.frame, false
  local saw_frame = { [last] = true }
  vim.wait(6000, function()
    if preview.popup ~= popup then
      return true
    end
    local f = popup.frame
    if f ~= last then
      advances = advances + 1
      last = f
      saw_frame[f] = true
      if advances >= 2 and f == 0 then
        wrapped = true
        return true
      end
    end
    return false
  end, 5)

  truthy('5.3 frames advance at least twice', advances >= 2, 'advances=' .. advances)
  truthy('5.3 and the frame on screen is the one recorded',
    popup_artwork(popup) == frame_text(popup.animation, popup.frame),
    popup_artwork(popup))
  truthy('5.3 the last frame was reached', saw_frame[#popup.animation.frames - 1])
  truthy('5.3 and playback wrapped to the first', wrapped)

  preview.close()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.4 Pause, resume and stepping while paused
--------------------------------------------------------------------------------

section('5.4', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local popup = open_image_popup(animated_fixture)
  truthy('5.4 the popup opens', popup ~= nil)
  if not popup then
    return
  end
  truthy('5.4 playing', popup.playing)

  -- Space is the pause key, bound in this popup's buffer.
  feed(config.options.keymaps.pause)
  expect('5.4 the key pauses', popup.playing, false)
  expect('5.4 and closes the timer', popup.timer, nil)
  local paused_at = popup.frame
  vim.wait(400)
  expect('5.4 and no frame advances while paused', popup.frame, paused_at)

  -- While paused, the stepping key moves exactly one frame.
  feed(config.options.keymaps.frame_next)
  expect('5.4 one step advances exactly one frame',
    popup.frame, (paused_at + 1) % #popup.animation.frames)
  expect('5.4 and stays paused', popup.playing, false)
  expect('5.4 and still has no timer', popup.timer, nil)
  truthy('5.4 the buffer shows the stepped frame',
    popup_artwork(popup) == frame_text(popup.animation, popup.frame))

  -- Resuming continues from the frame the reader chose.
  local resumed_at = popup.frame
  feed(config.options.keymaps.pause)
  expect('5.4 the key resumes', popup.playing, true)
  truthy('5.4 with a new timer', popup.timer ~= nil)
  local next_seen
  vim.wait(2000, function()
    if preview.popup ~= popup then
      return true
    end
    if popup.frame ~= resumed_at then
      next_seen = popup.frame
      return true
    end
    return false
  end, 5)
  expect('5.4 the first frame after resuming is the next one',
    next_seen, (resumed_at + 1) % #popup.animation.frames)

  preview.close()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.5 Closing and re-rendering stop playback
--------------------------------------------------------------------------------

--- The timer handles opened since here, set aside when they are closed.
---
--- `vim.uv.walk` would answer this directly, but it segfaults on Neovim
--- v0.10.4 — even with an empty callback — so the set is kept by wrapping the
--- constructor and the close method instead. Both live on libuv's own
--- setmetatable, so every timer any code creates after this point is counted;
--- a timer opened before it is neither counted nor missed when it closes.
local open_timers = {}
do
  local timer_mt = getmetatable(vim.uv.new_timer())
  local new_timer = vim.uv.new_timer
  local close = timer_mt.__index.close
  vim.uv.new_timer = function(...)
    local timer = new_timer(...)
    open_timers[timer] = true
    return timer
  end
  timer_mt.__index.close = function(self)
    open_timers[self] = nil
    return close(self)
  end
end

local function timer_handles()
  local n = 0
  for _ in pairs(open_timers) do
    n = n + 1
  end
  return n
end

section('5.5', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local baseline = timer_handles()

  local popup = open_image_popup(animated_fixture)
  truthy('5.5 the popup opens', popup ~= nil)
  if not popup then
    return
  end
  truthy('5.5 playing', popup.playing)
  expect('5.5 one timer was created', timer_handles(), baseline + 1)

  -- Close through the window rather than `M.close`, so the `WinClosed` path is
  -- the one under test.
  vim.cmd('close')
  truthy('5.5 the close is noticed', wait_until(function() return preview.popup == nil end))
  truthy('5.5 and the buffer is gone', not vim.api.nvim_buf_is_valid(popup.buf))
  expect('5.5 and the timer is closed', timer_handles(), baseline)
  local last = popup.frame
  vim.wait(300)
  expect('5.5 and no frame was written after the close', popup.frame, last)

  -- A re-render replaces the content, so playback of the old document stops.
  local again = open_image_popup(animated_fixture)
  truthy('5.5 a second popup opens and plays', again and again.playing)
  if not again then
    return
  end
  local replacement = {
    width = 1,
    layout_width = 1,
    styles = { { fg = '#000000', bg = nil, bold = false, underline = false } },
    lines = { { spans = { { 0, 'x' } }, source = 0 } },
    source_map = { 0 },
  }
  preview.adopt(replacement, again.budget, 'natural')
  expect('5.5 a re-render stops the old playback', again.playing, false)
  expect('5.5 and closes its timer', again.timer, nil)
  expect('5.5 leaving no animation behind', again.animation, nil)
  expect('5.5 and no handle at the baseline', timer_handles(), baseline)

  preview.close()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.6 A still image does not play
--------------------------------------------------------------------------------

section('5.6', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local baseline = timer_handles()

  -- A still PNG.
  local popup = open_image_popup(repo .. '/tests/fixtures/image.md')
  truthy('5.6 a still image opens a popup', popup ~= nil)
  if not popup then
    return
  end
  expect('5.6 with no animation', popup.animation, nil)
  expect('5.6 not playing', popup.playing, false)
  expect('5.6 with no timer', popup.timer, nil)
  expect('5.6 and no handle was created', timer_handles(), baseline)

  -- `pause` and `frame_next` are not bound here: they keep their ordinary
  -- editor meanings. Space moves the cursor right and <C-n> moves it down.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local before = vim.api.nvim_win_get_cursor(0)
  feed(config.options.keymaps.pause)
  local after_pause = vim.api.nvim_win_get_cursor(0)
  truthy('5.6 pause is Vim\'s space',
    after_pause[1] == before[1] and after_pause[2] > before[2],
    vim.inspect(after_pause))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed(config.options.keymaps.frame_next)
  local after_step = vim.api.nvim_win_get_cursor(0)
  truthy('5.6 frame_next keeps its ordinary meaning', after_step[1] > 1,
    vim.inspect(after_step))
  truthy('5.6 the popup is still open', preview.is_open())
  preview.close()

  -- An animated GIF with animation off is a still image too.
  config.setup({ image_mode = 'blocks', image_inline = 'art', image_animation = false })
  popup = open_image_popup(animated_fixture)
  truthy('5.6 animation off still opens a popup', popup ~= nil)
  if not popup then
    return
  end
  expect('5.6 with no animation data', popup.animation, nil)
  expect('5.6 no timer', popup.timer, nil)
  expect('5.6 and the handle count is unchanged', timer_handles(), baseline)
  preview.close()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.8 An animation over the caps is reported in the popup too
--------------------------------------------------------------------------------

section('5.8', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  local before = #notifications
  local popup = open_image_popup(repo .. '/tests/fixtures/too-large-animation.md')
  truthy('5.8 a refused animation still opens a popup', popup ~= nil)
  if not popup then
    return
  end
  truthy('5.8 and the reader is told', wait_until(function()
    return #notifications > before
  end))
  expect('5.8 as a warning', notifications[#notifications].level, vim.log.levels.WARN)
  truthy('5.8 saying the image is too large',
    notifications[#notifications].msg:find('too large to animate', 1, true) ~= nil,
    notifications[#notifications].msg)
  expect('5.8 with nothing to play', popup.animation, nil)
  expect('5.8 and no timer', popup.timer, nil)
  preview.close()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 8.3 Setup attaches the buffer already on screen
--------------------------------------------------------------------------------

--- Run `body` in a fresh Neovim and return its `vim.system` result.
---
--- A startup-order check cannot be written in this process: its plugin has been
--- sourced and its autocmds are already installed, so "FileType fired before
--- the plugin loaded" is no longer a state this instance can be in. A second
--- Neovim whose runtimepath names the checkout is the only honest way to test
--- the order.
local function run_nested(body)
  local lines = {
    'local repo = ' .. vim.inspect((repo:gsub('\\', '/'))),
    'vim.opt.runtimepath:prepend(repo)',
    'vim.opt.swapfile = false',
    'vim.opt.hidden = true',
    'vim.o.columns = 80',
    'vim.o.lines = 24',
  }
  vim.list_extend(lines, body)
  local script = vim.fn.tempname() .. '.lua'
  vim.fn.writefile(lines, script)
  -- `real_system`: the spawn counter around `vim.system` counts engine calls,
  -- and a second Neovim is not one. The nested instance's own spawns happen in
  -- its process and are invisible here either way.
  local res = real_system({ 'nvim', '--headless', '-u', 'NONE', '-l', script },
    { text = true, timeout = 60000 }):wait()
  vim.fn.delete(script)
  return res
end

--- The lines that wait for R and leave the exit code to the caller.
local nested_wait_for_r = {
  'local function rendered()',
  '  local win = vim.api.nvim_get_current_win()',
  '  local st = require("md-render.state").windows[win]',
  '  return st ~= nil and st.mode == "R" and st.rendered ~= nil',
  '    and vim.api.nvim_buf_is_valid(st.rendered)',
  '    and vim.api.nvim_win_get_buf(win) == st.rendered',
  'end',
  'os.exit(vim.wait(8000, rendered, 10) and 0 or 1)',
}

local fixture_rel = 'tests/fixtures/plugin.md'

section('8.3', function()
  -- The ordinary startup: the plugin is loaded before the file is edited, so
  -- `FileType` does the attaching. The helper must not attach a second time —
  -- one source, one render, one attach call.
  local startup_script = {
    'vim.cmd("filetype plugin indent on")',
    'local md = require("md-render")',
    'local attaches = 0',
    'local real_attach = md.attach',
    'md.attach = function(...)',
    '  attaches = attaches + 1',
    '  return real_attach(...)',
    'end',
    'vim.cmd("runtime! plugin/md-render.lua")',
    'vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/' .. fixture_rel .. '"))',
    'local function rendered()',
    '  local win = vim.api.nvim_get_current_win()',
    '  local st = require("md-render.state").windows[win]',
    '  return st ~= nil and st.mode == "R" and st.rendered ~= nil',
    '    and vim.api.nvim_win_get_buf(win) == st.rendered',
    'end',
    'assert(vim.wait(8000, rendered, 10), "the first buffer never reached R")',
    'vim.wait(100)',
    'assert(attaches == 1, "attach ran " .. attaches .. " times, not once")',
    'os.exit(0)',
  }
  local res = run_nested(startup_script)
  check('8.2 a normal startup attaches the file once', res.code == 0,
    (res.stderr or '') .. (res.stdout or ''))

  -- A markdown buffer is current and setup{} is called with no plugin
  -- autocmds installed: the helper is the only thing that can attach it.
  local setup_script = {
    'vim.cmd("filetype plugin indent on")',
    'vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/' .. fixture_rel .. '"))',
    'assert(vim.bo.filetype == "markdown", "the fixture has no markdown filetype")',
    'assert(not pcall(vim.api.nvim_get_autocmds, { group = "MdRender" }),',
    '  "the autocmds were already installed")',
    'local md = require("md-render")',
    'md.setup{}',
  }
  vim.list_extend(setup_script, nested_wait_for_r)
  local res = run_nested(setup_script)
  check('8.3 setup{} attaches the current markdown buffer', res.code == 0,
    (res.stderr or '') .. (res.stdout or ''))

  -- With no filetype yet there is nothing to attach; the helper must not guess.
  local late_script = {
    'vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/' .. fixture_rel .. '"))',
    'assert(vim.bo.filetype == "", "filetype detection should be off")',
    'local md = require("md-render")',
    'md.setup{}',
    'vim.wait(100)',
    'local win = vim.api.nvim_get_current_win()',
    'assert(require("md-render.state").windows[win] == nil,',
    '  "the helper attached a buffer with no filetype")',
    'vim.bo.filetype = "markdown"',
  }
  vim.list_extend(late_script, nested_wait_for_r)
  res = run_nested(late_script)
  check('8.3 setup{} before filetype detection waits for FileType', res.code == 0,
    (res.stderr or '') .. (res.stdout or ''))

  -- Sourcing the plugin after FileType: no event will fire again, so the
  -- startup call is what attaches the buffer on screen.
  local source_after_script = {
    'vim.cmd("filetype plugin indent on")',
    'vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/' .. fixture_rel .. '"))',
    'assert(vim.bo.filetype == "markdown", "the fixture has no markdown filetype")',
    'vim.wait(50)',
    'local win = vim.api.nvim_get_current_win()',
    'assert(require("md-render.state").windows[win] == nil,',
    '  "something attached before the plugin was sourced")',
    'vim.cmd("source " .. vim.fn.fnameescape(repo .. "/plugin/md-render.lua"))',
  }
  vim.list_extend(source_after_script, nested_wait_for_r)
  res = run_nested(source_after_script)
  check('8.3 sourcing the plugin after FileType attaches that buffer', res.code == 0,
    (res.stderr or '') .. (res.stdout or ''))

  -- Two setup() calls must not double the autocmds or the buffer maps.
  truthy('8.3 in R on the fixture', reset_to_r())
  local st = current_state()
  local before = #vim.api.nvim_get_autocmds({ group = 'MdRender' })
  md.setup({})
  md.setup({})
  expect('8.3 two setup{} calls leave one autocmd group',
    #vim.api.nvim_get_autocmds({ group = 'MdRender' }), before)

  local toggle = with_leader(config.options.keymaps.toggle)
  local maps = 0
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.source, 'n')) do
    if m.lhs == toggle then
      maps = maps + 1
    end
  end
  expect('8.3 and one set of buffer maps', maps, 1)
end)

--------------------------------------------------------------------------------
-- 8.4 A lazy `ft = 'markdown'` load still reaches the first buffer
--------------------------------------------------------------------------------

section('8.4', function()
  -- lazy.nvim with `ft` sources the plugin from FileType. BufWinEnter has
  -- already fired too, so the source is the only thing that runs afterwards.
  local script = {
    'vim.cmd("filetype plugin indent on")',
    'local saw_buf_win_enter = false',
    'vim.api.nvim_create_autocmd("BufWinEnter", {',
    '  callback = function() saw_buf_win_enter = true end,',
    '})',
    'vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/' .. fixture_rel .. '"))',
    'assert(vim.bo.filetype == "markdown", "the fixture has no markdown filetype")',
    'assert(saw_buf_win_enter, "BufWinEnter did not fire")',
    'vim.wait(50)',
    'local win = vim.api.nvim_get_current_win()',
    'assert(require("md-render.state").windows[win] == nil,',
    '  "the buffer was attached before the plugin loaded")',
    'vim.cmd("source " .. vim.fn.fnameescape(repo .. "/plugin/md-render.lua"))',
  }
  vim.list_extend(script, nested_wait_for_r)
  local res = run_nested(script)
  check('8.4 a lazy ft load shows R without :e', res.code == 0,
    (res.stderr or '') .. (res.stdout or ''))
end)

--------------------------------------------------------------------------------
-- 8.5 The attach helper leaves other windows alone
--------------------------------------------------------------------------------

section('8.5', function()
  -- A buffer the plugin does not manage is not attached and costs no engine.
  --
  -- A split rather than an `:edit` in the attached window: a window's state
  -- outlives an edit to an unmanaged file (the plugin keeps it so that going
  -- back to the document is a toggle, not a re-render), so the helper needs a
  -- window that has no state yet to test.
  truthy('8.5 in R on the fixture', reset_to_r())
  md.toggle()
  truthy('8.5 in S on the fixture', wait_until(showing_source))
  vim.cmd('vsplit ' .. vim.fn.fnameescape(plain))
  local plain_win = vim.api.nvim_get_current_win()
  vim.bo.filetype = ''
  local before = engine_calls
  md.attach_current()
  vim.wait(50)
  expect('8.5 a non-managed buffer gets no state', state.windows[plain_win], nil)
  expect('8.5 and starts no render', engine_calls, before)
  vim.cmd('close')

  -- A window that has moved to another buffer is not attached to the buffer
  -- the caller named: it is showing something else now.
  md.show_rendered()
  truthy('8.5 back in R', wait_until(showing_rendered))
  local st = current_state()
  local source = st.source
  local other = vim.api.nvim_create_buf(false, true)
  md.attach_current(other, st.win)
  vim.wait(50)
  expect('8.5 a window showing another buffer is not attached', st.source, source)
  vim.api.nvim_buf_delete(other, { force = true })

  -- A window already attached to this buffer is left exactly as it is. S is
  -- the sharper case: forcing R here would undo a toggle.
  md.toggle()
  truthy('8.5 in S on the fixture', wait_until(showing_source))
  before = engine_calls
  md.attach_current()
  vim.wait(100)
  expect('8.5 an attached window is left in S', current_state().mode, 'S')
  expect('8.5 and nothing was rendered', engine_calls, before)

  md.toggle()
  truthy('8.5 back in R', wait_until(showing_rendered))
end)

--------------------------------------------------------------------------------
-- 9.1 The health module's two halves
--------------------------------------------------------------------------------

section('9.1', function()
  local health = require('md-render.health')
  expect('9.1 probe is a function', type(health.probe), 'function')
  expect('9.1 check is a function', type(health.check), 'function')

  -- `check()` is presentation only; stubbing the health API is what lets the
  -- check see what it would have printed without opening a health buffer.
  local calls = {}
  local saved = {}
  for _, name in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    saved[name] = vim.health[name]
    vim.health[name] = function(msg)
      calls[#calls + 1] = { kind = name, msg = msg }
    end
  end
  local ok, err = pcall(health.check)
  for name, fn in pairs(saved) do
    vim.health[name] = fn
  end

  check('9.1 check() renders without raising', ok, tostring(err))
  truthy('9.1 it starts an md-render section',
    calls[1] ~= nil and calls[1].kind == 'start' and calls[1].msg:find('md%-render') ~= nil,
    vim.inspect(calls[1]))

  local printed = {}
  for _, call in ipairs(calls) do
    printed[#printed + 1] = call.msg
  end
  local all = table.concat(printed, '\n')
  for _, name in ipairs({
    'Neovim', 'engine', '--version', 'wire format', "'termguicolors'", 'filetypes',
  }) do
    truthy('9.1 it reports ' .. name, all:find(name, 1, true) ~= nil, all)
  end
end)

--------------------------------------------------------------------------------
-- 9.2 :checkhealth leaves the document and the window alone
--------------------------------------------------------------------------------

section('9.2', function()
  local health = require('md-render.health')
  truthy('9.2 in R on the fixture', reset_to_r())
  local win = vim.api.nvim_get_current_win()
  local st = current_state()
  local source, rendered = st.source, st.rendered
  local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(source)

  -- Two engine calls, never a render of the buffer on screen.
  local before = engine_calls
  local report = health.probe()
  expect('9.2 probe runs the engine twice', engine_calls - before, 2)
  expect('9.2 and leaves the source unchanged',
    vim.api.nvim_buf_get_changedtick(source), tick)
  expect('9.2 and the window in R', vim.api.nvim_win_get_buf(win), rendered)
  expect('9.2 reading the wire version', report.wire, 1)

  -- `:checkhealth` opens a health buffer of its own. Whatever it does to the
  -- layout, the document and the window's mode have to survive it.
  local ok, err = pcall(vim.cmd, 'checkhealth md-render')
  check('9.2 :checkhealth md-render opens', ok, tostring(err))
  vim.wait(100)
  local health_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_get_current_win() ~= win then
    vim.cmd('close')
  end
  md.show_rendered(win)
  truthy('9.2 the window returns to R', wait_until(function()
    return vim.api.nvim_win_get_buf(win) == rendered
  end))
  eq_table('9.2 the source still holds its lines',
    vim.api.nvim_buf_get_lines(source, 0, -1, false), lines)
  if vim.api.nvim_buf_is_valid(health_buf) and health_buf ~= source
    and health_buf ~= rendered then
    pcall(vim.api.nvim_buf_delete, health_buf, { force = true })
  end
end)

--------------------------------------------------------------------------------
-- 9.3 Healthy, missing, mismatched and without truecolor
--------------------------------------------------------------------------------

section('9.3', function()
  local health = require('md-render.health')
  local saved_engine = config.options.engine

  local function find(report, name)
    for _, item in ipairs(report.checks) do
      if item.name == name then
        return item
      end
    end
  end

  -- Healthy: whatever step the local checkout resolves on.
  config.options.engine = saved_engine
  local report = health.probe()
  truthy('9.3 a healthy engine reports ok', report.ok, vim.inspect(report.checks))
  truthy('9.3 and names the resolution step',
    type(report.step) == 'string' and report.step ~= '', tostring(report.step))
  truthy('9.3 and its path', type(report.engine) == 'string' and report.engine ~= '',
    tostring(report.engine))
  expect('9.3 and the wire version', report.wire, 1)
  truthy('9.3 and the --version output',
    type(report.version) == 'string' and report.version ~= '', tostring(report.version))
  eq_table('9.3 and the configured filetypes', report.filetypes, config.options.filetypes)

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')

  -- Missing: the report fails and says where the path came from.
  config.options.engine = dir .. '/not-here'
  report = health.probe()
  check('9.3 a missing engine fails the report', report.ok == false, vim.inspect(report))
  local engine_check = find(report, 'engine')
  truthy('9.3 the engine check explains the path',
    engine_check ~= nil and engine_check.ok == false
      and engine_check.detail:find('not%-here') ~= nil,
    engine_check and engine_check.detail)
  truthy('9.3 and offers remediation',
    engine_check ~= nil and type(engine_check.remediation) == 'string',
    engine_check and engine_check.remediation)

  -- Wire mismatch: the engine runs but speaks a different format.
  local wire2 = stand_in_engine(dir, 'wire2', {
    '@echo off',
    'if "%1"=="--version" (',
    '  echo md-render 9.9.9',
    '  exit /b 0',
    ')',
    'echo {"version":2,"lines":[],"styles":[]}',
    'exit /b 0',
  }, {
    'if [ "$1" = "--version" ]; then',
    '  echo "md-render 9.9.9"',
    '  exit 0',
    'fi',
    "echo '{\"version\":2,\"lines\":[],\"styles\":[]}'",
    'exit 0',
  })
  config.options.engine = wire2
  report = health.probe()
  check('9.3 a wire mismatch fails the report', report.ok == false, vim.inspect(report))
  local wire_check = find(report, 'wire format')
  truthy('9.3 and names both versions',
    wire_check ~= nil and wire_check.detail:find('2', 1, true) ~= nil
      and wire_check.detail:find('expects 1', 1, true) ~= nil,
    wire_check and wire_check.detail)
  truthy('9.3 and offers remediation',
    wire_check ~= nil and type(wire_check.remediation) == 'string'
      and wire_check.remediation:find('Rebuild', 1, true) ~= nil,
    wire_check and wire_check.remediation)

  -- No truecolor: a warning with a remedy, not a failure. CI runs headless,
  -- where `'termguicolors'` is off, and the plugin still works there.
  config.options.engine = saved_engine
  local saved_tgc = vim.o.termguicolors
  vim.o.termguicolors = false
  report = health.probe()
  expect('9.3 without truecolor the report says so', report.termguicolors, false)
  expect('9.3 and images resolve to ascii', report.image_encoding, 'ascii')
  local tgc = find(report, "'termguicolors'")
  expect('9.3 as a warning', tgc and tgc.severity, 'warn')
  truthy('9.3 with remediation', tgc ~= nil and type(tgc.remediation) == 'string',
    tgc and tgc.remediation)
  truthy('9.3 which does not fail the report', report.ok, vim.inspect(report.checks))

  vim.o.termguicolors = saved_tgc
  config.options.engine = saved_engine
  pcall(vim.fn.delete, dir, 'd')
end)

--------------------------------------------------------------------------------
-- 10.3 `:help md-render` resolves
--------------------------------------------------------------------------------

section('10.3', function()
  local help_file = repo .. '/doc/md-render.txt'
  truthy('10.3 the help file exists', vim.uv.fs_stat(help_file) ~= nil, help_file)
  truthy('10.3 and the tags file is tracked',
    vim.uv.fs_stat(repo .. '/doc/tags') ~= nil, repo .. '/doc/tags')

  local function resolves(tag)
    local before = #vim.api.nvim_list_wins()
    local ok, err = pcall(vim.cmd, 'help ' .. tag)
    local name = vim.api.nvim_buf_get_name(0)
    while #vim.api.nvim_list_wins() > before do
      vim.cmd('close')
    end
    return ok and name:find('md%-render%.txt$') ~= nil, tostring(err)
  end

  for _, tag in ipairs({
    'md-render',
    ':MdRenderToggle',
    ':MdRenderShow',
    ':MdRenderSource',
    ':MdRenderReset',
    'md-render.setup()',
    'md-render-options',
    'md-render-commands',
    'md-render-keymaps',
  }) do
    check('10.3 :help ' .. tag .. ' resolves', resolves(tag), 'did not open md-render.txt')
  end
end)

--------------------------------------------------------------------------------
-- 10.4 The help covers the public surface
--------------------------------------------------------------------------------

section('10.4', function()
  local text = table.concat(vim.fn.readfile(repo .. '/doc/md-render.txt'), '\n')

  local function between(start_tag, end_tag)
    local body = text:match('%*' .. start_tag .. '%*(.-)%*' .. end_tag .. '%*')
    return body or ''
  end

  -- The options section runs from its heading to the commands heading; the
  -- keymaps section likewise. Searching only there is what makes "documented"
  -- mean "documented as an option", not "mentioned somewhere".
  local options = between('md%-render%-options', 'md%-render%-commands')
  local keymaps = between('md%-render%-keymaps', 'md%-render%-links')
  truthy('10.4 the options section is found', options ~= '', 'no *md-render-options* section')
  truthy('10.4 the keymaps section is found', keymaps ~= '', 'no *md-render-keymaps* section')

  for key in pairs(config.defaults) do
    truthy('10.4 option ' .. key .. ' is documented',
      options:find(key, 1, true) ~= nil, key .. ' is missing from *md-render-options*')
  end
  for key in pairs(config.defaults.keymaps) do
    truthy('10.4 keymap ' .. key .. ' is documented',
      keymaps:find(key, 1, true) ~= nil, key .. ' is missing from *md-render-keymaps*')
  end

  local plugin = table.concat(vim.fn.readfile(repo .. '/plugin/md-render.lua'), '\n')
  local commands = 0
  for name in plugin:gmatch("nvim_create_user_command%(%s*'([%w]+)'") do
    commands = commands + 1
    truthy('10.4 command :' .. name .. ' is documented',
      text:find(name, 1, true) ~= nil, name .. ' is missing from the help file')
  end
  expect('10.4 the commands were found', commands, 4)
end)

--------------------------------------------------------------------------------
-- 7.3 Engine resolution order
--------------------------------------------------------------------------------

section('7.3', function()
  local bin_dir = repo .. '/bin'
  local bin_name = is_windows and 'md-render.exe' or 'md-render'
  local bin_engine = bin_dir .. '/' .. bin_name
  local data_dir = vim.fn.stdpath('data') .. '/md-render'
  local data_engine = data_dir .. '/' .. bin_name

  if not vim.uv.fs_stat(bin_engine) then
    -- A data-directory-only run (no bin/): the step this section owns is the
    -- data-directory fallback, so check that and leave the bin/ comparisons to
    -- a run that has one.
    local resolved, step = engine_mod.resolve(nil)
    expect('7.3 with no bin/, the data directory resolves', resolved, data_engine)
    expect('7.3 and names the data-directory step', step, 'data directory')
    return
  end

  -- The data directory is the user's, so anything already there is put back
  -- afterwards: a check that passes by deleting someone's engine is not a
  -- check worth having.
  local backup = data_engine .. '.mdrn-test-backup'
  local had_data = vim.uv.fs_stat(data_engine) ~= nil
  if had_data then
    assert(vim.uv.fs_rename(data_engine, backup))
  end
  vim.fn.mkdir(data_dir, 'p')
  assert(vim.uv.fs_copyfile(bin_engine, data_engine))

  local hidden_bin = bin_engine .. '.mdrn-test-hidden'
  local bin_hidden = false

  local function hide_bin()
    assert(vim.uv.fs_rename(bin_engine, hidden_bin))
    bin_hidden = true
  end

  local function restore_bin()
    if bin_hidden then
      vim.uv.fs_rename(hidden_bin, bin_engine)
      bin_hidden = false
    end
  end

  local ok, err = pcall(function()
    -- The repository's bin/ is ahead of the data directory, so a fresh local
    -- build is not shadowed by an older download.
    local resolved, step = engine_mod.resolve(nil)
    check('7.3 bin/ wins over the data directory', same_path(resolved, bin_engine),
      tostring(resolved))
    expect('7.3 and names the bin/ step', step, 'bin/')

    hide_bin()
    resolved, step = engine_mod.resolve(nil)
    check('7.3 the data directory is found when bin/ is absent', same_path(resolved, data_engine),
      tostring(resolved))
    expect('7.3 and names the data-directory step', step, 'data directory')
    restore_bin()

    -- A file that exists but cannot run is skipped, not reported as found and
    -- then failed on later.
    if not is_windows then
      hide_bin()
      vim.fn.setfperm(data_engine, 'rw-------')
      resolved = engine_mod.resolve(nil)
      expect('7.3 a non-executable candidate is skipped', resolved, nil)

      -- A configured path is authoritative: while the file still cannot run,
      -- the search must not quietly fall through to another engine.
      resolved, step = engine_mod.resolve(data_engine)
      expect('7.3 a configured non-executable path fails', resolved, nil)
      truthy('7.3 and its message names the path',
        type(step) == 'string' and step:find(data_engine, 1, true) ~= nil, tostring(step))
      vim.fn.setfperm(data_engine, 'rwx------')
      restore_bin()
    end

    -- The same rule for a path that is simply not there, which is the case a
    -- Windows test can share.
    resolved, step = engine_mod.resolve(data_dir .. '/not-here')
    expect('7.3 a configured missing path fails', resolved, nil)
    truthy('7.3 and its message names the missing path',
      type(step) == 'string' and step:find('not%-here') ~= nil, tostring(step))
  end)

  restore_bin()
  vim.uv.fs_unlink(data_engine)
  if had_data then
    vim.uv.fs_rename(backup, data_engine)
  else
    -- Only when this check created the directory: `:delete dir` removes an
    -- empty one and does nothing when anything else is there.
    pcall(vim.fn.delete, data_dir, 'd')
  end

  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 7.4 A wire version the plugin does not understand
--------------------------------------------------------------------------------

section('7.4', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local wire2 = stand_in_engine(dir, 'wire2',
    { '@echo {"version":2,"lines":[],"styles":[]}', '@exit /b 0' },
    { 'echo \'{"version":2,"lines":[],"styles":[]}\'', 'exit 0' })

  local before = #notifications
  config.setup({ engine = wire2, theme = 'wire-mismatch' })
  vim.cmd('edit! ' .. vim.fn.fnameescape(fixture))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  truthy('7.4 the mismatch is reported', wait_until(function()
    return #notifications > before
  end))

  local seen = notifications[#notifications]
  expect('7.4 as an error', seen.level, vim.log.levels.ERROR)
  truthy('7.4 naming the version the engine speaks',
    seen.msg:find('format 2', 1, true) ~= nil, seen.msg)
  truthy('7.4 and the version the plugin expects',
    seen.msg:find('expects 1', 1, true) ~= nil, seen.msg)

  local st = current_state()
  expect('7.4 the window stays in S', st.mode, 'S')
  truthy('7.4 showing the source',
    vim.api.nvim_win_get_buf(st.win) == st.source)

  config.setup({})
  vim.fn.delete(dir, 'rf')
end)

--------------------------------------------------------------------------------
-- Graphics protocol: identification, sequences, the popup
--------------------------------------------------------------------------------

local ESC = string.char(27)
local ST = string.char(92)
-- The cursor save/restore every placement is wrapped in: `DECSC` and `DECRC`.
local SAVE = ESC .. '7'
local RESTORE = ESC .. '8'

--- A fresh directory holding one file of `bytes`, for the plan checks.
---
--- Written through `fs_write` rather than `writefile`, which translates a `NL`
--- in the text and would not give back the bytes it was handed: the checks here
--- compare exact byte strings, and a PNG's signature contains one.
local function temp_file(name, bytes)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/' .. name
  local fd = assert(vim.uv.fs_open(path, 'w', 420))
  assert(vim.uv.fs_write(fd, bytes, 0))
  vim.uv.fs_close(fd)
  return dir, path
end

--- Whether `buf` maps `lhs` in normal mode, however Neovim stored it.
---
--- `nvim_buf_get_keymap` reports the canonical form, so `<Space>` comes back as
--- a literal space and `<C-n>` as `<C-N>`: comparing the configured string to
--- the reported `lhs` would find only the maps that needed no translation.
local function has_keymap(buf, lhs)
  local wanted = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == wanted then
      return true
    end
  end
  return false
end

--- The right-hand side `buf` maps `lhs` to, `'<callback>'` for a Lua
--- function, or nil when it maps nothing.
---
--- The sideways scroll keys are bound on every popup and *re*-bound to a no-op
--- on a graphic one, and which of the two a buffer holds is the whole difference
--- between a key that scrolls and a key that would erase the image: presence
--- alone cannot tell them apart.
local function keymap_rhs(buf, lhs)
  local wanted = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == wanted then
      if map.callback ~= nil then
        return '<callback>'
      end
      return map.rhs
    end
  end
  return nil
end

--- Open `path`'s image popup with `tier`'s placement, and return the popup and
--- the placement.
---
--- `tier` nil asks the real decision, which is what the fallback checks need.
--- The caller installs the recording `graphics.send` before calling, so that
--- what closing the popup sends is recorded too.
local function open_image(tag, path, tier, opts)
  preview.close()
  config.setup(vim.tbl_extend('force', { image_mode = 'blocks', image_inline = 'art' },
    opts or {}))
  truthy(tag .. ' reset to ' .. vim.fn.fnamemodify(path, ':t'), reset_to(path))
  local st = current_state()
  local row = artwork_row(st)
  truthy(tag .. ' the artwork is drawn', row ~= nil)
  local lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  local block = row and preview.locate(st.doc, row, lines)
  truthy(tag .. ' the artwork resolves to an image block', block and block.kind == 'image')
  local base = vim.fn.fnamemodify(path, ':p:h')
  local graphic = block and graphics.plan(block.ref, base, tier) or nil

  local geometry = preview.geometry('image', 80)
  local view = preview.view(block, geometry, base, graphic)
  local doc, err, done
  preview.render_block(config.options, block, view, function(e, d)
    err, doc, done = e, d, true
  end)
  truthy(tag .. ' the popup render answers', wait_until(function() return done end), tostring(err))
  if not doc then
    return nil, graphic
  end
  preview.open(doc, geometry, block, graphic)
  return preview.popup, graphic
end

--------------------------------------------------------------------------------
-- 1.2 Which terminal, and which transport
--------------------------------------------------------------------------------

section('1.2', function()
  expect('1.2 WezTerm by TERM_PROGRAM',
    graphics.identify({ TERM_PROGRAM = 'WezTerm' }), 'osc')
  expect('1.2 WezTerm by WEZTERM_PANE',
    graphics.identify({ WEZTERM_PANE = '0' }), 'osc')
  expect('1.2 iTerm2 by TERM_PROGRAM',
    graphics.identify({ TERM_PROGRAM = 'iTerm.app' }), 'osc')
  expect('1.2 iTerm2 by LC_TERMINAL',
    graphics.identify({ LC_TERMINAL = 'iTerm2' }), 'osc')
  expect('1.2 kitty by KITTY_WINDOW_ID',
    graphics.identify({ KITTY_WINDOW_ID = '1' }), 'kitty')
  expect('1.2 kitty by TERM',
    graphics.identify({ TERM = 'xterm-kitty' }), 'kitty')
  expect('1.2 kitty by a -kitty TERM suffix',
    graphics.identify({ TERM = 'foo-kitty' }), 'kitty')
  expect('1.2 Ghostty by TERM_PROGRAM',
    graphics.identify({ TERM_PROGRAM = 'ghostty' }), 'kitty')
  expect('1.2 Ghostty by TERM',
    graphics.identify({ TERM = 'xterm-ghostty' }), 'kitty')

  -- Order matters: WezTerm implements both protocols, and OSC 1337 is the one
  -- that reaches it through ConPTY.
  expect('1.2 WezTerm wins over a Kitty variable',
    graphics.identify({ TERM_PROGRAM = 'WezTerm', KITTY_WINDOW_ID = '1' }), 'osc')

  expect('1.2 an unknown terminal',
    graphics.identify({ TERM = 'xterm-256color', TERM_PROGRAM = 'Apple_Terminal' }), nil)
  expect('1.2 an empty environment', graphics.identify({}), nil)
  expect('1.2 tmux by TMUX',
    graphics.identify({ TERM_PROGRAM = 'WezTerm', TMUX = '/tmp/tmux-1/default,1,0' }), nil)
  expect('1.2 tmux by TERM',
    graphics.identify({ TERM_PROGRAM = 'WezTerm', TERM = 'tmux-256color' }), nil)
  expect('1.2 screen by TERM',
    graphics.identify({ TERM_PROGRAM = 'WezTerm', TERM = 'screen-256color' }), nil)
end)

--------------------------------------------------------------------------------
-- 1.3 The conditions that turn graphics off, and the health sentence
--------------------------------------------------------------------------------

section('1.3', function()
  local real = { has_send = graphics.has_send, uis = graphics.uis, env = graphics.env }
  local function stub(opts)
    graphics.has_send = function() return opts.send ~= false end
    graphics.uis = function() return opts.uis or { {} } end
    graphics.env = function() return opts.env or { TERM_PROGRAM = 'WezTerm' } end
    config.setup({ graphics = opts.mode or 'auto' })
  end
  local function restore()
    graphics.has_send, graphics.uis, graphics.env = real.has_send, real.uis, real.env
    config.setup({})
  end

  local ok, err = pcall(function()
    stub({ send = false })
    local no_api = graphics.reason()
    truthy('1.3 no raw-bytes API turns graphics off', not graphics.available())
    truthy('1.3 and names the API', no_api:find('nvim_ui_send', 1, true) ~= nil, no_api)

    stub({ uis = {} })
    local no_ui = graphics.reason()
    truthy('1.3 no attached UI turns graphics off', not graphics.available())
    truthy('1.3 and names the UI', no_ui:find('UI', 1, true) ~= nil, no_ui)

    stub({ mode = 'off' })
    local option = graphics.reason()
    truthy('1.3 the option turns graphics off', not graphics.available())
    truthy("1.3 and names 'off'", option:find("'off'", 1, true) ~= nil, option)

    stub({ env = { TERM_PROGRAM = 'WezTerm', TMUX = '/tmp/tmux-1/default,1,0' } })
    local mux = graphics.reason()
    truthy('1.3 a multiplexer turns graphics off', not graphics.available())
    truthy('1.3 and names the multiplexer', mux:find('multiplexer', 1, true) ~= nil, mux)

    stub({ env = { TERM = 'xterm-256color' } })
    local unknown = graphics.reason()
    truthy('1.3 an unknown terminal turns graphics off', not graphics.available())
    truthy('1.3 and names the terminal', unknown:find('identify', 1, true) ~= nil, unknown)

    stub({})
    local sentence, on = graphics.reason()
    truthy('1.3 an identified terminal turns graphics on', graphics.available())
    truthy('1.3 and names the transport', on and sentence:find('OSC 1337', 1, true) ~= nil,
      sentence)
    expect('1.3 with the tier', graphics.tier(), 'osc')

    stub({ env = { TERM = 'xterm-kitty' } })
    expect('1.3 and the Kitty tier', graphics.tier(), 'kitty')
  end)
  restore()
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 2.1 The OSC 1337 sequence
--------------------------------------------------------------------------------

section('2.1', function()
  expect('2.1 the exact bytes',
    graphics.osc_sequence({ 0, 0 }, 10, 5, 'AAAA'),
    SAVE .. ESC .. '[1;1H'
      .. ESC .. ']1337;File=inline=1;width=10;height=5;preserveAspectRatio=0;doNotMoveCursor=1:AAAA'
      .. ESC .. ST .. RESTORE)
  local head = SAVE .. ESC .. '[7;4H'
  expect('2.1 the cursor move is 1-based, between a save and a restore',
    graphics.osc_sequence({ 6, 3 }, 1, 1, 'x'):sub(1, #head), head)
  local tail = ESC .. ST .. RESTORE
  local sequence = graphics.osc_sequence({ 6, 3 }, 1, 1, 'x')
  expect('2.1 and the cursor is restored after it',
    sequence:sub(-#tail), tail)
  local payload = vim.base64.encode('abc')
  truthy('2.1 the payload is carried as given',
    graphics.osc_sequence({ 0, 0 }, 2, 2, payload):find(':' .. payload .. ESC .. ST, 1, true)
      ~= nil)
end)

--------------------------------------------------------------------------------
-- 2.2 The Kitty sequences
--------------------------------------------------------------------------------

section('2.2', function()
  local path = 'C:/tmp/a.png'
  expect('2.2 the placement bytes',
    graphics.kitty_sequence({ 2, 4 }, 20, 9, 7, path),
    SAVE .. ESC .. '[3;5H'
      .. ESC .. '_Gi=7,a=T,t=f,f=100,p=7,c=20,r=9,C=1,q=2;'
      .. vim.base64.encode(path) .. ESC .. ST .. RESTORE)
  local wide = 'C:/图片/图.png'
  truthy('2.2 a non-ASCII path is sent as its bytes',
    graphics.kitty_sequence({ 0, 0 }, 1, 1, 1, wide):find(vim.base64.encode(wide), 1, true)
      ~= nil)
  expect('2.2 the delete bytes',
    graphics.kitty_delete(7), ESC .. '_Ga=d,d=I,i=7,q=2' .. ESC .. ST)
end)

--------------------------------------------------------------------------------
-- 2.3 What can be placed
--------------------------------------------------------------------------------

section('2.3', function()
  -- The path-carrying transport names PNG as the format and decodes nothing
  -- else, so the fixture has to be a PNG's bytes, not merely its name.
  local bytes = '\137PNG\r\n\26\nabc'
  local dir, path = temp_file('pic.png', bytes)
  local ref = { target = 'pic.png' }

  -- `fs_stat` and `vim.fs.joinpath` normalize separators, so the resolved path
  -- is the file's identity rather than the string `temp_file` built.
  local resolved = vim.fs.normalize(path)

  local osc = graphics.plan(ref, dir, 'osc')
  truthy('2.3 a readable file plans an OSC placement', osc ~= nil)
  expect('2.3 with the resolved path', osc and osc.path, resolved)
  expect('2.3 carrying the encoded bytes', osc and osc.data, vim.base64.encode(bytes))
  expect('2.3 and its transport', osc and osc.tier, 'osc')

  local kitty = graphics.plan(ref, dir, 'kitty')
  truthy('2.3 a readable file plans a Kitty placement', kitty ~= nil)
  expect('2.3 with the path', kitty and kitty.path, resolved)
  expect('2.3 and no bytes', kitty and kitty.data, nil)
  truthy('2.3 and an id to place and delete by', type(kitty and kitty.id) == 'number')

  expect('2.3 a missing file plans nothing',
    graphics.plan({ target = 'not-there.png' }, dir, 'osc'), nil)
  expect('2.3 a directory plans nothing',
    graphics.plan({ target = '.' }, dir, 'osc'), nil)
  expect('2.3 an https URL plans nothing',
    graphics.plan({ target = 'https://example.com/a.png' }, dir, 'osc'), nil)
  expect('2.3 an http URL plans nothing',
    graphics.plan({ target = 'HTTP://example.com/a.png' }, dir, 'kitty'), nil)
  expect('2.3 a data URI plans nothing',
    graphics.plan({ target = 'data:image/png;base64,AAAA' }, dir, 'kitty'), nil)
  expect('2.3 an empty destination plans nothing',
    graphics.plan({ target = '' }, dir, 'kitty'), nil)

  -- The path transport decodes PNG and nothing else, refusing the rest with
  -- `EBADPNG`: a file it cannot decode plans nothing, so the popup keeps its
  -- artwork instead of placing a picture that would never be drawn.
  local other = temp_file('photo.jpg', 'not a png at all')
  expect('2.3 a path-carrying plan needs a PNG',
    graphics.plan({ target = 'photo.jpg' }, other, 'kitty'), nil)
  truthy('2.3 while the byte-carrying one takes it',
    graphics.plan({ target = 'photo.jpg' }, other, 'osc') ~= nil)
  vim.fn.delete(other, 'rf')

  expect('2.3 a relative destination joins the document directory',
    graphics.resolve('pic.png', dir), vim.fs.joinpath(dir, 'pic.png'))
  expect('2.3 an absolute destination is used as it is',
    graphics.resolve(path, '/somewhere/else'), path)

  -- The cap belongs to the transport that carries the bytes; the one that
  -- carries a path has nothing to bound.
  local cap = graphics.MAX_BYTES
  graphics.MAX_BYTES = 2
  expect('2.3 a file over the cap is not sent whole',
    graphics.plan(ref, dir, 'osc'), nil)
  truthy('2.3 the path-carrying transport has no cap',
    graphics.plan(ref, dir, 'kitty') ~= nil)
  graphics.MAX_BYTES = cap

  vim.fn.delete(dir, 'rf')
end)

--------------------------------------------------------------------------------
-- 2.4 Placing and removing, through the injectable sender
--------------------------------------------------------------------------------

section('2.4', function()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor', row = 2, col = 3, width = 10, height = 5,
  })
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes) sends[#sends + 1] = bytes end

  local ok, err = pcall(function()
    graphics.place(win, { tier = 'osc', data = 'AAAA' })
    expect('2.4 an OSC placement is one send', #sends, 1)
    expect('2.4 carrying the window\'s position and box', sends[1],
      graphics.osc_sequence({ 2, 3 }, 10, 5, 'AAAA'))

    sends = {}
    graphics.place(win, { tier = 'kitty', id = 3, path = 'p.png' })
    expect('2.4 a Kitty placement is one send', #sends, 1)
    expect('2.4 carrying the path and the box', sends[1],
      graphics.kitty_sequence({ 2, 3 }, 10, 5, 3, 'p.png'))

    -- A bordered float reports its *frame's* corner, one cell above and left of
    -- its first text cell. `screenpos` is the independent measure of where the
    -- text begins, so the two disagreeing is what this pins.
    local bbuf = vim.api.nvim_create_buf(false, true)
    local bwin = vim.api.nvim_open_win(bbuf, false, {
      relative = 'editor', row = 2, col = 3, width = 10, height = 5,
      style = 'minimal', border = 'rounded',
    })
    local sp = vim.fn.screenpos(bwin, 1, 1)
    truthy('2.4 a bordered window reports one cell outside its text',
      sp.row - 1 ~= vim.api.nvim_win_get_position(bwin)[1], sp.row)
    sends = {}
    graphics.place(bwin, { tier = 'osc', data = 'AAAA' })
    expect('2.4 and is placed at its first text cell', sends[1],
      graphics.osc_sequence({ sp.row - 1, sp.col - 1 }, 10, 5, 'AAAA'))
    pcall(vim.api.nvim_win_close, bwin, true)
    pcall(vim.api.nvim_buf_delete, bbuf, { force = true })

    sends = {}
    graphics.place(win, nil)
    expect('2.4 no placement sends nothing', #sends, 0)

    graphics.remove({ tier = 'osc', data = 'AAAA' })
    expect('2.4 removing an OSC placement sends nothing', #sends, 0)
    graphics.remove({ tier = 'kitty', id = 3 })
    expect('2.4 removing a Kitty placement deletes it', sends[#sends], graphics.kitty_delete(3))
  end)
  graphics.send = real
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 3.1 The block keeps its reference, and a URL yields no placement
--------------------------------------------------------------------------------

section('3.1', function()
  local doc = { lines = { { source = 0, spans = { { nil, 'x' } } } } }
  local block = preview.locate(doc, 0, { '![alt](pic.png)' })
  truthy('3.1 an image row resolves to an image block', block and block.kind == 'image')
  truthy('3.1 carrying its parsed reference', block and block.ref ~= nil)
  expect('3.1 the reference targets the file', block and block.ref and block.ref.target,
    'pic.png')

  local url = preview.locate(doc, 0, { '![alt](https://example.com/a.png)' })
  truthy('3.1 a URL reference is still a block', url ~= nil)
  expect('3.1 but yields no placement', graphics.plan(url.ref, nil, 'osc'), nil)
end)

--------------------------------------------------------------------------------
-- 3.2 What the engine is asked for, per transport
--------------------------------------------------------------------------------

section('3.2', function()
  local block = { kind = 'image', lines = { '![a](pic.png)' } }
  local geometry = preview.geometry('image', 80)
  expect('3.2 without a placement the frames are requested',
    preview.view(block, geometry, nil, nil).animation, config.options.image_animation)
  expect('3.2 the OSC transport asks for no frames',
    preview.view(block, geometry, nil, { tier = 'osc' }).animation, false)
  expect('3.2 the Kitty transport still asks for them',
    preview.view(block, geometry, nil, { tier = 'kitty' }).animation,
    config.options.image_animation)
  expect('3.2 and the dimensions stay the artwork\'s',
    preview.view(block, geometry, nil, { tier = 'osc' }).width, geometry.inner)
end)

--------------------------------------------------------------------------------
-- 3.3 The popup places the file, or keeps its artwork
--------------------------------------------------------------------------------

section('3.3', function()
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes) sends[#sends + 1] = bytes end
  local ok, err = pcall(function()
    local popup, graphic = open_image('3.3', inline_fixture, 'osc')
    truthy('3.3 a still image on OSC opens a popup', popup ~= nil)
    expect('3.3 and is placed once', #sends, 1)
    -- The popup's interior, measured from the screen rather than from the
    -- window's report: `screenpos` is where its first text cell really is, which
    -- is one cell inside the frame the position names.
    local sp = vim.fn.screenpos(popup.win, 1, 1)
    expect('3.3 with the sequence for the popup\'s own box', sends[1],
      graphics.osc_sequence(
        { sp.row - 1, sp.col - 1 },
        vim.api.nvim_win_get_width(popup.win),
        vim.api.nvim_win_get_height(popup.win),
        graphic.data))
    local shown = table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false), '\n')
    truthy('3.3 the artwork is still the buffer',
      shown:find('▀', 1, true) ~= nil or shown:find('▄', 1, true) ~= nil, shown)
    expect('3.3 an OSC popup has no frames to play', popup.animation, nil)
    expect('3.3 and no pause key', has_keymap(popup.buf, config.options.keymaps.pause), false)
    expect('3.3 and no frame-step key',
      has_keymap(popup.buf, config.options.keymaps.frame_next), false)
    preview.close()

    sends = {}
    local kpopup = open_image('3.3', inline_fixture, 'kitty')
    truthy('3.3 a still image on Kitty opens a popup', kpopup ~= nil)
    expect('3.3 and is placed once', #sends, 1)
    truthy('3.3 with the Kitty sequence', sends[1]:find('a=T,t=f', 1, true) ~= nil, sends[1])
    preview.close()

    sends = {}
    local apopup = open_image('3.3', animated_fixture, 'kitty')
    truthy('3.3 an animated image on Kitty opens a popup', apopup ~= nil)
    expect('3.3 and is not placed', #sends, 0)
    truthy('3.3 and keeps its animation', apopup and apopup.animation ~= nil)
    truthy('3.3 with frames to play',
      apopup and apopup.animation and #apopup.animation.frames > 1)
    truthy('3.3 and its pause key', has_keymap(apopup.buf, config.options.keymaps.pause))
    preview.close()
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 3.5 A resize re-places the image, once per burst
--------------------------------------------------------------------------------

section('3.5', function()
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes) sends[#sends + 1] = bytes end
  local ok, err = pcall(function()
    open_image('3.5', inline_fixture, 'osc')
    expect('3.5 the popup places the image when it opens', #sends, 1)

    -- A drag-resize arrives as a burst of events.
    vim.cmd('doautocmd <nomodeline> VimResized')
    vim.cmd('doautocmd <nomodeline> VimResized')
    vim.cmd('doautocmd <nomodeline> WinResized')
    truthy('3.5 the burst re-places the image',
      wait_until(function() return #sends == 2 end))
    vim.wait(200)
    expect('3.5 once per burst, not once per event', #sends, 2)
    expect('3.5 with the same bytes', sends[2], sends[1])

    preview.close()
    local after = #sends
    vim.cmd('doautocmd <nomodeline> VimResized')
    vim.wait(200)
    expect('3.5 a closed popup is not re-placed', #sends, after)
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 3.6 What closing removes, per transport
--------------------------------------------------------------------------------

section('3.6', function()
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes) sends[#sends + 1] = bytes end
  local ok, err = pcall(function()
    local _, graphic = open_image('3.6', inline_fixture, 'kitty')
    expect('3.6 the Kitty placement is sent once', #sends, 1)
    preview.close()
    expect('3.6 closing sends the delete', #sends, 2)
    expect('3.6 naming the placed id', sends[2], graphics.kitty_delete(graphic.id))
    preview.close()
    expect('3.6 a second close sends nothing more', #sends, 2)

    -- Closed by another route — `:close`, a click elsewhere — is the same
    -- removal.
    sends = {}
    local popup, other = open_image('3.6', inline_fixture, 'kitty')
    vim.api.nvim_win_close(popup.win, true)
    expect('3.6 a close by another route also deletes', #sends, 2)
    expect('3.6 naming the placed id', sends[2], graphics.kitty_delete(other.id))

    sends = {}
    open_image('3.6', inline_fixture, 'osc')
    preview.close()
    expect('3.6 an OSC close sends no delete', #sends, 1)
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 3.7 A placed graphic freezes the popup's viewport
--------------------------------------------------------------------------------

section('3.7', function()
  local real = graphics.send
  graphics.send = function() end
  local ok, err = pcall(function()
    local popup = open_image('3.7', inline_fixture, 'osc')
    truthy('3.7 a still image on OSC opens a popup', popup ~= nil)
    for _, key in ipairs({ '<ScrollWheelUp>', '<ScrollWheelDown>', '<C-e>', '<C-y>', '<C-d>', '<C-u>' }) do
      truthy('3.7 ' .. key .. ' moves nothing while the image is shown',
        popup and keymap_rhs(popup.buf, key) == '<callback>')
    end
    -- The sideways keys move the viewport too, so they are frozen with the
    -- wheel: a reported failure, where pressing one left the artwork showing.
    -- They are bound on every popup before the placement, so this is a
    -- re-binding rather than an addition, and it is the binding that matters.
    for _, name in ipairs({ 'scroll_left', 'scroll_right' }) do
      local key = config.options.keymaps[name]
      expect('3.7 ' .. key .. ' moves nothing while the image is shown',
        popup and keymap_rhs(popup.buf, key), '<callback>')
    end
    -- The keys that are not scroll keys keep their meaning: the popup is still
    -- a reading surface, and its close key is not a casualty of the freeze.
    expect('3.7 the close key is untouched',
      has_keymap(popup.buf, config.options.keymaps.preview), true)
    preview.close()

    popup = open_image('3.7', inline_fixture, 'kitty')
    truthy('3.7 a still image on Kitty freezes too',
      popup and has_keymap(popup.buf, '<ScrollWheelDown>'))
    expect('3.7 and freezes its sideways keys too', popup and
      keymap_rhs(popup.buf, config.options.keymaps.scroll_right), '<callback>')
    preview.close()

    -- Every popup that keeps its artwork keeps both ways of moving around it,
    -- which is why the freeze has to be per-popup rather than global.

    -- The artwork animation is the content there, and scrolling it is how a
    -- large frame is read; nothing covers it, so nothing is frozen.
    popup = open_image('3.7', animated_fixture, 'kitty')
    truthy('3.7 an animated image on Kitty keeps its artwork',
      popup and popup.animation and #popup.animation.frames > 1)
    expect('3.7 and keeps the wheel',
      has_keymap(popup.buf, '<ScrollWheelDown>'), false)
    local rhs = popup and keymap_rhs(popup.buf, config.options.keymaps.scroll_right)
    truthy('3.7 and keeps its sideways key scrolling',
      rhs ~= nil and rhs:match('l$') ~= nil, rhs)
    preview.close()

    -- No placement, no freeze: a fallback popup scrolls exactly as before.
    popup = open_image('3.7', inline_fixture, nil)
    truthy('3.7 a fallback popup opens', popup ~= nil)
    expect('3.7 with the wheel left alone',
      has_keymap(popup.buf, '<ScrollWheelDown>'), false)
    rhs = popup and keymap_rhs(popup.buf, config.options.keymaps.scroll_right)
    truthy('3.7 and its sideways key still scrolling', rhs ~= nil and rhs:match('l$') ~= nil, rhs)
    preview.close()
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 4.1 Health reports the transport or the reason it is off
--------------------------------------------------------------------------------

section('4.1', function()
  local health = require('md-render.health')
  local report = health.probe()

  local entry, others_ok = nil, true
  for _, item in ipairs(report.checks) do
    if item.name == 'graphics' then
      entry = item
    elseif not item.ok and item.severity ~= 'warn' then
      others_ok = false
    end
  end

  truthy('4.1 the report has a graphics entry', entry ~= nil)
  expect('4.1 as a warning, not an error', entry and entry.severity, 'warn')
  expect('4.1 and it does not decide the verdict', report.ok, others_ok)
  -- This runner has no UI, so the entry names the condition that is first.
  local expected = vim.api.nvim_ui_send and 'UI' or 'nvim_ui_send'
  truthy('4.1 naming why graphics is off',
    entry and entry.detail:find(expected, 1, true) ~= nil, entry and entry.detail)
  truthy('4.1 with a remedy', entry and entry.remediation ~= nil)
end)

--------------------------------------------------------------------------------
-- 4.2 The fallbacks are the artwork, unchanged
--------------------------------------------------------------------------------

section('4.2', function()
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes) sends[#sends + 1] = bytes end
  local ok, err = pcall(function()
    -- The option alone turns it off, even in a terminal that could draw.
    local popup, graphic = open_image('4.2', inline_fixture, nil, { graphics = 'off' })
    truthy('4.2 with graphics off the popup still opens', popup ~= nil)
    expect('4.2 with no placement', graphic, nil)
    expect('4.2 and nothing sent', #sends, 0)
    local shown = table.concat(vim.api.nvim_buf_get_lines(popup.buf, 0, -1, false), '\n')
    truthy('4.2 showing the artwork',
      shown:find('▀', 1, true) ~= nil or shown:find('▄', 1, true) ~= nil, shown)
    preview.close()

    -- An animated image with graphics off is exactly the popup it always was:
    -- playing, with its pause key.
    local apopup = open_image('4.2', animated_fixture, nil, { graphics = 'off' })
    truthy('4.2 the animated popup still plays', apopup and apopup.animation ~= nil)
    truthy('4.2 with its pause key', has_keymap(apopup.buf, config.options.keymaps.pause))
    truthy('4.2 with its frame-step key',
      has_keymap(apopup.buf, config.options.keymaps.frame_next))
    expect('4.2 and nothing sent', #sends, 0)
    preview.close()
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 3.1 The image_inline option
--------------------------------------------------------------------------------

section('3.1', function()
  config.setup({})
  expect('3.1 image_inline defaults to auto', config.defaults.image_inline, 'auto')

  for _, value in ipairs({ 'auto', 'card', 'art' }) do
    local resolved = config.setup({ image_inline = value })
    expect('3.1 setup accepts ' .. value, resolved.image_inline, value)
  end

  -- Every accepted value resolves to something the engine takes, so none of
  -- them can be refused by the engine for being itself.
  config.setup({ image_inline = 'auto' })
  expect('3.1 auto resolves to the card', config.image_inline_encoding(), 'card')
  config.setup({ image_inline = 'card' })
  expect('3.1 card resolves to the card', config.image_inline_encoding(), 'card')
  config.setup({ image_inline = 'art', image_mode = 'blocks' })
  expect('3.1 art resolves to the artwork', config.image_inline_encoding(), 'blocks')

  -- An unknown value is not quietly turned into one of the three: it is sent
  -- to the engine as the encoding, and the engine refuses it by name, which is
  -- how a bad image_mode is refused today.
  config.setup({ image_inline = 'dots' })
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local before = #notifications
  vim.cmd('edit! ' .. vim.fn.fnameescape(image_fixture))
  md.attach(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())

  local refused, message = false, nil
  wait_until(function()
    for i = before + 1, #notifications do
      if notifications[i].level >= vim.log.levels.ERROR then
        refused, message = true, notifications[i].msg
        return true
      end
    end
    return false
  end)
  truthy('3.1 an unknown value is refused', refused)
  truthy('3.1 by name', message and message:find('dots', 1, true) ~= nil, message)
  truthy('3.1 and R is not entered on a failed render', not showing_rendered())

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.2 The presentation the render asks for
--------------------------------------------------------------------------------

section('3.2', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'
  local inner = vim.system
  local commands = {}
  vim.system = function(cmd, opts, on_exit)
    commands[#commands + 1] = cmd
    return inner(cmd, opts, on_exit)
  end

  local function find_arg(cmd, flag)
    for i, arg in ipairs(cmd or {}) do
      if arg == flag then
        return cmd[i + 1]
      end
    end
    return nil
  end

  --- The engine command one render with `opts` produces, forced past the cache
  --- so a case whose options resemble the last one's still spawns.
  local function command_for(opts)
    config.setup(opts)
    if not reset_to(image_fixture) then
      return nil
    end
    local st = current_state()
    state.forget_cache(st.source)
    local before = #commands
    md.show_rendered()
    if not wait_until(function() return #commands > before end) then
      return nil
    end
    return commands[#commands]
  end

  --- The `--image-encoding` one render with `opts` produces.
  local function encoding_for(opts)
    return find_arg(command_for(opts), '--image-encoding')
  end

  local termguicolors = vim.o.termguicolors
  vim.o.termguicolors = true

  -- `art` is the old behaviour, so image_mode's own encoding comes through.
  expect('3.2 art with braille asks for braille',
    encoding_for({ image_inline = 'art', image_mode = 'braille' }), 'braille')
  expect('3.2 art with auto asks for braille on a true-colour terminal',
    encoding_for({ image_inline = 'art', image_mode = 'auto' }), 'braille')
  expect('3.2 art with off asks for off',
    encoding_for({ image_inline = 'art', image_mode = 'off' }), 'off')

  -- `auto` and `card` both ask for the card, whatever image_mode would draw.
  expect('3.2 auto with braille asks for the card',
    encoding_for({ image_inline = 'auto', image_mode = 'braille' }), 'card')
  expect('3.2 card with blocks asks for the card',
    encoding_for({ image_inline = 'card', image_mode = 'blocks' }), 'card')

  -- `image_mode = 'off'` outranks both: no picture means no card either.
  expect('3.2 auto with image_mode off asks for off',
    encoding_for({ image_inline = 'auto', image_mode = 'off' }), 'off')
  expect('3.2 card with image_mode off asks for off',
    encoding_for({ image_inline = 'card', image_mode = 'off' }), 'off')

  -- The resolution never consults availability, so a terminal that could not
  -- draw (this runner has no UI) and `graphics = 'off'` change nothing.
  expect('3.2 auto asks for the card with graphics off',
    encoding_for({ image_inline = 'auto', graphics = 'off' }), 'card')
  expect('3.2 art asks for the artwork with graphics off',
    encoding_for({ image_inline = 'art', image_mode = 'quads', graphics = 'off' }), 'quads')

  -- A card nothing is painted over is compact, and wide enough to hold the
  -- hint written on it. This runner has no UI, so `auto` is that case.
  local hint = config.image_hint_text()
  expect('3.2 a card on a terminal that cannot paint is three rows',
    find_arg(command_for({ image_inline = 'auto' }), '--image-card-rows'), '3')
  expect('3.2 and at least as wide as the hint it carries',
    find_arg(command_for({ image_inline = 'auto' }), '--image-card-min-width'),
    tostring(vim.fn.strdisplaywidth(hint) + 2))
  expect('3.2 with neither image key bound there is no width floor',
    find_arg(command_for({
      image_inline = 'auto',
      keymaps = { preview = false, open_image = false },
    }), '--image-card-min-width'), nil)

  -- Artwork has no card, so it asks for no card shape.
  expect('3.2 artwork asks for no card shape',
    find_arg(command_for({ image_inline = 'art', image_mode = 'blocks' }), '--image-card-rows'), nil)

  -- A picture painted over the card is measured for the artwork's box, so the
  -- card keeps it; a card forced on the same terminal stays compact.
  local restore = drawing_terminal()
  expect('3.2 a painted card keeps the artwork box',
    find_arg(command_for({ image_inline = 'auto' }), '--image-card-rows'), nil)
  expect('3.2 a card forced on a painting terminal stays compact',
    find_arg(command_for({ image_inline = 'card' }), '--image-card-rows'), '3')
  restore()

  vim.o.termguicolors = termguicolors
  vim.system = inner
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.3 The presentation is part of the render cache key
--------------------------------------------------------------------------------

section('3.3', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'
  config.setup({ image_inline = 'card', image_mode = 'blocks' })
  truthy('3.3 in R with a card', reset_to(image_fixture))
  local before = engine_calls

  -- `auto` and `card` resolve to the same presentation, and neither the
  -- palette nor any other image option moves with them, so the document the
  -- cache holds is still the right one.
  config.setup({ image_inline = 'auto', image_mode = 'blocks' })
  md.show_rendered()
  vim.wait(300)
  expect('3.3 two values that resolve alike do not re-render', engine_calls, before)

  -- Under `auto`/`card`, image_mode only chooses what would have been drawn,
  -- and nothing is: the card is the same card either way.
  config.setup({ image_inline = 'auto', image_mode = 'quads' })
  md.show_rendered()
  vim.wait(300)
  expect('3.3 image_mode under the card does not re-render', engine_calls, before)

  -- A different presentation is a different document.
  config.setup({ image_inline = 'art', image_mode = 'blocks' })
  md.show_rendered()
  truthy('3.3 switching to art re-renders',
    wait_until(function() return engine_calls > before end))
  local after_art = engine_calls

  -- `image_mode = 'off'` outranks the card, so it is a different presentation
  -- once more.
  config.setup({ image_inline = 'auto', image_mode = 'off' })
  md.show_rendered()
  truthy("3.3 switching to 'off' re-renders",
    wait_until(function() return engine_calls > after_art end))

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.4 A card changes the picture's rows and the document's narrowest width
--------------------------------------------------------------------------------

section('3.4', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'

  local function rendered_with(inline)
    config.setup({ image_mode = 'braille', image_inline = inline })
    if not reset_to(image_fixture) then
      return nil
    end
    -- The document is captured here, not read off the state later: the state
    -- table is the one live record, and the second render replaces its `doc`.
    local st = current_state()
    return st, vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false), st.doc
  end

  -- The source line the image reference is on, so the rows it produced can be
  -- told from the prose around them.
  local source_lines = vim.fn.readfile(image_fixture)
  local image_line
  for i, text in ipairs(source_lines) do
    if text:find('!%[') then
      image_line = i - 1
      break
    end
  end
  truthy('3.4 the fixture has an image reference', image_line ~= nil)

  local card, card_text, card_doc = rendered_with('card')
  truthy('3.4 a card document renders', card ~= nil)
  if not card then
    config.setup({})
    return
  end

  -- Search and yank are the buffer's: take them while the card is showing, and
  -- compare them with the artwork's after it is rendered.
  local card_row
  for i, line in ipairs(card_doc.lines) do
    if line.source == image_line then
      card_row = card_row or i - 1
    end
  end
  truthy('3.4 the card occupies rows of its own', card_row ~= nil)
  vim.api.nvim_win_set_cursor(card.win, { 1, 0 })
  local searched = vim.fn.search('After the picture', 'W')
  truthy('3.4 prose is still searchable', searched > 0)
  local yanked = card_text[searched]

  local art, art_text, art_doc = rendered_with('art')
  truthy('3.4 the artwork document renders', art ~= nil)
  if not art then
    config.setup({})
    return
  end

  -- The compact card is shorter than the artwork — that is what it is for — so
  -- the two documents are compared over everything that is not the picture,
  -- and the card's own rows are checked against the reference's line.
  --
  -- The width is the one thing the card may add: it carries the hint, so it can
  -- be wider than the picture it stands in for. It is never wider than the page.
  truthy('3.4 the card is no narrower than the artwork',
    card_doc.layout_width >= art_doc.layout_width)
  truthy('3.4 and no wider than the page', card_doc.layout_width <= card_doc.width)

  local function outside_image(doc, rendered)
    local kept = {}
    for i, line in ipairs(doc.lines) do
      if line.source ~= image_line then
        kept[#kept + 1] = { text = rendered[i], source = line.source }
      end
    end
    return kept
  end
  eq_table('3.4 every row outside the image is the same text on the same line',
    outside_image(card_doc, card_text), outside_image(art_doc, art_text))

  -- Drawn rows only: the blank line that closes the block inherits the
  -- reference's source line, exactly as it does around the artwork.
  local card_rows, mapped = 0, true
  for i, line in ipairs(card_doc.lines) do
    if line.source == image_line then
      if render.source_line_for(card_doc, i - 1) ~= image_line then
        mapped = false
      end
      local text = {}
      for _, span in ipairs(line.spans) do
        text[#text + 1] = span[2]
      end
      if vim.fn.strdisplaywidth(table.concat(text)) > 0 then
        card_rows = card_rows + 1
      end
    end
  end
  expect('3.4 the card is three rows tall', card_rows, 3)
  truthy('3.4 every card row maps back to the reference', mapped)

  -- The reference is still there to follow from the card's first row.
  local ref = card_row and link.image_at_row(source_lines, card_doc, card_row)
  truthy('3.4 the card row resolves to the image reference', ref ~= nil)
  expect('3.4 with its destination', ref and ref.raw, 'images/image_sample.png')

  -- Search still finds the prose, and a yank of it is the same text. The row
  -- itself is not the same one — the card is shorter than the artwork — which
  -- is why it is the text that is compared, not the row.
  vim.api.nvim_win_set_cursor(art.win, { 1, 0 })
  local art_searched = vim.fn.search('After the picture', 'W')
  truthy('3.4 search still finds the prose', art_searched > 0)
  expect('3.4 and a yank of it is the same text', art_text[art_searched], yanked)

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 3.5 image_inline leaves the popup alone
--------------------------------------------------------------------------------

section('3.5', function()
  local geometry = preview.geometry('image', 80)
  local block = { kind = 'image', lines = { '![a small image](images/image_sample.png)' } }

  -- The arguments the popup builds come from `image_mode` alone.
  for _, value in ipairs({ 'auto', 'card', 'art' }) do
    config.setup({ image_mode = 'blocks', image_inline = value })
    local view = preview.view(block, geometry, nil, nil)
    expect('3.5 ' .. value .. ' leaves the popup at image_mode\'s encoding',
      view.encoding, 'blocks')
    expect('3.5 ' .. value .. ' leaves the popup width alone', view.width, geometry.inner)
    expect('3.5 ' .. value .. ' leaves the popup height alone',
      view.height, geometry.max_h - 2)
  end

  -- A card document's block still opens a popup that draws the file, on either
  -- transport, and places it once.
  local real = graphics.send
  local sends = {}
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end
  local ok, err = pcall(function()
    for _, tier in ipairs({ 'osc', 'kitty' }) do
      for _, value in ipairs({ 'auto', 'card', 'art' }) do
        preview.close()
        sends = {}
        local tag = string.format('3.5 %s/%s', value, tier)
        config.setup({ image_mode = 'blocks', image_inline = value })
        truthy(tag .. ': in R', reset_to(inline_fixture))
        local st = current_state()

        -- The image block's first row, found by the source line it anchors to
        -- rather than by dots a card does not have.
        local source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
        local row
        for i, line in ipairs(st.doc.lines) do
          local src = line.source
          if src and source_lines[src + 1] and source_lines[src + 1]:find('!%[') then
            row = i - 1
            break
          end
        end
        truthy(tag .. ': the image block is found', row ~= nil)
        local found = row and preview.locate(st.doc, row, source_lines)
        truthy(tag .. ': it resolves to an image block', found and found.kind == 'image')
        if not found then
          return
        end

        local base = vim.fn.fnamemodify(inline_fixture, ':p:h')
        local graphic = graphics.plan(found.ref, base, tier)
        local view = preview.view(found, geometry, base, graphic)
        local doc, done, failure
        preview.render_block(config.options, found, view, function(e, d)
          failure, doc, done = e, d, true
        end)
        truthy(tag .. ': the popup render answers',
          wait_until(function() return done end), tostring(failure))
        if not doc then
          return
        end

        preview.open(doc, geometry, found, graphic)
        local shown = table.concat(
          vim.api.nvim_buf_get_lines(preview.popup.buf, 0, -1, false), '\n')
        truthy(tag .. ': the popup shows the artwork',
          shown:find('▀', 1, true) ~= nil or shown:find('▄', 1, true) ~= nil, shown)
        expect(tag .. ': and places the file once', #sends, 1)
        preview.close()
      end
    end
  end)
  graphics.send = real
  preview.close()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 4.1 The preview key on an image follows the transport
--------------------------------------------------------------------------------

section('4.1', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('4.1 in R on the animated fixture', reset_to(animated_fixture))
  local st = current_state()
  local row = artwork_row(st)
  truthy('4.1 the artwork is drawn', row ~= nil)

  local opened = {}
  local real_open = vim.ui.open
  vim.ui.open = function(path)
    opened[#opened + 1] = path
    return {}
  end

  local function press()
    preview.close()
    vim.api.nvim_win_set_cursor(st.win, { row + 1, 0 })
    feed(config.options.keymaps.preview)
    vim.wait(300)
  end

  -- The transport's own conditions, one at a time, with the rest of the
  -- terminal left in order: each must route the key out rather than open a
  -- popup, and `image_inline = 'art'` is deliberately kept throughout.
  local real = {
    has_send = graphics.has_send,
    uis = graphics.uis,
    env = graphics.env,
  }
  local function good_send() return true end
  local function good_uis() return { {} } end
  local function good_env() return { TERM = 'xterm-kitty' } end

  local function condition(tag, opts)
    graphics.has_send = opts.has_send or good_send
    graphics.uis = opts.uis or good_uis
    graphics.env = opts.env or good_env
    config.setup({ image_mode = 'blocks', image_inline = 'art', graphics = opts.graphics })
    local before = #opened
    press()
    expect('4.1 ' .. tag .. ': no popup', preview.is_open(), false)
    expect('4.1 ' .. tag .. ': one file handed to the desktop', #opened, before + 1)
    graphics.has_send, graphics.uis, graphics.env = real.has_send, real.uis, real.env
  end

  condition('without nvim_ui_send', { has_send = function() return false end })
  condition('without an attached UI', { uis = function() return {} end })
  condition("with graphics 'off'", { graphics = 'off' })
  condition('behind a multiplexer', { env = function()
    return { TERM = 'xterm-kitty', TMUX = '/tmp/tmux-1000/default,1,0' }
  end })
  condition('in a terminal it cannot identify', { env = function()
    return { TERM = 'xterm-256color' }
  end })

  -- Where every condition holds, the popup opens as it always has and nothing
  -- is handed out.
  graphics.has_send, graphics.uis, graphics.env = good_send, good_uis, good_env
  local before = #opened
  press()
  truthy('4.1 a drawable terminal opens the popup', wait_until(preview.is_open))
  expect('4.1 and launches nothing', #opened, before)
  preview.close()
  graphics.has_send, graphics.uis, graphics.env = real.has_send, real.uis, real.env

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 4.2 The routed key resolves and reports exactly as the open-image key does
--------------------------------------------------------------------------------

section('4.2', function()
  config.setup({ image_mode = 'blocks', image_inline = 'art', graphics = 'off' })

  local opened = {}
  local real_open = vim.ui.open
  vim.ui.open = function(path)
    opened[#opened + 1] = path
    return {}
  end

  local function latest()
    return notifications[#notifications] or {}
  end

  --- Press the preview key on the first row `find` names and report what the
  --- that press produced with `tag`.
  local function press_on(tag, find)
    preview.close()
    local st = current_state()
    local row = find(st)
    truthy(tag .. ': the image row is found', row ~= nil)
    vim.api.nvim_win_set_cursor(st.win, { (row or 0) + 1, 0 })
    local sends, notes = #opened, #notifications
    feed(config.options.keymaps.preview)
    vim.wait(300)
    return st, sends, notes
  end

  -- Relative: resolved against the document's directory.
  truthy('4.2 in R on the animated fixture', reset_to(animated_fixture))
  local _, sends, notes = press_on('4.2 relative', function(st)
    return artwork_row(st)
  end)
  expect('4.2 a relative reference opens one file', #opened, sends + 1)
  truthy('4.2 resolved beside the document',
    same_path(opened[sends + 1], repo .. '/tests/fixtures/images/image_animation.gif'), opened[sends + 1])
  expect('4.2 silently', #notifications, notes)
  expect('4.2 and opens no popup', preview.is_open(), false)

  -- Absolute: used as given.
  local abs = repo .. '/tests/fixtures/images/image_sample.png'
  local tmp = vim.fn.tempname() .. '.md'
  vim.fn.writefile({ '![absolute](' .. abs .. ')' }, tmp)
  truthy('4.2 in R on an absolute reference', reset_to(tmp))
  local _, asends, anotes = press_on('4.2 absolute', artwork_row)
  expect('4.2 an absolute reference opens one file', #opened, asends + 1)
  truthy('4.2 used as written', same_path(opened[asends + 1], abs), opened[asends + 1])
  expect('4.2 silently', #notifications, anotes)
  vim.fn.delete(tmp)

  -- Remote: reported, never fetched.
  truthy('4.2 in R on a remote reference', reset_to(repo .. '/tests/fixtures/remote-image.md'))
  local _, rsends, rnotes = press_on('4.2 remote', function(st)
    return rendered_row(st, 'a remote picture')
  end)
  expect('4.2 a remote reference launches nothing', #opened, rsends)
  expect('4.2 and is reported exactly once', #notifications, rnotes + 1)
  truthy('4.2 as not a local file', latest().msg:find('is not a local file', 1, true) ~= nil,
    latest().msg)
  expect('4.2 and opens no popup', preview.is_open(), false)

  -- A `data:` URI is not a local file either.
  local data_path = vim.fn.tempname() .. '.md'
  vim.fn.writefile({ '![a data picture](data:image/png;base64,AAAA)' }, data_path)
  truthy('4.2 in R on a data URI', reset_to(data_path))
  local _, dsends, dnotes = press_on('4.2 data', function(st)
    return rendered_row(st, 'a data picture')
  end)
  expect('4.2 a data URI launches nothing', #opened, dsends)
  expect('4.2 and is reported exactly once', #notifications, dnotes + 1)
  truthy('4.2 as not a local file', latest().msg:find('is not a local file', 1, true) ~= nil,
    latest().msg)
  expect('4.2 and opens no popup', preview.is_open(), false)
  vim.fn.delete(data_path)

  -- Missing: reported, nothing launched.
  truthy('4.2 in R on a missing reference', reset_to(repo .. '/tests/fixtures/missing-image.md'))
  local _, msends, mnotes = press_on('4.2 missing', function(st)
    return rendered_row(st, 'a missing image')
  end)
  expect('4.2 a missing file launches nothing', #opened, msends)
  expect('4.2 and is reported exactly once', #notifications, mnotes + 1)
  truthy('4.2 as no such file', latest().msg:find('no such file', 1, true) ~= nil, latest().msg)
  expect('4.2 and opens no popup', preview.is_open(), false)

  -- Not a file: reported, nothing launched.
  truthy('4.2 in R on a directory reference', reset_to(repo .. '/tests/fixtures/directory-image.md'))
  local _, xsends, xnotes = press_on('4.2 directory', function(st)
    return rendered_row(st, 'a directory')
  end)
  expect('4.2 a directory launches nothing', #opened, xsends)
  expect('4.2 and is reported exactly once', #notifications, xnotes + 1)
  truthy('4.2 as not a file', latest().msg:find('not a file', 1, true) ~= nil, latest().msg)
  expect('4.2 and opens no popup', preview.is_open(), false)

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 4.3 Only images are routed; every other key is what it always was
--------------------------------------------------------------------------------

section('4.3', function()
  -- Availability off throughout: these are the blocks and keys that do not
  -- consult it.
  config.setup({ image_mode = 'blocks', image_inline = 'art', graphics = 'off' })
  local plugin_fixture = repo .. '/tests/fixtures/plugin.md'

  local opened = {}
  local real_open = vim.ui.open
  vim.ui.open = function(path)
    opened[#opened + 1] = path
    return {}
  end

  local diagram = open_diagram(plugin_fixture, '4.3')
  truthy('4.3 a mermaid fence opens its popup without graphics',
    diagram ~= nil and diagram.kind == 'mermaid', diagram and diagram.kind)
  preview.close()

  -- A table is a block too: wrapping, not clipping, so it has no viewer to
  -- route out to.
  truthy('4.3 in R on the table', reset_to(plugin_fixture))
  local st = current_state()
  local source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  local table_line
  for i, text in ipairs(source_lines) do
    if text:match('^|%s*a%s*|') then
      table_line = i - 1
      break
    end
  end
  truthy('4.3 the fixture has a table', table_line ~= nil)
  local table_row = table_line and render.row_for_source(st.doc, table_line)
  truthy('4.3 the table has a display row', table_row ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { (table_row or 0) + 1, 0 })
  feed(config.options.keymaps.preview)
  truthy('4.3 a table opens its popup without graphics', wait_until(preview.is_open))
  expect('4.3 and it is the table', preview.popup and preview.popup.kind, 'table')
  expect('4.3 and launches nothing', #opened, 0)
  preview.close()

  -- On prose the key is Vim's. A `w` stands in for "the ordinary action", since
  -- `nvim -l` never enters the main loop and a pending operator could not be
  -- observed.
  config.setup({ image_mode = 'blocks', graphics = 'off', keymaps = { preview = 'w' } })
  truthy('4.3 in R on prose', reset_to(plugin_fixture))
  st = current_state()
  local prose = rendered_row(st, 'First paragraph')
  truthy('4.3 the prose row exists', prose ~= nil)
  vim.api.nvim_win_set_cursor(st.win, { (prose or 0) + 1, 0 })
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  feed('w')
  truthy('4.3 on prose the preview key reaches Vim',
    not vim.deep_equal(vim.api.nvim_win_get_cursor(st.win), cursor))
  expect('4.3 and opens no popup', preview.is_open(), false)
  expect('4.3 and launches nothing', #opened, 0)

  -- The open-image key does not ask the transport anything: on a terminal that
  -- could draw it still hands the file out rather than opening a popup.
  local restore = drawing_terminal()
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('4.3 in R on the artwork with a drawable terminal', reset_to(animated_fixture))
  st = current_state()
  vim.api.nvim_win_set_cursor(st.win, { artwork_row(st) + 1, 0 })
  feed(config.options.keymaps.open_image)
  vim.wait(300)
  expect('4.3 the open-image key still launches the file', #opened, 1)
  expect('4.3 and opens no popup', preview.is_open(), false)
  restore()

  vim.ui.open = real_open
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.1 The thumbnail request and its cache
--------------------------------------------------------------------------------

section('5.1', function()
  local requests = {}
  local failure = nil
  local real_run = graphics.run_thumbnail
  graphics.run_thumbnail = function(exe, source, cols, rows, background, out)
    requests[#requests + 1] = {
      source = source, cols = cols, rows = rows, background = background, out = out,
    }
    if failure then
      return false, failure
    end
    vim.fn.writefile({ 'THUMB' }, out, 'b')
    return true
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local picture = dir .. '/picture.png'
  vim.fn.writefile({ 'PNG' }, picture, 'b')

  local bytes = graphics.thumbnail(picture, 40, 10, '#101010')
  expect('5.1 a thumbnail is requested once', #requests, 1)
  truthy('5.1 and its bytes are returned', bytes ~= nil and #bytes > 0)
  if #requests == 1 then
    expect("5.1 for the block's columns", requests[1].cols, 40)
    expect("5.1 for the block's rows", requests[1].rows, 10)
    expect('5.1 with the requested background', requests[1].background, '#101010')
    expect('5.1 and the temporary file is gone', vim.fn.filereadable(requests[1].out), 0)
  end

  -- The same picture in the same box is the same answer.
  local again = graphics.thumbnail(picture, 40, 10, '#101010')
  expect('5.1 a repeat asks nothing again', #requests, 1)
  expect('5.1 and answers the same bytes', again, bytes)

  -- Another box is another picture.
  graphics.thumbnail(picture, 20, 5, '#101010')
  expect('5.1 another box is another request', #requests, 2)

  -- A rewrite changes the mtime, so it is a new picture.
  local now = os.time() + 10
  vim.uv.fs_utime(picture, now, now)
  local fresher = graphics.thumbnail(picture, 40, 10, '#101010')
  expect('5.1 a changed file is requested again', #requests, 3)
  truthy('5.1 and answered', fresher ~= nil)
  expect('5.1 with its temporary file gone too', vim.fn.filereadable(requests[3].out), 0)

  -- A refusal is quiet: no bytes, no message, and the temporary name is not
  -- left behind either.
  local noted = #notifications
  failure = 'md-render: cannot read it'
  local refused = graphics.thumbnail(picture, 41, 11, '#101010')
  failure = nil
  expect('5.1 a refusal answers nothing', refused, nil)
  expect('5.1 with no message', #notifications, noted)
  expect('5.1 and no temporary file', vim.fn.filereadable(requests[#requests].out), 0)

  -- The cache is bounded, and the entry it drops is the least recently used.
  for i = 1, graphics.THUMBNAIL_CACHE_LIMIT + 1 do
    local path = string.format('%s/evict-%d.png', dir, i)
    vim.fn.writefile({ 'PNG' }, path, 'b')
    graphics.thumbnail(path, 2, 1, '#000000')
  end
  local before = #requests
  graphics.thumbnail(dir .. '/evict-2.png', 2, 1, '#000000')
  expect('5.1 a recently used entry is still cached', #requests, before)
  graphics.thumbnail(dir .. '/evict-1.png', 2, 1, '#000000')
  expect('5.1 the least recently used entry was evicted', #requests, before + 1)

  graphics.run_thumbnail = real_run
  vim.fn.delete(dir, 'rf')
end)

--------------------------------------------------------------------------------
-- 5.2 A block's rectangle, and whether the window shows all of it
--------------------------------------------------------------------------------

section('5.2', function()
  local image_fixture = repo .. '/tests/fixtures/image.md'
  -- Artwork rather than a card: the boundary checks below need a block the
  -- window cannot show whole, and a compact card is three rows, which the
  -- runner's window shows entirely however it is scrolled.
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('5.2 in R on the image fixture', reset_to(image_fixture))
  local st = current_state()

  local source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
  local image_line
  for i, text in ipairs(source_lines) do
    if text:find('!%[') then
      image_line = i - 1
      break
    end
  end
  truthy('5.2 the fixture has an image reference', image_line ~= nil)

  local rect = graphics.rect(st.doc, image_line)
  truthy('5.2 the block has a rectangle', rect ~= nil)
  if not rect then
    config.setup({})
    return
  end

  local function row_width(line)
    local parts = {}
    for _, span in ipairs(line.spans) do
      parts[#parts + 1] = span[2]
    end
    return vim.fn.strdisplaywidth(table.concat(parts))
  end

  local rows, widest = 0, 0
  for _, line in ipairs(st.doc.lines) do
    if line.source == image_line and row_width(line) > 0 then
      rows = rows + 1
      widest = math.max(widest, row_width(line))
    end
  end
  expect("5.2 with the block's drawn rows", rect.height, rows)
  expect('5.2 and its widest row', rect.width, widest)
  expect("5.2 starting at the block's first row",
    st.doc.lines[rect.top + 1] and row_width(st.doc.lines[rect.top + 1]) > 0, true)
  local after = st.doc.lines[rect.top + rect.height + 1]
  truthy('5.2 and ending at its last drawn row',
    after == nil or after.source ~= image_line or row_width(after) == 0)

  local win = st.win
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { rect.top + 1, 0 })
  vim.fn.winrestview({ topline = rect.top + 1 })
  local slice = graphics.slice(win, rect)
  truthy('5.2 a wholly visible block has a slice', slice ~= nil, vim.inspect(rect))
  expect('5.2 covering all of its rows', slice and slice.rows, rect.height)
  expect('5.2 from its first row', slice and slice.top, rect.top)
  local sp = vim.fn.screenpos(win, rect.top + 1, 1)
  expect('5.2 at the row screenpos names', slice and slice.origin[1], sp.row - 1)
  expect('5.2 and its column', slice and slice.origin[2], sp.col - 1)
  local origin = slice and slice.origin

  -- Scrolled so its first rows are above the window: the slice starts where the
  -- window does and carries the rows that are left.
  vim.api.nvim_win_set_cursor(win, { rect.top + rect.height, 0 })
  vim.fn.winrestview({ topline = rect.top + 3 })
  slice = graphics.slice(win, rect)
  truthy('5.2 a block with rows above the window still has a slice', slice ~= nil)
  expect('5.2 starting two rows in', slice and slice.top, rect.top + 2)
  expect('5.2 and two rows shorter', slice and slice.rows, rect.height - 2)
  expect('5.2 at the window top',
    slice and slice.origin[1], vim.fn.screenpos(win, rect.top + 3, 1).row - 1)

  -- Scrolled so its last row is below the window: the slice stops at the
  -- window's last line.
  vim.api.nvim_win_set_cursor(win, { rect.top + 1, 0 })
  vim.fn.winrestview({ topline = math.max(1, rect.top) })
  slice = graphics.slice(win, rect)
  truthy('5.2 a block with its last row below the window still has a slice', slice ~= nil)
  expect('5.2 from its own first row', slice and slice.top, rect.top)
  expect("5.2 to the window's last line", slice and slice.top + slice.rows, vim.fn.line('w$'))
  truthy('5.2 which is short of the block', slice and slice.rows < rect.height)

  -- Scrolled past it: nothing of the block is on screen, so there is nothing to
  -- paint. The cursor goes with the view: `winrestview` leaves it where it was,
  -- and a cursor above the window pulls the view back when the window is next
  -- validated, which would leave the block on screen after all.
  local past = math.min(rect.top + rect.height + 2, vim.api.nvim_buf_line_count(
    vim.api.nvim_win_get_buf(win)))
  vim.api.nvim_win_set_cursor(win, { past, 0 })
  vim.fn.winrestview({ topline = past })
  expect('5.2 a block scrolled out has no slice', graphics.slice(win, rect), nil)

  -- `scrolloff` moves the view without changing what is visible: a block that
  -- fits with room for the margin is still wholly visible, and one that fills
  -- the window cannot be, which is why this case uses a shorter picture.
  config.setup({ image_mode = 'blocks', image_inline = 'art', image_max_height = 3 })
  truthy('5.2 in R on a short image block', reset_to(image_fixture))
  st = current_state()
  local short = graphics.rect(st.doc, image_line)
  truthy('5.2 the short block has a rectangle', short ~= nil)
  truthy('5.2 and it is shorter than the window',
    short and short.height < vim.api.nvim_win_get_height(st.win))
  if short then
    vim.wo[st.win].scrolloff = 4
    vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
    vim.fn.winrestview({ topline = 1 })
    local whole = graphics.slice(st.win, short)
    expect('5.2 scrolloff leaves a wholly visible block whole',
      whole and whole.rows, short.height)
  end
  vim.wo[st.win].scrolloff = 0

  config.setup({})
end)

--------------------------------------------------------------------------------
-- 5.3 Paint on settle, only what the window wholly shows
--------------------------------------------------------------------------------

section('5.3', function()
  local restore = drawing_terminal()
  local sends = {}
  local paints = 0
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end
  -- Counted separately from the sends so that "one paint, two blocks" and
  -- "two paints" are told apart when a check fails.
  local real_paint = graphics.paint
  graphics.paint = function(win, doc, lines, base)
    paints = paints + 1
    return real_paint(win, doc, lines, base)
  end

  --- The sends of each kind: a placement shows a picture, a delete takes one
  --- off. Counting them apart is what lets a check say "nothing was placed"
  --- while the block's own delete went out.
  local function placements()
    local n = 0
    for _, send in ipairs(sends) do
      if not send:find('a=d', 1, true) then
        n = n + 1
      end
    end
    return n
  end

  local function deletes()
    local n = 0
    for _, send in ipairs(sends) do
      if send:find('a=d', 1, true) then
        n = n + 1
      end
    end
    return n
  end

  --- A burst of scroll events, then long enough for one settle to have run.
  local function burst()
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds('WinScrolled', {})
    end
    vim.wait(config.options.resize_debounce + 200)
  end

  local ok, err = pcall(function()
    local image_fixture = repo .. '/tests/fixtures/image.md'
    config.setup({ image_mode = 'blocks', image_inline = 'auto' })
    truthy('5.3 in R on the image fixture', reset_to(image_fixture))
    local st = current_state()
    local win = st.win
    vim.wo[win].scrolloff = 0

    local source_lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
    local image_line
    for i, text in ipairs(source_lines) do
      if text:find('!%[') then
        image_line = i - 1
        break
      end
    end
    local rect = graphics.rect(st.doc, image_line)
    truthy('5.3 the block has a rectangle', rect ~= nil)
    if not rect then
      return
    end

    -- The block is taller than what is left of the window on entry, so putting
    -- it wholly in view is the reader's scroll; the mountain of events that a
    -- scroll really is collapses into one placement.
    vim.api.nvim_win_set_cursor(win, { rect.top + 1, 0 })
    vim.fn.winrestview({ topline = rect.top + 1 })
    vim.wait(200)
    sends, paints = {}, 0
    burst()
    expect('5.3 one placement for a burst of scrolls', placements(), 1)
    expect('5.3 and one paint for the burst', paints, 1)

    -- Partly visible: the settle runs, and places nothing over the card.
    vim.api.nvim_win_set_cursor(win, { rect.top + rect.height, 0 })
    vim.fn.winrestview({ topline = rect.top + 3 })
    vim.wait(200)
    sends, paints = {}, 0
    burst()
    expect('5.3 none for a partly visible block', placements(), 0)
    expect('5.3 and its placement is deleted', deletes(), 1)
    expect('5.3 though the settle ran', paints, 1)

    -- Back in the window: placed again, from the cache.
    vim.api.nvim_win_set_cursor(win, { rect.top + 1, 0 })
    vim.fn.winrestview({ topline = rect.top + 1 })
    vim.wait(200)
    sends, paints = {}, 0
    burst()
    expect('5.3 scrolled back, it is placed again', placements(), 1)

    -- Closing a window over the picture repaints what was underneath it.
    sends, paints = {}, 0
    local float = vim.api.nvim_open_win(st.source, false, {
      relative = 'editor', row = 1, col = 1, width = 10, height = 3, style = 'minimal',
    })
    vim.api.nvim_win_close(float, true)
    truthy('5.3 a close asks for the picture again',
      wait_until(function() return #sends >= 1 end))
    vim.wait(200)
    expect('5.3 once', placements(), 1)
    expect('5.3 in one paint', paints, 1)

    -- A floating window over the block owns its cells. The transport that
    -- keeps one image layer for the tab draws whatever was placed last on top,
    -- so a settle re-placing the inline picture while the preview popup was
    -- open put it over the popup's own — measured by hand in WezTerm. Nothing
    -- is placed under a float, and the placement already there is taken off.
    local slice = graphics.slice(win, rect)
    local origin = slice and slice.origin
    truthy('5.3 the block has an origin for the float', origin ~= nil)
    local over = vim.api.nvim_open_win(st.source, false, {
      relative = 'editor', row = origin and origin[1] or 0, col = origin and origin[2] or 0,
      width = rect.width, height = rect.height, style = 'minimal',
    })
    local frame = vim.api.nvim_win_get_position(over)
    expect('5.3 the float is where the block starts', frame[1], origin and origin[1])
    expect('5.3 and at its column', frame[2], origin and origin[2])
    truthy('5.3 which makes it cover the block', graphics.occluded(win, rect, origin))
    vim.wait(200)
    sends, paints = {}, 0
    burst()
    expect('5.3 nothing is placed under a float', placements(), 0)
    expect('5.3 and the placement it had is deleted', deletes(), 1)
    expect('5.3 though the settle ran', paints, 1)
    sends, paints = {}, 0
    burst()
    expect('5.3 and nothing on the next settle either', placements(), 0)
    expect('5.3 with nothing left to delete', deletes(), 0)

    -- Closing it gives the cells back, and the picture with them.
    vim.api.nvim_win_close(over, true)
    sends, paints = {}, 0
    burst()
    expect('5.3 closing the float places it again', placements(), 1)

    -- A float that covers none of the block is not in the way: the popup may
    -- be open over another part of the page and the block keeps its picture.
    local beside = vim.api.nvim_open_win(st.source, false, {
      relative = 'editor',
      row = origin and origin[1] or 0,
      col = (origin and origin[2] or 0) + rect.width + 2,
      width = 5, height = 3, style = 'minimal',
    })
    truthy('5.3 beside the block, it is not in the way',
      not graphics.occluded(win, rect, origin))
    sends, paints = {}, 0
    burst()
    expect('5.3 and the picture is placed', placements(), 1)
    vim.api.nvim_win_close(beside, true)
    vim.wait(200)
    sends = {}

    -- Two blocks, both wholly visible: one placement each. This is also the
    -- re-render path: entering R is what paints the picture with nobody having
    -- scrolled.
    local two = vim.fn.tempname() .. '.md'
    local sample = repo .. '/tests/fixtures/images/image_sample.png'
    vim.fn.writefile({
      '# Two',
      '',
      '![one](' .. sample .. ')',
      '',
      '![two](' .. sample .. ')',
      '',
    }, two)
    config.setup({ image_mode = 'blocks', image_inline = 'auto', image_max_height = 2 })
    sends, paints = {}, 0
    truthy('5.3 in R on two images', reset_to(two))
    st = current_state()
    local found = {}
    local lines = vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
    for i, text in ipairs(lines) do
      if text:find('!%[') then
        found[#found + 1] = graphics.rect(st.doc, i - 1)
      end
    end
    expect('5.3 both references are found', #found, 2)
    local visible = 0
    for _, r in ipairs(found) do
      local piece = r and graphics.slice(st.win, r)
      if piece and piece.rows == r.height then
        visible = visible + 1
      end
    end
    expect('5.3 both blocks are wholly visible', visible, 2)
    truthy('5.3 entering R places both', wait_until(function() return placements() >= 2 end))
    vim.wait(200)
    expect('5.3 one placement for each, unasked for', placements(), 2)
    expect('5.3 in one paint', paints, 1)
    sends, paints = {}, 0
    burst()
    expect('5.3 and the same again for a burst', placements(), 2)
    expect('5.3 in one paint', paints, 1)
    vim.fn.delete(two)
  end)

  graphics.paint = real_paint
  restore()
  config.setup({})
  vim.wait(200)
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 5.4 The payload of each transport, and the delete
--------------------------------------------------------------------------------

section('5.4', function()
  -- A known picture, so that the bytes of both transports can be written out
  -- here and compared exactly rather than matched loosely.
  local thumb = 'THUMB'
  local requests = {}
  local real_run = graphics.run_thumbnail
  graphics.run_thumbnail = function(exe, source, cols, rows, background, out, crop)
    requests[#requests + 1] = {
      source = source, cols = cols, rows = rows, background = background, out = out, crop = crop,
    }
    vim.fn.writefile({ thumb }, out, 'b')
    return true
  end
  local restore = drawing_terminal()
  local sends = {}
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end

  --- One scroll event, and long enough for its settle to have run.
  local function settle()
    vim.api.nvim_exec_autocmds('WinScrolled', {})
    vim.wait(config.options.resize_debounce + 200)
  end

  local ok, err = pcall(function()
    local image_fixture = repo .. '/tests/fixtures/image.md'
    config.setup({ image_mode = 'blocks', image_inline = 'auto' })
    truthy('5.4 in R on the image fixture', reset_to(image_fixture))
    local st = current_state()
    local win = st.win
    vim.wo[win].scrolloff = 0

    local line
    for i, text in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
      if text:find('!%[') then
        line = i - 1
        break
      end
    end
    local rect = graphics.rect(st.doc, line)
    truthy('5.4 the block has a rectangle', rect ~= nil)
    if not rect then
      return
    end
    local base = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(st.source), ':p:h')
    local path = graphics.resolve('images/image_sample.png', base)
    truthy('5.4 the picture resolves to a file', path ~= nil and vim.uv.fs_stat(path) ~= nil)

    local function show_block()
      vim.api.nvim_win_set_cursor(win, { rect.top + 1, 0 })
      vim.fn.winrestview({ topline = rect.top + 1 })
      vim.wait(200)
    end

    -- The Kitty transport sends the path, at the block's origin, in a box the
    -- size of the block's cells, under an id of its own.
    show_block()
    local slice = graphics.slice(win, rect)
    local origin = slice and slice.origin
    truthy('5.4 the block has a screen origin', origin ~= nil)
    sends = {}
    settle()
    expect('5.4 one placement', #sends, 1)
    local placed = sends[1] or ''
    local id = tonumber(placed:match('i=(%d+)'))
    truthy('5.4 carrying an image id', id ~= nil, placed)
    expect('5.4 the Kitty sequence is the whole payload', placed,
      graphics.kitty_sequence(origin, rect.width, rect.height, id, path))

    -- A repaint replaces the same placement rather than stacking another on
    -- top of it.
    sends = {}
    settle()
    expect('5.4 a repaint keeps the id', #sends, 1)
    expect('5.4 and sends the same sequence', sends[1], placed)

    -- Leaving the window deletes it by name: a Kitty placement is not erased
    -- by rewriting the cells. The cursor is put at the new top line, because a
    -- view the cursor sits above is not the view the window keeps.
    vim.api.nvim_win_set_cursor(win, { rect.top + 3, 0 })
    vim.fn.winrestview({ topline = rect.top + 3 })
    vim.wait(200)
    sends = {}
    settle()
    expect('5.4 off the window, one send', #sends, 1)
    expect('5.4 and it is the delete', sends[1], graphics.kitty_delete(id))

    -- Returning to the source takes R off the screen, and the placement with it.
    show_block()
    sends = {}
    settle()
    local again = tonumber((sends[1] or ''):match('i=(%d+)'))
    truthy('5.4 back in view, placed again', again ~= nil, sends[1] or '')
    sends = {}
    md.toggle(win)
    expect('5.4 leaving R deletes its placement', #sends, 1)
    expect('5.4 once', sends[1], graphics.kitty_delete(again))

    -- The OSC transport sends the thumbnail bytes, in the same box and at the
    -- same origin, and it is the bytes the engine produced. The threshold for
    -- sending a file unchanged is set to zero here: this section is about the
    -- thumbnail's box, and the fixture is small enough that its own bytes would
    -- otherwise be the payload (5.6 is where that choice is checked).
    graphics.env = function()
      return { TERM = 'xterm-256color', TERM_PROGRAM = 'WezTerm' }
    end
    config.setup({
      image_mode = 'blocks', image_inline = 'auto', image_inline_original_bytes = 0,
    })
    md.show_rendered(win)
    truthy('5.4 back in R', wait_until(showing_rendered))
    -- The settle that entering R asks for is allowed to happen here, before the
    -- view is put on the block, so that the requests counted below are the
    -- block's own whatever order the two settles land in.
    vim.wait(config.options.resize_debounce + 200)
    show_block()
    sends = {}
    settle()
    expect('5.4 one send', #sends, 1)
    truthy('5.4 a thumbnail was requested', #requests >= 1, 'requests=' .. #requests)
    local asked = requests[#requests] or {}
    expect('5.4 for the block columns', asked.cols, rect.width)
    expect('5.4 rows', asked.rows, rect.height)
    local background
    for _, span in ipairs(st.doc.lines[rect.top + 1].spans or {}) do
      local style = span[1] and st.doc.styles[span[1] + 1]
      if style and style.bg then
        background = style.bg
        break
      end
    end
    truthy('5.4 the card carries a surface colour', background ~= nil)
    expect('5.4 which is the letterbox', asked.background, background)
    slice = graphics.slice(win, rect)
    origin = slice and slice.origin
    truthy('5.4 the block is in view again', origin ~= nil)
    expect('5.4 and it is the whole block', slice and slice.rows, rect.height)
    expect('5.4 the OSC sequence is the whole payload', sends[1],
      graphics.osc_sequence(origin, rect.width, rect.height, vim.base64.encode(thumb)))

    -- Nothing has to be deleted on this transport: the picture is in the cells.
    -- A block still showing some rows is painted over those rows (5.7), so
    -- "off" has to mean past its last one.
    local beyond = math.min(rect.top + rect.height + 2,
      vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))
    vim.api.nvim_win_set_cursor(win, { beyond, 0 })
    vim.fn.winrestview({ topline = beyond })
    vim.wait(200)
    sends = {}
    settle()
    expect('5.4 off the window, nothing is sent', #sends, 0)
  end)

  graphics.run_thumbnail = real_run
  restore()
  config.setup({})
  vim.wait(200)
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 5.5 A paint that fails is quiet
--------------------------------------------------------------------------------

section('5.5', function()
  local restore = drawing_terminal()
  -- The byte-carrying transport, because it is the one with a step that can
  -- fail: the thumbnail request. The path-carrying one only writes the path and
  -- the terminal answers nothing.
  graphics.env = function()
    return { TERM = 'xterm-256color', TERM_PROGRAM = 'WezTerm' }
  end
  local sends = {}
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end

  local mode = 'refuse'
  local real_run = graphics.run_thumbnail
  graphics.run_thumbnail = function(_, _, _, _, _, out)
    if mode == 'refuse' then
      return false, 'md-render: cannot read it'
    end
    if mode == 'empty' then
      vim.fn.writefile({}, out, 'b')
      return true
    end
    vim.fn.writefile({ 'THUMB' }, out, 'b')
    return true
  end

  local function settle()
    vim.api.nvim_exec_autocmds('WinScrolled', {})
    vim.wait(config.options.resize_debounce + 200)
  end

  local ok, err = pcall(function()
    -- Its own directory, so that the thumbnail cache has no entry for it and
    -- every case below really reaches the failing step.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local picture = dir .. '/picture.png'
    vim.uv.fs_copyfile(repo .. '/tests/fixtures/images/image_sample.png', picture)
    local document = dir .. '/quiet.md'
    vim.fn.writefile({
      '# Quiet',
      '',
      '![a picture](' .. picture:gsub('\\', '/') .. ')',
      '',
    }, document)

    -- The thumbnail step is the subject here, so the file is never sent
    -- unchanged: it is small, and 5.6's threshold would skip the step under
    -- test.
    config.setup({
      image_mode = 'blocks', image_inline = 'auto', image_max_height = 2,
      image_inline_original_bytes = 0,
    })
    truthy('5.5 in R on the temporary picture', reset_to(document))
    local st = current_state()
    local line
    for i, text in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
      if text:find('!%[') then
        line = i - 1
        break
      end
    end
    local rect = graphics.rect(st.doc, line)
    truthy('5.5 the card is in the window',
      rect ~= nil and graphics.slice(st.win, rect) ~= nil)

    local content = vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false)
    local maps = vim.api.nvim_buf_get_keymap(st.rendered, 'n')

    local function unchanged(tag)
      eq_table('5.5 ' .. tag .. ' leaves the card alone',
        vim.api.nvim_buf_get_lines(st.rendered, 0, -1, false), content)
      eq_table('5.5 and its keys', vim.api.nvim_buf_get_keymap(st.rendered, 'n'), maps)
    end

    -- The engine refuses to make the thumbnail.
    sends = {}
    local noted = #notifications
    settle()
    expect('5.5 a refusal sends nothing', #sends, 0)
    expect('5.5 and says nothing', #notifications, noted)
    unchanged('a refusal')

    -- The engine answers with an empty file: no bytes, so nothing to place.
    mode = 'empty'
    sends = {}
    noted = #notifications
    settle()
    expect('5.5 an empty answer sends nothing', #sends, 0)
    expect('5.5 and says nothing', #notifications, noted)
    unchanged('an empty answer')

    -- The file is gone. Nothing is asked about it in the first place.
    vim.fn.delete(picture)
    sends = {}
    noted = #notifications
    settle()
    expect('5.5 a missing file sends nothing', #sends, 0)
    expect('5.5 and says nothing', #notifications, noted)
    unchanged('a missing file')

    -- The control: the same paint with a picture that can be made does place
    -- one, so the zeros above are quiet rather than unwired.
    vim.uv.fs_copyfile(repo .. '/tests/fixtures/images/image_sample.png', picture)
    mode = 'ok'
    sends = {}
    settle()
    expect('5.5 a picture that can be made is placed', #sends, 1)

    vim.fn.delete(dir, 'rf')
  end)

  graphics.run_thumbnail = real_run
  restore()
  config.setup({})
  vim.wait(200)
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 5.6 A small file is painted as it is, not downscaled
--------------------------------------------------------------------------------

section('5.6', function()
  local restore = drawing_terminal()
  graphics.env = function()
    return { TERM = 'xterm-256color', TERM_PROGRAM = 'WezTerm' }
  end
  local sends = {}
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end
  local requests = {}
  local real_run = graphics.run_thumbnail
  graphics.run_thumbnail = function(_, source, cols, rows, _, out, crop)
    requests[#requests + 1] = { source = source, cols = cols, rows = rows, crop = crop }
    vim.fn.writefile({ 'THUMB' }, out, 'b')
    return true
  end

  local ok, err = pcall(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local picture = dir .. '/picture.png'
    vim.uv.fs_copyfile(repo .. '/tests/fixtures/images/image_sample.png', picture)
    local animated = repo .. '/tests/fixtures/images/image_animation.gif'
    local size = vim.uv.fs_stat(picture).size
    local original_bytes = vim.fn.readblob(picture)

    local document = dir .. '/payload.md'
    vim.fn.writefile({
      '# Payload',
      '',
      '![a picture](' .. picture:gsub('\\', '/') .. ')',
      '',
    }, document)

    -- The default threshold is above this fixture, so its own bytes are what a
    -- settle sends — at its own resolution, with no encode behind it.
    config.setup({ image_mode = 'blocks', image_inline = 'auto', image_max_height = 4 })
    truthy('5.6 the default lets a small file through',
      size <= config.options.image_inline_original_bytes)
    expect("5.6 and answers the file's own bytes", graphics.original(picture), original_bytes)

    truthy('5.6 in R on the picture', reset_to(document))
    local st = current_state()
    vim.wo[st.win].scrolloff = 0
    local line
    for i, text in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
      if text:find('!%[') then
        line = i - 1
        break
      end
    end
    local rect = graphics.rect(st.doc, line)
    truthy('5.6 the block has a rectangle', rect ~= nil)
    if not rect then
      return
    end
    -- The block at the top of the window, as 5.4 does: `nvim -l` never repaints,
    -- so what `screenpos` reports as visible is whatever the window showed when
    -- it was last drawn.
    vim.api.nvim_win_set_cursor(st.win, { rect.top + 1, 0 })
    vim.fn.winrestview({ topline = rect.top + 1 })
    local slice = graphics.slice(st.win, rect)
    truthy('5.6 with a rectangle in the window', slice ~= nil, vim.inspect(rect))
    if not slice then
      return
    end
    expect('5.6 the whole block is in view', slice.rows, rect.height)
    local origin = slice.origin
    sends, requests = {}, {}
    vim.api.nvim_exec_autocmds('WinScrolled', {})
    vim.wait(config.options.resize_debounce + 200)
    truthy('5.6 the picture is placed', #sends >= 1, 'sends=' .. #sends)
    expect('5.6 as the file itself', sends[1],
      graphics.osc_sequence(origin, rect.width, rect.height, vim.base64.encode(original_bytes)))
    expect('5.6 and no thumbnail is asked for', #requests, 0)

    -- A threshold below the file's own size takes it back to the thumbnail.
    config.setup({
      image_mode = 'blocks', image_inline = 'auto', image_inline_original_bytes = size - 1,
    })
    expect('5.6 under the threshold the file is not sent', graphics.original(picture), nil)
    requests = {}
    expect('5.6 and the thumbnail is',
      graphics.inline_bytes(picture, 8, 4, '#101010'), 'THUMB')
    expect('5.6 asked for once', #requests, 1)

    -- Zero never sends a file unchanged.
    config.setup({ image_mode = 'blocks', image_inline = 'auto', image_inline_original_bytes = 0 })
    requests = {}
    -- A box the cache has not seen, so the count is this call's.
    graphics.inline_bytes(picture, 9, 5, '#101010')
    expect('5.6 zero always takes the thumbnail', #requests, 1)
    expect('5.6 and sends no file', graphics.original(picture), nil)

    -- An animated picture is one still frame inline, so it keeps its thumbnail
    -- whatever its size: the original would play itself.
    config.setup({ image_mode = 'blocks', image_inline = 'auto' })
    truthy('5.6 the animation is small enough to qualify',
      vim.uv.fs_stat(animated).size <= config.options.image_inline_original_bytes)
    expect('5.6 yet an animation is not sent unchanged', graphics.original(animated), nil)
    requests = {}
    expect('5.6 and its thumbnail is made',
      graphics.inline_bytes(animated, 8, 4, '#000000'), 'THUMB')
    expect('5.6 once', #requests, 1)

    -- A file that is gone answers nothing, and the card is what is left.
    vim.fn.delete(picture)
    expect('5.6 a missing file is not sent', graphics.original(picture), nil)

    vim.fn.delete(dir, 'rf')
  end)

  graphics.run_thumbnail = real_run
  restore()
  config.setup({})
  vim.wait(200)
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 5.7 A block the window cuts in half is painted up to the cut
--------------------------------------------------------------------------------

section('5.7', function()
  -- WezTerm, the byte-carrying transport: it is the one that can be handed an
  -- encode of part of the picture. Kitty is handed a path and keeps 5.3's rule.
  local restore = drawing_terminal()
  graphics.env = function()
    return { TERM = 'xterm-256color', TERM_PROGRAM = 'WezTerm' }
  end
  local sends = {}
  graphics.send = function(bytes)
    sends[#sends + 1] = bytes
  end
  local requests = {}
  local real_run = graphics.run_thumbnail
  graphics.run_thumbnail = function(_, source, cols, rows, background, out, crop)
    requests[#requests + 1] = {
      source = source, cols = cols, rows = rows, background = background, crop = crop,
    }
    vim.fn.writefile({ 'THUMB' }, out, 'b')
    return true
  end

  local ok, err = pcall(function()
    -- A picture of this section's own. The fixture is rendered by earlier
    -- sections, and both the document cache and the thumbnail cache would answer
    -- from what they saw then: the first would hand back a box shaped by
    -- another section's options, the second an encode cut from another crop.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local picture = dir .. '/picture.png'
    vim.uv.fs_copyfile(repo .. '/tests/fixtures/images/image_sample.png', picture)
    local document = dir .. '/cut.md'
    vim.fn.writefile({
      '# Cut',
      '',
      '![a picture](' .. picture:gsub('\\', '/') .. ')',
      '',
      'After the picture.',
      '',
    }, document)

    -- The thumbnail step is the subject, so a file small enough to send
    -- unchanged would skip it (5.6 is where that choice is checked).
    config.setup({
      image_mode = 'blocks', image_inline = 'auto', image_inline_original_bytes = 0,
    })
    truthy('5.7 in R on the picture', reset_to(document))
    -- The settle entering R asks for is allowed to land before the view moves.
    -- Left pending, it fires after the view is put on the block and fills the
    -- thumbnail cache with the very encode the checks below count.
    vim.wait(config.options.resize_debounce + 200)
    local st = current_state()
    local win = st.win
    vim.wo[win].scrolloff = 0

    local line
    for i, text in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
      if text:find('!%[') then
        line = i - 1
        break
      end
    end
    local rect = graphics.rect(st.doc, line)
    truthy('5.7 the block has a rectangle', rect ~= nil)
    if not rect then
      return
    end
    -- The rendered page is taller than this window, so the block always has
    -- rows the window does not show: the engine never makes an image taller
    -- than the page, and the cut comes from scrolling.
    truthy('5.7 the block starts below the first line', rect.top > 0, vim.inspect(rect))

    --- One settled scroll with the view already put where the check wants it.
    local function settle()
      vim.wait(200)
      sends, requests = {}, {}
      vim.api.nvim_exec_autocmds('WinScrolled', {})
      vim.wait(config.options.resize_debounce + 200)
    end

    -- The document two lines in: the block still starts inside the window and
    -- its last rows are below it, so the encode carries the top of the picture
    -- and stops at the window's edge. (Not the first line: entering R has
    -- already painted that view, and its encode is cached.)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.fn.winrestview({ topline = 2 })
    local cut = graphics.slice(win, rect)
    truthy('5.7 the block has a slice', cut ~= nil)
    expect('5.7 with fewer rows than the block', cut and cut.rows < rect.height, true)
    settle()
    expect('5.7 one placement', #sends, 1)
    truthy('5.7 from a thumbnail', #requests >= 1, 'requests=' .. #requests)
    local asked = requests[#requests] or {}
    expect('5.7 for the block columns', asked.cols, rect.width)
    -- The box the engine fits into is the whole block's: cutting its rows is
    -- what keeps the slice at the picture's own scale.
    expect('5.7 for the whole block rows', asked.rows, rect.height)
    expect('5.7 cut from the top of the block', asked.crop and asked.crop.top, 0)
    expect('5.7 by the number of rows on screen', asked.crop and asked.crop.rows, cut and cut.rows)
    expect('5.7 placed at the first visible row', sends[1],
      graphics.osc_sequence(cut and cut.origin, rect.width, cut and cut.rows,
        vim.base64.encode('THUMB')))

    -- Scrolled so the block's first rows are above the window: the encode is
    -- the other end of the picture. The cursor goes to the new top line, so the
    -- view the window reports is not one the cursor would scroll out of.
    vim.api.nvim_win_set_cursor(win, { rect.top + 3, 0 })
    vim.fn.winrestview({ topline = rect.top + 3 })
    local lower = graphics.slice(win, rect)
    truthy('5.7 a block with rows above the window still has a slice', lower ~= nil)
    expect('5.7 starting two rows in', lower and lower.top, rect.top + 2)
    settle()
    expect('5.7 one placement again', #sends, 1)
    asked = requests[#requests] or {}
    expect('5.7 cut two rows in', asked.crop and asked.crop.top, 2)
    expect('5.7 and as tall as what is left', asked.crop and asked.crop.rows, lower and lower.rows)
    expect('5.7 at the window top', sends[1],
      graphics.osc_sequence(lower and lower.origin, rect.width, lower and lower.rows,
        vim.base64.encode('THUMB')))

    -- The same view again is the same encode: the crop is part of the cache key,
    -- because the rows on screen are a different picture, not the same one.
    settle()
    expect('5.7 the same view is cached', #requests, 0)
    expect('5.7 and placed from the cache', #sends, 1)

    -- Past the block there is nothing to paint. The last line is the furthest
    -- the view can go, so the destination is clamped rather than assumed.
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    local beyond = math.min(rect.top + rect.height + 2, last)
    vim.api.nvim_win_set_cursor(win, { beyond, 0 })
    vim.fn.winrestview({ topline = beyond })
    settle()
    expect('5.7 off the window, nothing is sent', #sends, 0)

    vim.fn.delete(dir, 'rf')
  end)

  graphics.run_thumbnail = real_run
  restore()
  config.setup({})
  vim.wait(200)
  if not ok then
    error(err, 0)
  end
end)

--------------------------------------------------------------------------------
-- 6.2 The health report names what an inline image becomes
--------------------------------------------------------------------------------

section('6.2', function()
  local health = require('md-render.health')

  local function find(report, name)
    for _, item in ipairs(report.checks) do
      if item.name == name then
        return item
      end
    end
  end

  local function probe_with(opts)
    config.setup(opts)
    local report = health.probe()
    return report, find(report, 'image_inline')
  end

  -- `nvim -l` has no UI, so nothing can draw: the default is a card on its own.
  local report, entry = probe_with({ image_mode = 'blocks', image_inline = 'auto' })
  expect('6.2 the default resolves to a card', report.image_inline, 'card')
  truthy('6.2 the entry is reported', entry ~= nil)
  truthy('6.2 as a warning', entry ~= nil and entry.severity == 'warn', entry and entry.severity)
  truthy('6.2 saying why nothing is painted',
    entry ~= nil and entry.detail:find('on its own', 1, true) ~= nil, entry and entry.detail)
  expect('6.2 and it does not fail the report', report.ok, true)

  -- A terminal that can draw paints the picture over the card.
  local restore = drawing_terminal()
  report, entry = probe_with({ image_mode = 'blocks', image_inline = 'auto' })
  expect('6.2 with graphics the presentation is still a card', report.image_inline, 'card')
  truthy('6.2 painted over', entry ~= nil and entry.ok == true, entry and entry.detail)
  truthy('6.2 and the entry says so',
    entry ~= nil and entry.detail:find('painted over', 1, true) ~= nil, entry and entry.detail)
  expect('6.2 with the report still ok', report.ok, true)

  -- The card alone, asked for on purpose: a resolution, not a degradation.
  report, entry = probe_with({ image_mode = 'blocks', image_inline = 'card' })
  expect('6.2 card resolves to the card', report.image_inline, 'card')
  truthy('6.2 and is not a warning about the terminal',
    entry ~= nil and entry.ok == true, entry and entry.detail)
  truthy('6.2 because the option asked for it',
    entry ~= nil and entry.detail:find("image_inline = 'card'", 1, true) ~= nil,
    entry and entry.detail)

  -- `art` passes the artwork encoding through.
  report, entry = probe_with({ image_mode = 'blocks', image_inline = 'art' })
  expect('6.2 art resolves to the artwork encoding', report.image_inline, 'blocks')
  truthy('6.2 and the entry names it',
    entry ~= nil and entry.ok == true
      and entry.detail:find('blocks', 1, true) ~= nil, entry and entry.detail)

  -- `image_mode = 'off'` outranks the card.
  report, entry = probe_with({ image_mode = 'off', image_inline = 'auto' })
  expect('6.2 image_mode off resolves to alt text', report.image_inline, 'off')
  truthy('6.2 and the entry names that too',
    entry ~= nil and entry.ok == true
      and entry.detail:find('alt text', 1, true) ~= nil, entry and entry.detail)

  restore()
  config.setup({})
end)

--------------------------------------------------------------------------------
-- 7.1 The image hint: a card or an alt text says which key opens it
--------------------------------------------------------------------------------

section('7.1', function()
  local fixture = repo .. '/tests/fixtures/image.md'

  --- The image hint on `st`'s rendered row, or nil.
  ---
  --- The hint is virtual text drawn over its row rather than a highlight over
  --- its cells: a card's row is a band of surface cells with the caption
  --- centred in it, so an underline marked cells that are not text and never
  --- said which key to press.
  local function hinted(st, row)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.rendered, render.ns,
        { row, 0 }, { row, -1 }, { details = true })) do
      if m[4].virt_text then
        return m[4]
      end
    end
  end

  --- How many of `st`'s rendered rows carry a hint.
  local function hinted_rows(st)
    local count = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.rendered, render.ns,
        0, -1, { details = true })) do
      if m[4].virt_text then
        count = count + 1
      end
    end
    return count
  end

  --- The 0-based display rows attributed to source line `lnum`, blanks dropped.
  local function drawn_rows(st, lnum)
    local rows = {}
    for i, l in ipairs(st.doc.lines) do
      if l.source == lnum then
        local parts = {}
        for _, span in ipairs(l.spans or {}) do
          parts[#parts + 1] = span[2]
        end
        if table.concat(parts) ~= '' then
          rows[#rows + 1] = i - 1
        end
      end
    end
    return rows
  end

  --- The 0-based source line of the fixture's image reference.
  local function image_line(st)
    for i, text in ipairs(vim.api.nvim_buf_get_lines(st.source, 0, -1, false)) do
      if text:find('!%[', 1) then
        return i - 1
      end
    end
  end

  --- The card's rectangle as its top row, the row the hint is written on — the
  --- bottom of what is drawn — and its display width.
  local function card_of(st)
    local rect = graphics.rect(st.doc, image_line(st))
    if not rect then
      return nil
    end
    return rect.top, rect.top + rect.height - 1, rect.width
  end

  --- Render the fixture from scratch, so a changed option or a changed terminal
  --- reaches the hint rather than being answered from the cache.
  local function rerender()
    local current = current_state()
    if current and current.source then
      state.forget_cache(current.source)
    end
    return reset_to(fixture)
  end

  -- A card is a box of surface cells with a caption on its middle row. Nothing
  -- about it says a key opens the picture, so the bottom row carries the keys
  -- to press — on the card, inside the box, rather than beside it.
  config.setup({ image_mode = 'blocks', image_inline = 'auto' })
  truthy('7.1 in R on the image fixture', rerender())
  local st = current_state()
  local top, bottom, box = card_of(st)
  truthy('7.1 the reference is a card', top ~= nil)
  expect('7.1 a card nothing is painted over is three rows', bottom - top + 1, 3)
  local hint = hinted(st, bottom)
  truthy("7.1 the card's bottom row says a key opens it", hint ~= nil)
  eq_table('7.1 the hint names the keys that are bound', hint and hint.virt_text,
    { { ' <CR>/gx open image', 'MdRenderHint' } })
  expect('7.1 the hint is drawn over its row, not into it',
    hint and hint.virt_text_pos, 'win_col')
  truthy('7.1 the hint is written inside the box',
    hint ~= nil and hint.virt_text_win_col >= 0
      and hint.virt_text_win_col + vim.fn.strdisplaywidth(' <CR>/gx open image') <= box)
  expect('7.1 one hint for one reference', hinted_rows(st), 1)
  expect("7.1 the caption's row is left alone", hinted(st, top + 1), nil)

  -- On a terminal that paints the picture over the card there is nothing to
  -- say: the picture is the evidence, and text over it would go at the next
  -- placement. That card is the artwork's whole box, since the picture is
  -- measured for it. A card forced on the same terminal has no picture, is
  -- compact, and keeps its hint.
  local restore = drawing_terminal()
  config.setup({ image_inline = 'auto' })
  truthy('7.1 on a terminal that can paint', rerender())
  st = current_state()
  expect('7.1 no hint under a painted picture', hinted_rows(st), 0)
  top, bottom = card_of(st)
  truthy('7.1 a painted card keeps the artwork box', bottom - top + 1 > 3)
  config.setup({ image_inline = 'card' })
  truthy('7.1 with the picture never painted', rerender())
  st = current_state()
  top, bottom = card_of(st)
  expect('7.1 a forced card is compact', bottom - top + 1, 3)
  truthy('7.1 a forced card on that terminal is hinted', hinted(st, bottom) ~= nil)
  restore()

  -- `image_mode = 'off'` keeps the alt text, which is prose the reader has no
  -- reason to take for a control either. The hint follows the text on its last
  -- row, leaving the prose itself alone.
  config.setup({ image_mode = 'off', image_inline = 'auto' })
  truthy('7.1 with image_mode off', rerender())
  st = current_state()
  local rows = drawn_rows(st, image_line(st))
  truthy('7.1 the alt text has a row', #rows > 0)
  local last = rows[#rows]
  local alt = vim.api.nvim_buf_get_lines(st.rendered, last, last + 1, false)[1]
  local alt_hint = hinted(st, last)
  truthy('7.1 the alt text says a key opens it', alt_hint ~= nil)
  expect('7.1 the hint follows the alt text', alt_hint and alt_hint.virt_text_win_col,
    vim.fn.strdisplaywidth(alt) + 1)
  expect('7.1 one hint for the alt text', hinted_rows(st), 1)

  -- `art` leaves the picture to `image_mode`; the artwork is a drawing, and an
  -- annotation over its glyphs would repaint it. It is not hinted.
  config.setup({ image_mode = 'blocks', image_inline = 'art' })
  truthy('7.1 back to the artwork', rerender())
  st = current_state()
  top = card_of(st)
  truthy('7.1 the artwork has a box', top ~= nil)
  expect('7.1 artwork carries no hint', hinted_rows(st), 0)

  -- The text follows the keys that are there: with only one bound it names only
  -- that one.
  config.setup({ keymaps = { preview = false } })
  truthy('7.1 with only the open-image key bound', rerender())
  st = current_state()
  local _, bottom_row = card_of(st)
  hint = hinted(st, bottom_row)
  eq_table('7.1 the hint names only the keys that are bound', hint and hint.virt_text,
    { { ' gx open image', 'MdRenderHint' } })

  -- With neither key bound there is nothing to advertise, which is the rule the
  -- follow hint already follows.
  config.setup({ keymaps = { preview = false, open_image = false } })
  truthy('7.1 with neither image key bound', rerender())
  st = current_state()
  truthy('7.1 the card is still there', graphics.rect(st.doc, image_line(st)) ~= nil)
  expect('7.1 no hint for a key that is not there', hinted_rows(st), 0)

  config.setup({})
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
