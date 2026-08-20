-- Populates "arcanist://T123"-style buffers with a Phorge object's content,
-- fetched live over Conduit, writes edits back on `:w`, and detects the
-- object_reference (T123, D456, ...) at a given buffer position.
--
-- The buffer scheme itself is driven by BufReadCmd/BufWriteCmd autocmds on
-- "arcanist://*" -- the idiom fugitive.nvim uses for "fugitive://" -- so
-- reading and writing happen here regardless of how a buffer was reached:
-- `:e`/`:w arcanist://T123` typed by hand, `arcanist.lsp`'s
-- textDocument/definition handler (see that module for why) resolving a
-- reference under the cursor via `M.at()`, or `:ArcWrite`.
--
-- Rendering and parsing are `arcanist.fields`' job -- see that module for
-- the plain-text format and why every declared field is fully editable.

local conduit = require('arcanist.conduit')
local fields = require('arcanist.fields')

local M = {}

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

local STATUS = fields.value_source({
    method = 'maniphest.status.search',
    display = function(item)
        return item.name
    end,
    value = function(item)
        return item.value
    end,
    aliases = function(item)
        return { item.value }
    end,
})

--- A task's `fields.priority` reads back as { value = 90, name = "Needs
--- Triage" } but `maniphest.edit` rejects both of those on write -- it
--- wants a keyword ("triage") that appears nowhere in the read response.
--- Confirmed live: posting the display name back verbatim fails with a
--- clear "not a valid task priority" error listing the real keywords.
local PRIORITY = fields.value_source({
    method = 'maniphest.priority.search',
    display = function(item)
        return item.name
    end,
    value = function(item)
        return item.keywords[1]
    end,
    aliases = function(item)
        return item.keywords
    end,
})

-- One entry per supported object-reference prefix. `search`/`params`/`edit`
-- are the Conduit methods to look an object up and write it back;
-- `filetype` picks how the buffer gets highlighted; `fields` (see
-- arcanist.fields) is the document schema.
--
-- Only T/D for now -- P/F/M/C/r<repo> refs point at pastes, files, macros,
-- commits, and repositories respectively; left for later.
--- @type table<string, { search: string, edit: string, params: fun(id: integer): table, filetype: string, fields: table[] }>
local HANDLERS = {
    T = {
        search = 'maniphest.search',
        edit = 'maniphest.edit',
        params = by_id,
        filetype = 'remarkup',
        fields = {
            {
                key = 'title',
                kind = 'title',
                write = fields.TEXT,
                read = function(f)
                    return f.name
                end,
            },
            {
                key = 'status',
                kind = 'line',
                label = 'Status',
                write = STATUS,
                read = function(f)
                    return f.status.name
                end,
            },
            {
                key = 'priority',
                kind = 'line',
                label = 'Priority',
                write = PRIORITY,
                read = function(f)
                    return f.priority.name
                end,
            },
            {
                key = 'description',
                kind = 'block',
                label = 'Description',
                write = fields.TEXT,
                read = function(f)
                    return f.description and f.description.raw
                end,
            },
        },
    },
    D = {
        search = 'differential.revision.search',
        edit = 'differential.revision.edit',
        params = by_id,
        filetype = 'remarkup',
        fields = {
            {
                key = 'title',
                kind = 'title',
                write = fields.TEXT,
                read = function(f)
                    return f.title
                end,
            },
            {
                key = 'summary',
                kind = 'block',
                label = 'Summary',
                write = fields.TEXT,
                read = function(f)
                    return f.summary
                end,
            },
            {
                key = 'testPlan',
                kind = 'block',
                label = 'Test Plan',
                write = fields.TEXT,
                read = function(f)
                    return f.testPlan
                end,
            },
        },
        -- Deliberately no Status field: differential.revision.edit has no
        -- transaction for it at all (confirmed live -- it errors "invalid
        -- type \"status\""). Status there only moves as a side effect of
        -- workflow verbs (accept/reject/abandon/...), which is a different
        -- feature from editing a text field, so it's left out rather than
        -- shown and silently rejected.
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

--- Look up `prefix`'s handler, notifying (as `action`, e.g. "open"/"write")
--- and returning nil if it's unsupported. `ref_str` only names the target
--- in the error message (e.g. "arcanist://T123").
--- @param prefix string?
--- @param ref_str string
--- @param action string
--- @return table? handler
local function resolve_handler(prefix, ref_str, action)
    local handler = prefix and HANDLERS[prefix]
    if not handler then
        notify_err(string.format('cannot %s %s', action, ref_str))
        return nil
    end
    return handler
end

--- The handler for `bufnr` if it's a loaded "arcanist://" buffer of a
--- supported type, else nil. Lets `arcanist.completion` find a buffer's
--- field schema without its own copy of the URI/HANDLERS lookup.
--- @param bufnr integer
--- @return table? handler
function M.handler_for(bufnr)
    local prefix = parse_uri(vim.api.nvim_buf_get_name(bufnr))
    return prefix and HANDLERS[prefix]
end

--- Fetch `prefix`+`id` synchronously.
--- @param handler table one of HANDLERS' values
--- @param id integer
--- @return table? obj
--- @return string? err
local function fetch_sync(handler, id)
    local config = require('arcanist').config
    local ok, response, err = conduit.call_sync(handler.search, handler.params(id), config.conduit_timeout)
    if not ok then
        return nil, err
    end
    return response.data[1], nil
end

--- Replace `bufnr`'s content without leaving it dirty.
---
--- For a failed/loading buffer (`editable = false`), explicitly clears
--- 'readonly' before flipping 'modifiable' on (rather than assuming it's
--- already off) and only sets 'readonly' back once 'modifiable' is off
--- again -- the two are never both true at the same time -- since either
--- ordering mistake trips Vim's "W10: Warning: Changing a readonly file"
--- on our own writes, including on a revisit of an already-loaded buffer.
--- @param bufnr integer
--- @param lines string[]
--- @param editable boolean
local function set_lines(bufnr, lines, editable)
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    if not editable then
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
    end
end

--- Populate `bufnr` (already named "arcanist://<ref>") by fetching
--- `prefix`+`id` over Conduit. Asynchronous -- there's no reason to block
--- the editor while a buffer loads; only `:w` blocks.
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
    vim.bo[bufnr].buftype = 'acwrite'
    -- A swapfile can't do its job here and actively gets in the way: this
    -- BufReadCmd repopulates the buffer from the server on every open, so
    -- recovered content is overwritten the moment the buffer opens, while a
    -- swapfile left behind by a crash makes the next open fail with E325
    -- against a "file" that "CANNOT BE FOUND". netrw disables them for its
    -- remote buffers for the same reason.
    vim.bo[bufnr].swapfile = false
    -- Survive navigating away rather than being unloaded -- cursor,
    -- scroll and buffer-list position all stay put when you come back.
    -- The tradeoff: since the buffer is still *loaded*, revisiting it via
    -- `:e`/`:b` does not re-fire BufReadCmd (same as any real file), so
    -- you see whatever was last fetched, not necessarily the current
    -- server state. `:e!` forces a fresh fetch when that matters.
    vim.bo[bufnr].bufhidden = 'hide'
    -- Non-editable while loading -- this is what backstops a write racing
    -- the fetch (see push()), and doubles as the "loaded successfully"
    -- marker via arcanist_loaded below.
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    vim.b[bufnr].arcanist_loaded = nil
    notify(vim.log.levels.INFO, string.format('loading %s%d...', prefix, id))

    conduit.call(handler.search, handler.params(id), function(ok, response, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if not ok then
            -- Content, not just the "loading" state, might be stale here --
            -- this fetch could be a reload of a previously-loaded buffer --
            -- so it's explicitly cleared rather than left as-is.
            set_lines(bufnr, {}, false)
            notify_err(string.format('failed to load %s%d: %s', prefix, id, err))
            return
        end

        local obj = response.data[1]
        if not obj then
            set_lines(bufnr, {}, false)
            notify_err(string.format('%s%d not found', prefix, id))
            return
        end

        vim.bo[bufnr].filetype = handler.filetype
        set_lines(bufnr, fields.render(handler.fields, obj), true)
        vim.b[bufnr].arcanist_loaded = {
            values = fields.raw_values(handler.fields, obj),
            date_modified = obj.fields.dateModified,
        }
    end)
end

--- Push `lines` (from `bufnr`) to `prefix`+`id` over Conduit. When `bufnr`
--- is itself the "arcanist://<ref>" buffer being updated, runs the
--- staleness guard first (unless `force`) and refreshes its
--- baseline/'modified' afterward. Synchronous: the caller needs a definite
--- success/failure before it can decide whether to clear 'modified', and
--- leaving it set on failure is what keeps Vim's own E37 guard protecting
--- unsaved edits.
---
--- Only fields that actually changed become transactions -- diffed against
--- `arcanist_loaded`, the baseline recorded at load (or after the last
--- successful push). A foreign buffer (e.g. `:w arcanist://T1` from an
--- unrelated buffer, or the README's `:w {file}` / `:e {file}` / `:w
--- arcanist://T1` round-trip) has no such baseline, so every field present
--- in it is sent -- there's nothing to diff against. Either way, a field
--- whose label was deleted from the buffer is simply absent from the
--- parse, and left untouched on the server.
---
--- Shared by two entry points: `:w` on an "arcanist://" buffer (via
--- write_reference below), and the ":ArcWrite" command, which pushes
--- the current buffer's content directly over Conduit instead of asking
--- Vim to write to a name -- the only way to push when the target's own
--- buffer is already open elsewhere, since Vim's own E139 ("file is loaded
--- in another buffer") blocks `:w {name}` for that case before our
--- BufWriteCmd ever runs, and `!` does not override it.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param id integer
--- @param lines string[]
--- @param force boolean skip the staleness guard (from `:w!`/`:ArcWrite!`)
--- and overwrite the server's version even if it changed since load.
local function push(bufnr, handler, prefix, id, lines, force)
    local ref_name = string.format('%s%d', prefix, id)
    local config = require('arcanist').config
    local is_own = vim.api.nvim_buf_get_name(bufnr) == ('arcanist://' .. ref_name)
    local baseline = is_own and vim.b[bufnr].arcanist_loaded or nil

    if is_own and not baseline then
        notify_err(string.format('%s has not loaded successfully; nothing to update', ref_name))
        return
    end

    local values, parse_err = fields.parse(handler.fields, lines)
    if not values then
        notify_err(string.format('failed to update %s: %s', ref_name, parse_err))
        return
    end

    local transactions = {}
    for _, field in ipairs(handler.fields) do
        local raw = values[field.key]
        if raw ~= nil and fields.changed(field, baseline and baseline.values[field.key], raw) then
            local value, err = fields.write_value(field, raw)
            if not value then
                notify_err(string.format('failed to update %s: %s', ref_name, err))
                return
            end
            table.insert(transactions, { type = field.key, value = value })
        end
    end

    if #transactions == 0 then
        notify(vim.log.levels.INFO, ref_name .. ': no changes to update')
        if is_own then
            vim.bo[bufnr].modified = false
        end
        return
    end

    -- Blocking Conduit calls follow; say so before the UI freezes, not
    -- after. nvim_echo (what vim.notify's default handler calls) flushes to
    -- the message area synchronously, before this function's own call
    -- returns, so this is visible before the wait.
    notify(vim.log.levels.INFO, 'updating ' .. ref_name .. '...')

    -- Skipped entirely with `force` (":w!"/":ArcWrite!") -- the round-trip
    -- exists to catch a conflict, and force means overwrite regardless of
    -- one, so there's nothing to check for.
    if is_own and not force then
        local obj, err = fetch_sync(handler, id)
        if err then
            notify_err(string.format('failed to check %s for changes: %s', ref_name, err))
            return
        end
        if not obj then
            notify_err(string.format('%s no longer exists', ref_name))
            return
        end
        if obj.fields.dateModified ~= baseline.date_modified then
            -- `:e` alone won't work here -- the buffer is modified, so Vim
            -- refuses with E37 -- and `:e!` discards the edits, hence the
            -- nudge to save them off somewhere first. `!` overwrites the
            -- server's version instead, same as any other Vim write.
            notify_err(
                string.format(
                    '%s changed on the server since it was loaded. Your edits are still here; '
                        .. ':w {file} to keep a copy, then :e! to reload -- or :w!/:ArcWrite! '
                        .. 'to overwrite the server\'s version',
                    ref_name
                )
            )
            return
        end
    end

    local ok, _, err = conduit.call_sync(handler.edit, {
        objectIdentifier = ref_name,
        transactions = transactions,
    }, config.conduit_timeout)
    if not ok then
        notify_err(string.format('failed to update %s: %s', ref_name, err))
        return
    end

    if not is_own then
        notify(vim.log.levels.INFO, 'updated ' .. ref_name)
        return
    end

    -- Re-fetch to pick up the new dateModified/loaded baseline. Content is
    -- deliberately left alone so the cursor and undo history survive the
    -- save.
    local obj, refresh_err = fetch_sync(handler, id)
    if obj then
        vim.b[bufnr].arcanist_loaded = {
            values = fields.raw_values(handler.fields, obj),
            date_modified = obj.fields.dateModified,
        }
        vim.bo[bufnr].modified = false
        notify(vim.log.levels.INFO, 'updated ' .. ref_name)
    else
        vim.bo[bufnr].modified = false
        notify(
            vim.log.levels.WARN,
            string.format(
                'updated %s, but could not refresh it (%s); :e to reload',
                ref_name,
                refresh_err or 'not found'
            )
        )
    end
end

--- Handle `:w`/`:w!` on an "arcanist://<ref>" target. `v:cmdbang` (rather
--- than `args`, which carries no bang info) is how autocmd callbacks learn
--- whether `!` was given.
--- @param args table autocmd callback args
local function write_reference(args)
    local prefix, id = parse_uri(args.match)
    local handler = resolve_handler(prefix, args.match, 'write')
    if not handler then
        return
    end

    local bufnr = args.buf
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    push(bufnr, handler, prefix, id, lines, vim.v.cmdbang == 1)
end

--- Handle ":ArcWrite[!] [ref]". `ref` defaults to the current buffer's own
--- reference if it's an "arcanist://" buffer; otherwise it's required. This
--- is the way to push when the target's own buffer is already open
--- elsewhere -- see push()'s doc comment for why `:w` can't do that.
--- @param cmd_args table nvim_create_user_command callback args
local function push_command(cmd_args)
    local bufnr = vim.api.nvim_get_current_buf()
    local ref_arg = vim.trim(cmd_args.args)
    local prefix, id, target

    if ref_arg ~= '' then
        prefix, id = parse_ref(ref_arg)
        target = 'arcanist://' .. ref_arg
        if not prefix then
            notify_err('invalid reference: ' .. ref_arg)
            return
        end
    else
        target = vim.api.nvim_buf_get_name(bufnr)
        prefix, id = parse_uri(target)
        if not prefix then
            notify_err(':ArcWrite needs a reference (current buffer is not an "arcanist://" buffer)')
            return
        end
    end

    local handler = resolve_handler(prefix, target, 'push')
    if not handler then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    push(bufnr, handler, prefix, id, lines, cmd_args.bang)
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

local installed = false

--- Install the "arcanist://" buffer scheme handlers. Idempotent -- safe to
--- call from plugin/ at startup and again from every remarkup buffer, but
--- only does anything the first time: unlike a lone BufReadCmd, this now
--- registers a BufWriteCmd and a user command too, and neither needs
--- redoing on every remarkup buffer opened in a session.
function M.setup()
    if installed then
        return
    end
    installed = true

    local augroup = vim.api.nvim_create_augroup('arcanist.reference', { clear = true })

    vim.api.nvim_create_autocmd('BufReadCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            local prefix, id = parse_uri(args.match)
            local handler = resolve_handler(prefix, args.match, 'open')
            if handler then
                load_reference(args.buf, handler, prefix, id)
            end
        end,
    })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = write_reference,
    })

    vim.api.nvim_create_user_command('ArcWrite', push_command, {
        nargs = '?',
        bang = true,
        desc = 'Push the current buffer to a Phorge task/revision (defaults to the current '
            .. 'buffer\'s own reference). Unlike ":w arcanist://T123", works even if that '
            .. 'reference\'s own buffer is already open elsewhere. "!" overwrites even if the '
            .. 'object changed on the server since it was loaded.',
    })
end

return M
