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
--- @field gitcommit boolean Read a 'gitcommit' buffer as Remarkup instead,
--- in a working copy with an ".arcconfig" -- git's own
--- commit-message-editing files all get that filetype, and so does
--- anything else set that way.

--- @class arcanist.DraftsConfig
--- @field enabled boolean Hand an opened object's buffer to a local file:
--- `:w` is a plain local write, `:ArcWrite` pushes to Phorge, and the draft
--- survives across sessions.
--- @field dir string Directory the draft files live in.

--- @class arcanist.FileInfo
--- @field monogram string The file's monogram, e.g. "F123".
--- @field name string Filename as stored on Phorge.
--- @field bytes integer? Byte size from `file.search` (nil on a cache hit).
--- @field alt string? Phorge's own display text for this file, e.g.
--- "duck.png (320×200 px, 1 KB)" -- `fields.alt.default` from `file.search`.
--- Also nil on a cache hit.

--- @class arcanist.InlineSpec
--- @field buf integer Target buffer.
--- @field range integer[] { start_row, start_col, end_row, end_col }, 0-indexed, of the monogram node.
--- @field path string Local cache path of the downloaded file.
--- @field info arcanist.FileInfo
--- @field options table<string, string|boolean> This reference's parsed
--- "{F123, key=value, ...}" embed options (lowercased keys; a bare "key" with
--- no "=" reads as true). Empty for a bare "F123" reference or a braced embed
--- with none.

--- @class arcanist.InlineHandle
--- @field close fun() Tear this placement down.

--- @class arcanist.InlineConfig
--- @field text boolean Conceal each referenced monogram and show Phorge's
--- own description of the file (`fields.alt.default`, e.g. "duck.png
--- (320×200 px, 1 KB)") in its place -- the same way a `code span` conceals
--- its backticks in a `:h` file; the raw monogram reappears while the
--- cursor is on that exact reference. Never downloads the file -- only one
--- lightweight Conduit call per new reference -- so it is unaffected by
--- `file.max_bytes`, needs no external plugin or graphics-capable
--- terminal, and stays live as you type (`TextChanged`/`TextChangedI`)
--- rather than waiting for `:w`. Default false.
--- @field render (fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?)|"snacks"|nil
--- Downloads the file and draws it on the line below the reference. nil
--- (default): off. "snacks": renders through snacks.image, which decides
--- per file what it can draw (images, a video or PDF still frame);
--- anything else stays as the bare monogram. A function: called once per
--- referenced file after it downloads, with `spec.path` a real cache path;
--- return nil to leave that monogram as-is (a file type you don't handle,
--- say). A download is not something to redo on every keystroke, so
--- unlike `text` this only (re)runs on buffer open, `:w`, and explicit
--- enable/disable/toggle.
---
--- `text` and `render` are independent -- both can be on for the same
--- monogram at once (the description replaces the reference, and the
--- image still draws below it), or just one, or neither.
--- @field thumb_width integer? Pixel width the "snacks" preset boxes an
--- inline preview into when its embed has no "size"/"width"/"height" option,
--- or an unrecognized/"thumb" "size" -- mirrors Phorge's own default file
--- preview transform, which is 220px wide. nil: no width cap in that case.
--- Default 220.
--- @field thumb_height integer? The same, for height. Default nil (uncapped
--- -- aspect ratio follows from the width cap and the window).

--- @class arcanist.FileConfig
--- @field open (fun(path: string, info: arcanist.FileInfo))|"snacks"|nil
--- Called in place of `vim.ui.open` when `:ArcFile` displays a downloaded
--- file. A function routes it through your own viewer; "snacks" is a bundled
--- preset that renders through snacks.image. Default nil (`vim.ui.open`).
--- @field max_bytes integer Refuse to download a file larger than this
--- unless ":ArcFile!" is used.
--- @field inline arcanist.InlineConfig The inline-preview state each
--- Remarkup buffer opens with (see |arcanist-inline-preview|), and how file
--- monograms render -- see `arcanist.InlineConfig`'s own fields. Both
--- `text` and `render` off is "off" for the buffer-level state too, but
--- `require('arcanist.inline').enable()` can still turn a buffer on (it
--- then follows whatever `text`/`render` are set to, however sparse).

--- @class arcanist.Config
--- @field paste arcanist.PasteConfig
--- @field completion arcanist.CompletionConfig
--- @field detect arcanist.DetectConfig
--- @field drafts arcanist.DraftsConfig
--- @field file arcanist.FileConfig
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
        gitcommit = false,
    },
    drafts = {
        enabled = false,
        dir = vim.fn.stdpath('data') .. '/arcanist',
    },
    file = {
        open = nil,
        max_bytes = 25 * 1024 * 1024,
        inline = {
            text = false,
            render = nil,
            thumb_width = 220,
            thumb_height = nil,
        },
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
