local M = {}

--- @class arcanist.PasteConfig
--- @field upload boolean Auto-upload files pasted into remarkup buffers.
--- @field placeholder string Text shown at the cursor while a pasted file
--- is uploading; `%s` is replaced with the file's basename.

--- @class arcanist.CompletionConfig
--- @field mention_kind string `vim.lsp.protocol.CompletionItemKind` name
--- used for @mention completion items.
--- @field project_kind string `vim.lsp.protocol.CompletionItemKind` name
--- used for #project completion items.

--- @class arcanist.DetectConfig
--- @field identity boolean Read a file no filename rule matched as Remarkup
--- when its last line names a Phorge object.

--- @class arcanist.Config
--- @field paste arcanist.PasteConfig
--- @field completion arcanist.CompletionConfig
--- @field detect arcanist.DetectConfig
--- @field conduit_timeout integer Milliseconds to wait on a blocking
--- Conduit call (i.e. `:w` on an "arcanist://" buffer) before giving up.

--- @type arcanist.Config
local default_config = {
    paste = {
        upload = true,
        placeholder = '{Uploading %s...}',
    },
    completion = {
        mention_kind = 'Reference',
        project_kind = 'Module',
    },
    detect = {
        identity = true,
    },
    conduit_timeout = 10000,
}

M.config = default_config

--- Configure arcanist.nvim. Optional -- every field has a default, so
--- plugins/buffers work without calling this at all.
--- @param opts arcanist.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', default_config, opts or {})
end

--- Pick a Phorge task or revision and open it as an "arcanist://" buffer;
--- see arcanist.list for the options. Re-exported so a keymap needn't name
--- a submodule, and required lazily -- every remarkup buffer pulls this
--- module in for `config`, and most sessions never list.
--- @param opts arcanist.ListOpts?
function M.list(opts)
    require('arcanist.list').list(opts)
end

return M
