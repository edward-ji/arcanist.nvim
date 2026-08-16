-- Populates "arcanist://T123"-style buffers with a Phorge object's content,
-- fetched live over Conduit, and detects the object_reference (T123,
-- D456, ...) at a given buffer position.
--
-- The buffer scheme itself is populated by a BufReadCmd autocmd -- the same
-- idiom fugitive.nvim uses for "fugitive://" buffers -- regardless of what
-- triggers opening one. That can be `:e arcanist://T123` typed by hand, or
-- `arcanist.lsp`'s textDocument/definition handler (see that module for
-- why), which calls `M.at()` below to resolve the reference under the
-- cursor and then just `vim.cmd.edit()`s the resulting URI. Either way the
-- fetching and rendering happen here, which keeps this module ignorant of
-- LSP entirely.
--
-- Tasks and revisions render as a plain-text document: a bare title line,
-- then one labelled field per section ("Status: Open", "Description:").
-- That format deliberately matches what Phorge's own
-- `differential.getcommitmessage` emits -- the text `arc diff` puts in your
-- editor -- so it stays familiar, survives `:w {file}`, and keeps
-- everything a reader needs in the buffer's own text, with no hidden state
-- behind it.
--
-- Values are shown the way Phorge's web UI shows them ("Needs Triage", not
-- the `triage` keyword its edit API wants), which costs nothing here: the
-- display name is already in the object we fetched.
--
-- Buffers are read-only for now: there's no Conduit write-back wired up
-- yet. Once there is, this switches from 'nofile' to 'acwrite' with a
-- BufWriteCmd that parses these same labels back into an edit transaction.

local conduit = require('arcanist.conduit')

local M = {}

--- Split a remarkup blob into buffer lines. `plain = true` so literal `%`
--- etc. in the text isn't treated as a Lua pattern.
--- @param text string?
--- @return string[]
local function split_lines(text)
    return vim.split(text or '', '\n', { plain = true })
end

--- @param lines string[]
--- @return string[]
local function trim_trailing(lines)
    local last = #lines
    while last > 0 and vim.trim(lines[last]) == '' do
        last = last - 1
    end
    return vim.list_slice(lines, 1, last)
end

--- A field's stored text as buffer lines, with trailing blanks dropped so
--- an empty field renders as nothing rather than a run of blank lines.
--- @param text string?
--- @return string[]
local function body_lines(text)
    return trim_trailing(split_lines(text))
end

--- Parse a bare reference like "T123" into prefix + numeric id, or nil if
--- it doesn't look like one.
--- @param str string
--- @return string? prefix
--- @return integer? id
local function parse_ref(str)
    local prefix, id = str:match('^(%a+)(%d+)$')
    if not prefix then
        return nil
    end
    return prefix, tonumber(id)
end

--- The same, for an "arcanist://<ref>" URI.
--- @param uri string
--- @return string? prefix
--- @return integer? id
local function parse_uri(uri)
    local ref = uri:match('^arcanist://(.+)$')
    if not ref then
        return nil
    end
    return parse_ref(ref)
end

--- `params` for the common case: look an object up by its numeric id.
--- @param id integer
--- @return table
local function by_id(id)
    return { constraints = { ids = { id } } }
end

-- One entry per supported object-reference prefix. `search`/`params` look
-- the object up by id; `filetype` picks how the buffer gets highlighted.
--
-- `fields` renders as a labelled document. Each entry is
-- { key, kind, label?, read }: `read(obj.fields)` pulls the displayed value
-- out of the fetched object. `kind` is 'title' (bare, no label, always
-- first), 'line' (value on the label's own line), or 'block' (label alone,
-- value beneath it).
--
-- `key` is the Conduit transaction type each field maps to, unused while
-- these buffers are read-only but recorded here so the write path doesn't
-- need a second table mapping labels back to fields.
--
-- Only T/D for now -- P/F/M/C/r<repo> refs point at pastes, files, macros,
-- commits, and repositories respectively; left for later.
--- @type table<string, { search: string, params: fun(id: integer): table, fields: table[], filetype: string }>
local HANDLERS = {
    T = {
        search = 'maniphest.search',
        params = by_id,
        filetype = 'remarkup',
        fields = {
            {
                key = 'title',
                kind = 'title',
                read = function(f)
                    return f.name
                end,
            },
            {
                key = 'status',
                kind = 'line',
                label = 'Status',
                read = function(f)
                    return f.status.name
                end,
            },
            {
                key = 'priority',
                kind = 'line',
                label = 'Priority',
                read = function(f)
                    return f.priority.name
                end,
            },
            {
                key = 'description',
                kind = 'block',
                label = 'Description',
                read = function(f)
                    return f.description and f.description.raw
                end,
            },
        },
    },
    D = {
        search = 'differential.revision.search',
        params = by_id,
        filetype = 'remarkup',
        fields = {
            {
                key = 'title',
                kind = 'title',
                read = function(f)
                    return f.title
                end,
            },
            {
                key = 'status',
                kind = 'line',
                label = 'Status',
                read = function(f)
                    return f.status.name
                end,
            },
            {
                key = 'summary',
                kind = 'block',
                label = 'Summary',
                read = function(f)
                    return f.summary
                end,
            },
            {
                key = 'testPlan',
                kind = 'block',
                label = 'Test Plan',
                read = function(f)
                    return f.testPlan
                end,
            },
        },
    },
}

--- @param level integer vim.log.levels.*
--- @param msg string
local function notify(level, msg)
    vim.notify('arcanist.nvim: ' .. msg, level)
end

--- @param msg string
local function notify_err(msg)
    notify(vim.log.levels.ERROR, msg)
end

--- Build a handler's `fields` into buffer lines.
---
--- Blank-line placement is derived rather than spelled out per type: a run
--- of consecutive 'line' fields stays tight ("Status:" directly above
--- "Priority:"), while blocks and the title are always separated from
--- whatever follows. That keeps the layout consistent for any future field
--- list without adding another rule per handler.
--- @param handler table one of HANDLERS' values
--- @param obj table
--- @return string[]
local function render_fields(handler, obj)
    local f = obj.fields
    local lines = {}

    for i, field in ipairs(handler.fields) do
        if i > 1 then
            local prev = handler.fields[i - 1]
            if field.kind == 'block' or prev.kind == 'block' or prev.kind == 'title' then
                table.insert(lines, '')
            end
        end

        local value = field.read(f)
        if field.kind == 'title' then
            table.insert(lines, value or '')
        elseif field.kind == 'line' then
            table.insert(lines, string.format('%s: %s', field.label, value or ''))
        else
            table.insert(lines, field.label .. ':')
            vim.list_extend(lines, body_lines(value))
        end
    end

    return lines
end

--- Replace `bufnr`'s content, then mark it read-only again. Explicitly
--- clears 'readonly' before flipping 'modifiable' on (rather than assuming
--- it's already off) and only sets 'readonly' back once 'modifiable' is
--- off again -- the two are never both true at the same time -- since
--- either ordering mistake trips Vim's "W10: Warning: Changing a readonly
--- file" on our own writes, including on a revisit of an already-loaded
--- "arcanist://" buffer.
--- @param bufnr integer
--- @param lines string[]
local function set_lines(bufnr, lines)
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

--- Populate `bufnr` (already named "arcanist://<ref>") by fetching
--- `prefix`+`id` over Conduit. Asynchronous -- there's no reason to block
--- the editor while a buffer loads.
---
--- Progress and failures are reported through `vim.notify` rather than
--- written into the buffer: a buffer holding the text "Loading T1..." looks
--- exactly like a buffer whose content genuinely is that, and it would be
--- yanked, searched and saved as though it were real content.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param id integer
local function load_reference(bufnr, handler, prefix, id)
    vim.bo[bufnr].buftype = 'nofile'
    -- A swapfile can't do its job here and actively gets in the way: this
    -- BufReadCmd repopulates the buffer from the server on every open, so
    -- recovered content is overwritten the moment the buffer opens, while a
    -- swapfile left behind by a crash makes the next open fail with E325
    -- against a "file" that "CANNOT BE FOUND". netrw disables them for its
    -- remote buffers for the same reason.
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    notify(vim.log.levels.INFO, string.format('loading %s%d...', prefix, id))

    conduit.call(handler.search, handler.params(id), function(ok, response, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if not ok then
            -- Cleared rather than left as-is: this may be a reload of a
            -- buffer that already held content, and stale content sitting
            -- under an error notification is worse than an empty buffer.
            set_lines(bufnr, {})
            notify_err(string.format('failed to load %s%d: %s', prefix, id, err))
            return
        end

        local obj = response.data[1]
        if not obj then
            set_lines(bufnr, {})
            notify_err(string.format('%s%d not found', prefix, id))
            return
        end

        vim.bo[bufnr].filetype = handler.filetype
        set_lines(bufnr, render_fields(handler, obj))
    end)
end

--- Return the "arcanist://<ref>" URI for the object_reference node at the
--- (0-indexed, byte-offset) `row`/`col` in `bufnr`, or nil if there isn't
--- one there, or it's a type we don't support opening yet.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? uri
function M.at(bufnr, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'remarkup')
    if not ok then
        return nil
    end
    -- get_node() needs an up-to-date tree; the LSP request that calls this
    -- may land before any redraw has triggered a parse.
    parser:parse()

    local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
    if not node or node:type() ~= 'object_reference' then
        return nil
    end

    -- Drop a trailing "#123" comment anchor (as in "T123#456") -- opens the
    -- object itself; jumping straight to the anchored comment is future
    -- work.
    local text = vim.treesitter.get_node_text(node, bufnr):match('^[^#]+')
    local prefix, id = parse_ref(text)
    if not (prefix and HANDLERS[prefix]) then
        return nil
    end

    return string.format('arcanist://%s%d', prefix, id)
end

--- Install the "arcanist://" buffer scheme handler. Idempotent -- safe to
--- call from plugin/ at startup and again from every remarkup buffer;
--- `clear = true` drops any autocmd from a prior call before this adds
--- exactly one back.
function M.setup()
    local augroup = vim.api.nvim_create_augroup('arcanist.reference', { clear = true })

    vim.api.nvim_create_autocmd('BufReadCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            local prefix, id = parse_uri(args.match)
            local handler = prefix and HANDLERS[prefix]
            if not handler then
                notify_err('cannot open ' .. args.match)
                return
            end
            load_reference(args.buf, handler, prefix, id)
        end,
    })
end

return M
