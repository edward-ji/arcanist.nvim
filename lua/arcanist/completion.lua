-- Completion for the fake in-process LSP client (arcanist.lsp):
-- @mention/#project sigils in any remarkup buffer, and Status/Priority
-- values on their own line inside an editable "arcanist://T*" buffer.
--
-- Two different data strategies, chosen by the same criterion Phorge's
-- own web typeahead uses (see JX.TypeaheadOnDemandSource vs
-- JX.TypeaheadPreloadedSource): @mention live-queries user.search's
-- `nameLike` (a real, non-deprecated substring search, debounced so
-- typing doesn't spawn an `arc` process per keystroke); #project has no
-- such search available via Conduit, so it preloads project.search once
-- per session via arcanist.source, same as Status/Priority already do.

local conduit = require('arcanist.conduit')
local reference = require('arcanist.reference')
local fields = require('arcanist.fields')
local source = require('arcanist.source')

local KIND = vim.lsp.protocol.CompletionItemKind

local M = {}

-- Matches Phorge's own default typeahead debounce (Prefab.js's
-- TypeaheadOnDemandSource queryDelay).
local QUERY_DELAY_MS = 125

-- Same character set as tree-sitter-remarkup's `_word` (grammar.js) -- the
-- only text that can ever parse back as a `mention`/`project_tag` node
-- once inserted, so it doubles as both "how much of the sigil's typed
-- text counts as the query" and "which candidates are even safe to
-- offer" -- real project slugs can contain characters our grammar
-- doesn't recognize (Unicode, "/"), so those are filtered out rather than
-- offered and then not highlighted.
local WORD = '[%w_.%-]'
local SIGIL_PATTERN = '([@#])(' .. WORD .. '*)$' -- sigil + typed-so-far query, at end of line
local WORD_ONLY_PATTERN = '^' .. WORD .. '+$' -- candidate text is entirely WORD chars

--- Generation counter guarding in-flight @mention queries -- a direct
--- port of TypeaheadOnDemandSource's `lastChange`/`when` check: once a
--- newer keystroke bumps this, an older debounced/in-flight request's
--- result is simply dropped instead of clobbering a fresher one.
local generation = 0

--- The sigil, its typed-so-far query text, and the buffer column the
--- query starts at -- or nil if `line` doesn't end (up to `col`) with a
--- sigil + partial word.
--- @param line string
--- @param col integer 0-indexed byte column
--- @return string? sigil
--- @return string? query
--- @return integer? start_col
local function sigil_query(line, col)
    local before = line:sub(1, col)
    local sigil, query = before:match(SIGIL_PATTERN)
    if not sigil then
        return nil
    end
    return sigil, query, col - #query
end

--- @mention candidates: live `user.search` query, debounced. `detail` is
--- the person's real name, so a completion menu showing a username like
--- "admin" can still tell you who that is.
--- @param query string
--- @param callback fun(items: arcanist.CompletionItem[])
local function mention_items(query, callback)
    -- Mirrors TypeaheadOnDemandSource's own `haveData = {'': true}`: the
    -- empty query never round-trips to the server.
    if query == '' then
        callback({})
        return
    end

    generation = generation + 1
    local my_generation = generation

    --- Every request from here needs a response one way or another (empty
    --- if this generation is no longer the latest); this is that "one way
    --- or another" for the two points below that can discover staleness.
    local function stale()
        if my_generation == generation then
            return false
        end
        callback({})
        return true
    end

    vim.defer_fn(function()
        if stale() then
            return
        end
        conduit.call('user.search', { constraints = { nameLike = query } }, function(ok, response)
            if stale() or not ok then
                return
            end
            local items = {}
            for _, user in ipairs(response.data) do
                local username = user.fields.username
                if username:match(WORD_ONLY_PATTERN) then
                    table.insert(items, { text = username, detail = user.fields.realName })
                end
            end
            callback(items)
        end)
    end, QUERY_DELAY_MS)
end

--- #project candidates: preloaded project.search list, filtered
--- client-side -- project.search has no non-deprecated substring/prefix
--- constraint (its `name` field is explicitly "(Deprecated.)"; `query` is
--- fulltext/whole-token only), so there's no live search to defer to.
--- Fetched via `source.fetch_async` (not `fetch`) so a cold cache doesn't
--- block the editor the first time `#` is typed in a session -- only the
--- write path needs the blocking variant.
--- @param query string
--- @param callback fun(items: arcanist.CompletionItem[])
local function project_items(query, callback)
    source.fetch_async('project.search', function(items)
        if not items then
            callback({})
            return
        end
        local needle = query:lower()
        local matches = {}
        for _, project in ipairs(items) do
            local slug = project.fields.slug
            if slug and slug:match(WORD_ONLY_PATTERN) and slug:lower():find(needle, 1, true) then
                table.insert(matches, { text = slug, detail = project.fields.name })
            end
        end
        callback(matches)
    end)
end

--- Completion candidates for the cursor at (0-indexed) `row`/`col` in
--- `bufnr`, or nil if nothing applies there. Callback-based throughout --
--- even the fully-cached sources call back through one -- so
--- `arcanist.lsp`'s textDocument/completion handler never blocks on a
--- cold cache and doesn't need to know which source is live vs cached;
--- `opts.live` is only there to set the LSP response's `isIncomplete`
--- correctly (a live search should be re-run as more is typed; a cached
--- list should just be filtered), and `opts.kind` picks the
--- CompletionItemKind so the menu shows something more specific than the
--- generic "Text" icon.
--- @param bufnr integer
--- @param row integer 0-indexed
--- @param col integer 0-indexed byte column
--- @param callback fun(items: arcanist.CompletionItem[]?, start_col: integer?, opts: { live: boolean, kind: integer }?)
function M.items_at(bufnr, row, col, callback)
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''

    local sigil, query, start_col = sigil_query(line, col)
    if sigil == '@' then
        mention_items(query, function(items)
            callback(items, start_col, { live = true, kind = KIND.Reference })
        end)
        return
    elseif sigil == '#' then
        -- Folder, not Reference: a project is a container you're filing
        -- into (Phorge projects nest via parent/milestone), not a pointer
        -- to one specific thing the way an @mention or T/D reference is.
        project_items(query, function(items)
            callback(items, start_col, { live = false, kind = KIND.Folder })
        end)
        return
    end

    local handler = reference.handler_for(bufnr)
    if not handler then
        callback(nil)
        return
    end

    -- Not folded into one `and`-chained expression: `and`/`or` only ever
    -- keep a multi-return call's first value, which would silently drop
    -- `prefix_len` here.
    local field, prefix_len = fields.field_for_line(handler.fields, line)
    if not (field and field.write.complete) or col < prefix_len then
        callback(nil)
        return
    end

    field.write.complete(function(items)
        callback(items, prefix_len, { live = false, kind = KIND.EnumMember })
    end)
end

return M
