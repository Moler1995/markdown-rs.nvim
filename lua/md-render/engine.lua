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

--- Render `content` as `view` describes.
---
--- `view` is everything about where the document is going:
---
---   width     columns the text may occupy (required)
---   height    display rows the page has, or nil to bound images by width alone
---   encoding  the engine's `--image-encoding`: 'braille', 'quads', 'blocks',
---             'ascii' or 'off'
---   base      directory relative image destinations resolve against, or nil to
---             leave them to the engine's working directory
---   animation true to ask for an animated image's frames as well as its first
---             frame; omitted or false leaves the engine's animation field out
---   palette   the engine's `--image-palette`: 'theme', 'adaptive' or 'full'
---   background what transparency is composited against: 'terminal', 'theme'
---             or a '#rrggbb' colour
---   dither    'auto', true or false for `--image-dither`
---   min_rows  fewest display rows to enlarge an image to, or 0 for never
---   sharpen   true to sharpen an image that was reduced
---   paper     the '#rrggbb' braille inks against, when the caller knows it;
---             nil lets the engine derive it from `background`
---
--- Calls `cb(err, doc)`. The callback runs on the main loop, so it is safe to
--- touch buffers from it. `err` is a human-readable string; there is no case
--- where both are set, and none where neither is.
function M.render(opts, content, view, cb)
  local exe = M.resolve(opts.engine)
  if not exe then
    cb('the md-render engine was not found: it is not on PATH and not in bin/')
    return
  end

  local args = { '--width', tostring(view.width) }
  if opts.theme and opts.theme ~= '' then
    args[#args + 1] = '--theme'
    args[#args + 1] = opts.theme
  end
  -- Always sent, so the engine's own default never has to be guessed at here:
  -- the plugin is the one that knows whether this terminal can show the
  -- block encodings.
  if view.encoding and view.encoding ~= '' then
    args[#args + 1] = '--image-encoding'
    args[#args + 1] = view.encoding
  end
  if view.height then
    args[#args + 1] = '--image-max-height'
    args[#args + 1] = tostring(view.height)
  end
  -- Omitted for a buffer with no file: the engine's working directory is the
  -- only thing left to resolve against, and passing it explicitly would say
  -- the same thing with more ways to be wrong.
  if view.base and view.base ~= '' then
    args[#args + 1] = '--base'
    args[#args + 1] = view.base
  end
  -- Only asked for when the caller wants frames. The flag makes the engine
  -- decode every frame of every animated image, which is work and payload no
  -- ordinary render should pay for.
  if view.animation then
    args[#args + 1] = '--image-animation'
  end
  -- The image quality options. The plugin resolves `auto` before it gets here,
  -- so what is sent is always a concrete engine value; the engine's own
  -- defaults exist for callers that are not this plugin.
  if view.palette and view.palette ~= '' then
    args[#args + 1] = '--image-palette'
    args[#args + 1] = view.palette
  end
  if view.background and view.background ~= '' then
    args[#args + 1] = '--image-background'
    args[#args + 1] = view.background
  end
  -- The page braille inks against. Only sent when the plugin knows it, which
  -- is when transparency is the terminal's: a named background already is the
  -- page, and the engine derives the paper from it.
  if view.paper and view.paper ~= '' then
    args[#args + 1] = '--image-paper'
    args[#args + 1] = view.paper
  end
  if view.dither ~= nil then
    local dither = view.dither
    if dither == true then
      dither = 'on'
    elseif dither == false then
      dither = 'off'
    end
    args[#args + 1] = '--image-dither'
    args[#args + 1] = dither
  end
  if view.min_rows and view.min_rows > 0 then
    args[#args + 1] = '--image-min-rows'
    args[#args + 1] = tostring(view.min_rows)
  end
  if view.sharpen then
    args[#args + 1] = '--image-sharpen'
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
