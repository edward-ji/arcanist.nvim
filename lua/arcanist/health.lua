-- `:checkhealth arcanist`. Neovim discovers this file by name -- shipping
-- `lua/arcanist/health.lua` with a `check()` is all it takes.
--
-- The advice strings deliberately echo after/ftplugin/remarkup.lua and
-- doc/arcanist.txt section 10 so the guidance reads the same everywhere.

local health = vim.health

local M = {}

--- Plugin root, for the "run `make` here" advice.
--- @return string?
local function plugin_dir()
    local this = debug.getinfo(1, 'S').source:match('^@(.*)')
    return this and this:match('(.*)/lua/arcanist/health%.lua$')
end

local function check_nvim()
    health.start('Neovim')
    if vim.fn.has('nvim-0.10') == 1 then
        health.ok('version ' .. tostring(vim.version()))
    else
        health.error('arcanist.nvim requires Neovim 0.10 or newer')
    end
end

--- Also runs a live user.whoami: one call exercises the endpoint URI and the
--- API token, and names who you are back.
local function check_arc()
    health.start('arc')

    if vim.fn.executable('arc') ~= 1 then
        health.error('`arc` not found on $PATH', {
            'Install Arcanist and put `arc` on your $PATH: '
                .. 'https://we.phorge.it/book/phorge/article/arcanist/',
            "Neovim's $PATH is not necessarily your shell's -- if `arc` runs "
                .. 'in a terminal but not here, check where your $PATH is set.',
        })
        return
    end
    health.ok('`arc` found: ' .. vim.fn.exepath('arc'))

    -- A health check shouldn't sit for the full conduit_timeout.
    local timeout = math.min(require('arcanist').config.conduit_timeout, 5000)
    local ok, result, err =
        require('arcanist.conduit').call_sync('user.whoami', {}, timeout)
    if ok then
        local host = type(result.uri) == 'string' and result.uri:match('^%w+://([^/]+)')
        health.ok(
            string.format(
                'authenticated as @%s%s',
                result.userName or '?',
                host and (' on ' .. host) or ''
            )
        )
    else
        -- Not an error: this also fails when `:checkhealth` is simply run
        -- from a directory with no .arcconfig, which is not a broken setup.
        health.warn('could not reach Phorge: ' .. (err or 'unknown error'), {
            'Run `:checkhealth arcanist` from inside a working copy -- '
                .. 'the call uses the .arcconfig of the current directory.',
            'A message about authentication or a certificate means ~/.arcrc '
                .. 'is not set up for this instance: run `arc install-certificate`.',
        })
    end
end

--- Parser built, ABI current, queries present.
local function check_parser()
    health.start('remarkup parser')

    local build_advice = {
        'Run `make` in ' .. (plugin_dir() or 'the plugin directory'),
        "or point your plugin manager's build step at it "
            .. "(e.g. lazy.nvim: `build = 'make'`).",
        'Building the parser needs a C compiler on $PATH.',
    }

    local so = vim.api.nvim_get_runtime_file('parser/remarkup.so', false)[1]
    -- pcall: on 0.10 language.add() raises; 0.11+ returns `nil, reason`. A
    -- stale build (loads, wrong ABI) and a missing one are both caught here.
    local pok, added, why = pcall(vim.treesitter.language.add, 'remarkup')
    if pok and added then
        health.ok('parser built: ' .. (so or '(found on runtimepath)'))
    elseif so then
        health.error(
            string.format('parser at %s failed to load: %s', so, why or added or 'unknown'),
            build_advice
        )
    else
        health.error('remarkup parser not built', build_advice)
    end

    local cc = vim.env.CC or 'cc'
    if vim.fn.executable(cc) == 1 then
        health.ok('C compiler: ' .. vim.fn.exepath(cc))
    else
        health.warn(
            string.format('`%s` not found on $PATH -- needed to build the parser', cc)
        )
    end

    -- query.get() raises (not nil) when the language has no parser at all.
    for _, name in ipairs({ 'highlights', 'injections' }) do
        local got, query = pcall(vim.treesitter.query.get, 'remarkup', name)
        if got and query then
            health.ok(name .. ' query found')
        else
            health.warn(name .. ' query not found -- check your runtimepath')
        end
    end
end

--- Optional integrations: icons, snacks preview, drafts dir. Never fatal.
local function check_optional()
    health.start('optional integrations')

    local config = require('arcanist').config

    -- Same detection idiom as arcanist.icon: global for mini.icons, require
    -- for devicons.
    if _G.MiniIcons then
        health.ok('icon provider: mini.icons')
    elseif pcall(require, 'nvim-web-devicons') then
        health.ok('icon provider: nvim-web-devicons')
    else
        health.info('no icon provider (nvim-web-devicons / mini.icons) -- '
            .. 'the Remarkup filetype glyph is skipped')
    end

    -- Both file.open and file.inline.render take "snacks", rendering through
    -- snacks.image.
    local snacks_users = { open = config.file.open, ['inline.render'] = config.file.inline.render }
    for key, value in pairs(snacks_users) do
        if value == 'snacks' then
            if pcall(require, 'snacks.image') then
                health.ok(('file.%s = "snacks": snacks.image is available'):format(key))
            else
                health.warn(('file.%s = "snacks" but snacks.image is not available'):format(key))
            end
        end
    end

    local dir = config.drafts.dir
    if not config.drafts.enabled then
        health.info('drafts disabled')
    elseif vim.fn.isdirectory(dir) ~= 1 then
        -- Created on first write, so absence now is only a note.
        health.info('drafts.dir does not exist yet (created on first draft): ' .. dir)
    elseif vim.fn.filewritable(dir) == 2 then
        health.ok('drafts.dir writable: ' .. dir)
    else
        health.warn('drafts.dir is not writable: ' .. dir)
    end
end

function M.check()
    check_nvim()
    check_arc()
    check_parser()
    check_optional()
end

return M
