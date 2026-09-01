-- The ":ArcLint" and ":ArcList" user commands. CamelCase matches the
-- ":ArcWrite" already registered by reference.lua (and
-- ":Inspect"/":InspectTree" in Neovim's own runtime).

local M = {}

--- `arc lint` severities (ArcanistLintSeverity.php), in the order findings
--- are reported, each with the quickfix type it maps to and its plural.
--- "disabled" is deliberately absent -- those messages are ones the project
--- has switched off, so they're dropped rather than listed.
local SEVERITIES = {
    { 'error', 'E', 'errors' },
    { 'warning', 'W', 'warnings' },
    { 'autofix', 'W', 'autofixes' },
    { 'advice', 'I', 'advice' },
}

--- severity -> quickfix type, derived so the two can't drift apart.
local QF_TYPE = {}
for _, severity in ipairs(SEVERITIES) do
    QF_TYPE[severity[1]] = severity[2]
end

--- Render counts as "2 errors, 1 warning", skipping whatever didn't occur.
--- Plurals are spelled out rather than suffixed because not all of them
--- inflect ("3 advice", not "3 advices").
--- @param counts table<string, integer>
--- @return string
local function tally(counts)
    local parts = {}
    for _, severity in ipairs(SEVERITIES) do
        local key, plural = severity[1], severity[3]
        local n = counts[key]
        if n and n > 0 then
            parts[#parts + 1] = string.format('%d %s', n, n == 1 and key or plural)
        end
    end
    if #parts == 0 then
        return 'nothing to report'
    end
    return table.concat(parts, ', ')
end

--- One quickfix item from one lint message, or nil for a severity we drop.
--- @param filename string Already resolved against the working copy.
--- @param message table
--- @return table?
local function lint_item(filename, message)
    local qf_type = QF_TYPE[message.severity]
    if not qf_type then
        return nil
    end
    -- Descriptions run to several sentences and can wrap onto more than one
    -- line; quickfix wants one.
    local description = (message.description or ''):gsub('%s+', ' ')
    return {
        filename = filename,
        lnum = message.line or 0,
        col = message.char or 0,
        type = qf_type,
        text = vim.trim(
            string.format('%s %s: %s', message.code or '', message.name or '', description)
        ),
    }
end

--- Parse `arc lint --output json`.
---
--- ArcanistJSONLintRenderer::renderLintResult() is called once per file and
--- each call writes its own `json_encode(...)."\n"`, so stdout is a stream
--- of one-line JSON objects -- not a single document. Decoding the whole
--- thing at once fails as soon as more than one file has messages.
---
--- Each object is `{ "<path>": [ <message>, ... ] }` with the path relative
--- to the project root and stripped from the messages themselves.
--- @param root string
--- @param stdout string
--- @return table[]? items
--- @return string message
local function parse_lint(root, stdout)
    local items = {}
    local counts = {}

    for line in vim.gsplit(stdout, '\n', { plain = true }) do
        if line ~= '' then
            -- luanil: `arc` emits JSON null for absent fields, and the
            -- vim.NIL sentinel is truthy, so it has to decode to real nil.
            local ok, decoded =
                pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if not ok or type(decoded) ~= 'table' then
                return nil, 'failed to parse lint output: ' .. line
            end

            for path, messages in pairs(decoded) do
                -- Invariant per file, and joinpath is a good deal more than
                -- a concat -- it normalizes, so it isn't free per message.
                local filename = vim.fs.joinpath(root, path)
                for _, message in ipairs(messages) do
                    local item = lint_item(filename, message)
                    if item then
                        counts[message.severity] = (counts[message.severity] or 0) + 1
                        items[#items + 1] = item
                    end
                end
            end
        end
    end

    return items, tally(counts)
end

--- Flags this command sets for itself. `arc` lets the last occurrence of a
--- flag win, so passing either again would hand parse_lint something that
--- isn't JSON, or divert the results to a file and leave stdout empty --
--- which reads as a clean run with no findings.
local RESERVED = {
    output = true,
    outfile = true,
}

--- The reserved flag the user passed, or nil. Scanning stops at "--", past
--- which everything is a path.
--- @param fargs string[]
--- @return string?
local function reserved_flag(fargs)
    for _, arg in ipairs(fargs) do
        if arg == '--' then
            return nil
        end
        local name = arg:match('^%-%-([^=]+)')
        if name and RESERVED[name] then
            return '--' .. name
        end
    end
    return nil
end

--- Order the user's arguments into an `arc` argument list: flags first, then
--- the paths behind a "--" that protects any path starting with "-".
--- Hoisting is safe -- `arc` collects non-flag arguments into the workflow's
--- paths wherever they appear.
---
--- Nothing here can tell "--rev HEAD~1" from a flag followed by a path, so a
--- flag taking a value has to be written "--rev=HEAD~1". A "--" written by
--- hand passes the list straight through, for when the two-word form is
--- wanted.
--- @param fargs string[]
--- @return string[]
local function order_args(fargs)
    if vim.list_contains(fargs, '--') then
        return fargs
    end

    local flags, paths = {}, { '--' }
    for _, arg in ipairs(fargs) do
        if arg:sub(1, 1) == '-' then
            flags[#flags + 1] = arg
        else
            paths[#paths + 1] = arg
        end
    end

    return vim.list_extend(flags, paths)
end

--- Complete ":ArcList [query] [type]".
---
--- The first word may be either a query or a type; the second offers only
--- the types accepting the query already typed, so ":ArcList open <Tab>"
--- offers "tasks" and nothing else (Differential has no "open" builtin).
--- Types are offered in the plural; type_named() takes either spelling.
--- @param arg_lead string
--- @param cmd_line string
--- @param cursor_pos integer
--- @return string[]
local function complete_list(arg_lead, cmd_line, cursor_pos)
    local reference = require('arcanist.reference')

    local words = vim.split(vim.trim(cmd_line:sub(1, cursor_pos)), '%s+')
    if arg_lead ~= '' then
        words[#words] = nil
    end
    table.remove(words, 1) -- the command name
    -- `words` is now exactly the arguments already settled.

    local candidates = {}
    if #words == 0 then
        -- Grouped rather than interleaved: the two answer different
        -- questions, and mixing them makes the menu read as noise.
        local keys = {}
        for _, name in ipairs(reference.types()) do
            local handler = reference.type_named(name).handler
            candidates[#candidates + 1] = handler.plural
            for _, key in ipairs(handler.query_keys) do
                keys[key] = true
            end
        end
        keys = vim.tbl_keys(keys)
        table.sort(keys)
        vim.list_extend(candidates, keys)
    elseif #words == 1 then
        -- Nothing may follow a type -- it is already the last word -- so a
        -- first word naming one completes to nothing.
        if reference.type_named(words[1]) then
            return {}
        end
        for _, name in ipairs(reference.types()) do
            local handler = reference.type_named(name).handler
            if vim.list_contains(handler.query_keys, words[1]) then
                candidates[#candidates + 1] = handler.plural
            end
        end
    end

    return vim.tbl_filter(function(candidate)
        return vim.startswith(candidate, arg_lead)
    end, candidates)
end

local installed = false

function M.setup()
    if installed then
        return
    end
    installed = true

    vim.api.nvim_create_user_command('ArcLint', function(args)
        -- Required here rather than at module load: registering the command
        -- is what has to happen at startup, and every session that never
        -- lints would otherwise pay for pulling the runner in.
        local qf = require('arcanist.qf')

        local taken = reserved_flag(args.fargs)
        if taken then
            require('arcanist.notify').err(
                string.format('ArcLint: %s is set by the plugin and cannot be overridden', taken)
            )
            return
        end

        local root = qf.root(vim.api.nvim_get_current_buf())

        local argv = { 'arc', 'lint', '--output', 'json' }
        vim.list_extend(argv, order_args(args.fargs))

        qf.run({
            argv = argv,
            cwd = root,
            command = 'ArcLint',
            force = args.bang,
            parse = function(stdout)
                return parse_lint(root, stdout)
            end,
        })
    end, {
        nargs = '*',
        bang = true,
        complete = 'file',
        desc = 'Run `arc lint` on the given paths and load the results into the '
            .. 'quickfix list. Accepts `arc lint` flags, which must use the '
            .. '"--flag=value" form. With "!", cancel a run already in progress '
            .. 'and start over.',
    })

    vim.api.nvim_create_user_command('ArcList', function(args)
        local fargs = args.fargs
        if #fargs > 2 then
            require('arcanist.notify').err('ArcList takes at most two arguments: [query] [type]')
            return
        end

        -- Both arguments are optional, so a lone word is whichever of the
        -- two it names.
        local query_key, type_name = fargs[1], fargs[2]
        if #fargs == 1 and require('arcanist.reference').type_named(fargs[1]) then
            query_key, type_name = nil, fargs[1]
        end

        require('arcanist').list({ query_key = query_key, type = type_name })
    end, {
        nargs = '*',
        complete = complete_list,
        desc = 'Browse Phorge tasks or revisions in a picker and open the chosen one. '
            .. 'Takes "[query] [type]", reading as English -- ":ArcList open tasks", '
            .. '":ArcList active revisions". The query defaults to "all" and the '
            .. 'type to revisions.',
    })
end

return M
