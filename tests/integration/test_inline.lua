-- Drives arcanist.inline against the fake `arc`: the "text" preset's live
-- conceal/description tracking (add, remove, duplicate occurrences, cursor
-- reveal), the enable/disable/toggle API, and the "render" side (a custom
-- function preset, and the bundled "snacks" preset's missing-dependency
-- warning -- the real snacks.nvim is not available in this harness, so the
-- happy path through it isn't covered here).

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child, dir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child, dir = helpers.new_child()
            helpers.capture_notify(child)
            -- file.lua's cache dir is computed once from stdpath('cache') at
            -- first require -- redirect it before that first require so the
            -- "render" cases (which download) never touch the real cache.
            child.lua(string.format([[vim.env.XDG_CACHE_HOME = %q]], dir .. '/xdg-cache'))
        end,
        post_case = function()
            helpers.stop(child, dir)
        end,
    },
})

--- A `file.search`-shaped envelope for one file.
--- @param opts { name: string, size: integer, alt: string? }
--- @return table
local function file_response(opts)
    return {
        data = {
            { fields = { name = opts.name, size = opts.size, alt = opts.alt and { default = opts.alt } } },
        },
    }
end

--- Every extmark (with details) in the "arcanist.inline.text" namespace.
--- @return table[]
local function text_extmarks()
    return child.lua_get([[(function()
        local ns = vim.api.nvim_get_namespaces()['arcanist.inline.text']
        return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    end)()]])
end

--- Block until the "arcanist.inline.text" namespace has at least `min`
--- extmarks, or 2s pass.
--- @param min integer
local function wait_for_marks(min)
    child.lua(string.format(
        [[
            vim.wait(2000, function()
                local ns = vim.api.nvim_get_namespaces()['arcanist.inline.text']
                return ns and #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) >= %d
            end, 10)
        ]],
        min
    ))
end

--- Block until `condition_expr` (evaluated inside the child) is true, or
--- 2s pass.
--- @param condition_expr string
local function wait_until(condition_expr)
    child.lua(string.format('vim.wait(2000, function() return %s end, 10)', condition_expr))
end

T['a {F123} reference is concealed and shows Phorge\'s description'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_for_marks(1)

    local marks = text_extmarks()
    eq(#marks, 2) -- one conceal mark, one virtual-text mark
    local shown
    for _, mark in ipairs(marks) do
        local virt = mark[4].virt_text
        if virt then
            shown = virt[1][1]
        end
    end
    eq(shown, 'duck.png (320x200 px, 1 KB)')
end

T['a reference to a missing file draws nothing'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', { data = {} })

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F404} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.lua([[vim.wait(500)]]) -- let the (failing) file.info round-trip finish

    eq(#text_extmarks(), 0)
end

T['inline preview can be toggled per buffer via enable/disable/toggle'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_for_marks(1)
    eq(child.lua_get([[require('arcanist.inline').is_enabled()]]), true)

    child.lua([[require('arcanist.inline').disable()]])
    eq(child.lua_get([[require('arcanist.inline').is_enabled()]]), false)
    eq(#text_extmarks(), 0)

    eq(child.lua_get([[require('arcanist.inline').toggle()]]), true)
    wait_for_marks(1)
    eq(#text_extmarks(), 2)

    eq(child.lua_get([[require('arcanist.inline').toggle()]]), false)
    eq(#text_extmarks(), 0)
end

T['typing a new reference live-adds a placement'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.lua([[vim.wait(200)]]) -- let the initial (empty) sync settle
    eq(#text_extmarks(), 0)

    child.type_keys('A', '{F123}', '<Esc>')
    wait_for_marks(1)

    eq(#text_extmarks(), 2)
end

T['deleting a reference live-removes its placement'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { '{F123}' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_for_marks(1)
    eq(#text_extmarks(), 2)

    child.type_keys('0', 'D')
    child.lua([[vim.wait(300)]])

    eq(#text_extmarks(), 0)
end

T['the same file referenced twice gets two independent placements'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} and also {F123} again.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_for_marks(4)

    eq(#text_extmarks(), 4) -- two conceal marks + two text marks
end

T['moving the cursor onto a concealed monogram hides its description, and away shows it'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { text = true } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500, alt = 'duck.png (320x200 px, 1 KB)' }))

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_for_marks(1)

    -- The text mark is the zero-width point at the reference's *end*
    -- (right after "}"); the conceal mark spans its *start* through there --
    -- so, on one line, the text mark is always the one with the larger
    -- column.
    local function text_virt()
        local marks = text_extmarks()
        table.sort(marks, function(a, b)
            return a[3] < b[3]
        end)
        return marks[#marks][4].virt_text
    end

    eq(text_virt() ~= nil, true) -- cursor starts on column 0, away from the reference

    child.type_keys('f{')
    eq(text_virt(), nil) -- cursor now inside the concealed range

    child.type_keys('0')
    eq(text_virt() ~= nil, true) -- cursor moved away again
end

T['a custom render function receives the downloaded file, closed on disable'] = function()
    child.lua([[
        _G.__render_specs = {}
        _G.__render_closed = 0
        require('arcanist').setup({
            file = {
                inline = {
                    render = function(spec)
                        table.insert(_G.__render_specs, { path = spec.path, monogram = spec.info and spec.info.monogram })
                        return { close = function() _G.__render_closed = _G.__render_closed + 1 end }
                    end,
                },
            },
        })
    ]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500 }))
    helpers.fixture(dir, 'download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    wait_until('#_G.__render_specs > 0')

    local specs = child.lua_get('_G.__render_specs')
    eq(#specs, 1)
    eq(specs[1].monogram, 'F123')
    eq(vim.endswith(specs[1].path, '/F123/duck.png'), true)

    child.lua([[require('arcanist.inline').disable()]])
    eq(child.lua_get('_G.__render_closed'), 1)
end

T['an unknown file.inline.render preset name reports a clear error'] = function()
    -- resolve_render() bails before ever fetching a reference's file, so no
    -- file.search/download fixture is needed for this one to reach place().
    child.lua([[require('arcanist').setup({ file = { inline = { render = 'not-a-real-preset' } } })]])

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.lua([[vim.wait(500)]])

    local log = helpers.notifications(child)
    eq(log[#log].msg, 'arcanist.nvim: file.inline.render: unknown preset "not-a-real-preset"')
end

T['render = "snacks" without snacks.nvim warns once, not once per reference'] = function()
    child.lua([[require('arcanist').setup({ file = { inline = { render = 'snacks' } } })]])
    helpers.fixture(dir, 'call-conduit file.search', file_response({ name = 'duck.png', size = 1500 }))
    helpers.fixture(dir, 'download', { bytes = 'PNGDATA' })

    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'See {F123} and {F456} for details.' })
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.lua([[vim.wait(500)]])

    local warnings = vim.tbl_filter(function(n)
        return n.msg:find('needs snacks.nvim', 1, true) ~= nil
    end, helpers.notifications(child))
    eq(#warnings, 1)
end

return T
