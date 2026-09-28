-- Drives arcanist.nvim's local-draft feature (`config.drafts.enabled`)
-- against the fake `arc`: a first open redirects to a local draft file,
-- revisiting it reads straight from disk with no network at all, and
-- ":ArcWrite" from a draft buffer still pushes to the server, refusing when
-- the object's "Last Modified:" says it was edited on the web meanwhile.
--
-- Uses revisions (D-type), not tasks: every one of their writable fields
-- is plain `fields.TEXT` (no Status/Priority `value_source` lookups to
-- fixture), which keeps a from-draft push's "no baseline, so every field
-- is sent" behavior (see push()'s doc comment) simple to assert on.

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
        transactions = {
            { type = 'title', value = 'My revision (edited)' },
            { type = 'summary', value = 'Summary.' },
            { type = 'testPlan', value = 'Plan.' },
            { type = 'projects.set', value = {} },
        },
    })
    -- Load, the "Last Modified:" check, and the read-back of the new one.
    eq(#child.calls('call-conduit differential.revision.search'), 3)
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
            helpers.revision_response({ id = 2, title = 'My revision' }),
            helpers.revision_response({ id = 2, title = 'My revision (edited)', modified = helpers.MODIFIED + 60 }),
        },
    })
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite!')

    eq(#child.calls('call-conduit differential.revision.edit'), 1)
    eq(last_line(), 'Last Modified: 2026-09-21T14:14:20Z')
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

T['a draft without a Last Modified line pushes without checking the server'] = function()
    child.fixture(
        'call-conduit differential.revision.search',
        helpers.revision_response({ id = 2, title = 'My revision' })
    )
    child.fixture('call-conduit differential.revision.edit', { object = { id = 2 } })

    open_draft('D2')
    child.cmd('$delete')
    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')

    eq(#child.calls('call-conduit differential.revision.edit'), 1)
    eq(#child.calls('call-conduit differential.revision.search'), 1) -- just the load
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

return T
