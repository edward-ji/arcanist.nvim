-- What a document's own text says about the object it is: the identity
-- line that ends it ("Maniphest Task: T123") and the "Last Modified:" line
-- under that, which dates the text for the staleness check a push makes.

local types = require('arcanist.object.types')

local M = {}

--- @param line string
--- @return boolean
local function is_last_modified(line)
    return vim.startswith(vim.trim(line), types.LAST_MODIFIED .. ':')
end

--- The object `bufnr` says it is: its last non-blank line (or the one above
--- a trailing "Last Modified:"), labelled with one of HANDLERS' `identity`
--- spellings and naming a single object. The monogram decides the type; the
--- label only qualifies the line as an identity at all.
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
--- @param bufnr integer
--- @return string? prefix
--- @return integer|string? key
--- @return string? err
function M.identity_of(bufnr)
    -- prevnonblank() answers "last line with anything on it" in one step,
    -- for the current buffer -- hence nvim_buf_call, which switches to
    -- `bufnr` without firing autocmds. Line 1 is always the title (see
    -- fields.parse), so a lone identity line is a title that looks like one.
    local function last_line(before)
        local lnum = vim.api.nvim_buf_call(bufnr, function()
            return vim.fn.prevnonblank(before)
        end)
        return lnum, lnum > 0 and vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
    end

    local lnum, line = last_line(vim.api.nvim_buf_line_count(bufnr))
    if is_last_modified(line) then
        lnum, line = last_line(lnum - 1)
    end
    if lnum < 2 then
        return nil
    end

    local label, value = vim.trim(line):match('^([^:]+):%s*(.*)$')
    local want = label and types.prefix_for_identity(label)
    if not want then
        return nil
    end

    -- `arc` writes a revision's URI ("https://phorge.example.com/D456");
    -- Phorge's own parser takes that or the bare monogram, so both do here.
    local monogram = value:match('^%S+/([^/%s]+)$') or value
    local prefix, key = types.parse_ref(monogram)
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
                types.get(want).type
            )
    end

    return prefix, key
end

--- The filetype for the object `bufnr`'s identity line names, if it names
--- one: the same HANDLERS entry an "arcanist://" buffer of it would get.
--- @param bufnr integer
--- @return string?
function M.filetype_of(bufnr)
    local prefix = M.identity_of(bufnr)
    return prefix and types.get(prefix).filetype
end

--- The server `dateModified` `bufnr`'s text is based on, if it records one:
--- its "Last Modified:" value (`raw`, parsed out of it), raised to what the
--- last push from this buffer recorded, since undo can take the line back
--- past that push. No line, or an empty one, is no record at all.
--- @param bufnr integer
--- @param ref_name string
--- @param raw string?
--- @return string? last_modified
--- @return string? err
function M.last_modified_of(bufnr, ref_name, raw)
    if raw == nil or raw == '' then
        return nil
    end
    if not raw:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then
        return nil, string.format('"%s: %s" is not a UTC time like %s', types.LAST_MODIFIED, raw, types.iso8601(0))
    end
    local pushed = vim.b[bufnr].arcanist_last_modified
    if pushed and pushed.ref == ref_name and pushed.value > raw then
        return pushed.value
    end
    return raw
end

--- Rewrite `bufnr`'s "Last Modified:" line to `value`, and remember it for
--- `last_modified_of`. Only that line changes, so the cursor stays put; the
--- edit is its own undo step, as Vim has no way to make one that isn't.
--- @param bufnr integer
--- @param ref_name string
--- @param value string
function M.set_last_modified(bufnr, ref_name, value)
    vim.b[bufnr].arcanist_last_modified = { ref = ref_name, value = value }
    local new = string.format('%s: %s', types.LAST_MODIFIED, value)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = #lines, 1, -1 do
        if is_last_modified(lines[i]) then
            if lines[i] ~= new then
                vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
            end
            return
        end
    end
end

return M
