-- Drives ":checkhealth arcanist" against the fake `arc`, covering the parts
-- of its report that are actually configuration-dependent: the `arc` check's
-- live user.whoami round-trip (and what `config.conduit_timeout` does to a
-- slow one), and "optional integrations"' reporting on `file.open`/
-- `file.inline.render = "snacks"` and `drafts.enabled`/`drafts.dir`.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = child.setup,
        post_case = child.teardown,
    },
})

--- Run ":checkhealth arcanist" and return its report buffer's full text.
--- Waits for "optional integrations" -- check_optional()'s own header,
--- always the last section M.check() renders -- as the signal that the
--- (blocking) whole check finished, not just that the buffer exists.
--- @return string
local function run_checkhealth()
    child.cmd('checkhealth arcanist')
    child.lua([[
        vim.wait(2000, function()
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.bo[buf].filetype == 'checkhealth' then
                    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
                    if text:find('optional integrations', 1, true) then
                        return true
                    end
                end
            end
            return false
        end, 20)
    ]])
    return child.lua_get([[(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == 'checkhealth' then
                return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
            end
        end
    end)()]])
end

T[':checkhealth arcanist reports who user.whoami authenticates as'] = function()
    child.fixture('call-conduit user.whoami', { userName = 'alice', uri = 'https://phorge.example/api/' })

    local report = run_checkhealth()

    eq(report:find('authenticated as @alice on phorge.example', 1, true) ~= nil, true)
end

T['a whoami that outlives conduit_timeout is reported as unreachable'] = function()
    child.lua([[require('arcanist').setup({ conduit_timeout = 50 })]])
    child.fixture('call-conduit user.whoami', { __control = { delay_ms = 500 } })

    local report = run_checkhealth()

    eq(report:find('could not reach Phorge: arc call-conduit timed out', 1, true) ~= nil, true)
end

T['file.open = "snacks" without snacks.nvim is reported unavailable'] = function()
    child.lua([[require('arcanist').setup({ file = { open = 'snacks' } })]])
    child.fixture('call-conduit user.whoami', { userName = 'alice' })

    local report = run_checkhealth()

    eq(report:find('file.open = "snacks" but snacks.image is not available', 1, true) ~= nil, true)
end

T['file.inline.render = "snacks" without snacks.nvim is reported unavailable'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { render = 'snacks' } } })]])
    child.fixture('call-conduit user.whoami', { userName = 'alice' })

    local report = run_checkhealth()

    eq(report:find('file.inline.render = "snacks" but snacks.image is not available', 1, true) ~= nil, true)
end

T['drafts disabled (the default) is reported as such'] = function()
    child.fixture('call-conduit user.whoami', { userName = 'alice' })

    local report = run_checkhealth()

    eq(report:find('drafts disabled', 1, true) ~= nil, true)
end

T['a configured drafts.dir that does not exist yet is only a note'] = function()
    local drafts_dir = child.dir .. '/not-yet-created'
    child.lua(string.format(
        [[require('arcanist').setup({ drafts = { enabled = true, dir = %q } })]],
        drafts_dir
    ))
    child.fixture('call-conduit user.whoami', { userName = 'alice' })

    local report = run_checkhealth()

    eq(report:find('drafts.dir does not exist yet (created on first draft): ' .. drafts_dir, 1, true) ~= nil, true)
end

T['an existing writable drafts.dir is reported ok'] = function()
    local drafts_dir = child.dir .. '/drafts'
    vim.fn.mkdir(drafts_dir, 'p')
    child.lua(string.format(
        [[require('arcanist').setup({ drafts = { enabled = true, dir = %q } })]],
        drafts_dir
    ))
    child.fixture('call-conduit user.whoami', { userName = 'alice' })

    local report = run_checkhealth()

    eq(report:find('drafts.dir writable: ' .. drafts_dir, 1, true) ~= nil, true)
end

return T
