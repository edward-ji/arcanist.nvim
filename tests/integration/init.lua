-- `-u` file for the child Neovim tests/integration spawns via mini.test's
-- `MiniTest.new_child_neovim()`. Deliberately minimal: adding this repo to
-- the runtimepath is all a real plugin manager would do, and
-- plugin/arcanist.lua self-registers everything else from there (BufReadCmd
-- for "arcanist://", :ArcLint, the gitcommit->remarkup reclassification,
-- ...) exactly as it would in a genuine install.
--
-- The repo root alone is not enough: Neovim's ftplugin machinery finds
-- "after/ftplugin/<type>.lua" by running "ftplugin/<type>.lua" against
-- *every* 'runtimepath' entry, so "<repo>/after" has to be its own rtp
-- entry (a real plugin manager always adds both) or after/ftplugin/
-- remarkup.lua -- which attaches the LSP client and paste hook -- never
-- fires.
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(root .. '/after')
