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
