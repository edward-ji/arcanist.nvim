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

--- @class arcanist.DraftsConfig
--- @field enabled boolean Hand an opened object's buffer to a local file:
--- `:w` is a plain local write, `:ArcWrite` pushes to Phorge, and the draft
--- survives across sessions.
--- @field dir string Directory the draft files live in.

--- @class arcanist.PreviewInfo
--- @field monogram string The file's monogram, e.g. "F123".
--- @field name string Filename as stored on Phorge.
--- @field bytes integer? Byte size from `file.search` (nil on a cache hit).

--- @class arcanist.InlineSpec
--- @field buf integer Target buffer.
--- @field range integer[] { start_row, start_col, end_row, end_col }, 0-indexed, of the monogram node.
--- @field path string Local cache path of the downloaded file.
--- @field info arcanist.PreviewInfo

--- @class arcanist.InlineHandle
--- @field close fun() Tear this placement down.

--- @class arcanist.PreviewConfig
--- @field open (fun(path: string, info: arcanist.PreviewInfo))|"snacks"|nil
--- Called in place of `vim.ui.open` when `:ArcFile` displays a downloaded
--- file. A function routes it through your own viewer; "snacks" is a bundled
--- preset that renders through snacks.image. Default nil (`vim.ui.open`).
--- @field max_bytes integer Refuse to download a file larger than this
--- unless ":ArcFile!" is used.
--- @field inline (fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?)|"snacks"|nil
--- The inline-preview state each Remarkup buffer opens with, and how file
--- monograms render below their reference. nil (default): off -- but
--- `require('arcanist.inline').enable()` can still turn a buffer on,
--- rendering through snacks.image. "snacks": on, via snacks.image (which
--- decides what it can draw). A function: on, called once per referenced
--- file after it downloads; return nil to leave that monogram as text.

--- @class arcanist.Config
--- @field paste arcanist.PasteConfig
--- @field completion arcanist.CompletionConfig
--- @field detect arcanist.DetectConfig
--- @field drafts arcanist.DraftsConfig
--- @field preview arcanist.PreviewConfig
--- @field conduit_timeout integer Milliseconds to wait on a blocking
--- Conduit call (i.e. `:w` on an "arcanist://" buffer, or `:ArcWrite`) before
--- giving up.

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
    drafts = {
        enabled = false,
        dir = vim.fn.stdpath('data') .. '/arcanist',
    },
    preview = {
        open = nil,
        max_bytes = 25 * 1024 * 1024,
        inline = nil,
    },
    conduit_timeout = 10000,
}

M.config = default_config

--- Configure arcanist.nvim. Optional -- every field has a default, so
--- plugins/buffers work without calling this at all.
--- @param opts arcanist.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', default_config, opts or {})
    if M.config.drafts.enabled then
        require('arcanist.draft').register_filetype()
    end
end

--- Pick a Phorge task or revision and open it as an "arcanist://" buffer;
--- see arcanist.list for the options. Re-exported so a keymap needn't name
--- a submodule, and required lazily -- every remarkup buffer pulls this
--- module in for `config`, and most sessions never list.
--- @param opts arcanist.ListOpts?
function M.list(opts)
    require('arcanist.list').list(opts)
end

--- Download a Phorge file object ("F123", or the monogram under the cursor
--- via `:ArcFile`) and open it; see arcanist.file. Re-exported and required
--- lazily, like `list`.
--- @param monogram string
--- @param opts? { force: boolean }
function M.preview(monogram, opts)
    require('arcanist.file').preview(monogram, opts)
end

return M
