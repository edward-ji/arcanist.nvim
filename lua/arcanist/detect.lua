-- Recognises a Remarkup file by what is in it, for buffers no filename rule
-- claimed. Registered by ftdetect/remarkup.lua, which explains where in
-- Neovim's filetype detection this gets its turn.
--
-- Naming a file by its content is guesswork, so the rule it applies is one
-- the user can switch off (see `detect` in arcanist.Config).
--
-- Both requires below sit inside the function rather than at the top of the
-- file, where the rest of the plugin puts them: this module is reached for
-- every otherwise-unrecognised buffer, and arcanist.reference pulls in
-- Conduit behind it.

local M = {}

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

return M
