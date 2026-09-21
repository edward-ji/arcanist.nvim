-- Bootstraps a plain Neovim instance for `make test`: clones mini.test's
-- home (mini.nvim) into deps/ on first run, then puts it and this repo's
-- lua/ on the runtimepath. Deliberately independent of any user config
-- (`nvim --noplugin -u` this file) so tests run the same everywhere.

local mini_path = vim.fn.getcwd() .. '/deps/mini.nvim'
if not vim.uv.fs_stat(mini_path) then
    vim.fn.system({
        'git',
        'clone',
        '--filter=blob:none',
        'https://github.com/echasnovski/mini.nvim',
        mini_path,
    })
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(vim.fn.getcwd())

require('mini.test').setup()
