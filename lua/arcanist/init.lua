local M = {}

--- @class arcanist.Config

--- @type arcanist.Config
local default_config = {}

M.config = default_config

--- Configure arcanist.nvim.
---
--- Currently a no-op placeholder: Remarkup syntax highlighting (ftdetect/,
--- queries/, parser/) works automatically once this plugin is on
--- 'runtimepath' and its parser has been built (`make`) -- calling setup()
--- isn't required for that. This is the conventional entry point for the
--- options future Phorge/Phabricator integration (browsing revisions,
--- posting comments, etc.) will need.
--- @param opts arcanist.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', default_config, opts or {})
end

return M
