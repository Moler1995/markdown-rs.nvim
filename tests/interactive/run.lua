-- Interactive verification of the six insert-entry keys, `Esc`, and the block
-- preview.
--
-- Run with:
--   nvim -l tests/interactive/run.lua
--
-- Why this is a separate runner rather than part of `tests/headless/run.lua`:
--
-- The six keys are implemented by swapping to the source buffer and then
-- handing the key back to Vim with `nvim_feedkeys(key, 'n', false)`, so that
-- Vim's own `i`, `a`, `o` and friends decide where the cursor ends up. That
-- design is what makes the six behave exactly as they do in any other buffer,
-- and it is also what makes them invisible to `nvim -l`:
--
--   * `nvim -l` never enters the main input loop, and only that loop reads a
--     key queued this way. A key fed with `nvim_feedkeys(..., 'x')` does not
--     drain it either — `'x'` executes what was already in the typeahead.
--   * `nvim_get_mode()` reports `'n'` under `nvim -l` even when insert mode was
--     genuinely entered, so the mode cannot be asserted on directly.
--   * `nvim_input` does not help: the input queue is drained when the main loop
--     is idle, and it is busy running the script that called `nvim_input`.
--
-- What is left in `nvim -l` is a partial execution — some keys act as the
-- normal-mode commands they share a spelling with — which is worse than no
-- check at all, because it looks like a passing test.
--
-- So this file drives a real Neovim instead. It starts one as a server, sends
-- keys with `--remote-send` while that server sits idle in its main loop, and
-- reads back what the server observed. The evidence that a key reached insert
-- mode is the server's own `InsertEnter` autocmd firing.

-- Forward slashes, not the platform's separator. The path is interpolated into
-- Lua source that the server then evaluates, and a Windows path like
-- `D:\projects\rust\markdown-rs.nvim` reads as the escapes `\p`, `\r`, `\n` —
-- the chunk fails to compile, `MD` is left nil, and every later step dies with a
-- traceback whose hit-enter prompt swallows the rest of the run.
local repo = (function()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return (vim.fn.fnamemodify(src, ':p:h:h:h'):gsub('\\', '/'))
end)()

local ADDRESS = '127.0.0.1:7787'
local OUT = vim.fn.tempname()
vim.fn.mkdir(OUT, 'p')

-- The same directory as a path the server can read out of a `:lua` chunk. A
-- Windows tempname has backslashes, and those are escapes in Lua source.
local OUT_CMD = (OUT:gsub('\\', '/'))

-- How long to give the server to produce something the driver is waiting for.
-- Only a genuine hang costs this much: every wait here is a poll, so a healthy
-- run pays a few milliseconds each.
local TIMEOUT_MS = 10000

--------------------------------------------------------------------------------
-- The driver
--------------------------------------------------------------------------------

local function send(keys)
  local result = vim.system({ 'nvim', '--server', ADDRESS, '--remote-send', keys }):wait()
  return result.code
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
end

--- Send `keys` and return, without waiting for the server to act on them.
---
--- No wait is needed for ordering: each send is a separate process that has
--- exited before the next is spawned, and the server reads its input queue in
--- order. A step's effect is therefore already queued behind every earlier
--- step, and only the *observations* — the files the server writes — need to be
--- waited for, which `wait_for` does.
local function step(keys)
  local code = send(keys)
  if code ~= 0 then
    error(string.format('could not reach the server (exit %d) while sending %q', code, keys))
  end
end

--- The lines of `path`, waiting until it has some.
local function wait_for(path)
  local lines
  vim.wait(TIMEOUT_MS, function()
    lines = read(path)
    return lines ~= nil and #lines > 0
  end, 20)
  return lines
end

local function read_report(tag)
  local lines = wait_for(string.format('%s/%s.txt', OUT, tag))
  if not lines then
    error(string.format(
      'the server wrote no report for %q.\nInsertEnter events seen: %s\n%s',
      tag,
      table.concat(read(OUT .. '/events.txt') or {}, ' | '),
      vim.inspect(vim.fn.readdir(OUT))
    ))
  end
  local out = {}
  for _, line in ipairs(lines) do
    local key, value = line:match('^([^=]+)=(.*)$')
    if key then
      out[key] = value
    end
  end
  return out
end

--- Run a call on the server's `MD` table, and wait until the server is done.
---
--- The wait is a barrier, not politeness. A step such as `reset()` blocks inside
--- `vim.wait()` while it waits for the render, and a wait in the server's own
--- loop reads the input queue: a key sent behind such a step is served *inside*
--- it instead of after it. That is how a fed `i` once arrived in the middle of
--- the next `:lua` command line, on CI only — a mangled report tag
--- (`ciross2_0.txt`) is the signature. Waiting for the step's own marker keeps
--- every key sent afterwards behind it.
---
--- The marker also carries the step's error. An error raised inside a `:lua`
--- call does not reach the server's stderr — it goes into the message area of a
--- headless server nobody is looking at — so an unwrapped call makes the run
--- wait for a report that was never going to be written, and the failure looks
--- like a missing file rather than like the error that stopped it.
local call_count = 0
local function md_call(call)
  call_count = call_count + 1
  local marker = string.format('%s/call%d.txt', OUT_CMD, call_count)
  step(string.format(
    ":lua local ok, e = pcall(function() MD.%s end) "
      .. "vim.fn.writefile({ ok and 'ok' or tostring(e) }, '%s')<CR>",
    call, marker))
  local result = wait_for(marker)
  if not result then
    error(string.format('the server never finished MD.%s', call))
  end
  if result[1] ~= 'ok' then
    error(string.format('MD.%s failed in the server: %s', call, table.concat(result, '\n')))
  end
end

local function report(tag)
  md_call(string.format("report('%s')", tag))
  return read_report(tag)
end

--- The report about the window showing R, for the checks where that is not the
--- window the cursor is in.
local function report_live(tag)
  md_call(string.format("report_live('%s')", tag))
  return read_report(tag)
end

--- The report about the preview, taken once the popup is in the state
--- `want_open` says it should be in.
local function preview_report(tag, want_open)
  md_call(string.format("preview_report('%s', %s)", tag, tostring(want_open)))
  return read_report(tag)
end

--- Press the preview key, and report what that left behind.
---
--- The key only starts a render, so the report is where the waiting happens:
--- `preview_report` waits for the state it was asked about before it looks.
local function preview_key(tag, want_open)
  step('<CR>')
  return preview_report(tag, want_open)
end

--------------------------------------------------------------------------------
-- Start the server and load the steps
--------------------------------------------------------------------------------

local env = vim.fn.environ()
env.MDRN_REPO = repo
env.MDRN_OUT = OUT

-- The server's own output is kept: an error raised inside it — a failing step,
-- a bad key — arrives here rather than as a silent missing report.
--
-- Collected through callbacks rather than written to paths by `vim.system`:
-- Neovim 0.10 accepts only a callback there, a path arrived in 0.11.
local server_output = { ['server.out'] = {}, ['server.err'] = {} }
local function collect(name)
  return function(_, data)
    if data then
      local sink = server_output[name]
      sink[#sink + 1] = data
    end
  end
end
local server = vim.system(
  { 'nvim', '--headless', '--listen', ADDRESS, '-u', 'NONE' },
  { env = env, stdout = collect('server.out'), stderr = collect('server.err') }
)

local started = false
for _ = 1, 50 do
  if send(':echo 1<CR>') == 0 then
    started = true
    break
  end
  vim.wait(200)
end

if not started then
  server:kill()
  io.stderr:write(string.format('could not start a server on %s\n', ADDRESS))
  os.exit(2)
end

-- `dofile`, not `:luafile`: the steps are returned as a table, and `:luafile`
-- discards a chunk's return value, which would leave `MD` undefined and every
-- `:lua MD.<step>()` failing inside the server rather than here.
step(string.format(":lua MD = dofile('%s/tests/interactive/server.lua')<CR>", repo))

-- Prove the steps loaded before anything depends on them. A `:lua` chunk that
-- fails to compile leaves `MD` nil, and every step after it dies with a
-- traceback whose hit-enter prompt then eats the whole run — a failure that
-- looks nothing like its cause.
step(":lua vim.fn.writefile({ 'ok' }, MD.out .. '/loaded.txt')<CR>")
if not wait_for(OUT .. '/loaded.txt') then
  server:kill()
  io.stderr:write('the server did not load tests/interactive/server.lua\n')
  os.exit(2)
end

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

--- Check `preview.open`, naming the plugin's own message when it has one.
---
--- A popup that did not open because the engine refused the block and one that
--- had not opened yet are the same `false` in the report; the plugin's last
--- error is the only thing that tells them apart, and it is worth having in the
--- log of the run that failed rather than in the next investigation.
local function expect_open(name, report, want)
  local reported = report.reported or ''
  check(name, report.open == tostring(want),
    string.format('got %s, want %s%s%s', vim.inspect(report.open), tostring(want),
      reported ~= '' and ('; the plugin reported: ' .. reported) or '',
      -- The row under the cursor says whether the key fell through to Vim's
      -- own `<CR>` instead of finding a block: it is the row *below* the one
      -- the check put the cursor on when it did.
      report.cursor_text and ('; cursor on ' .. report.cursor_text) or ''))
end

--- `  - nested item` is source line 5, counted from zero.
local NESTED = 5

--- What each key does, given the cursor on the display line for `NESTED`: the
--- three source lines the report covers from there on, and the 0-based source
--- line the cursor should end up on.
---
--- `i` and `I` differ only because the line is indented, and `a` and `A` differ
--- only because the cursor starts on the line's first character — which is what
--- makes the six distinguishable from each other rather than merely present.
---
--- `o` and `O` are the two whose cursor is not `NESTED`, because the line they
--- open is where the cursor goes; the plugin's part is done before that, having
--- put the cursor on `NESTED` for Vim to open beside. Their new line also keeps
--- the indentation of the line it was opened next to. That is `'autoindent'`,
--- which Neovim sets for every buffer by default, and which the plugin is right
--- not to touch: it hands the key back to Vim so that `o` in R behaves like `o`
--- anywhere else.
local EXPECTED = {
  i = { cursor = NESTED, lines = { 'X  - nested item', '', '| a | b |' } },
  a = { cursor = NESTED, lines = { ' X - nested item', '', '| a | b |' } },
  I = { cursor = NESTED, lines = { '  X- nested item', '', '| a | b |' } },
  A = { cursor = NESTED, lines = { '  - nested itemX', '', '| a | b |' } },
  o = { cursor = NESTED + 1, lines = { '  - nested item', '  X', '' } },
  O = { cursor = NESTED, lines = { '  X', '  - nested item', '' } },
}

--- Press `key` in R on the display line for `NESTED`, type a marker, and report
--- what the server saw.
local function press(key)
  md_call('reset()')
  md_call('goto(' .. NESTED .. ')')

  -- Truncated here rather than at reset, so an `InsertEnter` found afterwards
  -- can only have come from this key.
  vim.fn.writefile({}, OUT .. '/events.txt')

  step(key)
  -- The wait is the assertion: nothing else is going to put a line in this file
  -- between the truncation above and this key.
  local events = wait_for(OUT .. '/events.txt') or {}
  local entered_insert = false
  for _, event in ipairs(events) do
    if event == 'InsertEnter' then
      entered_insert = true
    end
  end
  check(string.format('8.4 %s: reaches insert mode', key), entered_insert,
    'InsertEnter never fired, so the key never reached insert mode')

  -- A marker to prove where the cursor was left, and out of insert mode. Both
  -- are queued behind this key and in front of the report, so the report sees
  -- the buffer they made.
  step('X')
  step('<Esc>')

  return report(key), entered_insert
end

local KEYS = { 'i', 'a', 'I', 'A', 'o', 'O' }

--- Press `i` in R with the cursor on the display row for source line `src`,
--- moved by `offset` rows, and report what the server saw.
---
--- Where `press` proves the six keys do what their letter says, this proves the
--- cursor they cross *to*: the same key, driven from three different kinds of
--- display row.
local function cross(src, offset)
  md_call('reset()')
  md_call(string.format('goto(%d, %d)', src, offset))
  step('i')
  -- The key crosses to S and feeds `i` back to Vim, so that key travels
  -- through the server's own typeahead rather than this driver's input queue.
  -- Wait until Vim has read it before sending `<Esc>`: a late `i` can otherwise
  -- arrive in the middle of the next command on a loaded machine, entering
  -- insert mode inside the command line.
  wait_for(OUT .. '/events.txt')
  step('<Esc>')
  return report(string.format('cross%d_%d', src, offset))
end

--- Everything that talks to the server. Run under `pcall` so that a failure
--- still shuts the server down: a run that dies must not leave an nvim
--- listening on this address, because the next run would then be answered by
--- that one instead of by its own, and the failure that follows would look
--- nothing like this one.
local function body()
  for _, key in ipairs(KEYS) do
    local seen = press(key)

    expect(string.format('8.4 %s: leaves the window in S', key), seen.state, 'S')
    expect(string.format('8.4 %s: the window shows the source buffer', key), seen.showing_source, 'true')
    expect(string.format('8.4 %s: lands on the mapped source line', key),
      tonumber(seen.cursor_line), EXPECTED[key].cursor + 1)

    local got = vim.json.decode(seen.lines)
    check(string.format('8.4 %s: inserts where the key says it does', key),
      vim.deep_equal(got, EXPECTED[key].lines),
      string.format('got %s, want %s', vim.inspect(got), vim.inspect(EXPECTED[key].lines)))
  end

  -- Esc must not bring R back. Entering insert mode and leaving it again is the
  -- whole test: the plugin could plausibly have mapped the return on `Esc`, and
  -- this is what says it did not.
  md_call('reset()')
  md_call('goto(' .. NESTED .. ')')
  step('i')
  step('<Esc>')
  local after = report('esc')

  expect('8.4 Esc: leaves the window in S', after.state, 'S')
  expect('8.4 Esc: the source buffer stays in the window', after.showing_source, 'true')
  expect('8.4 Esc: the cursor does not move', tonumber(after.cursor_line), NESTED + 1)

  -- 9.2, the R->S direction: `i` from a rendered paragraph lands on the source
  -- line that paragraph came from. Source line 2 is the fixture's first
  -- paragraph, and it is wrapped and re-laid-out, so landing on it is not the
  -- same as landing on the line the cursor happened to be on.
  local paragraph = cross(2, 0)
  expect('9.2 i from a paragraph shows the source', paragraph.state, 'S')
  expect('9.2 i from a paragraph lands on that paragraph\'s source line',
    tonumber(paragraph.cursor_line), 3)

  -- 9.3, a table border. The border is drawn rather than echoed, so it has no
  -- source line of its own: the cursor on it has to resolve to the construct it
  -- belongs to, which is the table whose header sits one row below.
  local border = cross(7, -1)
  expect('9.3 i from a table border shows the source', border.state, 'S')
  expect('9.3 i from a table border lands on the table\'s source line',
    tonumber(border.cursor_line), 8)

  -- 9.3, diagram artwork. The renderer gives every artwork row the fence's own
  -- source line, so this resolves without walking anywhere.
  local artwork = cross(62, 0)
  expect('9.3 i from diagram artwork shows the source', artwork.state, 'S')
  expect('9.3 i from diagram artwork lands on the fence\'s source line',
    tonumber(artwork.cursor_line), 63)

  -- 10.4, the live path: a real edit, typed, in a window showing S, with R on
  -- screen in another window. This is the one check that cannot be made from
  -- `nvim -l`: measured, no edit route raises `TextChanged` there — not
  -- `nvim_buf_set_lines`, not `:normal!`, not `nvim_input` — because the event
  -- is raised from the main loop's own change handling, and `nvim -l` never
  -- runs it. In this server it does, and `MD.settle` gives the debounce the
  -- idle loop it needs before the report is taken.
  md_call('reset()')
  md_call('split()')
  step('O')
  -- `O` is read by the server's own loop too, so wait for the `InsertEnter` it
  -- raised: a text step that arrives before it is read as normal-mode commands
  -- (`#` searches, `i` starts inserting) and mangles the buffer instead of
  -- typing a line into it.
  wait_for(OUT .. '/events.txt')
  step('# live-edit-10.4')
  step('<Esc>')
  md_call('settle(600)')

  local live = report_live('live')
  local source = vim.json.decode(live.source)
  local rendered = vim.json.decode(live.rendered)

  truthy('10.4 the typed line reached the source buffer',
    table.concat(source, '\n'):find('live%-edit%-10%.4') ~= nil,
    string.format('the source has no such line: %s', vim.inspect(source)))
  expect('10.4 the window showing R is still showing R', live.window_showing_r, 'true')
  truthy('10.4 and it caught up with the edit',
    table.concat(rendered, '\n'):find('live%-edit%-10%.4') ~= nil,
    'the rendered view never picked up the line typed in the other window')
  expect('10.4 the editing window is still in S', live.showing_source, 'true')

  ----------------------------------------------------------------------------
  -- 4.3, the fall-through
  ----------------------------------------------------------------------------

  -- Prose has no block, so the key has to be handed back to Vim and keep its
  -- ordinary meaning. The cursor is put on the rendered form of the fixture's
  -- first list item, whose next row is the *indented* nested item — so "the
  -- first non-blank of the next line" is a column that is not zero, and the
  -- check would fail if the plugin had moved the cursor itself rather than
  -- letting Vim's `<CR>` do it.
  --
  -- That the run reaches the report at all is the other half of the evidence.
  -- A fall-through without the `'n'` flag re-enters the mapping, which finds no
  -- block again and feeds the key again; this step would not finish.
  md_call('reset()')
  md_call('goto(4)')
  local prose_before = preview_report('prose_before')
  step('<CR>')
  local prose_after = preview_report('prose_after')

  expect_open('4.3 <CR> on prose opens no popup', prose_after, false)
  expect('4.3 and leaves the window in R', prose_after.state, 'R')
  expect('4.3 and still showing the rendered buffer', prose_after.showing_rendered, 'true')
  expect('4.3 the cursor moves down one display row',
    tonumber(prose_after.cursor_line), tonumber(prose_before.cursor_line) + 1)
  expect('4.3 to the first non-blank of that row',
    tonumber(prose_after.cursor_col), 2)
  truthy('4.3 which is the next row of the document',
    vim.json.decode(prose_after.cursor_text):find('nested item', 1, true) ~= nil,
    prose_after.cursor_text)

  ----------------------------------------------------------------------------
  -- 5.1, a window narrower than the cap
  ----------------------------------------------------------------------------

  -- The end-to-end form of the spec's "a window narrower than the cap" scenario.
  -- The window is split to 40 columns, well under the 70-column cap at an
  -- 80-column editor, so the popup's budget is the larger of the two (design D3)
  -- and the columns the window's rendering clipped are recoverable. Both kinds
  -- are checked because the engine lays a table and a diagram out in different
  -- code, and only one of them being recoverable would not show up in a
  -- single-kind check. Which budget each kind gets, and how far above the
  -- window's it is, is 5.3 and 5.4.
  md_call('reset_wide()')
  md_call('narrow(40)')
  md_call('goto(6)')
  local narrow_table = preview_key('narrow_table', true)

  expect_open('5.1 the table preview opens', narrow_table, true)
  expect('5.1 in a window narrower than the cap', narrow_table.window_width, '40')
  truthy('5.1 and the popup shows columns the window clipped',
    tonumber(narrow_table.popup_widest) > tonumber(narrow_table.window_width),
    string.format('popup %s, window %s',
      narrow_table.popup_widest, narrow_table.window_width))

  local closed = preview_key('narrow_closed', false)
  expect_open('5.1 and the key closes it again', closed, false)

  md_call('goto(12)')
  local narrow_diagram = preview_key('narrow_diagram', true)

  expect_open('5.1 the diagram preview opens', narrow_diagram, true)
  expect('5.1 in the same narrow window', narrow_diagram.window_width, '40')
  truthy('5.1 and the popup shows columns the window clipped',
    tonumber(narrow_diagram.popup_widest) > tonumber(narrow_diagram.window_width),
    string.format('popup %s, window %s',
      narrow_diagram.popup_widest, narrow_diagram.window_width))

  ----------------------------------------------------------------------------
  -- 5.2, the view underneath survives the round trip
  ----------------------------------------------------------------------------

  -- Scrolled first, so that the top line is something a stray redraw could
  -- actually lose. At the top of the document "the view is unchanged" would be
  -- true of almost any implementation. The scroll is `<C-e>` rather than a
  -- motion, because the cursor has to stay on the block the preview is opened
  -- over: a motion down the document would leave it on prose, where there is no
  -- block and the key falls through to Vim's own `<CR>` instead.
  md_call('reset_wide()')
  md_call('goto(6)')
  step('4<C-e>')
  local view_before = preview_report('view_before', false)

  truthy('5.2 the window is scrolled, so the view is something that could be lost',
    tonumber(view_before.topline) > 1, view_before.topline)

  local view_open = preview_key('view_open', true)
  expect_open('5.2 the preview opens over the wide table', view_open, true)
  expect('5.2 and the window underneath is still in R', view_open.state, 'R')

  local view_after = preview_key('view_after', false)

  expect_open('5.2 the key closes it again', view_after, false)
  expect('5.2 and the window is still in R', view_after.state, 'R')
  expect('5.2 on the same buffer', view_after.buffer, view_before.buffer)
  expect('5.2 with the same cursor line', view_after.cursor_line, view_before.cursor_line)
  expect('5.2 and the same top line', view_after.topline, view_before.topline)

  ----------------------------------------------------------------------------
  -- 5.3, a window as wide as the cap
  ----------------------------------------------------------------------------

  -- The other half of design D3: with one full-width window the popup's budget
  -- is floored at the window's, so the popup holds no fewer columns than the
  -- window did — and its window is still narrower than that content, which is
  -- what makes the columns past its edge reachable by scrolling rather than
  -- lost. Without the floor the engine would have clipped the block harder for
  -- the popup than it did for the window.
  md_call('reset_wide()')
  md_call('goto(6)')
  local full_table = preview_key('full_table', true)

  expect_open('5.3 the table preview opens', full_table, true)
  expect('5.3 in a window as wide as the editor',
    full_table.window_width, full_table.columns)
  truthy('5.3 and the popup holds no fewer columns than the window did',
    tonumber(full_table.popup_widest) >= tonumber(full_table.window_widest),
    string.format('popup %s, window %s',
      full_table.popup_widest, full_table.window_widest))
  truthy('5.3 with its window narrower than that content, so the rest scrolls',
    tonumber(full_table.popup_width) < tonumber(full_table.popup_widest),
    string.format('popup window %s, content %s',
      full_table.popup_width, full_table.popup_widest))

  ----------------------------------------------------------------------------
  -- 5.4, a diagram is not laid out against the popup's own width
  ----------------------------------------------------------------------------

  -- The other half of the per-kind budget (design D3): a table is laid out at
  -- the popup's inner width, and a diagram is not, because the engine clips a
  -- diagram that does not fit and the clipped columns are not in the buffer for
  -- scrolling to reach. The fixture's sequence diagram is wider than both the
  -- window and the popup's inner width, which is what makes this observable: any
  -- budget derived from either is at most the inner width, so content wider than
  -- the inner width is content the popup did not clip.
  --
  -- The window is narrowed to 40 for the same reason 5.1 narrows it — in a
  -- full-width window a table's budget is already the window's, so the window
  -- width would not tell the two budgets apart.
  md_call('reset_wide_diagram()')
  md_call('narrow(40)')
  md_call('goto(9)')
  local wide_diagram = preview_key('wide_diagram', true)

  expect_open('5.4 the diagram preview opens', wide_diagram, true)
  expect('5.4 in the narrow window', wide_diagram.window_width, '40')
  truthy('5.4 and the popup holds more of it than the popup\'s own width',
    tonumber(wide_diagram.popup_widest) > tonumber(wide_diagram.popup_inner),
    string.format('popup content %s, popup inner width %s',
      wide_diagram.popup_widest, wide_diagram.popup_inner))
  truthy('5.4 with its window narrower than that content, so the rest scrolls',
    tonumber(wide_diagram.popup_width) < tonumber(wide_diagram.popup_widest),
    string.format('popup window %s, content %s',
      wide_diagram.popup_width, wide_diagram.popup_widest))
end

local ok, err = pcall(body)

if ok then
  step(':qa!<CR>')
else
  server:kill()
end
server:wait()

-- An error raised inside the server — a step that failed, a key that did not
-- exist — arrives as a missing report rather than as a message, because a `:lua`
-- call cannot return to the driver. Its output is kept for exactly this reason,
-- and without printing it the cause is a report that never appeared and nothing
-- else. Printed before the results so it reads as the explanation of them.
if not ok then
  for _, name in ipairs({ 'server.err', 'server.out' }) do
    local text = table.concat(server_output[name])
    if #text > 0 then
      io.stdout:write(string.format('\n--- %s ---\n%s\n', name, text))
    end
  end
end

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

io.stdout:write(string.format('\n%d checks, %d failed\n', #results, failed))
if not ok then
  io.stdout:write(string.format('\nthe run stopped early: %s\n', err))
end
os.exit((ok and failed == 0) and 0 or 1)
