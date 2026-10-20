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
  if line:sub(i, i) == '!' and line:sub(i + 1, i + 1) == '[' then
    i = i + 1
  elseif line:sub(i, i) ~= '[' then
    return nil
  end

  local close = matching(line, i, '[', ']')
  if not close then
    return nil
  end

  local after = line:sub(close + 1, close + 1)
  if after == '(' then
    local endp = matching(line, close + 1, '(', ')')
    if not endp then
      return nil
    end
    return { from = start, to = endp, raw = clean_target(line:sub(close + 2, endp - 1)) }
  end

  if after == '[' then
    local endb = matching(line, close + 1, '[', ']')
    if not endb then
      return nil
    end
    local label = line:sub(close + 2, endb - 1)
    if label == '' then
      -- `[text][]` refers to itself.
      label = line:sub(i + 1, close - 1)
    end
    local raw = refs[label:lower()]
    return raw and { from = start, to = endb, raw = raw } or nil
  end

  -- A shortcut reference: `[text]` with the definition elsewhere.
  local raw = refs[line:sub(i + 1, close - 1):lower()]
  return raw and { from = start, to = close, raw = raw } or nil
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
        raw[#raw + 1] = { from = s, to = e, raw = target }
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
    target = target,
    fragment = fragment,
    kind = kind,
  }
end

--- Every link on line `lnum` (0-based), as `{ from, to, raw, target, fragment,
--- kind }` with `from` and `to` 1-based byte columns, `to` exclusive.
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
--- `col` may be nil, which means "any link on this line" and yields the first.
--- That is the R case: the rendered line is a layout of the source, so a
--- display column has no byte column in the source to be compared against.
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

--- The GitHub-style anchor a heading line produces.
---
--- `%p` is ASCII punctuation in Lua's default locale, so a CJK heading keeps
--- its characters rather than slugging to nothing.
function M.slug(text)
  text = text:lower():gsub('%p', '')
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
