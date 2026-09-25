-- Drives arcanist.detect's two content-based filetype rules: reclassifying
-- a 'gitcommit' buffer as remarkup inside a Phorge working copy, and
-- guessing remarkup from a file's own trailing identity line.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = child.setup,
        post_case = child.teardown,
    },
})

T["a 'gitcommit' buffer becomes remarkup when detect.gitcommit is on"] = function()
    child.lua([[require('arcanist').setup({ detect = { gitcommit = true } })]])

    local work = child.dir .. '/work'
    vim.fn.mkdir(work, 'p')
    local arcconfig = assert(io.open(work .. '/.arcconfig', 'w'))
    arcconfig:write('{}')
    arcconfig:close()
    local msg = assert(io.open(work .. '/COMMIT_EDITMSG', 'w'))
    msg:write('Fix the bug\n')
    msg:close()

    child.cmd('edit ' .. work .. '/COMMIT_EDITMSG')
    child.lua([[vim.bo.filetype = 'gitcommit']])

    eq(child.lua_get('vim.bo.filetype'), 'remarkup')
end

T["a 'gitcommit' buffer stays put when detect.gitcommit is off (default)"] = function()
    local work = child.dir .. '/work'
    vim.fn.mkdir(work, 'p')
    local arcconfig = assert(io.open(work .. '/.arcconfig', 'w'))
    arcconfig:write('{}')
    arcconfig:close()
    local msg = assert(io.open(work .. '/COMMIT_EDITMSG', 'w'))
    msg:write('Fix the bug\n')
    msg:close()

    child.cmd('edit ' .. work .. '/COMMIT_EDITMSG')
    child.lua([[vim.bo.filetype = 'gitcommit']])

    eq(child.lua_get('vim.bo.filetype'), 'gitcommit')
end

T['a file with no name of its own is guessed by its trailing identity line'] = function()
    -- detect.identity defaults to true -- no setup() call needed. The
    -- filename itself matches no rule at all (no extension, no known
    -- pattern), so only the content-sniffing catch-all can claim it.
    local path = child.dir .. '/some-random-file'
    local f = assert(io.open(path, 'w'))
    f:write('Some title\n\nDescription text.\n\nManiphest Task: T5\n')
    f:close()

    child.cmd('edit ' .. path)

    eq(child.lua_get('vim.bo.filetype'), 'remarkup')
end

T['content-based identity detection is skipped when detect.identity is off'] = function()
    child.lua([[require('arcanist').setup({ detect = { identity = false } })]])

    local path = child.dir .. '/off-by-config'
    local f = assert(io.open(path, 'w'))
    f:write('Some title\n\nDescription text.\n\nManiphest Task: T5\n')
    f:close()

    child.cmd('edit ' .. path)

    eq(child.lua_get('vim.bo.filetype') ~= 'remarkup', true)
end

T['a file whose last line names no known object type is left alone'] = function()
    local path = child.dir .. '/another-random-file'
    local f = assert(io.open(path, 'w'))
    f:write('Some title\n\nDescription text.\n\nMysterious Task: T5\n')
    f:close()

    child.cmd('edit ' .. path)

    -- "Mysterious Task" names no known handler, so this isn't guessed as
    -- remarkup -- confirms the rule actually reads the label, not just
    -- "ends with a colon and a number".
    eq(child.lua_get('vim.bo.filetype') ~= 'remarkup', true)
end

return T
