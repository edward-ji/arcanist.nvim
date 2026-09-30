-- Browse a Phorge instance's tasks and revisions and open the chosen one
-- as an "arcanist://" buffer -- the ":ArcList" command's implementation,
-- and the `require('arcanist').list` a user can bind to a key directly.
--
-- Results come from Conduit's `*.search` methods rather than `arc list`:
-- that workflow prints unstructured human text, and only ever covers
-- revisions.
--
-- The picker is `vim.ui.select`, so this module draws no UI of its own --
-- a fuzzy picker renders it if the user has one bound, Neovim's own
-- inputlist() if not.

local conduit = require('arcanist.arc.conduit')
local fields = require('arcanist.object.fields')
local notify = require('arcanist.notify')
local types = require('arcanist.object.types')

local M = {}

--- The builtin query used when none was asked for. Every type supports
--- "all", which is what lets ":ArcList tasks" mean ":ArcList all tasks".
local DEFAULT_QUERY_KEY = 'all'

--- The type listed when none was named.
local DEFAULT_TYPE = 'revisions'

--- The word standing for whoever is logged in, and the Phorge typeahead
--- function it becomes. Both constraints it can land on evaluate the
--- function server-side, so nothing here has to ask who the viewer is.
local VIEWER = { word = 'me', token = 'viewer()' }

--- One Phorge page, which is also Phorge's ceiling: Conduit rejects any
--- limit above 100 with ERR-INVALID-PAGE-SIZE, so `limit` can only be
--- lowered. Unlike arcanist.arc.source this deliberately does not follow the
--- cursor -- a picker is for finding something you can already name, and
--- truncation gets reported rather than hidden.
local DEFAULT_LIMIT = 100

--- The type a request covers, as an arcanist.ObjectType entry.
--- @param want string?
--- @return arcanist.ObjectType? entry
--- @return string? err
local function resolve_type(want)
    local name = want or DEFAULT_TYPE
    local entry = types.type_named(name)
    if not entry then
        return nil,
            string.format(
                '%q is not a type -- expected one of: %s',
                name,
                table.concat(types.types(), ', ')
            )
    end
    return entry
end

--- `filters` as the `constraints` map its type's search method takes, or
--- nil and a message naming the filters this type does take -- Conduit's
--- own ERR-INVALID-CONSTRAINT names none of them.
--- @param handler table
--- @param filters table<string, string[]>?
--- @return table? constraints
--- @return string? err
local function resolve_filters(handler, filters)
    local constraints = {}
    for name, users in pairs(filters or {}) do
        local key = handler.filters[name]
        if not key then
            local accepted = vim.tbl_keys(handler.filters)
            table.sort(accepted)
            return nil,
                string.format(
                    '%q is not a %s filter -- expected one of: %s',
                    name,
                    handler.type,
                    table.concat(accepted, ', ')
                )
        end

        local values = {}
        for _, user in ipairs(users) do
            values[#values + 1] = user == VIEWER.word and VIEWER.token or user
        end
        constraints[key] = values
    end
    return constraints
end

--- Upper-case the first letter. Deliberately not a general title-caser:
--- every word it sees is a fixed lower-case ASCII query key or type name.
--- @param str string
--- @return string
local function capitalize(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

--- A `format_item` that lines the reference and status columns up across
--- the whole result set, so the plain inputlist() fallback -- which gets no
--- columns of its own -- still reads as a table.
---
--- Widths are display cells (printf's "%S", not "%s"): status names are
--- instance-configurable and translatable, so counting bytes would
--- misalign the column on any instance that isn't plain ASCII.
--- @param items table[]
--- @return fun(item: table): string
local function formatter(items)
    local ref_width, status_width = 0, 0
    for _, item in ipairs(items) do
        ref_width = math.max(ref_width, vim.api.nvim_strwidth(item.ref))
        status_width = math.max(status_width, vim.api.nvim_strwidth(item.status))
    end

    return function(item)
        return vim.fn.printf(
            '%-*S  %-*S  %s',
            ref_width,
            item.ref,
            status_width,
            item.status,
            item.title
        )
    end
end

--- Render an item the way its "arcanist://" buffer will look -- the same
--- fields.render() call load_reference() makes -- so the preview can never
--- be laid out differently from what selecting it opens.
---
--- Highlighting is started directly instead of by setting 'filetype':
--- the remarkup ftplugin also attaches an LSP client and paste autocmds,
--- and a picker re-previews on every cursor move, so going through it
--- would do all that to a throwaway buffer once per keypress. A missing
--- parser is left silent here for the same reason -- the ftplugin already
--- says so, loudly, wherever it actually matters.
--- @param item table
--- @return table
local function preview_item(item)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fields.render(item.handler.fields, item.obj))
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = 'wipe'
    pcall(vim.treesitter.start, buf, item.handler.filetype)
    return { buf = buf }
end

--- @class arcanist.ListOpts
--- @field type? string Type to list -- "task"/"revision", or their plurals.
--- Defaults to "revisions".
--- @field query_key? string One of the type's builtin Phorge queries (see
--- HANDLERS in arcanist.object.types). Defaults to "all".
--- @field filters? table<string, string[]> Users to narrow to, keyed by one
--- of the type's filters (see HANDLERS in arcanist.object.types). "me" stands
--- for whoever is logged in.
--- @field limit? integer Results to fetch. Defaults to 100.

--- Pick a task or revision and open it as an "arcanist://" buffer.
---
--- Asynchronous throughout: a list is never worth freezing the editor for.
--- @param opts arcanist.ListOpts?
function M.list(opts)
    opts = opts or {}

    local entry, err = resolve_type(opts.type)
    if not entry then
        notify.err(err)
        return
    end
    local handler = entry.handler

    -- Validated up front rather than letting Conduit reject it, because the
    -- useful part of the message is which keys *this* type takes, and the
    -- server's ERR-BAD-QUERYKEY doesn't say.
    local query_key = opts.query_key or DEFAULT_QUERY_KEY
    if not vim.list_contains(handler.query_keys, query_key) then
        notify.err(
            string.format(
                '%q is not a %s query -- expected one of: %s',
                query_key,
                handler.type,
                table.concat(handler.query_keys, ', ')
            )
        )
        return
    end

    local constraints, filter_err = resolve_filters(handler, opts.filters)
    if not constraints then
        notify.err(filter_err)
        return
    end

    local limit = opts.limit or DEFAULT_LIMIT
    local what = handler.plural
    -- Hoisted out of the callback: the title field is a property of the
    -- type, so looking it up once beats once per result.
    local title = fields.title_field(handler.fields)

    local params = { queryKey = query_key, limit = limit, attachments = handler.attachments }
    if next(constraints) then
        params.constraints = constraints
    end

    conduit.call(
        handler.search,
        params,
        function(ok, response, call_err)
            if not ok then
                notify.err(string.format('failed to list %s: %s', what, call_err))
                return
            end

            local items = {}
            for _, obj in ipairs(response.data or {}) do
                items[#items + 1] = {
                    ref = handler.format(handler.key_of(obj)),
                    status = obj.fields.status and obj.fields.status.name or '',
                    title = title.read(obj.fields, obj) or '',
                    date_modified = obj.fields.dateModified or 0,
                    handler = handler,
                    obj = obj,
                }
            end

            if #items == 0 then
                notify.info(string.format('no %s matched %q', what, query_key))
                return
            end

            -- Newest-modified first, which is not Phorge's own order -- it
            -- sorts tasks by priority and revisions by creation -- so a
            -- result capped by `limit` is the newest of its slice, not of
            -- everything. Ties (same second) break on id descending;
            -- comparing monograms as strings would put "T9" after "T15".
            table.sort(items, function(a, b)
                if a.date_modified ~= b.date_modified then
                    return a.date_modified > b.date_modified
                end
                return a.obj.id > b.obj.id
            end)

            -- A cursor left pointing somewhere means the query has more
            -- results than `limit` asked for.
            if vim.tbl_get(response, 'cursor', 'after') then
                notify.warn(string.format('showing the first %d; more %s matched', limit, what))
            end

            vim.ui.select(items, {
                -- Echoes Phorge's own phrasing where the two line up: "Open
                -- Tasks", "All Tasks" and "Active Revisions" are verbatim
                -- getBuiltinQueryNames() labels. The keys Phorge names
                -- without a noun ("Assigned", "Authored", "Subscribed") get
                -- the type appended, so the prompt still says what it is
                -- listing.
                prompt = string.format('%s %s:', capitalize(query_key), capitalize(what)),
                -- 'preview_item' is a Neovim 0.12 addition to the
                -- vim.ui.select contract ('kind' long predates it). It is a
                -- plain opts key, so older versions and simpler
                -- implementations ignore it rather than failing on it.
                kind = 'arcanist',
                format_item = formatter(items),
                preview_item = preview_item,
            }, function(item)
                if item then
                    vim.cmd.edit(types.uri(entry.prefix, handler.key_of(item.obj)))
                end
            end)
        end
    )
end

--- Split ":ArcList" arguments into the positional "[query] [type]" and the
--- "key=value" filters. No type name or builtin query key contains an "=",
--- so position never has to tell the two apart.
--- @param fargs string[]
--- @return arcanist.ListOpts? opts
--- @return string? err
local function parse_list(fargs)
    local words, filters = {}, {}
    for _, arg in ipairs(fargs) do
        local name, value = arg:match('^([^=]*)=(.*)$')
        if not name then
            words[#words + 1] = arg
        elseif name == '' then
            return nil, string.format('%q needs a filter name before the "="', arg)
        elseif filters[name] then
            return nil, string.format('%q is set twice', name)
        else
            local users = vim.split(value, ',', { plain = true, trimempty = true })
            if #users == 0 then
                return nil, string.format('%q needs a value', name)
            end
            filters[name] = users
        end
    end

    if #words > 2 then
        return nil, 'ArcList takes at most two arguments: [query] [type]'
    end

    -- Both are optional, so a lone word is whichever of the two it names.
    local query_key, type_name = words[1], words[2]
    if #words == 1 and types.type_named(words[1]) then
        query_key, type_name = nil, words[1]
    end

    return { query_key = query_key, type = type_name, filters = filters }
end

--- The filter words `type_word` accepts, or every type's when no type is
--- settled yet -- the same union the query keys get offered as.
--- @param type_word string?
--- @return string[]
local function filter_keys(type_word)
    local keys = {}
    for _, name in ipairs(type_word and { type_word } or types.types()) do
        for key in pairs(types.type_named(name).handler.filters) do
            keys[key] = true
        end
    end
    keys = vim.tbl_keys(keys)
    table.sort(keys)
    return keys
end

--- Complete ":ArcList [query] [type] [key=value...]".
---
--- The first word may be either a query or a type; the second offers only
--- the types accepting the query already typed, so ":ArcList open <Tab>"
--- offers "tasks" and nothing else (Differential has no "open" builtin).
--- Types are offered in the plural; type_named() takes either spelling.
--- Filters are offered wherever they may be written, which is anywhere.
--- @param arg_lead string
--- @param cmd_line string
--- @param cursor_pos integer
--- @return string[]
local function complete_list(arg_lead, cmd_line, cursor_pos)
    local words = vim.split(vim.trim(cmd_line:sub(1, cursor_pos)), '%s+')
    if arg_lead ~= '' then
        words[#words] = nil
    end
    table.remove(words, 1) -- the command name

    -- Only the positional words place the next one, and the last type named
    -- among them is the one whose filters apply.
    local settled, type_word, used = {}, nil, {}
    for _, word in ipairs(words) do
        local name = word:match('^([^=]*)=')
        if name then
            used[name] = true
        else
            settled[#settled + 1] = word
            if types.type_named(word) then
                type_word = word
            end
        end
    end

    local keys = vim.tbl_filter(function(key)
        return not used[key]
    end, filter_keys(type_word))

    -- Past the "=" a username is all that can follow, and only the viewer
    -- has a spelling this can know without asking Conduit.
    local lead_key = arg_lead:match('^([^=]+)=')
    if lead_key then
        if not vim.list_contains(keys, lead_key) then
            return {}
        end
        return vim.tbl_filter(function(candidate)
            return vim.startswith(candidate, arg_lead)
        end, { lead_key .. '=me' })
    end

    local candidates = {}
    if #settled == 0 then
        -- Grouped rather than interleaved: the two answer different
        -- questions, and mixing them makes the menu read as noise.
        local query_keys = {}
        for _, name in ipairs(types.types()) do
            local handler = types.type_named(name).handler
            candidates[#candidates + 1] = handler.plural
            for _, key in ipairs(handler.query_keys) do
                query_keys[key] = true
            end
        end
        query_keys = vim.tbl_keys(query_keys)
        table.sort(query_keys)
        vim.list_extend(candidates, query_keys)
    elseif #settled == 1 and not type_word then
        for _, name in ipairs(types.types()) do
            local handler = types.type_named(name).handler
            if vim.list_contains(handler.query_keys, settled[1]) then
                candidates[#candidates + 1] = handler.plural
            end
        end
    end

    for _, key in ipairs(keys) do
        candidates[#candidates + 1] = key .. '='
    end

    return vim.tbl_filter(function(candidate)
        return vim.startswith(candidate, arg_lead)
    end, candidates)
end

--- Handle ":ArcList [query] [type] [key=value...]".
--- @param args table nvim_create_user_command callback args
function M.command(args)
    local opts, err = parse_list(args.fargs)
    if not opts then
        notify.err(err)
        return
    end
    M.list(opts)
end

M.complete = complete_list

return M
