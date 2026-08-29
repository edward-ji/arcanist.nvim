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

local conduit = require('arcanist.conduit')
local fields = require('arcanist.fields')
local notify = require('arcanist.notify')
local reference = require('arcanist.reference')

local M = {}

--- The builtin query used when none was asked for. Every type supports
--- "all", which is what lets ":ArcList tasks" mean ":ArcList all tasks".
local DEFAULT_QUERY_KEY = 'all'

--- One Phorge page, which is also Phorge's ceiling: Conduit rejects any
--- limit above 100 with ERR-INVALID-PAGE-SIZE, so `limit` can only be
--- lowered. Unlike arcanist.source this deliberately does not follow the
--- cursor -- a picker is for finding something you can already name, and
--- truncation gets reported rather than hidden.
local DEFAULT_LIMIT = 100

--- The types a request covers, as arcanist.ObjectType entries: everything
--- supported when `want` is nil, otherwise just the named one(s).
---
--- Deduplicated by prefix: "task" and "tasks" in one list would otherwise
--- fetch twice -- a wasted `arc` subprocess, and every object listed twice.
--- @param want string|string[]|nil
--- @return arcanist.ObjectType[]? entries
--- @return string? err
local function resolve_types(want)
    local names = want or reference.types()
    if type(names) == 'string' then
        names = { names }
    end

    local entries, seen = {}, {}
    for _, name in ipairs(names) do
        local entry = reference.type_named(name)
        if not entry then
            return nil,
                string.format(
                    '%q is not a type -- expected one of: %s',
                    name,
                    table.concat(reference.types(), ', ')
                )
        end
        if not seen[entry.prefix] then
            seen[entry.prefix] = true
            entries[#entries + 1] = entry
        end
    end

    -- Zero types would mean zero fetches, so the `pending` counter below
    -- never reaches 0 and the picker would silently never appear.
    if #entries == 0 then
        return nil, 'no types to list'
    end

    return entries
end

--- Upper-case the first letter. Deliberately not a general title-caser:
--- every word it sees is a fixed lower-case ASCII query key or type name.
--- @param str string
--- @return string
local function capitalize(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

--- The request's types as a noun phrase ("tasks", "tasks and revisions").
--- `transform` capitalizes for the picker prompt; the messages that use
--- this mid-sentence pass nothing.
--- @param entries arcanist.ObjectType[]
--- @param transform? fun(name: string): string
--- @return string
local function describe(entries, transform)
    local names = {}
    for _, entry in ipairs(entries) do
        local name = entry.handler.plural
        names[#names + 1] = transform and transform(name) or name
    end
    return table.concat(names, ' and ')
end

--- A `format_item` that lines the monogram and status columns up across
--- the whole result set, so the plain inputlist() fallback -- which gets no
--- columns of its own -- still reads as a table.
---
--- Widths are display cells (printf's "%S", not "%s"): status names are
--- instance-configurable and translatable, so counting bytes would
--- misalign the column on any instance that isn't plain ASCII.
--- @param items table[]
--- @return fun(item: table): string
local function formatter(items)
    local monogram_width, status_width = 0, 0
    for _, item in ipairs(items) do
        monogram_width = math.max(monogram_width, vim.api.nvim_strwidth(item.monogram))
        status_width = math.max(status_width, vim.api.nvim_strwidth(item.status))
    end

    return function(item)
        return vim.fn.printf(
            '%-*S  %-*S  %s',
            monogram_width,
            item.monogram,
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
--- @field type? string|string[] Type(s) to list -- "task"/"revision", or
--- their plurals. Omitted covers every supported type.
--- @field query_key? string One of the type's builtin Phorge queries (see
--- HANDLERS in arcanist.reference). Defaults to "all".
--- @field limit? integer Results to fetch per type. Defaults to 100.

--- Pick a task or revision and open it as an "arcanist://" buffer.
---
--- Asynchronous throughout: a list is never worth freezing the editor for,
--- and the types are fetched in parallel rather than one after another.
--- @param opts arcanist.ListOpts?
function M.list(opts)
    opts = opts or {}

    local entries, err = resolve_types(opts.type)
    if not entries then
        notify.err(err)
        return
    end

    -- Validated per type up front rather than letting Conduit reject it,
    -- because the useful part of the message is which keys *this* type
    -- takes, and the server's ERR-BAD-QUERYKEY doesn't say.
    local query_key = opts.query_key or DEFAULT_QUERY_KEY
    for _, entry in ipairs(entries) do
        if not vim.list_contains(entry.handler.query_keys, query_key) then
            notify.err(
                string.format(
                    '%q is not a %s query -- expected one of: %s',
                    query_key,
                    entry.handler.type,
                    table.concat(entry.handler.query_keys, ', ')
                )
            )
            return
        end
    end

    local limit = opts.limit or DEFAULT_LIMIT
    local what = describe(entries)
    local items, errors, truncated = {}, {}, false
    local pending = #entries

    local function finish()
        -- Reported even when some types did return results: a partial list
        -- that silently pretends to be the whole one is worse than a noisy
        -- one.
        if #errors > 0 then
            notify.err('failed to list: ' .. table.concat(errors, '; '))
        end

        if #items == 0 then
            if #errors == 0 then
                notify.info(string.format('no %s matched %q', what, query_key))
            end
            return
        end

        -- Newest-modified first, so the two fetches merge into one order
        -- instead of landing grouped. Not Phorge's own order -- it sorts
        -- tasks by priority and revisions by creation -- so a result
        -- capped by `limit` is the newest of its slice, not of everything.
        -- Ties (same second) break on prefix, then id descending;
        -- comparing monograms as strings would put "T9" after "T15".
        table.sort(items, function(a, b)
            if a.date_modified ~= b.date_modified then
                return a.date_modified > b.date_modified
            end
            if a.prefix ~= b.prefix then
                return a.prefix < b.prefix
            end
            return a.obj.id > b.obj.id
        end)

        if truncated then
            notify.warn(string.format('showing the first %d; more %s matched', limit, what))
        end

        vim.ui.select(items, {
            -- Echoes Phorge's own phrasing where the two line up: "Open
            -- Tasks", "All Tasks" and "Active Revisions" are verbatim
            -- getBuiltinQueryNames() labels. The keys Phorge names without
            -- a noun ("Assigned", "Authored", "Subscribed") get the type
            -- appended, so the prompt still says what it is listing.
            prompt = string.format(
                '%s %s:',
                capitalize(query_key),
                describe(entries, capitalize)
            ),
            -- 'preview_item' is a Neovim 0.12 addition to the
            -- vim.ui.select contract ('kind' long predates it). It is a
            -- plain opts key, so older versions and simpler
            -- implementations ignore it rather than failing on it.
            kind = 'arcanist',
            format_item = formatter(items),
            preview_item = preview_item,
        }, function(item)
            if item then
                vim.cmd.edit(reference.uri(item.prefix, item.obj.id))
            end
        end)
    end

    for _, entry in ipairs(entries) do
        -- Hoisted out of the callback: the title field is a property of the
        -- type, so looking it up once per type beats once per result.
        local title = fields.title_field(entry.handler.fields)
        conduit.call(
            entry.handler.search,
            { queryKey = query_key, limit = limit },
            function(ok, response, call_err)
                if ok then
                    for _, obj in ipairs(response.data or {}) do
                        items[#items + 1] = {
                            monogram = string.format('%s%d', entry.prefix, obj.id),
                            prefix = entry.prefix,
                            status = obj.fields.status and obj.fields.status.name or '',
                            title = title.read(obj.fields) or '',
                            date_modified = obj.fields.dateModified or 0,
                            handler = entry.handler,
                            obj = obj,
                        }
                    end
                    -- A cursor left pointing somewhere means the query has
                    -- more results than `limit` asked for.
                    if vim.tbl_get(response, 'cursor', 'after') then
                        truncated = true
                    end
                else
                    errors[#errors + 1] =
                        string.format('%s: %s', entry.handler.plural, call_err)
                end

                pending = pending - 1
                if pending == 0 then
                    finish()
                end
            end
        )
    end
end

return M
