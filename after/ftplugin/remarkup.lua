-- Unlike Markdown, Remarkup renders a single newline as a real line break
-- instead of folding it back into the paragraph. If 'formatoptions' still
-- has 't' (or 'a'), typing past 'textwidth' -- or any auto-formatter --
-- inserts hard newlines that silently change how the text renders. Turn
-- that off for remarkup buffers; manual `gq` reflow ('q') is left alone.
vim.opt_local.formatoptions:remove({ 'a', 't' })

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
