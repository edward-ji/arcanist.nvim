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
