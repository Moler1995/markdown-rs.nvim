-- What the plugin remembers between events.
--
-- Two things are worth remembering: which mode each window is in, and what the
-- engine last said about each buffer. The second is what makes toggling cheap
-- — a cache hit swaps buffers with no process spawned at all.

local M = {}

--- Per-window state, keyed by window id.
---
---   mode      what the window is showing now: 'S' or 'R'
---   want      what it should be showing: 'S' or 'R'
---   source    the markdown buffer
---   rendered  this window's rendered buffer, or nil before the first render
---   inherited the rendered buffer the window was showing when it was split off
---             another md-render window, if it was
---   doc       the document currently in `rendered`
---   frames    animation source line -> the frame index showing, per image
---   generation  bumped per request; a callback from an older one is dropped
M.windows = {}

--- Rendered buffer -> the window that owns it.
---
--- The rendered buffer is per-window rather than shared, which is what makes
--- two windows on one file safe: each has its own, so one window returning to
--- S cannot invalidate the buffer the other is showing.
M.by_rendered = {}

--- Source buffer -> { tick, width, height, encoding, theme, animation, image, doc }.
M.cache = {}

--- The state for `win`, created empty on first use.
function M.get(win)
  local st = M.windows[win]
  if not st then
    st = {
      win = win,
      mode = 'S',
      want = 'S',
      source = nil,
      rendered = nil,
      inherited = nil,
      doc = nil,
      -- The source's view when it was last left, and the rendered one. Held
      -- because `nvim_win_set_buf` restores a cursor line but not a top line.
      source_view = nil,
      rendered_view = nil,
      -- The display row R's cursor was put on when R was entered, or nil if it
      -- has not been entered since. Leaving R maps the cursor back to a source
      -- line only when it has moved off this row.
      rendered_anchor = nil,
      -- Animation source line -> the frame index showing, per image. Cleared
      -- whenever a new document is applied, which is what puts every image back
      -- on its first frame after a resize or an edit.
      frames = {},
      generation = 0,
    }
    M.windows[win] = st
  end
  return st
end

--- Drop every trace of `win`, wiping its rendered buffer if it still has one.
function M.forget(win)
  local st = M.windows[win]
  if not st then
    return
  end
  if st.rendered then
    M.by_rendered[st.rendered] = nil
    if vim.api.nvim_buf_is_valid(st.rendered) then
      pcall(vim.api.nvim_buf_delete, st.rendered, { force = true })
    end
  end
  M.windows[win] = nil
end

--- The cached document for this exact (buffer, width, height, encoding, theme,
--- animation, image, changedtick), or nil.
---
--- `changedtick` covers the document's *contents*: it changes on every edit and
--- on nothing else. Everything else in the key is a reason the same contents
--- could render differently — the width and height the page has, the encoding
--- images are drawn with, the theme, whether frames were asked for, and the
--- palette, background, dithering, minimum height and sharpening that decide
--- how an image is drawn. A height-only resize, or flipping `image_mode`,
--- changes what the engine would produce without touching the buffer, so those
--- have to be part of the key rather than assumed constant. `animation` is in
--- the key because an animated render and an ordinary one differ in their
--- payload while agreeing about every line: without it, asking for frames after
--- a plain render would be answered by the cache with the very document that
--- has none. `image` is compared as a whole, so a new option is one field in
--- the table below rather than another positional argument.
function M.cached(buf, tick, width, height, encoding, theme, animation, image)
  local entry = M.cache[buf]
  if entry and entry.tick == tick and entry.width == width and entry.height == height
    and entry.encoding == encoding and entry.theme == theme
    and entry.animation == (animation and true or false)
    and vim.deep_equal(entry.image, image) then
    return entry.doc
  end
  return nil
end

function M.store(buf, tick, width, height, encoding, theme, animation, image, doc)
  M.cache[buf] = {
    tick = tick,
    width = width,
    height = height,
    encoding = encoding,
    theme = theme,
    animation = animation and true or false,
    image = image and vim.deepcopy(image) or nil,
    doc = doc,
  }
end

--- Forget every cached render for `buf`. Used when a buffer is deleted.
function M.forget_cache(buf)
  M.cache[buf] = nil
end

return M
