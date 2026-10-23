-- Finding what the link under the cursor points at.
--
-- This is deliberately not a markdown parser. It answers one question — "what
-- does the thing under the cursor point at?" — for the link forms a reader
-- actually puts a cursor on, and returns nothing for everything else, so the
-- caller can hand the key back to Vim and let its own `gf` have a bare path.
--
-- It reads the *source* lines, never the rendered ones. The rendered text is a
-- layout of the source rather than a copy of it, and the engine drops link
-- targets entirely, so the target is only ever in the source. In R the caller
-- maps the display row back to a source line first, which is the same step the
-- toggle makes.

local M = {}

--- True when `path` is absolute in either the POSIX or the Windows sense.
---
--- A leading separator covers `/x` and `\x`, and therefore a UNC share
--- written as `\\server\share`; the drive form covers `C:/x` and `C:\x`.
--- A relative destination — `docs/x.md`, `./x`, `../x` — is not absolute and
--- is resolved against the document's directory by the caller.
function M.is_absolute(path)
  return path:match('^[/\\]') ~= nil or path:match('^%a:[/\\]') ~= nil
end

--- The index of the character closing the group opened at `open`, or nil.
---
--- `opener` and `closer` are single characters, and nesting is counted, so
--- `[a [b] c]` closes at its last bracket rather than its first. A backslash
--- escapes the character after it.
local function matching(line, open, opener, closer)
  local depth = 0
  local i = open
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2
    else
      if c == opener then
        depth = depth + 1
      elseif c == closer then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
      i = i + 1
    end
  end
  return nil
end

--- The index just past the code span starting at `i`, or nil if `i` is not one.
---
--- A link inside backticks is text about a link, not a link, so the scan has to
--- step over the span rather than look inside it.
local function skip_code_span(line, i)
  local ticks = line:match('^`+', i)
  if not ticks then
    return nil
  end
  local close = line:find(ticks, i + #ticks, true)
  return close and (close + #ticks) or (#line + 1)
end

--- A link destination as written, with the decoration taken off.
---
--- `(./a.md "Title")` is `./a.md`, and `(<./a b.md>)` is `./a b.md` — the angle
--- brackets are how a destination containing a space is written.
local function clean_target(inner)
  inner = vim.trim(inner)
  if inner:sub(1, 1) == '<' then
    local close = inner:find('>', 2, true)
    if close then
      return inner:sub(2, close - 1)
    end
  end
  -- A title is separated from the destination by whitespace.
  local cut = inner:find('%s["\'(]')
  if cut then
    inner = inner:sub(1, cut - 1)
  end
  return vim.trim(inner)
end

--- `[label]: target` definitions anywhere in the buffer, keyed by lowercased
--- label.
---
--- Keyed lowercased because a reference label is case-insensitive, and taken
--- from the whole buffer rather than the line because that is where a
--- definition is allowed to be.
local function definitions(lines)
  local refs = {}
  for _, line in ipairs(lines) do
    local label, target = line:match('^%s*%[([^%]]+)%]:%s*(.+)$')
    if label then
      refs[label:lower()] = clean_target(target)
    end
  end
  return refs
end

--- Parse a link or image starting at `i`, or nil when there is not one there.
local function parse_at(line, i, refs)
  local start = i
  local image = line:sub(i, i) == '!' and line:sub(i + 1, i + 1) == '['
  if image then
    i = i + 1
  elseif line:sub(i, i) ~= '[' then
    return nil
  end

  local close = matching(line, i, '[', ']')
  if not close then
    return nil
  end
  -- The text between the brackets is what the renderer puts on the line, so it
  -- is also what maps a link back to its source construct from the rendered
  -- view. Kept as written: inline markup inside a label is the caller's
  -- problem, and the mapping treats a label it cannot find as no match.
  local text = line:sub(i + 1, close - 1)

  local after = line:sub(close + 1, close + 1)
  if after == '(' then
    local endp = matching(line, close + 1, '(', ')')
    if not endp then
      return nil
    end
    return {
      from = start,
      to = endp,
      raw = clean_target(line:sub(close + 2, endp - 1)),
      image = image,
      text = text,
    }
  end

  if after == '[' then
    local endb = matching(line, close + 1, '[', ']')
    if not endb then
      return nil
    end
    local ref = line:sub(close + 2, endb - 1)
    if ref == '' then
      -- `[text][]` refers to itself.
      ref = text
    end
    local raw = refs[ref:lower()]
    return raw and { from = start, to = endb, raw = raw, image = image, text = text } or nil
  end

  -- A shortcut reference: `[text]` with the definition elsewhere.
  local raw = refs[text:lower()]
  return raw and { from = start, to = close, raw = raw, image = image, text = text } or nil
end

--- A URL written as itself rather than as a link's destination.
local AUTOLINKS = {
  { pat = '<(%a[%w+.-]*://[^%s>]*)>', bracketed = true },
  { pat = '<(mailto:[^%s>]*)>', bracketed = true },
  { pat = '(%a[%w+.-]*://[^%s<>%(%)%[%]]+)', bracketed = false },
}

local function autolinks(line)
  local raw = {}
  for _, a in ipairs(AUTOLINKS) do
    local init = 1
    while true do
      local s, e, target = line:find(a.pat, init)
      if not s then
        break
      end
      if not a.bracketed then
        -- A sentence's full stop is not part of the URL.
        local trimmed = target:gsub('[%.,;:!?]+$', '')
        e = e - (#target - #trimmed)
        target = trimmed
      end
      if target ~= '' then
        raw[#raw + 1] = { from = s, to = e, raw = target, text = target }
      end
      init = e + 1
    end
  end

  -- `<https://…>` matches twice — once with its brackets, once by the bare-URL
  -- pattern looking inside them. Only the outer one is the link, so a match
  -- contained in another is dropped rather than reported as a second link.
  local out = {}
  for i, candidate in ipairs(raw) do
    local contained = false
    for j, other in ipairs(raw) do
      if i ~= j and candidate.from >= other.from and candidate.to <= other.to then
        contained = true
        break
      end
    end
    if not contained then
      out[#out + 1] = candidate
    end
  end
  return out
end

--- Split a destination into a path, a fragment, and which of the three kinds
--- of thing it names.
local function finish(parsed)
  local raw = parsed.raw
  local target, fragment = raw, nil
  local hash = raw:find('#', 1, true)
  if hash then
    target = raw:sub(1, hash - 1)
    fragment = raw:sub(hash + 1)
    if fragment == '' then
      fragment = nil
    end
  end

  local kind = 'file'
  if raw:match('^%a[%w+.-]*://') or raw:match('^mailto:') then
    kind = 'url'
  elseif target == '' then
    kind = 'anchor'
  end

  return {
    from = parsed.from,
    to = parsed.to,
    raw = raw,
    text = parsed.text,
    target = target,
    fragment = fragment,
    kind = kind,
    image = parsed.image,
  }
end

--- Every link on line `lnum` (0-based), as `{ from, to, raw, text, target,
--- fragment, kind }` with `from` and `to` 1-based byte columns, `to`
--- exclusive, and `text` the label as written between the brackets.
---
--- A destination is looked for first, and a bare URL only when the line holds
--- no link at all: the URL inside `[text](https://…)` is that link's
--- destination, not a second thing to follow.
function M.links(lines, lnum)
  local line = lines[lnum + 1]
  if not line or line == '' then
    return {}
  end

  local refs = definitions(lines)
  local found = {}
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2
    elseif c == '`' then
      i = skip_code_span(line, i)
    elseif c == '[' or (c == '!' and line:sub(i + 1, i + 1) == '[') then
      local parsed = parse_at(line, i, refs)
      if parsed then
        found[#found + 1] = finish(parsed)
        i = parsed.to + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  if #found == 0 then
    for _, parsed in ipairs(autolinks(line)) do
      found[#found + 1] = finish(parsed)
    end
  end

  return found
end

--- The link covering byte column `col` (0-based) on line `lnum`, or nil.
---
--- This is the source view's resolution: the cursor's column is a byte column
--- in the same line the links were parsed from, so it decides directly. `col`
--- may be nil, which means "any link on this line" and yields the first; the
--- rendered view does not use that any more, since `M.source_line_at` resolves
--- its columns against a layout (see below).
function M.at(lines, lnum, col)
  local found = M.links(lines, lnum)
  if col == nil then
    return found[1]
  end
  for _, l in ipairs(found) do
    if col >= l.from - 1 and col < l.to then
      return l
    end
  end
  return nil
end

--- The text of one display line, its spans concatenated.
local function display_text(line)
  local parts = {}
  for _, span in ipairs(line.spans or {}) do
    parts[#parts + 1] = span[2]
  end
  return table.concat(parts)
end

--- The link on display row `row` (0-based) under byte column `col`, resolved
--- by matching the source line's link labels against the rendered text.
---
--- The rendered view is a layout of the source, so a display column has no byte
--- column in the source to compare against — but a link's *label* survives the
--- layout: `[快速上手](#使用-deepseek-recipe) · [流式响应](docs/streaming.zh.md)`
--- is drawn as `快速上手 · 流式响应`, one label after the other. Matching the
--- labels, in order, against the rows this source line produced is what tells
--- two links on one line apart without the engine having to report them.
---
--- The rows are joined before searching, because a label can wrap across two
--- of them; the cursor's offset is counted in the same joined text. A label
--- whose rendered form differs from its source (inline markup inside the
--- brackets, an image drawn as artwork) is simply not found, and a cursor that
--- is in no found label falls back to the first link — the behaviour of a line
--- with one link, which is what such a line usually is.
function M.source_line_at(doc, row, col, lines, lnum)
  local found = M.links(lines, lnum)
  if #found <= 1 then
    return found[1]
  end

  local chunks, starts, offset = {}, {}, 0
  for i, line in ipairs(doc.lines) do
    if line.source == lnum then
      local text = display_text(line)
      starts[i - 1] = offset
      chunks[#chunks + 1] = text
      offset = offset + #text
    end
  end
  if starts[row] == nil then
    return found[1]
  end

  local text = table.concat(chunks)
  local at = starts[row] + col
  local init = 1
  for _, link in ipairs(found) do
    if link.text and link.text ~= '' then
      local from, to = text:find(link.text, init, true)
      if from then
        if at >= from - 1 and at < to then
          return link
        end
        init = to + 1
      end
    end
  end
  return found[1]
end

--- The engine-reported link covering byte column `col` (0-based) on display
--- row `row` (0-based), or nil.
---
--- These are the links that are not in the source text: a mermaid `click`
--- directive names a URL, and the engine reports the label cells it covers as
--- byte ranges on the rendered line. Reading them from the document rather
--- than re-parsing the fence is what keeps "what is clickable" in one place.
---
--- The ranges are byte offsets into the line's text, which is exactly what a
--- cursor column is, so no display-column arithmetic is involved.
function M.rendered_at(doc, row, col)
  local line = doc and doc.lines and doc.lines[row + 1]
  local links = line and line.links
  if not links then
    return nil
  end
  for _, link in ipairs(links) do
    local from, to, raw = link[1], link[2], link[3]
    if col >= from and col < to then
      return finish({ raw = raw })
    end
  end
  return nil
end

--- Every image reference on line `lnum` (0-based), in left-to-right order.
---
--- An image is a link whose text was introduced by `!`; the rest of the entry
--- is the same shape `M.links` returns, `image = true` being what tells them
--- apart.
function M.images(lines, lnum)
  local out = {}
  for _, l in ipairs(M.links(lines, lnum)) do
    if l.image then
      out[#out + 1] = l
    end
  end
  return out
end

--- The image reference on the display line `row` (0-based) of rendered `doc`.
---
--- Every display line of an image's artwork carries the reference's source line,
--- and so does the line showing its alt text when the engine cannot draw it.
--- That is the whole lookup: no column arithmetic, because a display column has
--- no byte column in the source. A line with no source of its own — a table
--- border, a diagram's rows — has no image either, and so the helper returns nil
--- rather than guessing at a neighbour's.
---
--- The first image on the line wins when it holds more than one, which is the
--- same rule `M.at` follows from R.
function M.image_at_row(lines, doc, row)
  local line = doc and doc.lines and doc.lines[row + 1]
  local lnum = line and line.source
  if lnum == nil then
    return nil
  end
  return M.images(lines, lnum)[1]
end

--- The GitHub-style anchor a heading line produces.
---
--- `%p` is ASCII punctuation in Lua's default locale, so a CJK heading keeps
--- its characters rather than slugging to nothing. A hyphen and an underscore
--- are punctuation too, but GitHub keeps both in the anchor it generates, so
--- `## 使用 deepseek-recipe` is reachable as `#使用-deepseek-recipe` and
--- dropping the inner hyphen would make that link resolve to nothing.
function M.slug(text)
  text = text:lower():gsub('%p', function(c)
    if c == '-' or c == '_' then
      return c
    end
    return ''
  end)
  text = vim.trim(text)
  return (text:gsub('%s+', '-'))
end

--- The 0-based line of the heading whose anchor is `fragment`, or nil.
---
--- Fences are skipped, because a `#` inside one is a comment in whatever
--- language the fence holds rather than a heading.
function M.anchor_line(lines, fragment)
  local want = fragment:lower()
  local in_fence = false
  for i, line in ipairs(lines) do
    if line:match('^%s*```') or line:match('^%s*~~~') then
      in_fence = not in_fence
    elseif not in_fence then
      local _, text = line:match('^(#+)%s+(.*)$')
      if text and M.slug(text) == want then
        return i - 1
      end
    end
  end
  return nil
end

return M
