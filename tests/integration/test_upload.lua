-- Drives arcanist.upload against the fake `arc upload`: success, a
-- realistic multi-line failure stderr boiled down to one message, and
-- cancelling mid-upload.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua([[_G.__result = nil]])
        end,
        post_case = child.teardown,
    },
})

T['upload() succeeds and resolves the monogram'] = function()
    child.fixture('upload', { { id = 262 } })

    child.lua([[
        require('arcanist.upload').upload('/tmp/duck.png', function(ok, result)
            _G.__result = { ok, result }
        end)
    ]])
    child.wait_until('_G.__result ~= nil')

    eq(child.lua_get('_G.__result'), { true, 'F262' })
end

T['upload() boils a multi-line failure down to one message'] = function()
    child.fixture('upload', {
        __control = {
            exit_code = 1,
            stderr = 'EXCEPTION: (ArcanistUsageException) Could not upload file: no such file. '
                .. 'at [/path/to/file.php:42]\n#0 more trace\n#1 even more trace\n',
        },
    })
    child.lua([[
        _G.__notify_log = {}
        vim.notify = function(msg, level) table.insert(_G.__notify_log, { msg = msg, level = level }) end
        require('arcanist.upload').upload('/tmp/missing.png', function(ok, result)
            _G.__result = { ok, result }
        end)
    ]])
    child.wait_until('_G.__result ~= nil')

    eq(child.lua_get('_G.__result'), { false, 'Could not upload file: no such file.' })
    local log = child.lua_get('_G.__notify_log')
    eq(log[#log].msg, 'arcanist.nvim: upload of /tmp/missing.png failed: Could not upload file: no such file.')
end

T['cancelling an upload stops its callback from firing'] = function()
    child.fixture('upload', { __control = { delay_ms = 1000, value = { { id = 1 } } } })

    child.lua([[
        _G.__cancel = require('arcanist.upload').upload('/tmp/slow.png', function(ok, result)
            _G.__result = { ok, result }
        end)
    ]])
    child.lua([[_G.__cancel()]])
    child.lua([[vim.wait(1500)]]) -- past the fake's own delay

    eq(child.lua_get('_G.__result == nil'), true)
end

return T
