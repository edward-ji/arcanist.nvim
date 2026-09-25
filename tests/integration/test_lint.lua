-- Drives ":ArcLint" against the fake `arc` -- zero findings, a usage
-- error, refusing to run twice at once, "!" cancelling an in-flight run,
-- and rejecting a reserved flag.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.capture_notify()
        end,
        post_case = child.teardown,
    },
})

--- Every notify message captured so far that contains `substr`.
--- @param substr string
--- @return string[]
local function messages_containing(substr)
    local out = {}
    for _, entry in ipairs(child.notifications()) do
        if entry.msg:find(substr, 1, true) then
            out[#out + 1] = entry.msg
        end
    end
    return out
end

T[':ArcLint with nothing to report'] = function()
    child.fixture('lint', '') -- empty stdout: "nothing matched" path

    child.cmd('enew')
    child.cmd('ArcLint')
    child.lua([[vim.wait(500)]])

    eq(#messages_containing('nothing to report'), 1)
    eq(child.lua_get('vim.fn.getqflist()'), {})
end

T[':ArcLint on a usage error'] = function()
    child.fixture('lint', { exit_code = 1, stderr = 'Usage Exception: bad argument\n' })

    child.cmd('enew')
    child.cmd('ArcLint')
    child.lua([[vim.wait(500)]])

    eq(#messages_containing('arcanist.nvim: arc lint: bad argument'), 1)
    eq(child.lua_get('vim.fn.getqflist()'), {})
end

T[':ArcLint refuses to run twice at once'] = function()
    child.fixture('lint', { delay_ms = 500, stdout = '' })

    child.cmd('enew')
    child.cmd('ArcLint')
    child.cmd('ArcLint') -- issued immediately -- the first is still "running"

    eq(#messages_containing('is already running'), 1)
    child.lua([[vim.wait(1000)]]) -- let the slow one actually finish
end

T[':ArcLint! cancels an in-flight run and starts over'] = function()
    local first = vim.json.encode({ ['first.txt'] = { { severity = 'warning', line = 1, char = 1, code = 'X', name = 'X', description = 'first' } } }) .. '\n'
    local second = vim.json.encode({ ['second.txt'] = { { severity = 'warning', line = 1, char = 1, code = 'Y', name = 'Y', description = 'second' } } }) .. '\n'

    -- Not a `__sequence`: the cancelled run's own fake-arc process can be
    -- (and, confirmed live, reliably is) killed before it ever reads its
    -- fixture at all, so a shared "which call gets which sequence slot"
    -- counter races between the two processes and isn't a reliable way to
    -- tell them apart. Overwriting the fixture in between instead
    -- guarantees the second (surviving) run sees "second" regardless of
    -- what the first, discarded one manages to read.
    child.fixture('lint', { delay_ms = 1500, stdout = first })
    child.cmd('enew')
    child.cmd('ArcLint')

    child.fixture('lint', { stdout = second })
    child.cmd('ArcLint!')
    child.wait_until('#vim.fn.getqflist() > 0')

    local qf = child.lua_get('vim.fn.getqflist()')
    eq(#qf, 1)
    eq(qf[1].text, 'Y Y: second')
    eq(#messages_containing('cancelled after'), 1)
end

T[':ArcLint rejects a reserved flag before spawning anything'] = function()
    child.cmd('enew')
    child.cmd('ArcLint --output=text')

    eq(#messages_containing('--output is set by the plugin'), 1)
    eq(#child.calls(), 0) -- never even spawned the fake arc
end

return T
