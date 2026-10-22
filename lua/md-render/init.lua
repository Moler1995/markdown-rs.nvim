-- md-render.nvim: a rendered reading view for markdown, in the same window.
--
-- The design in one paragraph. A markdown buffer has two states. S is the
-- source buffer, exactly as the editor would have opened it, fully editable. R
-- is a second buffer holding the engine's rendered output, shown in the same
-- window by `nvim_win_set_buf`. Because R is a real buffer rather than a
-- decoration of S, every normal-mode motion, search and yank works on it for
-- free — and because it is a different buffer with `modifiable` off, no editing
-- command can reach the source through it. Movement between the two is
-- explicit: a toggle mapping, one of the six insert-entry keys, or the key that
-- follows the link under the cursor.

local config = require('md-render.config')
local engine = require('md-render.engine')
local link = require('md-render.link')
local preview = require('md-render.preview')
local render = require('md-render.render')
local state = require('md-render.state')

local M = {}

--- Exposed so `require('md-render').config.options` is the live table.
M.config = config

M.augroup = vim.api.nvim_create_augroup('MdRender', { clear = true })

--- The six keys that mean "I want to type here".
---
--- They are not configurable and not remappable: they are the way out of a
--- read-only buffer, so a user who rebinds one should get the rebinding rather
--- than lose the exit.
local INSERT_ENTRY = { 'i', 'a', 'I', 'A', 'o', 'O' }

--- Columns available for text in `win`.
---
--- `winwidth - textoff` is exactly it, measured rather than assumed: a line of
--- `winwidth - textoff` columns occupies one screen line, and one column more
--- occupies two. In particular a vertical split does *not* cost the left window
--- a column — the separator is not drawn inside either window — and `textoff`
--- does cover the number, sign and fold columns.
---
--- Getting this wrong in the generous direction is the dangerous one: one
--- column too many and the engine's longest line soft-wraps, which breaks the
--- one-display-line-per-buffer-line correspondence the cursor mapping rests on.
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  local off = (info and info.textoff) or 0
  return math.max(1, vim.api.nvim_win_get_width(win) - off)
end

--- Display rows available to text in `win`.
---
--- `nvim_win_get_height` is the window's text height: the statusline is not in
--- it. That is what an image may be bounded by — artwork that covered the
--- statusline would not be shown, it would be scrolled past.
local function page_height(win)
  return vim.api.nvim_win_get_height(win)
end

--- The directory relative image destinations in `source` resolve against.
---
--- The source file's own directory, so `![](img/a.png)` means what it means to
--- every other markdown tool. An unnamed buffer has no directory to speak of;
--- the engine then resolves against its working directory, so this is left nil
--- rather than guessed at.
local function image_base(source)
  local name = vim.api.nvim_buf_get_name(source)
  if name == '' then
    return nil
  end
  return vim.fn.fnamemodify(name, ':p:h')
end

--- The name to give this window's rendered buffer.
---
--- The buffer must be named: `:w` on an unnamed `acwrite` buffer fails with
--- `E32: No file name` before `BufWriteCmd` is ever consulted, so an unnamed
--- rendered buffer could not be written through. The window id keeps the name
--- unique per window, which is what lets two windows render the same document.
local function rendered_name(win, source)
  local name = vim.api.nvim_buf_get_name(source)
  name = name ~= '' and vim.fn.fnamemodify(name, ':t') or '[No Name]'
  return string.format('md-render://%d/%s', win, name)
end

--- Create (or recreate) this window's rendered buffer, empty.
local function new_rendered_buffer(st)
  local buf = vim.api.nvim_create_buf(false, true)

  -- The name is set before `buftype`, so a failure to set it cannot leave a
  -- buffer that is `acwrite` and unnamed — the one combination that breaks `:w`.
  pcall(vim.api.nvim_buf_set_name, buf, rendered_name(st.win, st.source))

  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].buflisted = false

  M.set_keymaps(buf, true)

  -- `acwrite` routes `:w` here instead of to the file, which is what makes a
  -- write in R a write of the source.
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = M.augroup,
    buffer = buf,
    callback = function()
      M.write_source(st)
    end,
  })

  -- `bufhidden=wipe` discards the buffer when the window leaves it. Keeping the
  -- map clean is the one thing Vim will not do for us — and so is the mode: a
  -- wiped buffer cannot be what the window is showing, so the state has to stop
  -- claiming otherwise.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = M.augroup,
    buffer = buf,
    once = true,
    callback = function()
      state.by_rendered[buf] = nil
      if st.rendered == buf then
        st.rendered = nil
        st.doc = nil
        st.mode = 'S'
      end
    end,
  })

  return buf
end

--- True when `st`'s window still shows one of the buffers that belong to it.
---
--- A window is not ours to rearrange once something else has put a buffer in
--- it: `:edit`, a file tree's split, any plugin that repurposes the window. The
--- state stays behind otherwise, and the next refresh — or a render already in
--- flight — would swap R back in and take the window from whatever took it.
---
--- `inherited` is the exception, and it is not a foreign buffer: a window split
--- off R legitimately shows the *other* window's rendered buffer until its own
--- first render answers. Counting that as someone else's would throw the state
--- away at the one moment it is working correctly.
local function still_ours(st)
  if not vim.api.nvim_win_is_valid(st.win) then
    return false
  end
  local shown = vim.api.nvim_win_get_buf(st.win)
  return shown == st.source or shown == st.rendered or shown == st.inherited
end

--- Show `doc` in R in `st`'s window.
---
--- The cursor is placed by mapping the source position rather than by
--- remembering a row: the two views are kept in step by deriving each from the
--- other at the moment of the swap, so reading in R and then asking to edit
--- lands on the source line being read.
local function show_rendered(st, doc)
  local win = st.win
  if not still_ours(st) then
    state.forget(win)
    return
  end

  local buf = st.rendered
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = new_rendered_buffer(st)
    st.rendered = buf
    state.by_rendered[buf] = win
  end

  if st.doc ~= doc then
    render.apply(buf, doc)
    st.doc = doc
    -- A new document is a new layout, and the frame that was showing belonged
    -- to the old one. Every render starts the image over on its first frame.
    -- The reports go with it: a resize is a new answer, and a new warning to
    -- give if the image is still over the caps.
    st.frames = {}
    st.limited = {}
  end

  -- Read before the swap, not after. `nvim_win_set_buf` leaves the window
  -- reporting the *rendered* buffer's own remembered cursor — which, since
  -- `bufhidden=wipe` discards that buffer on every return to S, is line 1
  -- rather than wherever the reader actually is. Reading it after the swap
  -- would map line 1 to source line 1 and drag the cursor there.
  local crossing = st.source and vim.api.nvim_buf_is_valid(st.source)
    and vim.api.nvim_win_get_buf(win) == st.source
  local line
  if crossing then
    -- Saved because `nvim_win_set_buf` does not restore it. Measured: it brings
    -- back the cursor line but leaves the top line at 1, so a scroll position
    -- survives the round trip only if it is held on to explicitly.
    st.source_view = vim.fn.winsaveview()
    line = st.source_view.lnum - 1
  end

  vim.api.nvim_win_set_buf(win, buf)

  -- Its own rendered buffer is in the window now, so the one inherited from the
  -- window it was split off is no longer what this state is entitled to.
  st.inherited = nil

  -- Measured on 0.12.6: none of the swap paths re-list an unlisted buffer. The
  -- option is what keeps R out of `:ls` and `:bnext`, though, so it is cheap
  -- insurance against a version that does.
  vim.bo[buf].buflisted = false

  -- Only when crossing. A re-render while R is already on screen leaves the
  -- cursor where the reader put it; re-placing it from a round trip through
  -- `source_map` would shift it by a line wherever a construct is synthetic.
  if line then
    local row = render.row_for_source(doc, line)
    if row then
      vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
    end
    -- Where R was entered, so that leaving it again can tell "the reader is
    -- still where they arrived" from "the reader moved and means it".
    st.rendered_anchor = vim.api.nvim_win_get_cursor(win)[1] - 1
  end

  st.mode = 'R'
end

--- Show the source in `st`'s window, at the line R was showing.
---
--- The source's own view is restored from the copy taken when it was left, and
--- the cursor is placed on the source line the display line came from — but only
--- when the reader actually moved in R. The two maps are not inverses and cannot
--- be: `source_map` sends several source lines to one display line wherever a
--- construct is drawn rather than echoed (a table's delimiter row becomes a
--- border, so it has no display line of its own). Round-tripping through them
--- therefore drifts by a line, and toggling would walk the cursor down the
--- document. Restoring a view the reader never changed has to be exact, so it is
--- done from the saved view alone; the mapping is for when they did move, and
--- then it is what they meant.
local function show_source(st)
  local win = st.win
  if not still_ours(st) then
    state.forget(win)
    return
  end
  local source = st.source
  if not source or not vim.api.nvim_buf_is_valid(source) then
    return
  end

  local line
  if st.rendered and vim.api.nvim_buf_is_valid(st.rendered)
    and vim.api.nvim_win_get_buf(win) == st.rendered and st.doc then
    st.rendered_view = vim.fn.winsaveview()
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if st.rendered_anchor == nil or row ~= st.rendered_anchor then
      line = render.source_line_for(st.doc, row)
    end
  end

  if vim.api.nvim_win_get_buf(win) ~= source then
    vim.api.nvim_win_set_buf(win, source)
  end
  st.inherited = nil

  if st.source_view then
    vim.fn.winrestview(st.source_view)
  end
  if line then
    local count = vim.api.nvim_buf_line_count(source)
    vim.api.nvim_win_set_cursor(win, { math.min(line + 1, count), 0 })
  end

  st.want = 'S'
  st.mode = 'S'
end

--- Report a rendering failure, once per failure rather than once per attempt.
local function report(st, message)
  if st.reported ~= message then
    st.reported = message
    vim.notify('md-render: ' .. message, vim.log.levels.ERROR)
  end
end

--- Bumped per preview request, so an answer to a superseded one is dropped.
local preview_generation = 0

--- Put `key` into the typeahead, unremapped.
---
--- The `'n'` flag is load-bearing wherever this hands a key back to Vim: the
--- mapping that is giving it back is buffer-local, so a fed key that was
--- subject to remapping would re-enter that same mapping and loop. Unremapped,
--- the key performs its ordinary editor action — which for the default `<CR>`
--- is the move to the first non-blank of the next line, and for `gf` is Vim's
--- own file-under-the-cursor.
local function feed(key)
  if not key or key == '' or key == false then
    return
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
end

--- Hand the preview key back to Vim.
local function fall_through()
  feed(config.options.keymaps.preview)
end

--- A one-line hint at the bottom of the editor, or its removal when `nil`.
---
--- The frame fetch is the one render that can take seconds — a 640×360 GIF of
--- 189 frames costs about a second and a half of decoding — and until it lands
--- the picture looks inert, so a reader pressing the step key has no way to
--- tell work from a broken key. The hint is echoed rather than notified: it is
--- status, not a message worth keeping in `:messages`, and it is cleared when
--- the answer arrives whether or not the answer was usable.
local function status(message)
  vim.api.nvim_echo({ { message or '', 'Comment' } }, false, {})
end

--- Ask the engine for a document, and show it if R is still what we want.
---
--- A cache hit short-circuits the process entirely; that is what makes toggling
--- back and forth free. Otherwise the request is stamped with a generation, and
--- a callback from an older generation is dropped rather than applied.
---
--- `opts.animate` asks the engine for an animated image's frames as well as its
--- first frame. `opts.after(doc)` runs with the answer once it has been accepted
--- — after the staleness check, so it is safe to act on.
local function request(st, opts)
  opts = opts or {}
  local win = st.win
  local source = st.source
  if not vim.api.nvim_win_is_valid(win) or not source or not vim.api.nvim_buf_is_valid(source) then
    return
  end

  -- Anything that is not the frame fetch supersedes it: its answer will be
  -- dropped by the generation check, so the in-flight state cannot wait for
  -- that answer to clear itself.
  if not opts.animate then
    st.fetching = nil
    st.pending_steps = nil
  end

  local width = text_width(win)
  -- Inline artwork is bounded by the page unless the reader asked for smaller
  -- pictures. `false` (or any non-positive number) means no cap: `setup`
  -- merges tables, where nil cannot say "off" because it is indistinguishable
  -- from a missing key. The popup builds its own view and is deliberately not
  -- routed through here, so the preview still shows an image at its own size.
  local height = page_height(win)
  local cap = config.options.image_max_height
  if type(cap) == 'number' and cap > 0 then
    height = math.min(height, cap)
  end
  local encoding = config.image_encoding()
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local theme = config.options.theme
  -- Frames are asked for only when a caller actually wants them — the step key
  -- on an image, or the popup opening one. With the option off they are never
  -- asked for, whatever the caller wants.
  local animation = (opts.animate and config.options.image_animation) and true or false

  local cached = state.cached(source, tick, width, height, encoding, theme, animation)
  if cached then
    st.reported = nil
    if st.want == 'R' then
      show_rendered(st, cached)
    end
    if opts.after then
      opts.after(cached)
    end
    return
  end

  local generation = st.generation + 1
  st.generation = generation

  local content = table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n')
  local view = {
    width = width,
    height = height,
    encoding = encoding,
    base = image_base(source),
    animation = animation,
  }

  if opts.animate then
    status('md-render: decoding image frames…')
  end

  engine.render(config.options, content, view, function(err, doc)
    if opts.animate then
      status(nil)
    end
    -- Two answers are stale, and both have to be dropped here rather than
    -- checked for downstream: one for a state that has asked again, and one for
    -- a state the window no longer has. The second is the subtle one — a state
    -- dropped by `state.forget` keeps its `generation`, and a fresh state starts
    -- counting from zero, so a render left over from a window's *previous*
    -- document passes the generation check on its own terms and would then swap
    -- its own rendered buffer into that window, taking the place of the document
    -- actually being opened and leaving the current state's swap unable to
    -- recognise the source it was going to cross from.
    if st.generation ~= generation or not vim.api.nvim_win_is_valid(st.win)
      or state.windows[st.win] ~= st then
      return
    end

    if err then
      -- The fetch failed, so no `after` will run: the in-flight state has to be
      -- cleared here or the step key would wait forever for an answer that is
      -- never coming.
      if opts.animate then
        st.fetching = nil
        st.pending_steps = nil
      end
      -- The spec is explicit that a failure leaves the editor in S rather than
      -- showing a partial view, so this swaps back if R had already been shown.
      report(st, err)
      if st.mode == 'R' then
        show_source(st)
      end
      return
    end

    st.reported = nil
    state.store(source, tick, width, height, encoding, theme, animation, doc)
    if opts.animate and st.doc and st.want == 'R' then
      -- Adopted, not applied. The engine guarantees an animated document's
      -- `lines` are the static document's, so swapping the document under the
      -- buffer would repaint every line to say the same thing — and would throw
      -- away the frame index the caller is about to step from.
      st.doc = doc
    elseif st.want == 'R' then
      show_rendered(st, doc)
    end
    -- Runs only for an answer that passed the staleness check, so a step that
    -- was overtaken by a newer render never writes a frame.
    if opts.after then
      opts.after(doc)
    end
  end)
end

--- Bring `st`'s window in line with `st.want`.
local function sync(st)
  if st.want == 'R' then
    request(st)
  else
    show_source(st)
  end
end

--- Render again in every window that is showing R.
---
--- Called only from the debounce below. It is safe to call when nothing has
--- changed: `request` looks the document up by (buffer, width, theme,
--- changedtick) first and returns on a hit, so the only windows that reach the
--- engine are the ones whose width or contents actually moved.
local function refresh()
  for _, st in pairs(state.windows) do
    if st.want == 'R' then
      request(st)
    end
  end
end

--- The coalescing timer for `refresh`.
local refresh_timer = vim.uv.new_timer()

--- Ask for a refresh, coalescing bursts into one render.
---
--- Two things make R stale, and both arrive in bursts: a drag-resize fires
--- `WinResized` once per column, and typing fires `TextChanged` once per
--- keystroke. Neither burst is worth one engine process per event — the render
--- that answers the last event answers all of them — so the timer collapses the
--- burst and the work happens once.
---
--- A toggle is deliberately *not* routed through here: it calls `sync` directly.
--- That is the difference between this and the measured precedent in
--- `render-markdown.nvim`, whose 100 ms gate drops a toggle issued immediately
--- after a render. Here the debounce only ever coalesces refreshes, so it has no
--- user action to swallow.
local function schedule_refresh()
  local wanted = false
  for _, st in pairs(state.windows) do
    if st.want == 'R' then
      wanted = true
      break
    end
  end
  if not wanted then
    -- Nothing on screen is showing R, so there is nothing to refresh and no
    -- reason to wake the loop for it. The buffer's changedtick has moved, and
    -- the cache is keyed on it, so the render that does happen will be a fresh
    -- one anyway.
    return
  end
  refresh_timer:stop()
  refresh_timer:start(config.options.resize_debounce, 0, vim.schedule_wrap(refresh))
end

--- Attach to `buf` in `win`: remember it and ask for R.
---
--- Called for every window a managed buffer is shown in, so each window gets
--- its own state and its own rendered buffer.
function M.attach(buf, win)
  win = win or vim.api.nvim_get_current_win()
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not config.manages(vim.bo[buf].filetype) then
    return
  end
  local st = state.get(win)
  if st.source and st.source ~= buf then
    -- The window has moved to a different document; the old state is not
    -- reachable from here any more.
    state.forget(win)
    st = state.get(win)
  end
  -- A window split off a window showing R starts out showing that window's
  -- rendered buffer, and keeps showing it until this state's first render
  -- answers. Recorded so `still_ours` can tell it apart from a buffer somebody
  -- else has put in the window.
  if st.rendered == nil then
    local shown = vim.api.nvim_win_get_buf(win)
    if state.by_rendered[shown] then
      st.inherited = shown
    end
  end

  st.source = buf
  st.want = 'R'
  st.reported = nil
  M.set_keymaps(buf, false)
  sync(st)
end

--- Forget everything about `win`.
function M.detach(win)
  state.forget(win)
end

--- Swap between R and S in `win`.
function M.toggle(win)
  win = win or vim.api.nvim_get_current_win()
  local st = state.get(win)
  if not st.source then
    return
  end
  st.want = st.want == 'R' and 'S' or 'R'
  sync(st)
end

--- Ask for R in `win`, whether or not it is already there.
function M.show_rendered(win)
  win = win or vim.api.nvim_get_current_win()
  local st = state.get(win)
  if not st.source then
    return
  end
  st.want = 'R'
  sync(st)
end

--- Ask for S in `win`, whether or not it is already there.
function M.show_source(win)
  win = win or vim.api.nvim_get_current_win()
  local st = state.get(win)
  if not st.source then
    return
  end
  show_source(st)
end

--- Preview the block under the cursor in `win`, or close an open preview.
---
--- Where there is no previewable block the key is handed back to Vim rather than
--- swallowed, so it keeps whatever motion it has everywhere else.
function M.preview(win)
  win = win or vim.api.nvim_get_current_win()

  -- The popup has focus while it is open, so a second press is a close.
  if preview.is_open() then
    preview.close()
    return
  end

  local st = state.get(win)
  local source = st.source
  local lines = source and vim.api.nvim_buf_is_valid(source)
    and vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local block = (st.doc and lines) and preview.locate(st.doc, row, lines) or nil

  if not block then
    fall_through()
    return
  end

  -- A preview is a second render of a block, and two can be in flight if the
  -- key is pressed twice before the first engine answers. The older answer is
  -- dropped rather than opened over the newer one.
  preview_generation = preview_generation + 1
  local generation = preview_generation

  local geometry = preview.geometry(block.kind, text_width(win))
  local view = preview.view(block, geometry, image_base(source))
  preview.render_block(config.options, block, view, function(err, doc)
    if generation ~= preview_generation then
      return
    end
    if err then
      -- The spec asks for no popup at all rather than an empty one: the popup's
      -- job is to show the block, and there is no block to show.
      report(st, err)
      return
    end
    preview.open(doc, geometry, block)
  end)
end

--- The source lines of `st`'s document, or nil when there are none to read.
local function source_lines(st)
  if not st.source or not vim.api.nvim_buf_is_valid(st.source) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(st.source, 0, -1, false)
end

--- The animation `doc` carries for the reference on source line `lnum`, if any.
---
--- Absent while the document was rendered without `--image-animation`, which is
--- every ordinary render: the frames are fetched the first time they are asked
--- for, not before.
local function animation_for(doc, lnum)
  for _, animation in ipairs(doc.animations or {}) do
    if animation.source == lnum then
      return animation
    end
  end
  return nil
end

--- True when the engine refused the animation for the reference on `lnum`.
---
--- The image is a GIF or WebP that does animate, but the whole frame set was
--- over the engine's frame or pixel cap. The document still draws its first
--- frame; only the frames are missing, and the reader is told so rather than
--- left pressing the step key at a picture that never moves.
local function animation_limited(doc, lnum)
  for _, source in ipairs(doc.animations_limited or {}) do
    if source == lnum then
      return true
    end
  end
  return false
end

--- Tell the reader that `ref` is too large to animate, once per render.
---
--- The network of causes here is worth one clear message rather than a key
--- that silently does nothing: the picture is drawn, so it looks playable, and
--- only the frames are missing. Repeating the press is answered from
--- `st.limited`, so a reader who keeps trying gets no engine round trip and no
--- second warning.
local function notify_limited(st, ref, lnum)
  st.limited = st.limited or {}
  if st.limited[lnum] then
    return
  end
  st.limited[lnum] = true
  vim.notify(
    ('md-render: %s is too large to animate; showing its first frame'):format(
      vim.fn.fnamemodify(ref.target or '', ':t')),
    vim.log.levels.WARN)
end

--- True when `ref` names something that could be animated.
---
--- Only a local GIF or WebP can carry frames, so the step key needs no engine
--- round trip to know a PNG, a URL or a `data:` URI is not worth one. Whether
--- the file really animates — and whether it is over the engine's caps — is the
--- engine's answer, not the extension's.
local function maybe_animated(ref)
  if not ref or ref.kind ~= 'file' then
    return false
  end
  local target = (ref.target or ''):lower()
  return target:sub(-4) == '.gif' or target:sub(-5) == '.webp'
end

--- Draw frame `index` (0-based) of `animation` and remember it.
local function show_frame(st, animation, index)
  if render.frame(st.rendered, st.doc, animation, index) then
    st.frames = st.frames or {}
    st.frames[animation.source] = index
  end
end

--- Draw the frame `delta` places from the one on screen, wrapping at the ends.
local function step_frame(st, animation, delta)
  local current = (st.frames and st.frames[animation.source]) or 0
  show_frame(st, animation, (current + delta) % #animation.frames)
end

--- Show the next frame of the animated image under the cursor in `win`.
---
--- R never plays by itself: this key is the only thing that moves an image, and
--- it moves it one frame. When the document on screen has no frames for the
--- image — the ordinary case, since frames are fetched lazily — the animated
--- render is requested and the step is taken as it lands. Everywhere else the
--- key goes back to Vim, so `<C-n>` keeps its ordinary meaning on prose and on
--- a still image.
function M.frame_next(win)
  win = win or vim.api.nvim_get_current_win()
  local key = config.options.keymaps.frame_next
  local st = state.get(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not config.options.image_animation or not st.doc or buf ~= st.rendered then
    return feed(key)
  end

  local lines = source_lines(st)
  if not lines then
    return feed(key)
  end

  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local lnum = render.source_line_for(st.doc, row)
  local ref = lnum and link.images(lines, lnum)[1]
  if not ref then
    return feed(key)
  end

  local animation = animation_for(st.doc, lnum)
  if animation then
    if #animation.frames > 1 then
      step_frame(st, animation, 1)
    else
      feed(key)
    end
    return
  end

  -- Already refused by an earlier press: say so again without a second engine
  -- render, because nothing about the answer can have changed.
  if animation_limited(st.doc, lnum) then
    return notify_limited(st, ref, lnum)
  end

  if not maybe_animated(ref) then
    return feed(key)
  end

  -- A press while the frames are already being fetched is remembered, not
  -- thrown away: decoding the same image again in parallel only burns another
  -- CPU core and starts a second multi-megabyte render whose answer the
  -- generation check would drop. The presses are counted here and replayed when
  -- the one answer lands, so three presses move three frames.
  if st.fetching then
    st.pending_steps = (st.pending_steps or 1) + 1
    return
  end
  st.fetching = true
  st.pending_steps = 1

  -- Asked for and stepped in one press. The step waits for the answer, so the
  -- image goes from its first frame straight to its second; if the answer has
  -- no frames for this image — a still GIF, a file that is not there — the
  -- press falls through as if the key had never been seen. An image the engine
  -- refused for size is different: the key is consumed and the reader is told
  -- why, because falling through would move the cursor and still not explain
  -- the motionless picture.
  local want = lnum
  request(st, {
    animate = true,
    after = function(doc)
      st.fetching = nil
      local steps = st.pending_steps or 1
      st.pending_steps = nil
      if animation_limited(doc, want) then
        return notify_limited(st, ref, want)
      end
      local fetched = animation_for(doc, want)
      if not fetched or #fetched.frames < 2 then
        -- Each press was the reader's, not ours: hand them all back.
        for _ = 1, steps do
          feed(key)
        end
        return
      end
      show_frame(st, fetched, steps % #fetched.frames)
    end,
  })
end

--- Open the image under the cursor in `win` with the system application.
---
--- The destination is resolved the way the engine resolves it: an absolute path
--- as given, a relative one against the directory of the document holding the
--- reference, and a document with no file against the working directory. Only
--- a local file is opened: a URL and a `data:` URI are reported rather than
--- fetched, and so is a path that is not there. Off an image the key goes back
--- to Vim, where `gx` keeps its own meaning.
function M.open_image(win)
  win = win or vim.api.nvim_get_current_win()
  local key = config.options.keymaps.open_image
  local st = state.get(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not st.doc or buf ~= st.rendered then
    return feed(key)
  end

  local lines = source_lines(st)
  if not lines then
    return feed(key)
  end

  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local lnum = render.source_line_for(st.doc, row)
  local ref = lnum and link.images(lines, lnum)[1]
  if not ref then
    return feed(key)
  end

  local target = ref.target or ''
  if ref.kind == 'url' or target:match('^data:') then
    vim.notify('md-render: cannot open ' .. ref.raw .. ': it is not a local file',
      vim.log.levels.WARN)
    return
  end

  local name = vim.api.nvim_buf_get_name(st.source)
  local base = name ~= '' and vim.fn.fnamemodify(name, ':h') or vim.fn.getcwd()
  local path = target
  -- Absolute in either the POSIX or the Windows sense: a leading separator, a
  -- drive letter, or a UNC share.
  if not (path:match('^[/\\]') or path:match('^%a:[/\\]')) then
    path = base .. '/' .. path
  end
  path = vim.fn.fnamemodify(path, ':p')

  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat then
    vim.notify('md-render: cannot open ' .. target .. ': no such file', vim.log.levels.WARN)
    return
  end
  if stat.type ~= 'file' then
    vim.notify('md-render: cannot open ' .. target .. ': not a file', vim.log.levels.WARN)
    return
  end

  -- `vim.ui.open` is the editor's own dispatch layer: it knows the desktop's
  -- handler on this platform, and it returns the reason when there is none.
  local _, err = vim.ui.open(path)
  if err then
    vim.notify('md-render: could not open ' .. target .. ': ' .. err, vim.log.levels.WARN)
  end
end

--- Move the cursor to the heading `fragment` names, in whichever state the
--- window is in. Returns false when there is no such heading.
local function jump_anchor(st, fragment)
  local lines = source_lines(st)
  local at = lines and link.anchor_line(lines, fragment)
  if not at then
    return false
  end

  local win = st.win
  if st.doc and vim.api.nvim_win_get_buf(win) == st.rendered then
    -- In R the heading's source line has to be turned back into a display row.
    -- A heading the engine drew no line for has none, and there is nowhere to
    -- put the cursor, so the jump is refused rather than misplaced.
    local row = render.row_for_source(st.doc, at)
    if not row then
      return false
    end
    vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
    st.rendered_anchor = row
  else
    vim.api.nvim_win_set_cursor(win, { at + 1, 0 })
  end
  return true
end

--- Open what the link under the cursor points at.
---
--- A file opens in the window, a URL opens in whatever the desktop opens URLs
--- with, and an anchor scrolls to the heading it names — in this document, or
--- in the one just opened.
---
--- In R there is no link to read: the engine drops link targets, so the
--- rendered text holds the link's text and nothing else. The display row is
--- therefore mapped back to the source line it came from — the same step the
--- toggle makes — and the link is read from the source. That is what lets a
--- reader follow a link without leaving the reading view first.
---
--- A source line holding more than one link resolves to the first of them when
--- it is followed from R, because the rendered line is a layout of the source
--- rather than a copy of it and a display column has no byte column in the
--- source to be compared against. From S the cursor's own column decides.
---
--- With no link under the cursor the key goes back to Vim, so `gf` keeps its
--- ordinary meaning on a path written as plain text.
function M.follow(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local st = state.get(win)
  local key = config.options.keymaps.follow
  local lines = source_lines(st)
  local buf = vim.api.nvim_win_get_buf(win)
  if not lines or (buf ~= st.source and buf ~= st.rendered) then
    return feed(key)
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local lnum = row

  if buf == st.rendered then
    lnum = st.doc and render.source_line_for(st.doc, row)
    if not lnum then
      return feed(key)
    end
    col = nil
  end

  local found = link.at(lines, lnum, col)
  if not found then
    return feed(key)
  end

  if found.kind == 'url' then
    vim.ui.open(found.raw)
    return
  end

  if found.kind == 'anchor' then
    if found.fragment and jump_anchor(st, found.fragment) then
      return
    end
    vim.notify('md-render: no heading matches ' .. found.raw, vim.log.levels.WARN)
    return
  end

  -- The destination is written relative to the document holding it rather than
  -- to the working directory, which is what Vim's own `gf` does too.
  local name = vim.api.nvim_buf_get_name(st.source)
  local base = name ~= '' and vim.fn.fnamemodify(name, ':h') or vim.fn.getcwd()
  local path = vim.fn.fnamemodify(base .. '/' .. found.target, ':p')
  if vim.fn.filereadable(path) == 0 then
    vim.notify('md-render: no such file: ' .. found.target, vim.log.levels.WARN)
    return
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(path))

  -- Placed before the attach rather than after it. The attach renders the new
  -- document from the source buffer, so moving the cursor now is what makes R
  -- open on the section instead of on line 1.
  if found.fragment then
    local at = link.anchor_line(vim.api.nvim_buf_get_lines(0, 0, -1, false), found.fragment)
    if at then
      vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
    end
  end

  -- Attached here rather than left to the `FileType` autocmd, because that
  -- event does not fire for a file that is already loaded: `:edit` on a buffer
  -- whose filetype is already set raises `BufEnter` and `BufWinEnter` and
  -- nothing else, so following a second link to the same file would leave it
  -- on screen as source.
  --
  -- Where the event does fire — a file being loaded for the first time — the
  -- attach it schedules arrives on top of this one. That is harmless: it finds
  -- the state already in place and asks for the same document again rather than
  -- starting over, and of the two answers it is the later that lands, the
  -- earlier being dropped by the generation check.
  M.attach(vim.api.nvim_get_current_buf(), win)
end

--- Cross from R into S at the source line under the cursor, then feed `key`.
---
--- The cursor is placed before the key is fed, so that Vim's own `i`, `o` and
--- friends act on the source line the display line came from rather than on
--- whatever line the source buffer happened to be left at.
function M.enter_insert(win, key)
  win = win or vim.api.nvim_get_current_win()
  local st = state.get(win)
  if not st.source or not st.doc then
    return
  end

  show_source(st)

  -- Fed rather than executed: `i` and `A` are not commands, and letting Vim
  -- interpret the key is what makes each of the six behave exactly as it does
  -- in any other buffer. Unremapped, the key is left in the typeahead, which
  -- Vim reads as soon as this mapping returns.
  feed(key)
end

--- Write the source buffer, from wherever the write was issued.
function M.write_source(st)
  local source = st.source
  if not source or not vim.api.nvim_buf_is_valid(source) then
    vim.notify('md-render: nothing to write', vim.log.levels.WARN)
    return
  end
  if vim.api.nvim_buf_get_name(source) == '' then
    vim.notify('md-render: the source buffer has no file name', vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_call(source, function()
    vim.cmd('silent write')
  end)
end

--- Set up the config and the autocmds. Returns the resolved options.
function M.setup(opts)
  local options = config.setup(opts)
  M.setup_autocmds()
  return options
end

--- Install the maps a managed buffer needs, in `buf`.
---
--- `insert_entry` is what separates the two states. The toggle and the write
--- key belong to both, because they are how you leave either one. The six
--- insert-entry keys belong only to R: mapping them in S would shadow Vim's own
--- `i`, `a` and the rest, which in the source buffer mean exactly what they
--- always mean.
function M.set_keymaps(buf, insert_entry)
  local options = config.options
  local function map(lhs, rhs, desc)
    if lhs and lhs ~= '' and lhs ~= false then
      vim.keymap.set('n', lhs, rhs, { buffer = buf, desc = desc, nowait = true })
    end
  end

  map(options.keymaps.toggle, function()
    M.toggle()
  end, 'md-render: toggle rendered view')

  map(options.keymaps.write, function()
    -- Through `:write` rather than `M.write_source` directly, so that the key
    -- and `:w` are one route rather than two: in R the buffer in the window is
    -- the rendered one, and its `BufWriteCmd` is what reaches the source.
    vim.cmd('silent write')
  end, 'md-render: write')

  -- The one key besides the toggle and the write key that belongs to both
  -- states: a link is followed from wherever the reader is, and the rendered
  -- view is exactly where the links are worth following from.
  map(options.keymaps.follow, function()
    M.follow()
  end, 'md-render: follow the link under the cursor')

  if not insert_entry then
    return
  end

  -- The preview belongs to R only. In S the cursor is already on the block's
  -- source, which is what the preview would be showing, so a second way to look
  -- at it earns nothing.
  map(options.keymaps.preview, function()
    M.preview()
  end, 'md-render: preview this block')

  -- Frames and files are R's too: an image is something the rendered view can
  -- show, and in S its reference is ordinary text that Vim's own `gx`/`<C-n>`
  -- should keep operating on.
  map(options.keymaps.frame_next, function()
    M.frame_next()
  end, 'md-render: next frame of the animated image')

  map(options.keymaps.open_image, function()
    M.open_image()
  end, 'md-render: open the image under the cursor')

  for _, key in ipairs(INSERT_ENTRY) do
    map(key, function()
      M.enter_insert(nil, key)
    end, 'md-render: edit at this line')
  end
end

--- The autocmds the plugin needs. Called from `plugin/md-render.lua` so that a
--- user who only wants the Lua API can skip them.
function M.setup_autocmds()
  if M.autocmds_ready then
    return
  end
  M.autocmds_ready = true
  local group = M.augroup

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(args)
      if config.manages(vim.bo[args.buf].filetype) then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(args.buf) then
            M.attach(args.buf, vim.api.nvim_get_current_win())
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = group,
    callback = function(args)
      state.forget_cache(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      M.detach(tonumber(args.match))
    end,
  })

  -- A split of a window showing R puts the same rendered buffer in the new
  -- window, and that window needs its own state: without one its toggle would do
  -- nothing, and it would go on showing the other window's rendered buffer,
  -- which that window's return to S would then have to keep alive.
  --
  -- `WinEnter`, not `BufWinEnter`: measured, `:split` fires `WinNew` and
  -- `WinEnter` and *no* `BufWinEnter` at all, because the buffer was already on
  -- screen and Vim does not consider it newly shown. At `WinEnter` the new
  -- window already has the buffer, which is what makes this a lookup rather
  -- than a guess.
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      -- A floating window inherits the buffer of whatever it was opened over,
      -- and `nvim_open_win` fires `WinEnter` for it *before* swapping its own
      -- buffer in. Matching here would therefore attach the float as if it were
      -- a split of R: it would be given a rendered buffer of its own and would
      -- stop showing what it was opened to show. Floats are never splits of R,
      -- so they are excluded before the buffer is looked at.
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= '' or cfg.external then
        return
      end
      local inherited = vim.api.nvim_win_get_buf(win)
      local owner = state.by_rendered[inherited]
      if not owner then
        return
      end
      local st = state.windows[owner]
      -- The second condition is what stops this from re-entering itself:
      -- attaching swaps a rendered buffer into a window, and by the time that
      -- is done the window has state of its own.
      if not (st and st.source) or state.windows[win] ~= nil then
        return
      end

      -- Deferred, and re-checked against the buffer the window inherited.
      --
      -- A window shows the buffer it inherited for a moment whether it was
      -- split from R or split by a plugin that is about to put its own buffer
      -- there — `:Lexplore` is the one that found this: netrw splits, inherits
      -- R, and opens its tree in that window. At `WinEnter` the two are
      -- indistinguishable. By the next tick a genuine split still shows the
      -- rendered buffer; netrw's window shows its tree, and is left alone.
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) or state.windows[win] ~= nil then
          return
        end
        if vim.api.nvim_win_get_buf(win) ~= inherited then
          return
        end
        local owner_st = state.windows[owner]
        if owner_st and owner_st.source then
          M.attach(owner_st.source, win)
        end
      end)
    end,
  })

  -- The width changed: R is laid out for a width the window no longer has.
  -- `VimResized` is here as well as `WinResized` because a terminal resize
  -- resizes the windows too, and coalescing makes a doubled event free.
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = schedule_refresh,
  })

  -- The source changed: R is stale until it is rendered again, but only where R
  -- is actually on screen — a re-render for a window showing S would be a
  -- process spawned for nobody to look at. The render is also deferred to the
  -- end of the burst rather than run per keystroke.
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = function(args)
      -- Matched against a window showing R rather than merely against a managed
      -- filetype: `render.apply` sets lines in the rendered buffers, which fires
      -- this event too, and only the source is worth re-rendering.
      for _, st in pairs(state.windows) do
        if st.want == 'R' and st.source == args.buf then
          schedule_refresh()
          return
        end
      end
    end,
  })
end

return M
