-- Remarkup renders a single newline as a real line break, so Neovim must
-- never auto-insert one. Setting 'textwidth' to 0 is what does it: with
-- no wrap column, nothing reflows a line while typing, and the (now
-- meaningless) 'colorcolumn' ruler goes quiet. Dropping 't'/'a' from
-- 'formatoptions' is a backstop for when 'textwidth' is set elsewhere.
vim.opt_local.formatoptions:remove({ 'a', 't' })
vim.opt_local.textwidth = 0
vim.opt_local.wrapmargin = 0

-- Not comments -- Remarkup has none. 'comments' is the leader list that
-- `gq` and `J` preserve when reflowing by hand; keep only the Remarkup
-- markers, as the markdown ftplugin does: '*'/'-' bullets (trailing space
-- required, so '**bold**' and '---' are exempt) and '>' quotes.
vim.opt_local.comments = 'fb:*,fb:-,n:>'

-- Start treesitter highlighting for remarkup buffers.
-- pcall guards the case where the `remarkup` parser hasn't been built yet
-- (run `make` in the plugin directory), so opening a remarkup buffer
-- doesn't throw at every startup.
local ok, err = pcall(vim.treesitter.start)
if not ok then
    vim.notify(
        'arcanist.nvim: remarkup parser not built -- run `make` in the plugin directory ('
            .. tostring(err)
            .. ')',
        vim.log.levels.WARN
    )
end

-- Auto-upload files pasted into remarkup buffers.
if require('arcanist').config.paste.upload then
    require('arcanist.paste').setup()
end

-- Attach the "arcanist" LSP client (see lua/arcanist/lsp.lua for why), so
-- `gd` on a T123/D456/P789/... reference opens it in a scratch buffer.
require('arcanist.lsp').setup()
