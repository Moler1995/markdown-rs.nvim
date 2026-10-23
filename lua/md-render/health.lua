-- `:checkhealth md-render`.
--
-- The split between `probe()` and `check()` is deliberate: the report is data,
-- so the headless suite can assert on it without parsing a health buffer, and
-- `check()` is only presentation. `probe()` runs the engine at most twice —
-- `--version` and one empty-document render to read the wire version — and
-- neither call touches a buffer, so a health check cannot change what the user
-- is looking at.

local M = {}

local engine = require('md-render.engine')
local config = require('md-render.config')

--- How long either engine call may take, in milliseconds.
---
--- Long enough for a cold start on a slow disk, short enough that a hung
--- binary does not hang `:checkhealth`.
local TIMEOUT_MS = 5000

--- Neovim's version as `major.minor.patch`.
local function nvim_version()
  local v = vim.version()
  return string.format('%d.%d.%d', v.major, v.minor, v.patch)
end

--- Run `exe` and return its trimmed stdout, or nil and a one-line reason.
local function run(exe, args, stdin)
  local cmd = { exe }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, stdin = stdin, timeout = TIMEOUT_MS })
      :wait(TIMEOUT_MS + 1000)
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    local err = (res.stderr or ''):gsub('%s+$', '')
    local why = res.code == 124 and 'timed out' or ('exited ' .. tostring(res.code))
    if err ~= '' then
      why = why .. ': ' .. err
    end
    return nil, why
  end
  return ((res.stdout or ''):gsub('%s+$', ''))
end

--- Append one check and fold its failure into `report.ok`.
---
--- A `warn` is shown but does not fail the report: images degrade, the plugin
--- still works, and `:checkhealth` is run in places — CI among them — where a
--- terminal with truecolor is not present.
local function add(report, name, ok, detail, remediation, severity)
  report.checks[#report.checks + 1] = {
    name = name,
    ok = ok,
    detail = detail,
    remediation = remediation,
    severity = severity or 'error',
  }
  if not ok and severity ~= 'warn' then
    report.ok = false
  end
end

--- Gather everything `:checkhealth md-render` reports, without rendering.
function M.probe()
  local report = {
    ok = true,
    checks = {},
    termguicolors = vim.o.termguicolors,
    image_encoding = config.image_encoding(),
    filetypes = vim.deepcopy(config.options.filetypes),
    engine = nil,
    step = nil,
    version = nil,
    wire = nil,
  }

  local supported = vim.fn.has('nvim-0.10') == 1
  add(report, 'Neovim', supported,
    nvim_version() .. (supported and ' (0.10 or newer)' or ' (0.10 or newer is required)'),
    'Upgrade Neovim to 0.10 or newer.')

  local exe, step = engine.resolve(config.options.engine)
  if not exe then
    add(report, 'engine', false, step, table.concat({
      'Build it from a checkout with `cargo build --release -p md-render` and',
      "copy the binary to the plugin's bin/ directory, or download a release and",
      'put the binary in ' .. vim.fn.stdpath('data') .. '/md-render.',
    }, '\n'))
  else
    report.engine, report.step = exe, step
    add(report, 'engine', true, exe .. ' (found on ' .. step .. ')')
  end

  if exe then
    local version, err = run(exe, { '--version' })
    if version then
      report.version = version
      add(report, '--version', true, version)
    else
      add(report, '--version', false, err,
        'Run `' .. exe .. ' --version` by hand to see the full error.')
    end

    -- A minimal render: enough for the engine to print a document and say
    -- which wire format it speaks, and nothing that depends on the user's
    -- buffers, width or cursor.
    local out, render_err = run(exe, { '--width', '80' }, '')
    local doc = nil
    if out then
      local ok, decoded = pcall(vim.json.decode, out)
      if ok then
        doc = decoded
      else
        render_err = 'produced output that is not JSON: ' .. tostring(decoded)
      end
    end
    if not doc then
      add(report, 'wire format', false, render_err,
        'The engine resolves but cannot produce a document; rebuild or replace it.')
    else
      report.wire = doc.version
      local speaks = doc.version == nil and 'no wire version' or tostring(doc.version)
      add(report, 'wire format', doc.version == engine.WIRE_VERSION,
        string.format('engine speaks %s; plugin expects %d', speaks, engine.WIRE_VERSION),
        'Rebuild the engine from this checkout '
          .. '(`cargo build --release -p md-render`), or upgrade the plugin and '
          .. 'the engine together.')
    end
  end

  add(report, "'termguicolors'", vim.o.termguicolors,
    vim.o.termguicolors and 'enabled: images use the braille encoding'
      or 'disabled: images fall back to the ASCII encoding',
    'Add `vim.o.termguicolors = true` to your config for braille image artwork.',
    'warn')

  local filetypes = #report.filetypes > 0 and table.concat(report.filetypes, ', ')
    or 'none: the plugin attaches to no filetype'
  add(report, 'filetypes', true, filetypes .. ' (image encoding: ' .. report.image_encoding .. ')')

  return report
end

--- Render `probe()` through `vim.health`.
function M.check()
  local report = M.probe()
  vim.health.start('md-render: engine and configuration')
  for _, item in ipairs(report.checks) do
    local line = item.name .. ': ' .. item.detail
    if item.ok then
      vim.health.ok(line)
    elseif item.severity == 'warn' then
      vim.health.warn(line)
    else
      vim.health.error(line)
    end
    if not item.ok and item.remediation then
      vim.health.info(item.remediation)
    end
  end
end

return M
