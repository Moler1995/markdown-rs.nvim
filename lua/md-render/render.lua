-- Putting a rendered document into a buffer, and mapping between the two
-- coordinate systems afterwards.
--
-- The engine's output is already the layout: a list of lines, each with its
-- text and its styles, and each knowing the source line it came from. So
-- "rendering" here is a `nvim_buf_set_lines` and one extmark per span. There
-- is no conceal, no virtual text and no line-height arithmetic, because R is a
-- real buffer rather than a decorated view of S.

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

--- Replace `buf`'s contents with `doc` and style every span.
function M.apply(buf, doc)
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
    -- Extmark columns are byte offsets, so this walks bytes rather than
    -- columns. That is also why the engine's width guarantee matters here: a
    -- line that overflowed would soft-wrap and break the one-display-line-per-
    -- buffer-line correspondence the cursor mapping depends on.
    local col = 0
    for _, span in ipairs(line.spans) do
      local index, text = span[1], span[2]
      local len = #text
      if len > 0 then
        vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, col, {
          end_col = col + len,
          hl_group = style.group(doc.styles[index + 1], index),
        })
        col = col + len
      end
    end
  end

  vim.bo[buf].modifiable = false

  -- Writing the lines marked the buffer modified, and a modified buffer cannot
  -- be abandoned without `!` or `'hidden'`. Nothing in this buffer is ever
  -- something the user could save, so the flag is cleared rather than left to
  -- turn every swap back to S into an E37.
  vim.bo[buf].modified = false
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
