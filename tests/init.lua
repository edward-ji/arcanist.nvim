-- Bootstraps a plain Neovim instance for `make test`: clones a pinned
-- mini.test into deps/ on first run, then puts it and this repo's lua/ on
-- the runtimepath. Deliberately independent of any user config
-- (`nvim --noplugin -u` this file) so tests run the same everywhere.

-- The version is part of the clone's path, so bumping it clones afresh
-- rather than silently reusing an older checkout.
local MINI_TEST_VERSION = 'v0.18.0'

local mini_path = vim.fn.getcwd() .. '/deps/mini.test-' .. MINI_TEST_VERSION
if not vim.uv.fs_stat(mini_path) then
    vim.fn.system({
        'git',
        'clone',
        '--depth',
        '1',
        '--branch',
        MINI_TEST_VERSION,
        'https://github.com/nvim-mini/mini.test',
        mini_path,
    })
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(vim.fn.getcwd())

require('mini.test').setup()
