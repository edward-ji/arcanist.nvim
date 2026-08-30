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
--   `read(obj.fields, obj)`  pulls the displayed value out of the fetched
--            object. Shown the way Phorge's web UI shows it ("Needs
--            Triage", not the `triage` keyword the edit API wants) --
--            free, since the display name is already in the object. The
--            whole object comes second, for the values that aren't among
--            its `fields` -- an id is a sibling of them, not one.
--   `write`  turns parsed text into a transaction value: `M.TEXT` sends it
--            as-is, or `M.value_source({...})` (below) resolves it against
--            Phorge's own valid values first. One write answers both "what
--            does this send" and "has it changed", so there is no separate
--            change-detection case to keep in sync. A `value_source` write
--            also answers a third: what are the valid values, for
--            completion -- `M.TEXT` has no such list. Absent on a field
--            that names the object rather than describing it, which is
--            therefore never sent.
--
-- A field Phorge itself has no way to write (a revision's Status, which
-- only moves via accept/reject/abandon, never a settable value) is left
-- out of the field list rather than shown and then rejected.

local source = require('arcanist.source')

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

--- One completion candidate: `text` is what gets inserted, `detail` (if
--- any) is a human-readable label shown alongside it -- e.g. a value
--- source's `text` is already the display name, so it has no separate
--- `detail`, but a username's `detail` is the person's real name.
--- `filter`/`sort` (if any) become LSP filterText/sortText -- the sigil
--- sources set them so an item found by a non-label word (a real name, a
--- project name) survives client-side re-filtering and ranks the way
--- Phorge's typeahead ranks it; value-source items omit both, and the
--- label defaults apply.
--- @alias arcanist.CompletionItem { text: string, detail: string?, filter: string?, sort: string? }

-- A field's `write` is `{ write_value(raw) -> value, err; changed(loaded,
-- raw) -> boolean; complete(callback)? }` -- turn parsed text into a
-- transaction value, decide if it's different enough from the baseline to
-- send, and (optionally) list the valid values for completion. Free text
-- (M.TEXT) and value-source fields (M.value_source, below) both satisfy
-- the first two the same way, so callers (M.write_value/M.changed) never
-- branch on which kind of field they have; `complete` is the one part
-- that's genuinely absent for free text, so callers of it must check.
-- `complete` is callback-based (rather than returning a list directly)
-- because its first call in a session may need to fetch over Conduit, and
-- that shouldn't block the editor the way `write_value` blocking during
-- `:w` already does by design.
--- @alias arcanist.Write { write_value: fun(raw: string): string?, string?, changed: fun(loaded: string?, raw: string): boolean, complete: (fun(callback: fun(items: arcanist.CompletionItem[])))? }

--- @type arcanist.Write
M.TEXT = {
    write_value = function(raw)
        return raw
    end,
    changed = function(loaded, raw)
        return loaded == nil or loaded ~= raw
    end,
}

--- Build a `write` for a field whose valid values come from Phorge itself
--- rather than a hardcoded list -- e.g. a task's Status/Priority are both
--- admin-configurable per instance. `method`'s response is fetched once per
--- session (the lists are small and rarely change) and cached via
--- `arcanist.source`, shared across every field (and completion) that uses
--- the same source. `value`/`display` read one item from the response;
--- `aliases` lists every spelling that should resolve to it (so both the
--- display name and any write keyword work as input).
--- @param spec { method: string, display: fun(item: table): string, value: fun(item: table): string, aliases: fun(item: table): string[] }
--- @return arcanist.Write
function M.value_source(spec)
    -- Resolve typed text against the spec's display name or any alias,
    -- trimmed and case-insensitive.
    local function resolve(input)
        local items, err = source.fetch(spec.method)
        if not items then
            return nil, string.format('failed to fetch valid values: %s', err)
        end

        local needle = vim.trim(input):lower()
        for _, item in ipairs(items) do
            if spec.display(item):lower() == needle then
                return spec.value(item)
            end
            for _, alias in ipairs(spec.aliases(item)) do
                if alias:lower() == needle then
                    return spec.value(item)
                end
            end
        end

        local valid = vim.tbl_map(spec.display, items)
        return nil, string.format('"%s" is not valid -- expected one of: %s', input, table.concat(valid, ', '))
    end

    return {
        write_value = resolve,
        changed = function(loaded, raw)
            -- Compared the way resolve() will match it, so retyping the
            -- same value with different casing or spacing isn't a change.
            return loaded == nil or loaded:lower() ~= vim.trim(raw):lower()
        end,
        complete = function(callback)
            source.fetch_async(spec.method, nil, function(items)
                if not items then
                    callback({})
                    return
                end
                callback(vim.tbl_map(function(item)
                    return { text = spec.display(item) }
                end, items))
            end)
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

        local value = field.read(f, obj)
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

--- The 'title'-kind field, which every field list has exactly one of.
--- Read an object's one-line name through this rather than reaching into
--- it: a task's title lives at `fields.name`, a revision's at
--- `fields.title`, and knowing that difference is this module's job.
--- @param fields table[]
--- @return table
function M.title_field(fields)
    for _, field in ipairs(fields) do
        if field.kind == 'title' then
            return field
        end
    end
    error('field list has no title field')
end

--- The 'line'-kind field (if any) whose "Label: " prefix starts `line`,
--- and that prefix's length. Used by completion to know which field's
--- valid values apply while the cursor sits on that line, and where its
--- value starts -- unlike M.parse's matching, this cares about the exact
--- byte offset, so it doesn't trim first. Returns the length alongside
--- the field (rather than making callers redo `#field.label + 2`) so
--- there's one place that knows the "Label: " separator is two bytes.
--- @param fields table[]
--- @param line string
--- @return table? field
--- @return integer? prefix_len
function M.field_for_line(fields, line)
    for _, field in ipairs(fields) do
        if field.kind == 'line' then
            local prefix = field.label .. ': '
            if line:sub(1, #prefix) == prefix then
                return field, #prefix
            end
        end
    end
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
