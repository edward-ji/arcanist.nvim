-- Drives arcanist.nvim's local-draft feature (`config.drafts.enabled`)
-- against the fake `arc`: a first open redirects to a local draft file,
-- revisiting it reads straight from disk with no network at all, and
-- ":ArcWrite" from a draft buffer still pushes to the server, refusing when
-- the object's "Last Modified:" says it was edited on the web meanwhile.
--
-- Uses revisions (D-type), not tasks: every one of their writable fields
-- is plain `fields.TEXT` (no Status/Priority `value_source` lookups to
-- fixture), which keeps what a from-draft push sends simple to assert on.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()
local drafts_dir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            drafts_dir = child.dir .. '/drafts'
            child.lua(string.format(
                [[require('arcanist').setup({ drafts = { enabled = true, dir = %q } })]],
                drafts_dir
            ))
        end,
        post_case = child.teardown,
    },
})

--- Open "arcanist://<ref>" and wait for the redirect to its draft file.
--- @param ref string e.g. "D2"
local function open_draft(ref)
    child.cmd('edit arcanist://' .. ref)
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/' .. ref))
end

--- The draft buffer's last line.
--- @return string
local function last_line()
    return child.lua_get('vim.api.nvim_buf_get_lines(0, -2, -1, false)')[1]
end

T['opening an object with drafts on redirects to a local draft file'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision', summary = 'Summary.', testPlan = 'Plan.' })
    )

    child.cmd('edit arcanist://D2')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))

    eq(child.lua_get('vim.bo.buftype'), '')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision')
end

T['revisiting an existing draft reads it from disk with no Conduit call'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )

    child.cmd('edit arcanist://D2')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))
    eq(#child.calls('call-conduit differential.revision.search'), 1)

    child.cmd('bwipeout')
    child.cmd('edit arcanist://D2')
    child.lua([[vim.wait(300)]])

    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), drafts_dir .. '/D2')
    eq(#child.calls('call-conduit differential.revision.search'), 1) -- still just the one
end

T[':ArcWrite from a draft buffer pushes to the server'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision', summary = 'Summary.', testPlan = 'Plan.' })
    )
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    child.cmd('edit arcanist://D2')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))

    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    local edits = child.calls('call-conduit differential.revision.edit')
    eq(#edits, 1)
    eq(edits[1].params, {
        objectIdentifier = 'D2',
        transactions = { { type = 'title', value = 'My revision (edited)' } },
    })
    -- Load, the "Last Modified:" check, and the read-back of the new one.
    eq(#child.calls('call-conduit differential.revision.search'), 3)
end

T[':ArcWrite on an unedited draft sends nothing'] = function()
    child.capture_notify()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision', summary = 'Summary.', testPlan = 'Plan.' })
    )

    open_draft('D2')
    child.cmd('ArcWrite')

    eq(#child.calls('call-conduit differential.revision.edit'), 0)
    eq(child.last_notification(), 'arcanist.nvim: D2: no changes to update')
end

T[':ArcWrite refuses a draft whose object was edited on the web since it was fetched'] = function()
    child.capture_notify()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'Edited on the web', modified = helpers.MODIFIED + 60 }),
        },
    })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(#child.calls('call-conduit differential.revision.edit'), 0)
    eq(
        child.last_notification(),
        'arcanist.nvim: D2 changed on the server since 2026-09-21T14:13:20Z. Your edits are still '
            .. 'here; :w {file} to keep a copy, then :e! arcanist://D2 to refetch -- or :ArcWrite! '
            .. "to overwrite the server's version"
    )
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision (edited)')
end

T[':ArcWrite! pushes a draft even though its object was edited on the web'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision', summary = 'Summary.' }),
            helpers.revision_response({
                id = 2,
                title = 'Edited on the web',
                summary = 'Summary.',
                modified = helpers.MODIFIED + 60,
            }),
            helpers.revision_response({
                id = 2,
                title = 'My revision',
                summary = 'Summary (edited).',
                modified = helpers.MODIFIED + 120,
            }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.cmd('/^Summary\\./')
    child.type_keys('A', '<BS> (edited).', '<Esc>')
    child.cmd('ArcWrite!')

    -- The web's title is overwritten; the untouched test plan isn't sent.
    eq(child.calls('call-conduit differential.revision.edit')[1].params.transactions, {
        { type = 'title', value = 'My revision' },
        { type = 'summary', value = 'Summary (edited).' },
    })
    eq(last_line(), 'Last Modified: 2026-09-21T14:15:20Z')
end

T["a push moves the draft's Last Modified up, for the next :w to save"] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision (edited)', modified = helpers.MODIFIED + 60 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(last_line(), 'Last Modified: 2026-09-21T14:14:20Z')
    eq(child.lua_get('vim.bo.modified'), true)
    child.cmd('write')
    local saved = vim.fn.readfile(drafts_dir .. '/D2')
    eq(saved[#saved], 'Last Modified: 2026-09-21T14:14:20Z')
end

T['undoing past a push does not make the next :ArcWrite look stale'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision (edited)', modified = helpers.MODIFIED + 60 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')
    child.type_keys('u')
    eq(last_line(), 'Last Modified: 2026-09-21T14:13:20Z') -- the line's own undo step

    child.type_keys('gg', 'A', ' again', '<Esc>')
    child.cmd('ArcWrite')

    eq(#child.calls('call-conduit differential.revision.edit'), 2)
end

T['a draft without a Last Modified line pushes even if its object was edited on the web'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'Edited on the web', modified = helpers.MODIFIED + 60 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.cmd('$delete')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(child.calls('call-conduit differential.revision.edit')[1].params.transactions, {
        { type = 'title', value = 'My revision (edited)' },
    })
end

T['a wiki document with drafts on redirects to a nested draft path'] = function()
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 9, slug = 'engineering/onboarding/', title = 'Onboarding', content = 'Welcome.' })
    )

    child.cmd('edit arcanist://w/engineering/onboarding/')
    -- Nested under the slug's own segments, "#"-marked leaf and all -- not
    -- one flat "w#engineering#onboarding#" file -- so the buffer name (and
    -- a directory listing) still read as the slug itself. See draft.lua's
    -- M.path for why the leaf can't just be "onboarding".
    child.wait_until(string.format(
        'vim.api.nvim_buf_get_name(0) == %q',
        drafts_dir .. '/w/engineering/onboarding#'
    ))

    eq(child.lua_get('vim.bo.buftype'), '')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Onboarding')
end

T['gf on a relative wiki link resolves from a draft buffer, not just a live one'] = function()
    -- Regression test: wiki_base() (lua/arcanist/reference.lua) used to read
    -- vim.b[bufnr].arcanist_loaded, which is only ever set on a *live*
    -- "arcanist://" buffer's own render -- never on the draft file
    -- redirect_to_draft hands off to. With drafts on (the common case),
    -- that made a relative link's own page silently unresolvable: exactly
    -- what this test is here to catch if it regresses.
    child.fixture('call-conduit phriction.document.search', {
        __sequence = {
            helpers.wiki_response({
                id = 9,
                slug = 'engineering/onboarding/',
                title = 'Onboarding',
                content = 'See also [[../setup]].',
            }),
            helpers.wiki_response({ id = 10, slug = 'engineering/setup/', title = 'Setup' }),
        },
    })

    child.cmd('edit arcanist://w/engineering/onboarding/')
    child.wait_until(string.format(
        'vim.api.nvim_buf_get_name(0) == %q',
        drafts_dir .. '/w/engineering/onboarding#'
    ))
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.api.nvim_win_set_cursor(0, { 4, 15 }) -- inside "../setup" on "See also [[../setup]]."

    child.type_keys('gf')
    child.wait_until(string.format(
        'vim.api.nvim_buf_get_name(0) == %q',
        drafts_dir .. '/w/engineering/setup#'
    ))

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Setup')
end

T['the wiki root and a page under it each get their own draft'] = function()
    child.fixture('call-conduit phriction.document.search', {
        __sequence = {
            helpers.wiki_response({ id = 1, slug = '/', title = 'Wiki Home' }),
            helpers.wiki_response({ id = 9, slug = 'engineering/', title = 'Engineering' }),
        },
    })

    child.cmd('edit arcanist://w/')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/w#'))
    child.cmd('edit arcanist://w/engineering/')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/w/engineering#'))

    eq(vim.fn.readfile(drafts_dir .. '/w#')[1], 'Wiki Home')
    eq(vim.fn.readfile(drafts_dir .. '/w/engineering#')[1], 'Engineering')
end

--- Record `confirm()` and answer it with `_G.__confirm_answer`: Esc unless a
--- test picks one. The real one would block the child forever.
local function stub_confirm()
    child.lua([[vim.fn.confirm = function(msg, choices, default)
        _G.__confirm = { msg = msg, choices = choices, default = default }
        return _G.__confirm_answer or 0
    end]])
end

T['check_on_open'] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.capture_notify()
            stub_confirm()
            child.lua(string.format(
                [[require('arcanist').setup({ drafts = { enabled = true, dir = %q, check_on_open = true } })]],
                drafts_dir
            ))
        end,
    },
})

T['prompt_on_stale'] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.capture_notify()
            stub_confirm()
            child.lua(string.format(
                [[require('arcanist').setup({
                    drafts = { enabled = true, dir = %q, check_on_open = true, prompt_on_stale = true },
                })]],
                drafts_dir
            ))
        end,
    },
})

local EDITED_ON_THE_WEB = {
    __sequence = {
        helpers.revision_response({ id = 2, title = 'My revision' }),
        helpers.revision_response({ id = 2, title = 'Edited on the web', modified = helpers.MODIFIED + 60 }),
    },
}

local CHANGED_WARNING = 'arcanist.nvim: D2 changed on the server'

local CHANGED_PROMPT = {
    msg = 'D2 changed on the server since 2026-09-21T14:13:20Z.\n'
        .. "Replace this draft with the server's version?",
    choices = '&Yes\n&No',
    default = 2,
}

--- Block until the fake `arc` has seen `count` revision searches, then long
--- enough for a response to come back and be acted on.
--- @param count integer
local function wait_for_searches(count)
    child.wait_until(function()
        return #child.calls('call-conduit differential.revision.search') >= count
    end)
    child.lua([[vim.wait(300)]])
end

--- Block until the changed-on-the-server prompt has been shown.
local function wait_for_prompt()
    child.wait_until('_G.__confirm ~= nil')
end

T['check_on_open']['reopening a draft warns when its object was edited on the web'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    child.wait_for_notification('changed on the server')

    eq(child.last_notification(), CHANGED_WARNING)
    eq(child.lua_get('_G.__confirm == nil'), true)
    -- Longer than this and it would stop at hit-enter, even mid-typing.
    eq(#child.last_notification() <= child.lua_get('vim.v.echospace'), true)
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision (edited)')
    eq(#child.calls('call-conduit differential.revision.search'), 2)
end

T['prompt_on_stale']['reopening a draft asks when its object was edited on the web'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    wait_for_prompt()

    eq(child.lua_get('_G.__confirm'), CHANGED_PROMPT)
    eq(#child.calls('call-conduit differential.revision.search'), 2)
end

T['prompt_on_stale']['answering no on open keeps the draft and its edits'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.lua('_G.__confirm_answer = 2')

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    wait_for_prompt()

    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision (edited)')
    eq(vim.fn.readfile(drafts_dir .. '/D2')[1], 'My revision (edited)')
end

T['prompt_on_stale']["answering yes on open puts the server's version in the buffer"] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.lua('_G.__confirm_answer = 1')

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    child.wait_for_notification('replaced')

    eq(child.last_notification(), 'arcanist.nvim: D2 replaced; :w to save it, u to undo')
    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), drafts_dir .. '/D2')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Edited on the web')
    eq(last_line(), 'Last Modified: 2026-09-21T14:14:20Z')
    eq(child.lua_get('vim.bo.modified'), true)

    child.cmd('write')
    eq(vim.fn.readfile(drafts_dir .. '/D2')[1], 'Edited on the web')
end

T['prompt_on_stale']['a stray yes on open can be undone, and leaves the file alone'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.lua('_G.__confirm_answer = 1')

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    child.wait_for_notification('replaced')

    eq(vim.fn.readfile(drafts_dir .. '/D2')[1], 'My revision (edited)')
    child.type_keys('u')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision (edited)')
    eq(child.lua_get('vim.bo.modified'), false)
end

T['prompt_on_stale']['answering yes keeps other windows on the draft open'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.lua('_G.__confirm_answer = 1')

    open_draft('D2')
    child.cmd('split')
    child.cmd('edit arcanist://D2')
    child.wait_for_notification('replaced')

    eq(#child.lua_get('vim.api.nvim_tabpage_list_wins(0)'), 2)
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'Edited on the web')
end

T['check_on_open']['reopening a draft whose object is unchanged says nothing'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )

    open_draft('D2')
    child.cmd('bwipeout')
    open_draft('D2')
    wait_for_searches(2)

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(child.notifications(), { { msg = 'arcanist.nvim: loading D2...', level = child.lua_get('vim.log.levels.INFO') } })
end

T['check_on_open']['a comment on an object the draft still matches says nothing'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision', modified = helpers.MODIFIED + 60 }),
        },
    })

    open_draft('D2')
    child.cmd('bwipeout')
    open_draft('D2')
    wait_for_searches(2)

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(child.notifications(), { { msg = 'arcanist.nvim: loading D2...', level = child.lua_get('vim.log.levels.INFO') } })
end

T['check_on_open'][':ArcWrite on a draft matching a commented object lets the next edit through'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision', modified = helpers.MODIFIED + 60 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.cmd('ArcWrite')
    eq(child.last_notification(), 'arcanist.nvim: D2: no changes to update')
    eq(last_line(), 'Last Modified: 2026-09-21T14:14:20Z')
    eq(child.lua_get('vim.bo.modified'), true)

    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')
    eq(child.calls('call-conduit differential.revision.edit')[1].params.transactions, {
        { type = 'title', value = 'My revision (edited)' },
    })
end

T['check_on_open']['opening a draft by its file path warns too'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)

    open_draft('D2')
    child.cmd('bwipeout')
    child.cmd('edit ' .. drafts_dir .. '/D2')
    child.wait_for_notification('changed on the server')

    eq(child.last_notification(), CHANGED_WARNING)
end

T['check_on_open']['going back to a draft still loaded in a buffer warns too'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)

    open_draft('D2')
    child.cmd('enew')
    open_draft('D2')
    child.wait_for_notification('changed on the server')

    eq(child.last_notification(), CHANGED_WARNING)
end

T['prompt_on_stale']['leaving the draft before the check lands gets a message, not a prompt'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            { __control = {
                delay_ms = 500,
                value = helpers.revision_response({ id = 2, title = 'Edited', modified = helpers.MODIFIED + 60 }),
            } },
        },
    })

    open_draft('D2')
    child.cmd('enew')
    open_draft('D2')
    child.cmd('enew')
    child.wait_for_notification('changed on the server')

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(child.last_notification(), CHANGED_WARNING)
end

T['check_on_open']['a first open and an :e! fetch once each, with nothing left to check'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )

    open_draft('D2')
    wait_for_searches(1)
    eq(#child.calls('call-conduit differential.revision.search'), 1)

    child.cmd('edit! arcanist://D2')
    wait_for_searches(2)
    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), drafts_dir .. '/D2')
    eq(#child.calls('call-conduit differential.revision.search'), 2)
end

T['check_on_open']['a draft whose object is gone says so'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = { helpers.revision_response({ id = 2, title = 'My revision' }), { data = {} } },
    })

    open_draft('D2')
    child.cmd('bwipeout')
    open_draft('D2')
    child.wait_for_notification('no longer exists')

    eq(child.last_notification(), 'arcanist.nvim: D2 no longer exists on the server')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision')
end

T['check_on_open']['a failed check says so and still opens the draft'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )

    open_draft('D2')
    child.cmd('bwipeout')
    vim.fn.delete(child.dir .. '/responses.json')
    open_draft('D2')
    child.wait_for_notification('could not check')

    eq(child.last_notification():find('arcanist.nvim: could not check D2 for changes: ', 1, true), 1)
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision')
end

T['check_on_open']['a draft with nothing to compare makes no request'] = function()
    child.fixture(
        'call-conduit phriction.document.search',
        helpers.wiki_response({ id = 9, slug = 'engineering/', title = 'Engineering' })
    )
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )

    -- Phorge dates no wiki document.
    child.cmd('edit arcanist://w/engineering/')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/w/engineering#'))
    child.cmd('bwipeout')
    child.cmd('edit arcanist://w/engineering/')
    child.wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/w/engineering#'))
    child.lua([[vim.wait(300)]])
    eq(#child.calls('call-conduit phriction.document.search'), 1)

    -- Deleting the line opts a dated draft out of the check.
    open_draft('D2')
    child.cmd('$delete')
    child.cmd('write')
    child.cmd('bwipeout')
    open_draft('D2')
    child.lua([[vim.wait(300)]])
    eq(#child.calls('call-conduit differential.revision.search'), 1)
end

local OVERWRITE_PROMPT = {
    msg = 'D2 changed on the server since 2026-09-21T14:13:20Z.\n'
        .. "Overwrite the server's version with this text?",
    choices = '&Yes\n&No',
    default = 2,
}

T['prompt_on_stale'][':ArcWrite asks, and answering yes overwrites the edit made on the web'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = {
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'Edited on the web', modified = helpers.MODIFIED + 60 }),
            helpers.revision_response({ id = 2, title = 'My revision (edited)', modified = helpers.MODIFIED + 120 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })
    child.lua('_G.__confirm_answer = 1')

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(child.lua_get('_G.__confirm'), OVERWRITE_PROMPT)
    eq(child.calls('call-conduit differential.revision.edit')[1].params.transactions, {
        { type = 'title', value = 'My revision (edited)' },
    })
    eq(last_line(), 'Last Modified: 2026-09-21T14:15:20Z')
    local log = child.notifications()
    eq(log[#log - 1].msg, 'arcanist.nvim: updating D2...')
    eq(log[#log].msg, 'arcanist.nvim: updated D2')
end

T['prompt_on_stale'][':ArcWrite answered no sends nothing and keeps the edits'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.lua('_G.__confirm_answer = 2')

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(child.lua_get('_G.__confirm'), OVERWRITE_PROMPT)
    eq(#child.calls('call-conduit differential.revision.edit'), 0)
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision (edited)')
    eq(child.lua_get('vim.bo.modified'), true)
    eq(child.last_notification(), 'arcanist.nvim: loading D2...') -- no "updating D2..."
end

T['prompt_on_stale'][':ArcWrite! pushes without asking'] = function()
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite!')

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(#child.calls('call-conduit differential.revision.edit'), 1)
end

T['prompt_on_stale'][':ArcWrite on an object that is gone refuses without asking'] = function()
    child.fixture('call-conduit differential.revision.search', {
        __sequence = { helpers.revision_response({ id = 2, title = 'My revision' }), { data = {} } },
    })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(child.last_notification(), 'arcanist.nvim: D2 no longer exists')
end

T['prompt_on_stale']['does not check on open by itself'] = function()
    child.lua(string.format(
        [[require('arcanist').setup({ drafts = { enabled = true, dir = %q, prompt_on_stale = true } })]],
        drafts_dir
    ))
    child.fixture('call-conduit differential.revision.search', EDITED_ON_THE_WEB)

    open_draft('D2')
    child.cmd('bwipeout')
    open_draft('D2')
    child.lua([[vim.wait(300)]])

    eq(child.lua_get('_G.__confirm == nil'), true)
    eq(#child.calls('call-conduit differential.revision.search'), 1)
end

return T
