-- Putting a rendered document into a buffer, and mapping between the two
-- coordinate systems afterwards.
--
-- The engine's output is already the layout: a list of lines, each with its
-- text and its styles, and each knowing the source line it came from. So
-- "rendering" here is a `nvim_buf_set_lines` and one extmark per span. There
-- is no conceal and no line-height arithmetic, because R is a real buffer
-- rather than a decorated view of S. The one piece of virtual text is the image
-- hint, drawn over the row it annotates: it shifts nothing and is not part of
-- the line's bytes, so the one-buffer-line-per-display-line correspondence the
-- source mapping rests on is untouched.

local config = require('md-render.config')
local style = require('md-render.style')

local M = {}

M.ns = vim.api.nvim_create_namespace('md-render')

--- The text of one wire line, with its spans concatenated.
local function line_text(line)
  local parts = {}
  for _, span in ipairs(line.spans) do
    parts[#parts + 1] = span[2]
  end
  return table.concat(parts)
end

--- Style one display row from a wire line's spans, and underline its links.
---
--- `styles` is the document's style table; each span's index is an index into
--- it. Styles are interned here rather than up front, so a frame using a colour
--- no earlier frame used costs one highlight group and nothing else.
---
--- `image` is the hint for a row that shows an image reference as something a
--- key opens — a card's caption row, or the alt text the engine writes when it
--- cannot draw the picture. Such a row looks like ordinary text or an inert
--- surface, so the hint says in words which key opens the picture; the caller
--- decides which row it goes on and at what column, since it is the one that
--- knows the presentation.
local function paint_line(buf, row, line, styles, hints, image)
  -- Extmark columns are byte offsets, so this walks bytes rather than
  -- columns. That is also why the engine's width guarantee matters here: a
  -- line that overflowed would soft-wrap and break the one-display-line-per-
  -- buffer-line correspondence the cursor mapping depends on.
  local col = 0
  for _, span in ipairs(line.spans) do
    local index, text = span[1], span[2]
    local len = #text
    if len > 0 then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, col, {
        end_col = col + len,
        hl_group = style.group(styles[index + 1], index),
      })
      col = col + len
    end
  end

  -- A link the engine laid into the line — a mermaid node named by a `click`
  -- directive — gets a second extmark whose group only adds an underline, so
  -- it says "this can be followed" without repainting the artwork. The ranges
  -- are byte offsets and the engine has already clamped them to the visible
  -- line; the clamp below is repeated because an extmark past the line's end is
  -- an error rather than a quiet truncation.
  --
  -- The hint is tied to the follow keys: with none of them bound there is
  -- nothing to advertise, and an underline that does nothing would be worse
  -- than none.
  if hints and line.links
    and (config.options.keymaps.follow or config.options.keymaps.follow_tab) then
    for _, link in ipairs(line.links) do
      local from, to = link[1], math.min(link[2], col)
      if from < to then
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, from, {
          end_col = to,
          hl_group = style.link_group,
          priority = 10,
        })
      end
    end
  end

  -- The image hint is virtual text drawn over the row, not an underline: a
  -- card's caption is centred in a box of surface cells and an alt text is a
  -- line of prose, so neither has a byte range to mark the way an engine link
  -- does, and a word at the row's end says which key to press. Overlay is the
  -- position that shifts nothing: end-of-line virtual text on a card would
  -- reach past the window's right edge, where a wrapped line would become two
  -- screen rows and the source mapping would drift.
  if image then
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      virt_text = { { image.text, style.hint_group } },
      virt_text_pos = 'overlay',
      virt_text_win_col = image.col,
      hl_mode = 'combine',
    })
  end
end

--- Replace `buf`'s contents with `doc` and style every span.
---
--- `hints` (default true) says whether a link the engine laid into a line is
--- underlined. The preview popup passes false: it shows the same lines but
--- binds no follow key of its own, and a hint for a key that is not there
--- would mislead.
---
--- `image_hints` maps a 0-based display row to `{ text, col }`: the hint saying
--- which key opens an image shown as a card or an alt text, and the window
--- column it is drawn at. It is built by the caller that knows the
--- presentation, the keys bound and the room on the row; the popup passes none.
function M.apply(buf, doc, hints, image_hints)
  local lines = {}
  for i, line in ipairs(doc.lines) do
    lines[i] = line_text(line)
  end
  -- A buffer must have at least one line, and the engine emits one for an
  -- empty document, so this only guards against a document that somehow has
  -- none.
  if #lines == 0 then
    lines = { '' }
  end

  -- `modifiable` is the property that keeps a reflexive `:w` or `dd` in R from
  -- touching anything; it is turned off again below, before the buffer is ever
  -- shown.
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  for i, line in ipairs(doc.lines) do
    paint_line(buf, i - 1, line, doc.styles, hints ~= false,
      image_hints ~= nil and image_hints[i - 1] or nil)
  end

  vim.bo[buf].modifiable = false

  -- Writing the lines marked the buffer modified, and a modified buffer cannot
  -- be abandoned without `!` or `'hidden'`. Nothing in this buffer is ever
  -- something the user could save, so the flag is cleared rather than left to
  -- turn every swap back to S into an E37.
  vim.bo[buf].modified = false
end

--- Replace an animated image's rows with frame `index` (0-based).
---
--- Only `start .. start + rows - 1` is written, and only those rows' extmarks
--- are reset. Every other line and extmark is left exactly as it was, so the
--- cursor, the scroll position and the source mapping stay valid while frames
--- are swapped; the engine guarantees a frame occupies its first frame's rows,
--- so the buffer's line count does not change either.
---
--- A frame line is a span array rather than a wire line — it has no `source`
--- and no `spans` field, because every row belongs to the reference the
--- animation names — hence the wrapping below. Styles are shared with the
--- document, so a colour a later frame introduces is interned on first sight.
---
--- Returns false when `index` is not one of `animation`'s frames.
function M.frame(buf, doc, animation, index)
  local frame = animation and animation.frames and animation.frames[index + 1]
  if not frame or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local first, rows = animation.start, animation.rows
  local lines = {}
  for i = 1, rows do
    local parts = {}
    for _, span in ipairs(frame.lines[i] or {}) do
      parts[#parts + 1] = span[2]
    end
    lines[i] = table.concat(parts)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, first + rows, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, first, first + rows)
  for i = 1, math.min(rows, #frame.lines) do
    paint_line(buf, first + i - 1, { spans = frame.lines[i] }, doc.styles)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  return true
end

--- The source line `row` (0-based display row) came from, or nil if synthetic.
---
--- Table borders and diagram artwork are synthetic and carry no source line.
--- Rather than refuse to move, this walks outward to the nearest line that
--- does have one — a cursor on a table's border belongs to the table.
function M.source_line_for(doc, row)
  local lines = doc.lines
  if not lines or #lines == 0 then
    return nil
  end
  row = math.max(0, math.min(row, #lines - 1))
  local i = row + 1

  if lines[i].source ~= nil then
    return lines[i].source
  end

  -- Forward first: a border belongs to the construct it opens.
  for j = i + 1, #lines do
    if lines[j].source ~= nil then
      return lines[j].source
    end
  end
  for j = i - 1, 1, -1 do
    if lines[j].source ~= nil then
      return lines[j].source
    end
  end
  return nil
end

--- The display row showing source line `source` (0-based), or nil.
---
--- The engine emits this map rather than leaving it to be derived, so that
--- "first display line at or after source line N" has one implementation.
function M.row_for_source(doc, source)
  local map = doc.source_map
  if not map or #map == 0 then
    return nil
  end
  local entry = map[source + 1]
  if entry == nil then
    return nil
  end
  return entry
end

return M
