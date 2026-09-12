-- Two Remarkup detection rules too situational for a plain `vim.filetype.add`
-- table entry, both switchable (see `detect` in arcanist.Config): guessing a
-- Remarkup file by what is in it, for buffers no filename rule claimed
-- (`match`, registered by ftdetect/remarkup.lua), and reclassifying a
-- 'gitcommit' buffer as Remarkup outright, however it ended up with that
-- filetype (`setup`, called from plugin/arcanist.lua).
--
-- The require in `match` sits inside the function rather than at the top of
-- the file, where the rest of the plugin puts them: it is reached for every
-- otherwise-unrecognised buffer, and arcanist.reference pulls in Conduit
-- behind it.

local M = {}

local installed = false

--- The filetype `bufnr`'s content suggests, if any.
---
--- The one thing looked for is the identity line: a document saved out of an
--- "arcanist://" buffer ends with "Maniphest Task: T123", the line naming the
--- object it is, and reading such a file back is that object's filetype
--- again. See arcanist.reference's filetype_of for what qualifies -- a
--- narrow rule, but still a guess, since any text ending that way is taken
--- for one.
--- @param bufnr integer
--- @return string?
function M.match(bufnr)
    if require('arcanist').config.detect.identity then
        return require('arcanist.reference').filetype_of(bufnr)
    end
    return nil
end

--- Turn a 'gitcommit' buffer into a Remarkup one when the `gitcommit`
--- option is on. A FileType autocmd rather than a filename table entry
--- like ftdetect/remarkup.lua's: git's own commit-message-editing files all
--- resolve to 'gitcommit' already, and so does anything else set that way,
--- so this reacts to the filetype itself. ".arcconfig" -- the same marker
--- arcanist.qf.root walks up for -- is what scopes it to a Phorge-backed
--- working copy.
---
--- Idempotent, and cheap to call unconditionally: nothing here runs until a
--- 'gitcommit' buffer actually shows up.
function M.setup()
    if installed then
        return
    end
    installed = true

    vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('arcanist.detect', { clear = true }),
        pattern = 'gitcommit',
        callback = function(args)
            local on = require('arcanist').config.detect.gitcommit
                and vim.fs.root(args.buf, '.arcconfig')
            if on then
                vim.bo[args.buf].filetype = 'remarkup'
            end
        end,
        desc = 'arcanist.nvim: read a git commit message as Remarkup',
    })
end

return M
