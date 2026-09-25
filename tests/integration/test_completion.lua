-- Drives arcanist.completion's items_at() directly -- not through a full
-- LSP completion round-trip driven via Neovim's own UI, which stays out of
-- scope here -- to cover its one directly configurable axis: which
-- vim.lsp.protocol.CompletionItemKind config.completion.mention_kind/
-- project_kind map an "@mention"/"#project" completion onto.

local helpers = dofile('tests/integration/helpers.lua')

local eq = MiniTest.expect.equality

local child = helpers.new_child()

local T = MiniTest.new_set({
    hooks = {
        pre_case = child.setup,
        post_case = child.teardown,
    },
})

--- Open a scratch remarkup buffer with one line of text, cursor at its end.
--- @param line string
local function open_with_line(line)
    child.cmd('enew')
    child.lua([[vim.bo.filetype = 'remarkup']])
    child.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    child.api.nvim_win_set_cursor(0, { 1, #line })
end

--- Call arcanist.completion.items_at() for the current buffer/cursor and
--- return its callback's three values, waiting out the module's own
--- query-debounce (125ms) and its Conduit round-trip.
--- @return table items
--- @return integer? start_col
--- @return { live: boolean, kind: integer }? opts
local function items_at()
    local result = child.lua_get([[(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local got
        require('arcanist.completion').items_at(bufnr, row - 1, col, function(items, start_col, opts)
            got = { items = items, start_col = start_col, opts = opts }
        end)
        vim.wait(2000, function() return got ~= nil end, 10)
        return got
    end)()]])
    return result.items, result.start_col, result.opts
end

T['@mention completions use the default mention_kind'] = function()
    child.fixture('call-conduit user.search', {
        data = { { fields = { username = 'lincoln', realName = 'Abraham Lincoln' } } },
    })
    open_with_line('@linc')

    local items, start_col, opts = items_at()

    eq(#items, 1)
    eq(items[1].text, 'lincoln')
    eq(start_col, 1)
    eq(opts.kind, vim.lsp.protocol.CompletionItemKind['Reference'])
end

T['#project completions use the default project_kind'] = function()
    child.fixture('call-conduit project.search', {
        data = {
            {
                fields = { name = 'Quality Assurance', status = 'active' },
                attachments = { slugs = { slugs = { { slug = 'qa' } } } },
            },
        },
    })
    open_with_line('#qa')

    local items, _, opts = items_at()

    eq(#items, 1)
    eq(items[1].text, 'qa')
    eq(opts.kind, vim.lsp.protocol.CompletionItemKind['Module'])
end

T['a custom mention_kind/project_kind is reflected in each completion'] = function()
    child.lua([[require('arcanist').setup({
        completion = { mention_kind = 'Function', project_kind = 'Class' },
    })]])
    child.fixture('call-conduit user.search', {
        data = { { fields = { username = 'lincoln', realName = 'Abraham Lincoln' } } },
    })
    child.fixture('call-conduit project.search', {
        data = {
            {
                fields = { name = 'Quality Assurance', status = 'active' },
                attachments = { slugs = { slugs = { { slug = 'qa' } } } },
            },
        },
    })

    open_with_line('@linc')
    local _, _, mention_opts = items_at()
    eq(mention_opts.kind, vim.lsp.protocol.CompletionItemKind['Function'])

    open_with_line('#qa')
    local _, _, project_opts = items_at()
    eq(project_opts.kind, vim.lsp.protocol.CompletionItemKind['Class'])
end

return T
