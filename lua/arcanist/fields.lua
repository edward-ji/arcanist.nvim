-- Renders a Phorge object's fields as a plain-text document, and parses
-- that same text back into values to write. Two directions of one schema,
-- kept together so they can't drift apart.
--
-- A field list is an array of { key, kind, label?, read, write }:
--   `key`    the Conduit transaction type this field maps to.
--   `kind`   'title' (bare, no label, always first and always one line),
--            'line' (value on the label's own line), or 'block' (label
--            alone, value beneath it, any number of lines).
--   `label`  the buffer text ("Status:"); absent only for 'title'.
--   `read(obj.fields)`  pulls the displayed value out of the fetched
--            object. Shown the way Phorge's web UI shows it ("Needs
--            Triage", not the `triage` keyword the edit API wants) --
--            free, since the display name is already in the object.
--   `write`  turns parsed text into a transaction value: `M.TEXT` sends it
--            as-is, or `M.value_source({...})` (below) resolves it against
--            Phorge's own valid values first. Every field has one -- there
--            is no separate "how do I tell if this changed" case to keep
--            in sync, since a write behavior answers both questions.
--
-- Every declared field is both readable and writable -- there's no
-- "read-only field" here, because Vim has no way to make a specific line
-- unmodifiable anyway. A field Phorge itself has no way to write (a
-- revision's Status, which only moves via accept/reject/abandon, never a
-- settable value) is simply left out of the field list rather than shown
-- and then rejected.

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

-- A field's `write` is `{ write_value(raw) -> value, err; changed(loaded,
-- raw) -> boolean }` -- turn parsed text into a transaction value, and
-- decide if it's different enough from the baseline to send. Free text
-- (M.TEXT) and value-source fields (M.value_source, below) both satisfy
-- this the same way, so callers (M.write_value/M.changed) never branch on
-- which kind of field they have.
--- @alias arcanist.Write { write_value: fun(raw: string): string?, string?, changed: fun(loaded: string?, raw: string): boolean }

--- @type arcanist.Write
M.TEXT = {
    write_value = function(raw)
        return raw
    end,
    changed = function(loaded, raw)
        return loaded == nil or loaded ~= raw
    end,
}

--- @type table<string, table[]>
local source_cache = {}

--- Build a `write` for a field whose valid values come from Phorge itself
--- rather than a hardcoded list -- e.g. a task's Status/Priority are both
--- admin-configurable per instance. `method`'s response is fetched once per
--- session (the lists are small and rarely change) and cached, shared
--- across every field that uses the same source. `value`/`display` read
--- one item from the response; `aliases` lists every spelling that should
--- resolve to it (so both the display name and any write keyword work as
--- input).
--- @param source { method: string, display: fun(item: table): string, value: fun(item: table): string, aliases: fun(item: table): string[] }
--- @return arcanist.Write
function M.value_source(source)
    local function fetch()
        if source_cache[source.method] then
            return source_cache[source.method]
        end
        local timeout = require('arcanist').config.conduit_timeout
        local ok, response, err = conduit.call_sync(source.method, {}, timeout)
        if not ok then
            return nil, err
        end
        source_cache[source.method] = response.data
        return response.data
    end

    -- Resolve typed text against the source's display name or any alias,
    -- trimmed and case-insensitive.
    local function resolve(input)
        local items, err = fetch()
        if not items then
            return nil, string.format('failed to fetch valid values: %s', err)
        end

        local needle = vim.trim(input):lower()
        for _, item in ipairs(items) do
            if source.display(item):lower() == needle then
                return source.value(item)
            end
            for _, alias in ipairs(source.aliases(item)) do
                if alias:lower() == needle then
                    return source.value(item)
                end
            end
        end

        local valid = vim.tbl_map(source.display, items)
        return nil, string.format('"%s" is not valid -- expected one of: %s', input, table.concat(valid, ', '))
    end

    return {
        write_value = resolve,
        changed = function(loaded, raw)
            -- Compared the way resolve() will match it, so retyping the
            -- same value with different casing or spacing isn't a change.
            return loaded == nil or loaded:lower() ~= vim.trim(raw):lower()
        end,
    }
end

--- Build `fields` into buffer lines from a fetched object.
---
--- Blank-line placement is derived rather than spelled out per field list:
--- a run of consecutive 'line' fields stays tight ("Status:" directly
--- above "Priority:"), while blocks and the title are always separated
--- from whatever follows. That keeps the layout consistent for any future
--- field list without adding another rule per handler.
--- @param fields table[]
--- @param obj table
--- @return string[]
function M.render(fields, obj)
    local f = obj.fields
    local lines = {}

    for i, field in ipairs(fields) do
        if i > 1 then
            local prev = fields[i - 1]
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

--- Each field's canonical raw text for `obj` -- what `M.parse()` would
--- produce from an untouched buffer, gotten by actually round-tripping
--- through `M.render`/`M.parse` rather than a third hand-written copy of
--- the per-`kind` formatting rules. Used as the "did this field change"
--- baseline the write path diffs edits against.
--- @param fields table[]
--- @param obj table
--- @return table<string,string>
function M.raw_values(fields, obj)
    return M.parse(fields, M.render(fields, obj))
end

--- Parse buffer `lines` (as produced by `render`) back into
--- `{ key = raw string }`, one entry per field whose label is present.
--- A field whose label was deleted is simply absent from the result --
--- distinct from present-but-empty -- which is what lets the write path
--- treat "no label" as "leave this field alone".
---
--- The title is always exactly line 1. After that, a 'line' field's value
--- is whatever follows its own "Label: " on the same line; a 'block'
--- field's is everything up to the *next* known label (or EOF), so
--- multi-paragraph fields work -- a blank line never ends one, only
--- another label does. An unrecognized "Foo:" line is just content, so
--- prose containing "Note:" is untouched.
--- @param fields table[]
--- @param lines string[]
--- @return table<string,string>? values
--- @return string? err
function M.parse(fields, lines)
    local title_key
    local block_labels = {} -- exact "Label:" line -> field
    local line_prefixes = {} -- "Label: " prefix -> field
    for _, field in ipairs(fields) do
        if field.kind == 'title' then
            title_key = field.key
        elseif field.kind == 'line' then
            line_prefixes[field.label .. ': '] = field
        else
            block_labels[field.label .. ':'] = field
        end
    end

    local values = { [title_key] = vim.trim(lines[1] or '') }
    local seen = { [title_key] = true }
    local block_key, block_lines = nil, nil

    local function close_block()
        if block_key then
            values[block_key] = table.concat(trim_trailing(block_lines), '\n')
            block_key, block_lines = nil, nil
        end
    end

    for i = 2, #lines do
        local line = lines[i]
        local trimmed = vim.trim(line)

        local field, line_value = block_labels[trimmed], nil
        if not field then
            for prefix, candidate in pairs(line_prefixes) do
                if trimmed:sub(1, #prefix) == prefix then
                    field, line_value = candidate, vim.trim(trimmed:sub(#prefix + 1))
                    break
                end
            end
        end

        if field then
            if seen[field.key] then
                return nil, string.format('duplicate "%s:" label', field.label)
            end
            seen[field.key] = true
            close_block()
            if line_value ~= nil then
                values[field.key] = line_value
            else
                block_key, block_lines = field.key, {}
            end
        elseif block_key then
            table.insert(block_lines, line)
        elseif trimmed ~= '' then
            return nil, string.format('text before any field label: %q', line)
        end
    end
    close_block()

    return values
end

--- Turn one field's raw parsed text into the value its Conduit transaction
--- should carry.
--- @param field table
--- @param raw string
--- @return string? value
--- @return string? err
function M.write_value(field, raw)
    return field.write.write_value(raw)
end

--- Whether `raw` (freshly parsed) differs from `loaded` (the baseline
--- recorded at load or after the last push) meaningfully enough to need
--- resending.
--- @param field table
--- @param loaded string?
--- @param raw string
--- @return boolean
function M.changed(field, loaded, raw)
    return field.write.changed(loaded, raw)
end

return M
