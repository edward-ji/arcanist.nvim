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

T[':ArcList wikis opens the picked page by its slug'] = function()
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding' })
    )
    child.lua([[vim.ui.select = function(items, opts, on_choice)
        _G.__shown = opts.format_item(items[1])
        on_choice(items[1])
    end]])

    child.cmd('enew')
    child.cmd('ArcList wikis')
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), 'arcanist://w/engineering/onboarding/')
    eq(child.lua_get('_G.__shown'), 'w/engineering/onboarding/    Onboarding')
    eq(child.calls('call-conduit phriction.document.search')[1].params.attachments.content, true)
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

T[':ArcList completes the types a typed query applies to, then filters'] = function()
    eq(child.lua_get([[vim.fn.getcompletion('ArcList open ', 'cmdline')]]), { 'tasks', 'author=', 'owner=' })
    eq(child.lua_get([[vim.fn.getcompletion('ArcList open tasks owner=', 'cmdline')]]), { 'owner=me' })
end

T[':ArcList with a filter given twice says so'] = function()
    child.cmd('ArcList author=me author=alice')

    eq(child.last_notification(), 'arcanist.nvim: "author" is set twice')
    eq(#child.calls(), 0)
end

T[':ArcList wikis names the root page w/ and opens it'] = function()
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 1, slug = '/', title = 'Wiki Home' })
    )
    child.lua([[vim.ui.select = function(items, opts, on_choice)
        _G.__shown = opts.format_item(items[1])
        on_choice(items[1])
    end]])

    child.cmd('enew')
    child.cmd('ArcList wikis')
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    eq(child.lua_get('_G.__shown'), 'w/    Wiki Home')
    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), 'arcanist://w/')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, -2, -1, false)')[1], 'Wiki Document: w/')
    eq(child.calls('call-conduit phriction.document.search')[2].params.constraints.paths, { '/' })
end

return T
