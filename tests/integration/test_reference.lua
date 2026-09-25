-- Drives a real (child) Neovim through the "arcanist://" buffer scheme --
-- opening tasks and revisions, editing and saving them, `gd` on a
-- reference -- against the fake `arc` in fixtures/, so no real
-- Phorge/network is involved. See helpers.lua for how the fake is wired up.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = child.setup,
        post_case = child.teardown,
    },
})

--- Open "arcanist://T<id>" (or "D<id>") and wait for it to load.
--- @param ref string e.g. "T5"
local function open(ref)
    child.cmd('edit arcanist://' .. ref)
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')
end

--- The last captured notify message, or nil.
--- @return string?
local function last_notification()
    local log = child.notifications()
    return log[#log] and log[#log].msg
end

T['opening an arcanist:// buffer renders the fetched object'] = function()
    child.fixture(
        'call-conduit maniphest.search',
        helpers.task_response({ id = 5, title = 'Fix bug', description = 'Steps to reproduce.' })
    )

    open('T5')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), {
        'Fix bug',
        '',
        'Status: Open',
        'Priority: Normal',
        '',
        'Description:',
        'Steps to reproduce.',
        '',
        'Project Tags: ',
        '',
        'Maniphest Task: T5',
    })
end

T['opening a revision renders its own (different) field list'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision', summary = 'Summary text.', testPlan = 'Ran tests.' })
    )

    open('D2')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), {
        'My revision',
        '',
        'Summary:',
        'Summary text.',
        '',
        'Test Plan:',
        'Ran tests.',
        '',
        'Project Tags: ',
        '',
        'Differential Revision: D2',
    })
end

T['opening a wiki document renders it, and :write sends only the changed field'] = function()
    -- Mirrors ':write sends exactly the changed field' below, but over
    -- phriction.document.search/phriction.edit's own shapes (see HANDLERS.W):
    -- a slug-keyed ref rather than a numeric id, and an edit request with
    -- each field inlined directly rather than a transactions array wrapped
    -- in {objectIdentifier, transactions}.
    child.fixture('call-conduit phriction.document.search', {
        __sequence = {
            helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' }),
            helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' }),
            helpers.wiki_response({
                id = 9,
                slug = 'engineering/onboarding/',
                title = 'Onboarding',
                content = 'Welcome (updated).',
            }),
        },
    })
    child.fixture('call-conduit phriction.edit', { slug = 'engineering/onboarding/' })

    open('w/engineering/onboarding/')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), {
        'Onboarding',
        '',
        'Content:',
        'Welcome.',
        '',
        'Project Tags: ',
        '',
        'Wiki Document: w/engineering/onboarding/',
    })

    child.lua([[vim.api.nvim_buf_set_lines(0, 3, 4, false, {'Welcome (updated).'})]])
    child.cmd('write')

    local edits = child.calls('call-conduit phriction.edit')
    eq(#edits, 1)
    eq(edits[1].params, {
        slug = 'engineering/onboarding/',
        content = 'Welcome (updated).',
    })
    eq(child.lua_get('vim.bo.modified'), false)
end

T['object not found on load'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', { data = {} })

    child.cmd('edit arcanist://T404')
    child.wait_for_notification('T404 not found')

    eq(child.lua_get('vim.b[0].arcanist_loaded == nil'), true)
    eq(last_notification(), 'arcanist.nvim: T404 not found')
end

T[':write sends exactly the changed field, and clears modified'] = function()
    -- maniphest.search is called three times across a normal (non-bang)
    -- :write: the initial load, push()'s pre-write conflict check, and its
    -- post-write baseline refresh (lua/arcanist/reference.lua's push()).
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug (updated)' }),
        },
    })
    child.fixture('call-conduit maniphest.edit', { object = { id = 5, phid = 'PHID-TASK-fake' } })

    open('T5')

    child.type_keys('gg', 'A', ' (updated)', '<Esc>')
    child.cmd('write')

    local edits = child.calls('call-conduit maniphest.edit')
    eq(#edits, 1)
    eq(edits[1].params, {
        objectIdentifier = 'T5',
        transactions = { { type = 'title', value = 'Fix bug (updated)' } },
    })
    eq(child.lua_get('vim.bo.modified'), false)
end

T[':write with no edits sends nothing'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', helpers.task_response({ id = 5, title = 'Fix bug' }))

    open('T5')
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.search'), 1) -- no conflict check, no refresh
    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(last_notification(), 'arcanist.nvim: T5: no changes to update')
    eq(child.lua_get('vim.bo.modified'), false)
end

T[':write refuses when the pre-write conflict check times out'] = function()
    child.capture_notify()
    child.lua([[require('arcanist').setup({ conduit_timeout = 50 })]])
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            { __control = { delay_ms = 500 } }, -- outlives conduit_timeout; killed
        },
    })

    open('T5')
    child.type_keys('gg', 'A', ' (updated)', '<Esc>')
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(last_notification(), 'arcanist.nvim: failed to check T5 for changes: arc call-conduit timed out')
    eq(child.lua_get('vim.bo.modified'), true) -- the write never went through
end

T[':write warns (but keeps the edit) when the post-write refresh times out'] = function()
    child.capture_notify()
    child.lua([[require('arcanist').setup({ conduit_timeout = 50 })]])
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            { __control = { delay_ms = 500 } }, -- the refresh call; killed
        },
    })
    child.fixture('call-conduit maniphest.edit', { object = { id = 5 } })

    open('T5')
    child.type_keys('gg', 'A', ' (updated)', '<Esc>')
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 1) -- the edit itself still went through
    eq(
        last_notification(),
        'arcanist.nvim: updated T5, but could not refresh it (arc call-conduit timed out); :e to reload'
    )
    eq(child.lua_get('vim.bo.modified'), false)
end

T[':write! skips the pre-write conflict check'] = function()
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug (updated)' }),
        },
    })
    child.fixture('call-conduit maniphest.edit', { object = { id = 5 } })

    open('T5')
    child.type_keys('gg', 'A', ' (updated)', '<Esc>')
    child.cmd('write!')

    eq(#child.calls('call-conduit maniphest.search'), 2) -- load + refresh only, no conflict check
    eq(#child.calls('call-conduit maniphest.edit'), 1)
    eq(child.lua_get('vim.bo.modified'), false)
end

T[':write refuses when the server drifted since load'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug (drifted upstream)' }),
        },
    })

    open('T5')
    child.type_keys('gg', 'A', ' (my edit)', '<Esc>')
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(
        last_notification(),
        'arcanist.nvim: T5 changed on the server since it was loaded. Your edits are still here; '
            .. ':w {file} to keep a copy, then :e! to reload -- or :w!/:ArcWrite! to overwrite '
            .. "the server's version"
    )
end

T['editing a value_source field (Status) resolves and sends its keyword'] = function()
    child.fixture('call-conduit maniphest.status.search', {
        data = { { name = 'Open', value = 'open' }, { name = 'Resolved', value = 'resolved' } },
    })
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug', status = 'Open' }),
            helpers.task_response({ id = 5, title = 'Fix bug', status = 'Open' }),
            helpers.task_response({ id = 5, title = 'Fix bug', status = 'Resolved' }),
        },
    })
    child.fixture('call-conduit maniphest.edit', { object = { id = 5 } })

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, 2, 3, false, {'Status: Resolved'})]])
    child.cmd('write')

    local edits = child.calls('call-conduit maniphest.edit')
    eq(#edits, 1)
    eq(edits[1].params.transactions, { { type = 'status', value = 'resolved' } })
end

T['editing a value_source field to an invalid value refuses the write'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.status.search', {
        data = { { name = 'Open', value = 'open' }, { name = 'Resolved', value = 'resolved' } },
    })
    child.fixture(
        'call-conduit maniphest.search',
        helpers.task_response({ id = 5, title = 'Fix bug', status = 'Open' })
    )

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, 2, 3, false, {'Status: Not A Real Status'})]])
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(
        last_notification(),
        'arcanist.nvim: failed to update T5: "Not A Real Status" is not valid -- expected one '
            .. 'of: Open, Resolved'
    )
end

T['rendering Projects resolves project PHIDs to their hashtags'] = function()
    child.fixture(
        'call-conduit maniphest.search',
        helpers.task_response({ id = 5, title = 'Fix bug', projects = { 'PHID-PROJ-1', 'PHID-PROJ-2' } })
    )
    child.fixture('call-conduit project.search', {
        data = {
            { phid = 'PHID-PROJ-1', fields = { slug = 'qa' } },
            { phid = 'PHID-PROJ-2', fields = { slug = 'infra' } },
        },
    })

    open('T5')

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 7, 8, false)')[1], 'Project Tags: #qa #infra')
end

T['editing Projects resolves hashtags and sends projects.set'] = function()
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug', projects = { 'PHID-PROJ-qa' } }),
        },
    })
    child.fixture('call-conduit project.search', {
        maps = { slugMap = { qa = { slug = 'qa', projectPHID = 'PHID-PROJ-qa' } } },
    })
    child.fixture('call-conduit maniphest.edit', { object = { id = 5 } })

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, 7, 8, false, {'Project Tags: #qa'})]])
    child.cmd('write')

    local edits = child.calls('call-conduit maniphest.edit')
    eq(#edits, 1)
    eq(edits[1].params.transactions, { { type = 'projects.set', value = { 'PHID-PROJ-qa' } } })
end

T['editing Projects to an unknown hashtag refuses the write'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', helpers.task_response({ id = 5, title = 'Fix bug' }))
    child.fixture('call-conduit project.search', { maps = { slugMap = {} } })

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, 7, 8, false, {'Project Tags: #nonexistent'})]])
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(last_notification(), 'arcanist.nvim: failed to update T5: no such project: #nonexistent')
end

T['editing Projects on a wiki page sends its own phriction.document.edit call'] = function()
    -- Projects has no home in `phriction.edit` at all (see HANDLERS.W), so
    -- editing only Projects should never call it -- everything routes
    -- through the separate `phriction.document.edit` call instead, against
    -- the document's PHID rather than its slug.
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' })
    )
    child.fixture('call-conduit project.search', {
        maps = { slugMap = { qa = { slug = 'qa', projectPHID = 'PHID-PROJ-qa' } } },
    })
    child.fixture('call-conduit phriction.document.edit', { object = { id = 9 } })

    open('w/engineering/onboarding/')
    child.lua([[vim.api.nvim_buf_set_lines(0, 5, 6, false, {'Project Tags: #qa'})]])
    child.cmd('write')

    eq(#child.calls('call-conduit phriction.edit'), 0)
    local edits = child.calls('call-conduit phriction.document.edit')
    eq(#edits, 1)
    eq(edits[1].params, {
        objectIdentifier = 'PHID-WIKI-fake',
        transactions = { { type = 'projects.set', value = { 'PHID-PROJ-qa' } } },
    })
    -- build_edit_calls got the document (and its PHID) from push()'s own
    -- staleness check rather than fetching it again itself: load + staleness
    -- check + post-write baseline refresh, no more.
    eq(#child.calls('call-conduit phriction.document.search'), 3)
end

T['a mismatched identity line refuses to push elsewhere'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', helpers.task_response({ id = 5, title = 'Fix bug' }))

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, -2, -1, false, {'Maniphest Task: T99'})]])
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(
        last_notification(),
        'arcanist.nvim: T5: this text is labelled T99. Delete the "Maniphest Task:" line to '
            .. 'push it elsewhere'
    )
end

T['a duplicate label refuses the write with a parse error'] = function()
    child.capture_notify()
    child.fixture('call-conduit maniphest.search', helpers.task_response({ id = 5, title = 'Fix bug' }))

    open('T5')
    child.lua([[vim.api.nvim_buf_set_lines(0, 2, 2, false, {'Status: Resolved'})]])
    child.cmd('write')

    eq(#child.calls('call-conduit maniphest.edit'), 0)
    eq(last_notification(), 'arcanist.nvim: failed to update T5: duplicate "Status:" label')
end

T['revisiting a hidden buffer via :buffer does not refetch; :e! does'] = function()
    child.fixture('call-conduit maniphest.search', {
        __sequence = {
            helpers.task_response({ id = 5, title = 'Fix bug' }),
            helpers.task_response({ id = 5, title = 'Fix bug (reloaded)' }),
        },
    })

    open('T5')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Fix bug')

    -- 'bufhidden' = "hide" is what keeps T5's buffer around, unwiped, once
    -- left -- so leaving it and switching back is the actual scenario the
    -- "no re-fetch" behavior is about (plain :e on the buffer already
    -- showing is a different, ordinary Vim question).
    child.cmd('enew')
    child.cmd('buffer arcanist://T5')
    eq(#child.calls('call-conduit maniphest.search'), 1) -- no second call at all
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Fix bug')

    child.cmd('edit! arcanist://T5')
    child.wait_until('vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "Fix bug (reloaded)"')
    eq(#child.calls('call-conduit maniphest.search'), 2)
end

T['gf on a reference opens it as an arcanist:// buffer'] = function()
    child.fixture(
        'call-conduit maniphest.search',
        helpers.task_response({ id = 5, title = 'Fix bug', description = 'Steps to reproduce.' })
    )

    local probe = child.dir .. '/probe.rm'
    local f = assert(io.open(probe, 'w'))
    f:write('See T5 for details.\n')
    f:close()
    child.cmd('edit ' .. probe)
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.api.nvim_win_set_cursor(0, { 1, 5 }) -- inside "T5"

    child.type_keys('gf')
    child.wait_until('vim.api.nvim_buf_get_name(0):match("arcanist://T5$") ~= nil')
    -- The buffer switch is synchronous; load_reference's own fetch is not.
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    eq(child.lua_get('vim.b[0].arcanist_loaded ~= nil'), true)
end

T['gf on a wiki link opens it as an arcanist:// buffer'] = function()
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding' })
    )

    local probe = child.dir .. '/probe.rm'
    local f = assert(io.open(probe, 'w'))
    f:write('See [[engineering/onboarding]] for details.\n')
    f:close()
    child.cmd('edit ' .. probe)
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.api.nvim_win_set_cursor(0, { 1, 10 }) -- inside "engineering"

    child.type_keys('gf')
    child.wait_until('vim.api.nvim_buf_get_name(0):match("arcanist://w/engineering/onboarding/$") ~= nil')
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    eq(child.lua_get('vim.b[0].arcanist_loaded ~= nil'), true)
end

T['opening a wiki slug without its trailing slash still resolves and writes'] = function()
    -- Regression test: `phriction.document.search`'s `paths` constraint
    -- does a raw, unnormalized match against the stored (always-slashed)
    -- slug column (unlike `phriction.edit`'s `slug` param, which the server
    -- normalizes itself) -- so ":e arcanist://w/some/slug", typed without
    -- the trailing "/", used to 404 rather than resolve. HANDLERS.W's
    -- `parse` now normalizes it first.
    child.fixture('call-conduit phriction.document.search', {
        __sequence = {
            helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' }),
            helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' }),
        },
    })
    child.fixture('call-conduit phriction.edit', { slug = 'engineering/onboarding/' })

    child.cmd('edit arcanist://w/engineering/onboarding')
    child.wait_until('vim.b[0].arcanist_loaded ~= nil')

    local searches = child.calls('call-conduit phriction.document.search')
    eq(searches[1].params.constraints.paths, { 'engineering/onboarding/' })

    child.lua([[vim.api.nvim_buf_set_lines(0, 0, 1, false, {'Onboarding (edited)'})]])
    child.cmd('write')

    -- is_own recognized the buffer as its own object (see push()) despite
    -- the name it was opened under lacking the trailing slash, so 'modified'
    -- actually clears.
    eq(child.lua_get('vim.bo.modified'), false)
    local edits = child.calls('call-conduit phriction.edit')
    eq(#edits, 1)
    eq(edits[1].params.slug, 'engineering/onboarding/')
end

return T
