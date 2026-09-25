-- Drives arcanist.paste's `vim.paste` override against the fake `arc
-- upload`: a placeholder appears immediately and is swapped for the real
-- reference on success, removed on failure, and an abandoned buffer
-- cancels whatever upload was still in flight.

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

--- Open a fresh remarkup buffer with one empty line, cursor on it.
local function open_remarkup_buffer()
    child.cmd('enew')
    child.lua([[vim.bo.filetype = 'remarkup']])
end

T['pasting a file path uploads it and swaps the placeholder for {F<id>}'] = function()
    local path = child.dir .. '/photo.png'
    local f = assert(io.open(path, 'w'))
    f:write('not really a png')
    f:close()
    child.fixture('upload', { { id = 555 } })

    open_remarkup_buffer()
    child.lua(string.format('vim.paste({%q}, -1)', path))
    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "{F555}"')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)'), { '{F555}' })
end

T['a failed upload removes the placeholder'] = function()
    local path = child.dir .. '/broken.png'
    local f = assert(io.open(path, 'w'))
    f:write('x')
    f:close()
    child.fixture('upload', {
        __control = { exit_code = 1, stderr = 'EXCEPTION: (X) upload rejected at [f.php:1]\n' },
    })

    open_remarkup_buffer()
    child.lua(string.format('vim.paste({%q}, -1)', path))
    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == ""')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)'), { '' })
    local log = child.notifications()
    eq(log[#log].msg:find('upload rejected', 1, true) ~= nil, true)
end

T['paste.upload = false leaves pasted paths as plain text, never uploaded'] = function()
    child.lua([[require('arcanist').setup({ paste = { upload = false } })]])
    local path = child.dir .. '/photo.png'
    local f = assert(io.open(path, 'w'))
    f:write('not really a png')
    f:close()

    open_remarkup_buffer()
    child.lua(string.format('vim.paste({%q}, -1)', path))
    child.lua([[vim.wait(200)]])

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)'), { path })
    eq(#child.calls(), 0) -- `arc` was never invoked at all
end

T['a custom paste.placeholder format is shown while the upload is in flight'] = function()
    child.lua([[require('arcanist').setup({ paste = { placeholder = '<<uploading %s>>' } })]])
    local path = child.dir .. '/slow.png'
    local f = assert(io.open(path, 'w'))
    f:write('x')
    f:close()
    child.fixture('upload', { __control = { delay_ms = 500, value = { { id = 9 } } } })

    open_remarkup_buffer()
    child.lua(string.format('vim.paste({%q}, -1)', path))
    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= ""')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)'), { '<<uploading slow.png>>' })

    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "{F9}"')
end

T['wiping a buffer cancels whatever upload was still in flight'] = function()
    local path = child.dir .. '/slow.png'
    local f = assert(io.open(path, 'w'))
    f:write('x')
    f:close()
    child.fixture('upload', { __control = { delay_ms = 1000, value = { { id = 1 } } } })

    open_remarkup_buffer()
    child.lua(string.format('vim.paste({%q}, -1)', path))
    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= ""') -- placeholder inserted

    child.cmd('bwipeout!')
    child.lua([[vim.wait(1500)]]) -- past the fake's own delay

    local log = child.notifications()
    eq(log[#log].msg, 'arcanist.nvim: buffer unloaded -- cancelled 1 upload(s)')
end

return T
