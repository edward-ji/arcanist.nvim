-- Give the "remarkup" filetype Phabricator's own glyph, so a Remarkup
-- buffer is recognisable wherever an icon provider is asked what a buffer
-- is -- a file picker, a tab line, a statusline.
--
-- Neovim has no icon registry of its own, so this hands the icon to
-- whichever provider is installed. Both of them draw Nerd Font glyphs and
-- nothing else, so a loaded provider is itself the evidence that a Nerd
-- Font is in use. The two places a user says otherwise are honoured:
-- mini.icons' `style = 'ascii'`, and `vim.g.have_nerd_font`, the flag
-- Nerd-Font-aware configs set editor-wide.

local M = {}

-- nf-fa-phabricator, U+ED15. The blue is Phabricator's own tag blue;
-- cterm 31 is the nearest 256-colour approximation.
local GLYPH = ''
local COLOR = '#2980b9'
local CTERM_COLOR = '31'

local function register()
    if vim.g.have_nerd_font == false then
        return
    end

    -- mini.icons is checked through its global rather than `require`,
    -- because requiring it would load it for a user who has it installed
    -- but never set it up -- and because mini.icons can mock
    -- nvim-web-devicons, which is why the branch below tests for
    -- `set_icon` rather than trusting the module name.
    local mini = _G.MiniIcons
    if mini and mini.config.style ~= 'ascii' then
        local entry = { glyph = GLYPH, hl = 'MiniIconsBlue' }
        -- Re-running setup is what publishes a config change: mini.icons
        -- caches every lookup, and setup() is what clears that cache.
        mini.setup(vim.tbl_deep_extend('force', mini.config, {
            filetype = { remarkup = entry },
            extension = { remarkup = entry },
        }))
    end

    local ok, devicons = pcall(require, 'nvim-web-devicons')
    if ok and type(devicons.set_icon) == 'function' then
        devicons.set_icon({
            remarkup = {
                icon = GLYPH,
                color = COLOR,
                cterm_color = CTERM_COLOR,
                name = 'Remarkup',
            },
        })
        -- The extension entry above only answers for a file named
        -- "*.remarkup". An "arcanist://" buffer has no extension, so point
        -- the filetype at the same entry.
        if type(devicons.set_icon_by_filetype) == 'function' then
            devicons.set_icon_by_filetype({ remarkup = 'remarkup' })
        end
    end
end

--- Register the Remarkup icon with the installed icon provider.
function M.setup()
    -- Startup plugins load in directory-name order, and "arcanist.nvim"
    -- sorts before both providers, so registering now would write into a
    -- provider that hasn't loaded yet. VimEnter is after all of them.
    if vim.v.vim_did_enter == 1 then
        register()
    else
        vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = register })
    end
end

return M
