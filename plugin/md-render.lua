-- Startup file: the part of the plugin that is active without any setup call.
--
-- The autocmds and the user commands live here so that dropping the repository
-- on `runtimepath` is enough for the plugin to work. A user who wants to change
-- the config calls `require('md-render').setup{...}`, which re-runs the same
-- setup idempotently rather than installing a second set of autocmds.

if vim.g.loaded_md_render then
  return
end
vim.g.loaded_md_render = true

-- A Neovim too old for any of this should say so once, at startup, rather than
-- fail somewhere deeper with a message about a missing field.
if vim.fn.has('nvim-0.10') ~= 1 then
  vim.notify('md-render.nvim needs Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

local md = require('md-render')

md.setup_autocmds()

vim.api.nvim_create_user_command('MdRenderToggle', function()
  md.toggle()
end, { desc = 'md-render: toggle between the rendered view and the source' })

vim.api.nvim_create_user_command('MdRenderShow', function()
  md.show_rendered()
end, { desc = 'md-render: show the rendered view' })

vim.api.nvim_create_user_command('MdRenderSource', function()
  md.show_source()
end, { desc = 'md-render: show the source' })

vim.api.nvim_create_user_command('MdRenderReset', function()
  local style = require('md-render.style')
  style.forget()
  local state = require('md-render.state')
  state.cache = {}
  for win in pairs(state.windows) do
    local st = state.get(win)
    st.doc = nil
    if st.source then
      md.show_rendered(win)
    end
  end
  vim.notify('md-render: caches cleared', vim.log.levels.INFO)
end, { desc = 'md-render: forget every cached render and highlight group' })
