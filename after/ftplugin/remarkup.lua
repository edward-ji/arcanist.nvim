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

-- 'includeexpr' hook so `gf` (and the rest of its family: `gF`, CTRL-W_f,
-- CTRL-W_gf) on a T123 / {D456} reference opens it as an "arcanist://"
-- buffer, and passes any other text through to Vim's ordinary file lookup.
-- See arcanist.reference.gf.
vim.opt_local.includeexpr = "v:lua.require'arcanist.reference'.gf(v:fname)"

-- `gf` on a file monogram ("F123", "{F123}") previews it; any other
-- monogram or word falls through to the built-in `gf`, which picks up
-- T123/D456 references via 'includeexpr' above. A file monogram is
-- literally "go to file", but the download + viewer is a real side
-- effect, so it stays on an explicit `gf` keypress, not 'includeexpr'
-- (which peek/hover plugins also evaluate).
vim.keymap.set('n', 'gf', function()
    local monogram = require('arcanist.reference').monogram_at_cursor()
    if monogram and require('arcanist.file').file_id(monogram) then
        require('arcanist').preview(monogram)
    else
        -- Feed the built-in `gf` (count and all) rather than `:normal` it,
        -- so its own "E447" surfaces plainly instead of wrapped in a Lua
        -- error and traceback. "n" keeps this from recursing.
        vim.api.nvim_feedkeys(vim.v.count1 .. 'gf', 'n', false)
    end
end, { buffer = true, desc = 'Preview a file monogram under the cursor, else built-in gf' })

-- Attach the "arcanist" LSP client (see lua/arcanist/lsp.lua for why), for
-- @mention / #project / field-value completion.
require('arcanist.lsp').setup()
