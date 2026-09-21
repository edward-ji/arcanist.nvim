-- Drives ":ArcLint" against the fake `arc` -- zero findings, a usage
-- error, refusing to run twice at once, "!" cancelling an in-flight run,
-- and rejecting a reserved flag.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child, dir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child, dir = helpers.new_child()
            helpers.capture_notify(child)
        end,
        post_case = function()
            helpers.stop(child, dir)
        end,
    },
})

--- Block until `condition_expr` (a Lua boolean expression, evaluated
--- inside the child) is true, or 2s pass.
--- @param condition_expr string
local function wait_until(condition_expr)
    child.lua(string.format('vim.wait(2000, function() return %s end, 10)', condition_expr))
end

--- Every notify message captured so far that contains `substr`.
--- @param substr string
--- @return string[]
local function messages_containing(substr)
    local out = {}
    for _, entry in ipairs(helpers.notifications(child)) do
        if entry.msg:find(substr, 1, true) then
            out[#out + 1] = entry.msg
        end
    end
    return out
end

T[':ArcLint with nothing to report'] = function()
    helpers.fixture(dir, 'lint', '') -- empty stdout: "nothing matched" path

    child.cmd('enew')
    child.cmd('ArcLint')
    child.lua([[vim.wait(500)]])

    eq(#messages_containing('nothing to report'), 1)
    eq(child.lua_get('vim.fn.getqflist()'), {})
end

T[':ArcLint on a usage error'] = function()
    helpers.fixture(dir, 'lint', { exit_code = 1, stderr = 'Usage Exception: bad argument\n' })

    child.cmd('enew')
    child.cmd('ArcLint')
    child.lua([[vim.wait(500)]])

    eq(#messages_containing('arcanist.nvim: arc lint: bad argument'), 1)
    eq(child.lua_get('vim.fn.getqflist()'), {})
end

T[':ArcLint refuses to run twice at once'] = function()
    helpers.fixture(dir, 'lint', { delay_ms = 500, stdout = '' })

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
    helpers.fixture(dir, 'lint', { delay_ms = 1500, stdout = first })
    child.cmd('enew')
    child.cmd('ArcLint')

    helpers.fixture(dir, 'lint', { stdout = second })
    child.cmd('ArcLint!')
    wait_until('#vim.fn.getqflist() > 0')

    local qf = child.lua_get('vim.fn.getqflist()')
    eq(#qf, 1)
    eq(qf[1].text, 'Y Y: second')
    eq(#messages_containing('cancelled after'), 1)
end

T[':ArcLint rejects a reserved flag before spawning anything'] = function()
    child.cmd('enew')
    child.cmd('ArcLint --output=text')

    eq(#messages_containing('--output is set by the plugin'), 1)
    eq(#helpers.calls(dir), 0) -- never even spawned the fake arc
end

return T
