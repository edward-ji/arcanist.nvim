-- Drives arcanist.nvim's local-draft feature (`config.drafts.enabled`)
-- against the fake `arc`: a first open redirects to a local draft file,
-- revisiting it reads straight from disk with no network at all, and
-- ":ArcWrite" from a draft buffer still pushes to the server.
--
-- Uses revisions (D-type), not tasks: every one of their writable fields
-- is plain `fields.TEXT` (no Status/Priority `value_source` lookups to
-- fixture), which keeps a from-draft push's "no baseline, so every field
-- is sent" behavior (see push()'s doc comment) simple to assert on.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child, dir, drafts_dir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child, dir = helpers.new_child()
            drafts_dir = dir .. '/drafts'
            child.lua(string.format(
                [[require('arcanist').setup({ drafts = { enabled = true, dir = %q } })]],
                drafts_dir
            ))
        end,
        post_case = function()
            helpers.stop(child, dir)
        end,
    },
})

--- A `differential.revision.search`-shaped envelope for one revision.
--- @param opts { id: integer, title: string, summary: string?, testPlan: string? }
--- @return table
local function revision_response(opts)
    return {
        data = {
            { id = opts.id, fields = { title = opts.title, summary = opts.summary or '', testPlan = opts.testPlan or '' } },
        },
    }
end

--- Block until `condition_expr` (evaluated inside the child) is true, or
--- 2s pass.
--- @param condition_expr string
local function wait_until(condition_expr)
    child.lua(string.format('vim.wait(2000, function() return %s end, 10)', condition_expr))
end

--- Every recorded call matching `key`.
--- @param key string
--- @return table[]
local function calls(key)
    return vim.tbl_filter(function(call)
        return call.key == key
    end, helpers.calls(dir))
end

T['opening an object with drafts on redirects to a local draft file'] = function()
    helpers.fixture(
        dir,
        'call-conduit differential.revision.search',
        revision_response({ id = 2, title = 'My revision', summary = 'Summary.', testPlan = 'Plan.' })
    )

    child.cmd('edit arcanist://D2')
    wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))

    eq(child.lua_get('vim.bo.buftype'), '')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, 1, false)')[1], 'My revision')
end

T['revisiting an existing draft reads it from disk with no Conduit call'] = function()
    helpers.fixture(
        dir,
        'call-conduit differential.revision.search',
        revision_response({ id = 2, title = 'My revision' })
    )

    child.cmd('edit arcanist://D2')
    wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))
    eq(#calls('call-conduit differential.revision.search'), 1)

    child.cmd('bwipeout')
    child.cmd('edit arcanist://D2')
    child.lua([[vim.wait(300)]])

    eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), drafts_dir .. '/D2')
    eq(#calls('call-conduit differential.revision.search'), 1) -- still just the one
end

T[':ArcWrite from a draft buffer pushes to the server'] = function()
    helpers.fixture(
        dir,
        'call-conduit differential.revision.search',
        revision_response({ id = 2, title = 'My revision', summary = 'Summary.', testPlan = 'Plan.' })
    )
    helpers.fixture(dir, 'call-conduit differential.revision.edit', { object = { id = 2 } })

    child.cmd('edit arcanist://D2')
    wait_until(string.format('vim.api.nvim_buf_get_name(0) == %q', drafts_dir .. '/D2'))

    child.type_keys('gg', 'A', ' (edited)', '<Esc>')
    child.cmd('ArcWrite')
    child.lua([[vim.wait(300)]])

    local edits = calls('call-conduit differential.revision.edit')
    eq(#edits, 1)
    eq(edits[1].params, {
        objectIdentifier = 'D2',
        transactions = {
            { type = 'title', value = 'My revision (edited)' },
            { type = 'summary', value = 'Summary.' },
            { type = 'testPlan', value = 'Plan.' },
        },
    })
    -- A draft push has no baseline to conflict-check or refresh against.
    eq(#calls('call-conduit differential.revision.search'), 1)
end

return T
