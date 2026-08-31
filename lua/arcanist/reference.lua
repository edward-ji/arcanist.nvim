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
--
-- HANDLERS (below) is the registry of supported object types; adding one
-- there is what makes every feature, arcanist.list's picker included,
-- pick it up.

local conduit = require('arcanist.conduit')
local fields = require('arcanist.fields')
local notify = require('arcanist.notify')

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
-- `identity` is the label naming this type on a document's last line,
-- spelled the way Phorge spells it.
--
-- `type` is the name Phorge itself uses in prose for this kind of object
-- ("task", "revision" -- not the TASK/DREV PHID constants the API puts in
-- its `type` field), and `query_keys` lists the builtin queries its search
-- engine accepts, from its getBuiltinQueryNames(). Both are what
-- arcanist.list browses by.
--
-- `plural` is spelled out rather than suffixed -- not every noun inflects
-- with an "s", and "repositories" is next on the list below.
--
-- The two `query_keys` lists overlap only partly on purpose: Differential
-- has no "open", "assigned", "subscribed" or "reviewing" builtin, and
-- asking for one is a hard ERR-BAD-QUERYKEY, not an empty result.
--
-- Only T/D for now -- P/F/M/C/r<repo> refs point at pastes, files, macros,
-- commits, and repositories respectively; left for later.
--- @type table<string, { search: string, edit: string, params: fun(id: integer): table, filetype: string, type: string, plural: string, identity: string, query_keys: string[], fields: table[] }>
local HANDLERS = {
    T = {
        search = 'maniphest.search',
        edit = 'maniphest.edit',
        params = by_id,
        filetype = 'remarkup',
        type = 'task',
        plural = 'tasks',
        identity = 'Maniphest Task',
        query_keys = { 'assigned', 'authored', 'subscribed', 'open', 'all' },
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
        type = 'revision',
        plural = 'revisions',
        identity = 'Differential Revision',
        query_keys = { 'active', 'authored', 'all' },
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
        notify.err(string.format('cannot %s %s', action, ref_str))
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

--- The by-name view of HANDLERS, built once at load. HANDLERS is keyed by
--- monogram prefix, which is the one spelling no user ever types.
--- @type table<string, arcanist.ObjectType>
local BY_NAME = {}

--- @type string[]
local TYPE_NAMES = {}

--- Identity label -> the monogram prefix it names ("Maniphest Task" -> "T").
--- @type table<string, string>
local IDENTITY = {}

--- @class arcanist.ObjectType
--- @field handler table The HANDLERS entry.
--- @field prefix string The monogram prefix it is keyed by ("T"), which a
--- search result does not carry and callers need to name the object.

for prefix, handler in pairs(HANDLERS) do
    local entry = { handler = handler, prefix = prefix }
    BY_NAME[handler.type] = entry
    BY_NAME[handler.plural] = entry
    TYPE_NAMES[#TYPE_NAMES + 1] = handler.type
    IDENTITY[handler.identity] = prefix

    -- Every document ends with the line naming what it is: the same field
    -- every time bar the label, and with no `write`, so it is never sent.
    table.insert(handler.fields, {
        key = 'identity',
        kind = 'line',
        label = handler.identity,
        read = function(_, obj)
            return string.format('%s%d', prefix, obj.id)
        end,
    })
end
table.sort(TYPE_NAMES)

--- Every supported object type's singular name, sorted -- so command
--- completion and "expected one of: ..." messages have a stable order
--- rather than the hash's.
--- @return string[]
function M.types()
    return TYPE_NAMES
end

--- The type a user's word names, singular or plural, or nil if it names
--- none. The caller decides how to complain.
--- @param name string
--- @return arcanist.ObjectType?
function M.type_named(name)
    return BY_NAME[name]
end

--- The "arcanist://" URI for an object, so the scheme's spelling stays in
--- the module whose parse_uri() has to keep matching it.
--- @param prefix string
--- @param id integer
--- @return string
function M.uri(prefix, id)
    return string.format('arcanist://%s%d', prefix, id)
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

--- Make `bufnr` an "arcanist://" buffer, or (`scheme = false`) an ordinary
--- file buffer again.
---
--- A swapfile can't do its job here and actively gets in the way: the
--- BufReadCmd repopulates the buffer from the server on every open, so
--- recovered content is overwritten the moment the buffer opens, while a
--- swapfile left behind by a crash makes the next open fail with E325
--- against a "file" that "CANNOT BE FOUND". netrw disables them for its
--- remote buffers for the same reason.
---
--- 'bufhidden' keeps the buffer loaded when you navigate away -- cursor,
--- scroll and buffer-list position all stay put when you come back. The
--- tradeoff: revisiting it via `:e`/`:b` does not re-fire BufReadCmd (same
--- as any real file), so you see whatever was last fetched. `:e!` forces a
--- fresh fetch when that matters.
--- @param bufnr integer
--- @param scheme boolean
local function scheme_buffer(bufnr, scheme)
    -- Not `scheme and X or Y` per option: one value wanted here is `false`,
    -- which that idiom turns into Y.
    if scheme then
        vim.bo[bufnr].buftype = 'acwrite'
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].bufhidden = 'hide'
    else
        vim.bo[bufnr].buftype = ''
        vim.bo[bufnr].swapfile = vim.go.swapfile
        vim.bo[bufnr].bufhidden = ''
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
    scheme_buffer(bufnr, true)
    -- Non-editable while loading: this is what backstops a write racing the
    -- fetch (see push()), and an absent arcanist_loaded is what tells push()
    -- the buffer never received content.
    vim.b[bufnr].arcanist_loaded = nil
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    notify.info(string.format('loading %s%d...', prefix, id))
    -- A BufReadCmd stands in for the whole read, the BufReadPre/BufReadPost
    -- either side of it included, so they are fired here or not at all.
    -- Post waits for the fetch: it means "this buffer now holds the object".
    vim.api.nvim_exec_autocmds('BufReadPre', { buffer = bufnr })

    conduit.call(handler.search, handler.params(id), function(ok, response, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if not ok then
            -- Content, not just the "loading" state, might be stale here --
            -- this fetch could be a reload of a previously-loaded buffer --
            -- so it's explicitly cleared rather than left as-is.
            set_lines(bufnr, {}, false)
            notify.err(string.format('failed to load %s%d: %s', prefix, id, err))
            return
        end

        local obj = response.data[1]
        if not obj then
            set_lines(bufnr, {}, false)
            notify.err(string.format('%s%d not found', prefix, id))
            return
        end

        vim.bo[bufnr].filetype = handler.filetype
        set_lines(bufnr, fields.render(handler.fields, obj), true)
        vim.b[bufnr].arcanist_loaded = {
            ref = string.format('%s%d', prefix, id),
            values = fields.raw_values(handler.fields, obj),
        }
        vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr })
    end)
end

--- The object `lines` says it is: the last non-blank line, labelled with one
--- of HANDLERS' `identity` spellings and naming a single object. The monogram
--- decides the type; the label only qualifies the line as an identity at all.
--- Answered off the raw text because it settles which type's field list to
--- parse with, before there is one to parse against.
---
--- Narrow on purpose. Phorge's vocabulary does not distinguish "this file
--- *is* T123" from "this revision *references* T123" -- on a revision every
--- spelling of "task" is the task-reference field, whose aliases include the
--- singular "Maniphest Task". Only the plural is ever written there, so
--- requiring the exact singular label is what stops ":ArcWrite" in an `arc
--- diff` buffer -- which carries "Maniphest Tasks: T1" and no revision of its
--- own yet -- from pushing a commit message into T1.
---
--- Naming nothing is not an error; the caller decides whether it needed a
--- name. Looking like an identity but naming no one object is.
--- @param lines string[]
--- @return string? prefix
--- @return integer? id
--- @return string? err
local function identity_in(lines)
    local last
    for i = #lines, 1, -1 do
        if vim.trim(lines[i]) ~= '' then
            last = i
            break
        end
    end
    -- Line 1 is always the title (see fields.parse), so a lone identity line
    -- is a title that looks like one.
    if not last or last == 1 then
        return nil
    end

    local label, value = vim.trim(lines[last]):match('^([^:]+):%s*(.*)$')
    local want = label and IDENTITY[label]
    if not want then
        return nil
    end

    -- `arc` writes a revision's URI ("https://phorge.example.com/D456");
    -- Phorge's own parser takes that or the bare monogram, so both do here.
    local monogram = value:match('^%S+/([^/%s]+)$') or value
    local prefix, id = parse_ref(monogram)
    if not prefix then
        return nil, nil, string.format('"%s: %s" does not name one object', label, value)
    end
    if prefix ~= want then
        return nil,
            nil,
            string.format(
                '"%s:" cannot name %s -- that is not a %s',
                label,
                monogram,
                HANDLERS[want].type
            )
    end

    return prefix, id
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
--- successful push), which names the object it was taken from. A buffer
--- carrying a baseline for some other object, or none at all (`:w
--- arcanist://T1` from an unrelated buffer), sends every field present in
--- it -- there's nothing to diff against, and nothing to check for
--- staleness either. Either way, a field whose label was deleted from the
--- buffer is simply absent from the parse, and left untouched on the
--- server.
---
--- An identity line is cross-checked against the target first, whichever
--- entry point got here, so no path can push one object's text over
--- another's.
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
--- @return boolean pushed whether the object now matches the buffer.
local function push(bufnr, handler, prefix, id, lines, force)
    local ref_name = string.format('%s%d', prefix, id)
    local config = require('arcanist').config
    -- Two separate questions. Whether this is the object's own buffer
    -- (`is_own`) decides what happens to the buffer, 'modified' above all.
    -- Whether it carries a record of the object as loaded (`baseline`)
    -- decides what gets sent and whether a conflict is checked for. A copy
    -- saved out with ":sav" answers no to the first and yes to the second.
    local is_own = vim.api.nvim_buf_get_name(bufnr) == ('arcanist://' .. ref_name)
    local loaded = vim.b[bufnr].arcanist_loaded
    local baseline = loaded and loaded.ref == ref_name and loaded or nil

    if is_own and not baseline then
        notify.err(string.format('%s has not loaded successfully; nothing to update', ref_name))
        return false
    end

    local id_prefix, id_id, id_err = identity_in(lines)
    if id_err then
        notify.err(string.format('failed to update %s: %s', ref_name, id_err))
        return false
    end
    if id_prefix and not (id_prefix == prefix and id_id == id) then
        -- A copy about to go over the object it was copied from. `!` doesn't
        -- override this -- it means "ignore the staleness check" -- but
        -- deleting the line does.
        notify.err(
            string.format(
                '%s: this text is labelled %s%d. Delete the "%s:" line to push it elsewhere',
                ref_name,
                id_prefix,
                id_id,
                HANDLERS[id_prefix].identity
            )
        )
        return false
    end

    local values, parse_err = fields.parse(handler.fields, lines)
    if not values then
        notify.err(string.format('failed to update %s: %s', ref_name, parse_err))
        return false
    end

    local transactions = {}
    for _, field in ipairs(handler.fields) do
        local raw = values[field.key]
        -- No `write` is the identity line: nothing to send for it.
        if
            field.write
            and raw ~= nil
            and fields.changed(field, baseline and baseline.values[field.key], raw)
        then
            local value, err = fields.write_value(field, raw)
            if not value then
                notify.err(string.format('failed to update %s: %s', ref_name, err))
                return false
            end
            table.insert(transactions, { type = field.key, value = value })
        end
    end

    if #transactions == 0 then
        notify.info(ref_name .. ': no changes to update')
        if is_own then
            vim.bo[bufnr].modified = false
        end
        return true
    end

    -- Blocking Conduit calls follow; say so before the UI freezes, not
    -- after. nvim_echo (what vim.notify's default handler calls) flushes to
    -- the message area synchronously, before this function's own call
    -- returns, so this is visible before the wait.
    notify.info('updating ' .. ref_name .. '...')

    -- Skipped entirely with `force` (":w!"/":ArcWrite!") -- the round-trip
    -- exists to catch a conflict, and force means overwrite regardless of
    -- one, so there's nothing to check for.
    if baseline and not force then
        local obj, err = fetch_sync(handler, id)
        if err then
            notify.err(string.format('failed to check %s for changes: %s', ref_name, err))
            return false
        end
        if not obj then
            notify.err(string.format('%s no longer exists', ref_name))
            return false
        end
        -- Compared field by field rather than by dateModified, which has
        -- one-second resolution and moves for a write that changed nothing.
        -- Fields with no `write` are left out: a write cannot reach them, so
        -- a change to one is not a change this write could lose.
        local current = fields.raw_values(handler.fields, obj)
        local drifted = false
        for _, field in ipairs(handler.fields) do
            if
                field.write
                and fields.changed(field, baseline.values[field.key], current[field.key])
            then
                drifted = true
                break
            end
        end
        if drifted then
            -- `:e` alone won't work here -- the buffer is modified, so Vim
            -- refuses with E37 -- and `:e!` discards the edits, hence the
            -- nudge to save them off somewhere first. `!` overwrites the
            -- server's version instead, same as any other Vim write.
            notify.err(
                string.format(
                    '%s changed on the server since it was loaded. Your edits are still here; '
                        .. ':w {file} to keep a copy, then :e! to reload -- or :w!/:ArcWrite! '
                        .. 'to overwrite the server\'s version',
                    ref_name
                )
            )
            return false
        end
    end

    local ok, _, err = conduit.call_sync(handler.edit, {
        objectIdentifier = ref_name,
        transactions = transactions,
    }, config.conduit_timeout)
    if not ok then
        notify.err(string.format('failed to update %s: %s', ref_name, err))
        return false
    end

    if not baseline then
        notify.info('updated ' .. ref_name)
        return true
    end

    -- Re-fetch for a baseline matching what the server now holds. Content
    -- is deliberately left alone so the cursor and undo history survive the
    -- save.
    local obj, refresh_err = fetch_sync(handler, id)
    if is_own then
        vim.bo[bufnr].modified = false
    end
    if obj then
        vim.b[bufnr].arcanist_loaded = {
            ref = ref_name,
            values = fields.raw_values(handler.fields, obj),
        }
        notify.info('updated ' .. ref_name)
    else
        notify.warn(
            string.format(
                'updated %s, but could not refresh it (%s); :e to reload',
                ref_name,
                refresh_err or 'not found'
            )
        )
    end
    return true
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

    -- Read the buffer after BufWritePre, so anything that rewrites it there
    -- (a formatter, say) is part of what gets pushed, and announce the write
    -- only once it has actually landed.
    local bufnr = args.buf
    vim.api.nvim_exec_autocmds('BufWritePre', { buffer = bufnr })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if push(bufnr, handler, prefix, id, lines, vim.v.cmdbang == 1) then
        vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    end
end

--- Handle ":[line]r arcanist://<ref>": insert the object's document into
--- another buffer, after the line `:read` puts its '[ mark on. Blocking,
--- like a write: `:read` has to leave the inserted text and its marks in
--- place by the time the command returns.
--- @param args table autocmd callback args
local function read_reference(args)
    local prefix, id = parse_uri(args.match)
    local handler = resolve_handler(prefix, args.match, 'read')
    if not handler then
        return
    end

    vim.api.nvim_exec_autocmds('FileReadPre', { buffer = args.buf })
    local obj, err = fetch_sync(handler, id)
    if not obj then
        notify.err(string.format('failed to read %s%d: %s', prefix, id, err or 'not found'))
        return
    end

    local at = vim.fn.line("'[")
    local document = fields.render(handler.fields, obj)
    vim.api.nvim_buf_set_lines(args.buf, at, at, false, document)
    -- Doing the insertion by hand means setting the marks `:read` would
    -- leave around it, which is what "'[,']" after one addresses.
    vim.api.nvim_buf_set_mark(args.buf, '[', at + 1, 0, {})
    vim.api.nvim_buf_set_mark(args.buf, ']', at + #document, 0, {})
    vim.api.nvim_exec_autocmds('FileReadPost', { buffer = args.buf })
end

--- Handle ":ArcWrite[!] [ref]". `ref` defaults to the current buffer's own
--- reference if it's an "arcanist://" buffer, and otherwise to whatever its
--- identity line names (see identity_in). This is the way to push when the
--- target's own buffer is already open elsewhere -- see push()'s doc comment
--- for why `:w` can't do that.
--- @param cmd_args table nvim_create_user_command callback args
local function push_command(cmd_args)
    local bufnr = vim.api.nvim_get_current_buf()
    local ref_arg = vim.trim(cmd_args.args)
    local prefix, id, target

    if ref_arg ~= '' then
        prefix, id = parse_ref(ref_arg)
        target = 'arcanist://' .. ref_arg
        if not prefix then
            notify.err('invalid reference: ' .. ref_arg)
            return
        end
    else
        target = vim.api.nvim_buf_get_name(bufnr)
        prefix, id = parse_uri(target)
        if not prefix then
            -- Nothing in the name to go on, so fall back to what the text
            -- says it is.
            local id_prefix, id_id, id_err =
                identity_in(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            if id_err then
                notify.err(':ArcWrite: ' .. id_err)
                return
            end
            prefix, id = id_prefix, id_id
            if not prefix then
                notify.err(
                    ':ArcWrite needs a reference: this is not an "arcanist://" buffer, and its '
                        .. 'last line does not name a Phorge object'
                )
                return
            end
            target = M.uri(prefix, id)
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

    return M.uri(prefix, id)
end

local installed = false

--- Install the "arcanist://" buffer scheme handlers. Idempotent -- safe to
--- call from plugin/ at startup and again from every remarkup buffer, but
--- only does anything the first time: the autocmds and ":ArcWrite" are
--- session-wide, and nothing about them is per-buffer.
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

    vim.api.nvim_create_autocmd('FileReadCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = read_reference,
    })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = write_reference,
    })

    -- A partial write ("'<,'>w arcanist://T123") would parse as a document
    -- with most of its fields missing, and push that. Refused rather than
    -- half-done; without a FileWriteCmd of our own Vim would try to create a
    -- file literally called "arcanist://T123" and fail with E212.
    vim.api.nvim_create_autocmd('FileWriteCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            notify.err(
                string.format(
                    'cannot write part of a buffer to %s -- a document is written whole, '
                        .. 'with ":w %s" or ":ArcWrite"',
                    args.match:gsub('^arcanist://', ''),
                    args.match
                )
            )
        end,
    })

    -- ":saveas" and ":file" change a buffer's name and none of its options,
    -- which would leave 'buftype' at "acwrite" under a name no BufWriteCmd
    -- matches -- E676, and nothing written. BufFilePre matches the name being
    -- left and BufFilePost the one being taken, so a rename lands on whichever
    -- applies and the buffer ends up as what its new name says it is.
    vim.api.nvim_create_autocmd('BufFilePre', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            scheme_buffer(args.buf, false)
        end,
    })

    vim.api.nvim_create_autocmd('BufFilePost', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            scheme_buffer(args.buf, true)
        end,
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
