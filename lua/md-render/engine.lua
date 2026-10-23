-- Finding and running the `md-render` engine.
--
-- This is the whole of the plugin's knowledge about the engine: where the
-- binary is, how to invoke it, and what its output looks like at the top
-- level. Nothing here knows anything about markdown.

local M = {}

local unpack = table.unpack or unpack

--- The wire format this plugin understands.
---
--- The engine writes it into every document as `version`. A binary from a
--- different revision can still parse a markdown file, so without this check a
--- stale engine would render into a format the plugin reads wrongly rather than
--- fail loudly. Bump it in the engine's `wire.rs` when the shape changes, and
--- bump it here at the same time.
M.WIRE_VERSION = 1

--- The names the engine is installed under, in the order to try them.
---
--- Windows needs the `.exe`; POSIX does not. Trying the platform's name first
--- keeps the other name from winning on a file that happens to be executable
--- there too.
local function engine_names()
  if vim.fn.has('win32') == 1 then
    return { 'md-render.exe', 'md-render' }
  end
  return { 'md-render', 'md-render.exe' }
end

--- The directory the plugin's own files live in: `<repo>`, or a package's root.
local function plugin_root()
  local here = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(here, ':h:h:h')
end

--- The directory a downloaded engine goes in.
local function data_dir()
  return vim.fn.stdpath('data') .. '/md-render'
end

--- Resolve the engine binary.
--
--- Four steps, in order:
--
---   1. the configured `engine` path, used as given;
---   2. `md-render` on `PATH`;
---   3. `<plugin-root>/bin/md-render[.exe]`, a build copied next to the
---      checkout;
---   4. `<stdpath('data')>/md-render/md-render[.exe]`, where a downloaded
---      release goes.
--
--- The configured path is authoritative: when it is missing or not executable
--- the search stops there, because falling through would silently run a
--- different engine than the one the user named. The remaining steps are
--- automatic, and each candidate is checked with `vim.fn.executable` so a file
--- that exists but cannot run is skipped instead of failing later with EACCES.
---
--- Returns `path, step` on success, where `step` names the step that matched
--- (`'engine option'`, `'PATH'`, `'bin/'` or `'data directory'`). Returns
--- `nil, message` on failure, where the message names every location searched
--- and both ways of obtaining the engine.
function M.resolve(explicit)
  if explicit and explicit ~= '' then
    if vim.fn.executable(explicit) == 1 then
      return explicit, 'engine option'
    end
    return nil, table.concat({
      'the configured engine is not executable: ' .. explicit,
      'Set `engine` to an executable path, or set it to nil to search PATH,',
      "the plugin's bin/ directory and " .. data_dir() .. '.',
    }, '\n')
  end

  if vim.fn.executable('md-render') == 1 then
    return vim.fn.exepath('md-render'), 'PATH'
  end

  local dirs = {
    { plugin_root() .. '/bin', 'bin/' },
    { data_dir(), 'data directory' },
  }

  local searched = { '  PATH' }
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(engine_names()) do
      local candidate = dir[1] .. '/' .. name
      searched[#searched + 1] = '  ' .. candidate
      if vim.fn.executable(candidate) == 1 then
        return candidate, dir[2]
      end
    end
  end

  return nil, table.concat({
    'the md-render engine was not found. Searched:',
    unpack(searched),
    '',
    'Build it from a checkout with `cargo build --release -p md-render` and copy',
    'the binary to ' .. plugin_root() .. '/bin, or download a release and put the',
    'binary in ' .. data_dir() .. '.',
  }, '\n')
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
  local exe, step = M.resolve(opts.engine)
  if not exe then
    -- `step` is the failure message when resolution fails.
    cb(step)
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

        -- The document's shape is only safe to read when it is the shape this
        -- plugin was written for. A stale binary is the common cause, so the
        -- message names both versions and both remedies.
        if doc.version ~= M.WIRE_VERSION then
          local speaks = doc.version == nil and 'no wire version' or tostring(doc.version)
          cb(string.format(
            'the engine at %s speaks wire format %s, but this plugin expects %d. '
              .. 'Rebuild the engine from this checkout (`cargo build --release -p md-render`), '
              .. 'or upgrade the plugin and the engine together.',
            exe, speaks, M.WIRE_VERSION))
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
