-- Drives ":ArcList" against the fake `arc`: picking a result opens it as
-- an "arcanist://" buffer, and an unsupported query key for a type is
-- rejected client-side before any Conduit call.

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

T[':ArcList opens the picked result as an arcanist:// buffer'] = function()
    -- Both entries tie on date_modified, so M.list's own sort (ties break
    -- on id descending) puts D3 first -- the fake stubs vim.ui.select to
    -- always pick items[1], so this is the one that ends up opened.
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            { data = { { id = 2, fields = { title = 'Revision A' } }, { id = 3, fields = { title = 'Revision B' } } } },
            helpers.revision_response({ id = 3, title = 'Revision B' }),
        },
    })
    child.lua([[vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end]])

    child.cmd('enew')
    child.cmd('ArcList')
    child.wait_until('vim.api.nvim_buf_get_name(0):match("arcanist://D3$") ~= nil')
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Revision B')
end

T[':ArcList rejects a query key the type does not support'] = function()
    child.cmd('enew')
    child.cmd('ArcList reviewing tasks')

    local log = child.notifications()
    eq(#log, 1)
    eq(
        log[1].msg,
        'arcanist.nvim: "reviewing" is not a task query -- expected one of: '
            .. 'assigned, authored, subscribed, open, all'
    )
    eq(#child.calls(), 0) -- rejected before ever spawning the fake arc
end

return T
