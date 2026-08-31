-- Register the "arcanist://" buffer scheme at startup.
--
-- Without this, the scheme's BufReadCmd is only installed once a remarkup
-- buffer has been opened (via after/ftplugin/remarkup.lua), so `:e
-- arcanist://T123` typed into a fresh session would try to open a literal
-- file by that name and fail. Registering an autocmd is cheap enough to do
-- unconditionally; nothing here talks to Phorge until a buffer is actually
-- opened.

if vim.g.loaded_arcanist then
    return
end
vim.g.loaded_arcanist = true

require('arcanist.reference').setup()

-- Register ":ArcLint" at startup too. It has nothing to do with remarkup
-- buffers, so registering it from after/ftplugin would leave it undefined
-- in exactly the session you'd want it: a normal source file in a working
-- copy.
require('arcanist.command').setup()

require('arcanist.icon').setup()
