local M = {}

--- @class arcanist.PasteConfig
--- @field upload boolean Auto-upload files pasted into remarkup buffers.
--- @field placeholder string Text shown at the cursor while a pasted file
--- is uploading; `%s` is replaced with the file's basename.

--- @class arcanist.Config
--- @field paste arcanist.PasteConfig
--- @field conduit_timeout integer Milliseconds to wait on a blocking
--- Conduit call (i.e. `:w` on an "arcanist://" buffer) before giving up.
--- @field check_staleness boolean Re-fetch before writing an "arcanist://"
--- buffer and refuse the write if the object changed on the server since
--- it was loaded. Costs one extra round-trip per `:w`; set false to trade
--- that safety for speed.

--- @type arcanist.Config
local default_config = {
    paste = {
        upload = true,
        placeholder = '{Uploading %s...}',
    },
    conduit_timeout = 10000,
    check_staleness = true,
}

M.config = default_config

--- Configure arcanist.nvim. Optional -- every field has a default, so
--- plugins/buffers work without calling this at all.
--- @param opts arcanist.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', default_config, opts or {})
end

return M
