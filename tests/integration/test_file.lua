-- Drives ":ArcFile" against the fake `arc`: downloading and opening via a
-- custom open hook, the cache hit/force paths, the oversized-file refusal,
-- and a download failure.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.capture_notify()
            -- file.lua's cache dir is computed once from stdpath('cache')
            -- at first require -- redirect it into our scratch dir before
            -- that first require, so tests never touch the real cache.
            child.lua(string.format([[vim.env.XDG_CACHE_HOME = %q]], child.dir .. '/xdg-cache'))
            child.lua([[_G.__opened = nil]])
            child.lua([[require('arcanist').setup({
                file = { open = function(path, info) _G.__opened = { path = path, info = info } end },
            })]])
        end,
        post_case = child.teardown,
    },
})

T[':ArcFile downloads and hands the file to the open hook'] = function()
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))
    child.fixture('download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.cmd('ArcFile F123')
    child.wait_until('_G.__opened ~= nil')

    local opened = child.lua_get('_G.__opened')
    eq(opened.info.monogram, 'F123')
    eq(opened.info.name, 'duck.png')
    eq(vim.endswith(opened.path, '/F123/duck.png'), true)

    local f = assert(io.open(opened.path, 'rb'))
    eq(f:read('*a'), 'PNGDATA')
    f:close()
end

T[':ArcFile does not re-download an already-cached file'] = function()
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'duck.png', size = 1500 }))
    child.fixture('download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.cmd('ArcFile F123')
    child.wait_until('_G.__opened ~= nil')
    child.lua([[_G.__opened = nil]])

    child.cmd('ArcFile F123')
    child.wait_until('_G.__opened ~= nil') -- cache hit still calls the open hook

    eq(#child.calls('call-conduit file.search'), 1)
    eq(#child.calls('download'), 1)
end

T[':ArcFile! forces a re-download past the cache'] = function()
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'duck.png', size = 1500 }))
    child.fixture('download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.cmd('ArcFile F123')
    child.wait_until('_G.__opened ~= nil')
    child.lua([[_G.__opened = nil]])

    child.cmd('ArcFile! F123')
    child.wait_until('_G.__opened ~= nil')

    eq(#child.calls('call-conduit file.search'), 2)
    eq(#child.calls('download'), 2)
end

T[':ArcFile refuses a file past max_bytes without a bang'] = function()
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'big.bin', size = 30 * 1024 * 1024 }))

    child.cmd('enew')
    child.cmd('ArcFile F999')
    child.lua([[vim.wait(300)]])

    eq(#child.calls('download'), 0)
    local log = child.notifications()
    eq(#log, 1)
    eq(log[1].msg, 'arcanist.nvim: F999 is 30.0 MB (cap 25.0 MB) -- :ArcFile! to fetch it anyway')
end

T['an unknown file.open preset name reports a clear error'] = function()
    child.lua([[require('arcanist').setup({ file = { open = 'not-a-real-preset' } })]])
    child.lua([[_G.__opened = 'sentinel']]) -- would be overwritten if the (unknown) hook ran
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'duck.png', size = 1500 }))
    child.fixture('download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.cmd('ArcFile F123')
    child.lua([[vim.wait(300)]])

    local log = child.notifications()
    eq(log[#log].msg, 'arcanist.nvim: file.open: unknown preset "not-a-real-preset"')
    eq(child.lua_get('_G.__opened'), 'sentinel')
end

T[':ArcFile reports a download failure and caches nothing'] = function()
    child.fixture('call-conduit file.search', helpers.file_response({ name = 'ghost.bin', size = 10 }))
    child.fixture('download', { ok = false, code = 1, stderr = ' USAGE EXCEPTION Permission denied.\n' })

    child.cmd('enew')
    child.cmd('ArcFile F7')
    child.lua([[vim.wait(300)]])

    -- Also notifies "loading F7 (ghost.bin, 10 B)..." first (M.fetch's own
    -- progress message) before the download itself fails.
    local log = child.notifications()
    eq(log[#log].msg, 'arcanist.nvim: F7: Permission denied.')
    eq(child.lua_get('_G.__opened == nil'), true)
end

return T
