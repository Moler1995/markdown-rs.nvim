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
      zoom_in = '+', zoom_out = '-', scroll_left = '<C-h>', scroll_right = '<C-l>' })
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
  expect('12.1 the line of an anchor', link.anchor_line(lines, 'tail'), 30)
  expect('12.1 an anchor no heading matches', link.anchor_line(lines, 'nope'), nil)
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
