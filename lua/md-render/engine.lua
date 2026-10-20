-- Finding and running the `md-render` engine.
--
-- This is the whole of the plugin's knowledge about the engine: where the
-- binary is, how to invoke it, and what its output looks like at the top
-- level. Nothing here knows anything about markdown.

local M = {}

local uv = vim.uv or vim.loop
local unpack = table.unpack or unpack

--- Resolve the engine binary.
--
--- An explicit path in the config wins. Otherwise `md-render` on PATH, and
--- failing that `<repo>/bin/md-render.exe` — a build copied into the repository
--- so that it works with no PATH edit. That binary is not committed, so a
--- fresh clone has to build it; see `docs/porting.md`.
---
--- Returns `nil` when neither exists; the caller reports that.
function M.resolve(explicit)
  if explicit and explicit ~= '' then
    return explicit
  end

  local on_path = vim.fn.exepath('md-render')
  if on_path ~= '' then
    return on_path
  end

  -- This file is <repo>/lua/md-render/engine.lua, so three `:h` steps reach
  -- the repository root.
  local here = debug.getinfo(1, 'S').source:sub(2)
  local repo = vim.fn.fnamemodify(here, ':h:h:h')
  for _, name in ipairs({ 'md-render.exe', 'md-render' }) do
    local candidate = repo .. '/bin/' .. name
    if uv.fs_stat(candidate) then
      return candidate
    end
  end

  return nil
end

--- Render `content` at `width`.
---
--- Calls `cb(err, doc)`. The callback runs on the main loop, so it is safe to
--- touch buffers from it. `err` is a human-readable string; there is no case
--- where both are set, and none where neither is.
function M.render(opts, content, width, cb)
  local exe = M.resolve(opts.engine)
  if not exe then
    cb('the md-render engine was not found: it is not on PATH and not in bin/')
    return
  end

  local args = { '--width', tostring(width) }
  if opts.theme and opts.theme ~= '' then
    args[#args + 1] = '--theme'
    args[#args + 1] = opts.theme
  end

  -- Guarded, because a process that cannot be started at all is an error from
  -- `uv.spawn` rather than a non-zero exit: `vim.system` *raises* for a binary
  -- that is not there, and an uncaught raise here would escape into whatever
  -- autocmd asked for the render. An engine path that is merely wrong is a
  -- configuration mistake, and the spec asks for it to be reported like any
  -- other failure.
  local ok, handle = pcall(vim.system, { exe, unpack(args) }, { stdin = content, text = true },
    function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          local stderr = vim.trim(res.stderr or '')
          cb(stderr ~= '' and stderr or ('the engine exited with status ' .. res.code))
          return
        end

        local decoded, doc = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true } })
        if not decoded then
          cb('the engine produced output that is not JSON: ' .. tostring(doc))
          return
        end
        if type(doc) ~= 'table' or type(doc.lines) ~= 'table' or type(doc.styles) ~= 'table' then
          cb('the engine produced a document with no lines or styles')
          return
        end

        cb(nil, doc)
      end)
    end)

  if not ok then
    -- The raise carries the position in `vim.system`'s own Lua source, which is
    -- not something to show anyone: `[string "?"]:324: ENOENT: ...`.
    cb('could not start the engine at ' .. exe .. ': '
      .. (tostring(handle):gsub('^%[string "[^"]*"%]:%d+: ', '')))
  end
end

return M
