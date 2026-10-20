-- Configuration for md-render.nvim.
--
-- One table of defaults, one `setup` that deep-merges over them. Nothing here
-- reaches the engine directly; this module only says what the user wants, and
-- the modules that act on it read from here.

local M = {}

M.defaults = {
  -- Path to the engine binary. `nil` means "resolve it": `md-render` on PATH
  -- first, then `<repo>/bin/md-render.exe`. See `engine.resolve`.
  engine = nil,

  -- Theme handed to the engine with `--theme`. The default matches the
  -- colorscheme the editor is configured with, so the rendered view is not a
  -- different palette from the window around it.
  theme = 'catppuccin_mocha',

  -- Filetypes whose buffers open in R. A buffer not listed here is left alone
  -- entirely — no state, no autocmds, no keymaps.
  filetypes = { 'markdown' },

  -- Buffer-local keymaps set in R. Set a value to `false` to leave the key
  -- alone. `toggle` swaps between R and S; `preview` opens the block popup and
  -- belongs to R only, since in S the cursor is already on the block's source.
  -- The insert-entry keys are fixed and are not configurable, because they are
  -- the mode's escape hatch rather than a convenience.
  --
  -- `follow` is the one key set in both states, because a link is followed from
  -- wherever the reader happens to be: in S it resolves the link under the
  -- cursor, and in R it maps the display row back to its source line first and
  -- resolves the link there. It shadows `gf` in a managed buffer, and hands the
  -- key back to Vim when the cursor is not on a link, so a bare path still
  -- opens the way it always did.
  keymaps = {
    toggle = '<leader>mr',
    write = '<C-s>',
    preview = '<CR>',
    follow = 'gf',
  },

  -- The preview popup's caps, as fractions of the editor's size. The popup is
  -- sized to fit the block and only then clamped, so a small diagram gets a
  -- small popup rather than a large empty frame.
  preview = {
    max_width_pct = 0.9,
    max_height_pct = 0.9,
  },

  -- Milliseconds to coalesce the events that make R stale — `WinResized` and
  -- `TextChanged`. A drag-resize fires the first per column and typing fires
  -- the second per keystroke; without coalescing, each one would spawn an
  -- engine. Only refreshes are coalesced: a toggle is applied at once, so this
  -- cannot delay or swallow one.
  resize_debounce = 100,
}

M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults and return the result.
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

--- True when `ft` is one the plugin manages.
function M.manages(ft)
  return vim.tbl_contains(M.options.filetypes, ft)
end

return M
