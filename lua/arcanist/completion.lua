-- Completion for the fake in-process LSP client (arcanist.lsp):
-- @mention/#project sigils in any remarkup buffer, and Status/Priority
-- values on their own line inside an editable "arcanist://T*" buffer.
--
-- Both sigils search on demand (Prefab.js's JX.TypeaheadOnDemandSource):
-- each keystroke runs one debounced Conduit search, and only the newest
-- response is kept. Status/Priority are short fixed lists with no search
-- behind them, so they preload once via arcanist.source.
--
-- Both sources match and rank candidates the way Phorge's typeahead
-- does (see arcanist.typeahead): the query is a prefix of some *word* of
-- the candidate -- for users the username and real name, for projects
-- the display name and every hashtag -- so "@linc" finds Abraham Lincoln
-- and "#qual" finds a project named "Quality Assurance", offering its
-- "qa" hashtag.

local arcanist = require('arcanist')
local conduit = require('arcanist.conduit')
local reference = require('arcanist.reference')
local fields = require('arcanist.fields')
local typeahead = require('arcanist.typeahead')

local KIND = vim.lsp.protocol.CompletionItemKind

local M = {}

-- Matches Phorge's own default typeahead debounce (Prefab.js's
-- TypeaheadOnDemandSource queryDelay).
local QUERY_DELAY_MS = 125

-- Per-sigil query charsets, matching tree-sitter-remarkup (grammar.js) --
-- the only text that can ever parse back as a `mention`/`project_tag`
-- node once inserted, so they double as both "how much of the sigil's
-- typed text counts as the query" and "which candidates are even safe to
-- offer". Mentions are PhabricatorMentionRemarkupRule's explicit
-- username charset; hashtags are ProjectRemarkupRule's *negative* set
-- (anything but whitespace and `?!,:;{}#()"'*/~`, no edge "."), so
-- "#c++" and "#v1.0" query and complete fine. Real slugs outside even
-- that set (e.g. containing "/") are filtered out rather than offered
-- and then not highlighted. Both patterns capture the sigil's byte
-- position for the word-boundary check below.
local MENTION_QUERY = '()@([A-Za-z0-9_.%-]*)$'
local MENTION_WORD = '^[A-Za-z0-9_.%-]*[A-Za-z0-9_%-]$'
local HASHTAG_CHAR = '[^%s?!,:;{}#()"\'*/~]'
local HASHTAG_QUERY = '()#(' .. HASHTAG_CHAR .. '*)$'
local HASHTAG_WORD = '^' .. HASHTAG_CHAR .. '+$'

--- @type { sigil: string, pattern: string }[]
local SIGILS = {
    { sigil = '@', pattern = MENTION_QUERY },
    { sigil = '#', pattern = HASHTAG_QUERY },
}

-- PHUIXAutocomplete's word-boundary whitelist: besides start-of-line and
-- whitespace, the only characters a trigger sigil may follow ("might be
-- an unnumbered list", "might be a table cell", ...). Anything else --
-- "foo@bar.com", "c#", a doubled "@@"/"##" -- is probably not the start
-- of a mention or hashtag, and Phorge's editor doesn't complete there
-- either.
local BOUNDARY = { ['('] = true, ['-'] = true, ['.'] = true, ['|'] = true, ['>'] = true, ['!'] = true }

--- Order items by their Phorge-style sort key (see
--- typeahead.sort_text). sortText alone isn't enough: clients *may* sort
--- by it, but Neovim's built-in completion keeps the server's order, so
--- the response itself has to arrive ranked.
--- @param items arcanist.CompletionItem[]
--- @return arcanist.CompletionItem[]
local function ranked(items)
    table.sort(items, function(a, b)
        return a.sort < b.sort
    end)
    return items
end

--- The last Conduit failure surfaced to the user. Deduped because a
--- broken `arc` (wrong `.arcconfig` URI, expired token) would otherwise
--- notify once per typed character.
--- @type string?
local last_failure

--- @param sigil string
--- @param err string?
local function report_failure(sigil, err)
    local msg = string.format('%s completion failed: %s', sigil, err or 'unknown error')
    if msg ~= last_failure then
        last_failure = msg
        vim.notify('arcanist.nvim: ' .. msg, vim.log.levels.WARN)
    end
end

--- Generation counter guarding in-flight sigil queries -- a direct port
--- of TypeaheadOnDemandSource's `lastChange`/`when` check: once a newer
--- keystroke bumps this, an older debounced/in-flight request's result
--- is dropped instead of clobbering a fresher one. One counter for both
--- sigils: only one can be under the cursor, so a new `#` query
--- invalidates an outstanding `@` one too.
local generation = 0

--- The `constraints.query` value matching `query` as a substring.
---
--- Ferret's `~`, not the per-method name filters: user.search's
--- `nameLike` is a LIKE over binary-collation columns, so case-sensitive
--- ("edward" never finds "Edward Ji"), and project.search's `name` is
--- deprecated. The term is quoted because `~` followed by `-`, `+` or
--- `=` is a hard Conduit error and both sigil charsets can produce one
--- ("#-foo"); neither admits a `"`, so the quote cannot be closed early.
--- @param query string
--- @return string
local function substring_query(query)
    return '~"' .. query .. '"'
end

-- Phorge's own typeahead page size. The server applies it to the
-- substring match, before the stricter word-prefix filter, so a very
-- short query can fill the page with rows that all get filtered away.
local RESULT_LIMIT = 100

--- Run one debounced Conduit search for a sigil source and hand its
--- ranked items to `callback`. The empty query never round-trips
--- (TypeaheadOnDemandSource's own `haveData = {'': true}`); `spec.params`
--- adds whatever the method needs beyond the search itself.
--- @param spec { sigil: string, method: string, query: string, params: table?, build: fun(query: string, data: table[]): arcanist.CompletionItem[] }
--- @param callback fun(items: arcanist.CompletionItem[])
local function live_items(spec, callback)
    if spec.query == '' then
        callback({})
        return
    end

    generation = generation + 1
    local my_generation = generation

    --- A superseded request still owes its caller a response.
    local function stale()
        if my_generation == generation then
            return false
        end
        callback({})
        return true
    end

    local params = vim.tbl_deep_extend('force', {
        constraints = { query = substring_query(spec.query) },
        limit = RESULT_LIMIT,
    }, spec.params or {})

    vim.defer_fn(function()
        if stale() then
            return
        end
        conduit.call(spec.method, params, function(ok, response, err)
            if stale() then
                return
            end
            if not ok then
                report_failure(spec.sigil, err)
                callback({})
                return
            end
            last_failure = nil
            callback(ranked(spec.build(spec.query, response.data or {})))
        end)
    end, QUERY_DELAY_MS)
end

--- The sigil, its typed-so-far query text, and the buffer column the
--- query starts at -- or nil if `line` doesn't end (up to `col`) with a
--- word-boundary + sigil + partial word.
--- @param line string
--- @param col integer 0-indexed byte column
--- @return string? sigil
--- @return string? query
--- @return integer? start_col
local function sigil_query(line, col)
    local before = line:sub(1, col)
    for _, spec in ipairs(SIGILS) do
        local idx, query = before:match(spec.pattern)
        if idx then
            local prev = before:sub(idx - 1, idx - 1)
            if prev == '' or prev:match('%s') or BOUNDARY[prev] then
                return spec.sigil, query, col - #query
            end
            return nil
        end
    end
    return nil
end

--- Phorge marks these users "closed" in typeahead results (greyed and
--- sorted last, but still offered) -- mirrored here via `detail` and
--- sortText. Same precedence as PhabricatorPeopleDatasource.
--- @param roles string[]?
--- @return string?
local function closed_role(roles)
    local flags = {}
    for _, role in ipairs(roles or {}) do
        flags[role] = true
    end
    if flags.disabled then
        return 'disabled'
    elseif flags.bot then
        return 'bot'
    elseif flags.list then
        return 'mailing list'
    end
    return nil
end

--- @mention candidates: live `user.search` query, debounced. `detail` is
--- the person's real name, so a completion menu showing a username like
--- "admin" can still tell you who that is.
--- @param query string
--- @param callback fun(items: arcanist.CompletionItem[])
local function mention_items(query, callback)
    live_items({
        sigil = '@mention',
        method = 'user.search',
        query = query,
        build = function(_, data)
            local items = {}
            for _, user in ipairs(data) do
                local username = user.fields.username
                local real_name = user.fields.realName or ''
                -- `~` is a *substring* search, one notch looser than
                -- Phorge's own word-prefix typeahead -- so a hit with
                -- no word-prefix match ("@ncol" finding Lincoln) is
                -- dropped to keep results identical to the web UI's.
                local matched = typeahead.match(query, { username, real_name })
                if matched and username:match(MENTION_WORD) then
                    local closed = closed_role(user.fields.roles)
                    table.insert(items, {
                        text = username,
                        detail = closed and string.format('%s (%s)', real_name, closed)
                            or real_name,
                        filter = typeahead.graft(query, matched),
                        sort = typeahead.sort_text(
                            { vim.startswith(username:lower(), query:lower()) },
                            closed ~= nil,
                            username
                        ),
                    })
                end
            end
            return items
        end,
    }, callback)
end

--- One completion item per hashtag of every matching project. Phorge's
--- project datasource matches the same strings -- display name plus all
--- slugs -- but inserts only the primary slug; here every hashtag stays
--- its own candidate, so a project tagged both "#qa" and
--- "#quality_assurance" offers either.
--- @param query string
--- @param data table[]
--- @return arcanist.CompletionItem[]
local function project_build(query, data)
    local needle = query:lower()
    local items = {}
    for _, project in ipairs(data) do
        local name = project.fields.name
        local archived = project.fields.status == 'archived'
        local slugs = {}
        for _, entry in ipairs(vim.tbl_get(project, 'attachments', 'slugs', 'slugs') or {}) do
            table.insert(slugs, entry.slug)
        end
        local matched = typeahead.match(query, vim.list_extend({ name }, slugs))
        for _, slug in ipairs(matched and slugs or {}) do
            local ok_slug = slug:match(HASHTAG_WORD)
                and slug:sub(1, 1) ~= '.'
                and slug:sub(-1) ~= '.'
            if ok_slug then
                -- Prefer the slug's own text as the filter word when it
                -- matches: the user continuing to type *this label* must
                -- keep matching this item even if the project-name word
                -- they started with diverges ("infra..." vs
                -- "Infrastructure").
                local slug_prefix = vim.startswith(slug:lower(), needle)
                table.insert(items, {
                    text = slug,
                    detail = archived and (name .. ' (archived)') or name,
                    filter = typeahead.graft(query, slug_prefix and slug or matched),
                    -- This hashtag's own prefix outranks the project name's.
                    sort = typeahead.sort_text(
                        { slug_prefix, vim.startswith(name:lower(), needle) },
                        archived,
                        slug
                    ),
                })
            end
        end
    end
    return items
end

--- #project candidates: live `project.search` query, debounced. Ferret
--- indexes a project's slugs alongside its display name, so `~` finds a
--- project by any of its hashtags.
--- @param query string
--- @param callback fun(items: arcanist.CompletionItem[])
local function project_items(query, callback)
    live_items({
        sigil = '#project',
        method = 'project.search',
        query = query,
        -- The "slugs" attachment, not `fields.slug`: that's only a
        -- project's primary hashtag, and "#anything" resolves against all
        -- of them. `status = "all"`: project.search silently defaults to
        -- active-projects-only (its Status field has
        -- `setDefault('active')`), but Phorge's typeahead completes
        -- archived projects too, greyed and sorted last.
        params = {
            attachments = { slugs = true },
            constraints = { status = 'all' },
        },
        build = project_build,
    }, callback)
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
---
--- Both sigil sources are live: each re-queries Conduit, and the client
--- can't take over the filtering as more is typed -- word-prefix
--- matching runs over many words per candidate, but filterText carries
--- only one string per item.
--- @param bufnr integer
--- @param row integer 0-indexed
--- @param col integer 0-indexed byte column
--- @param callback fun(items: arcanist.CompletionItem[]?, start_col: integer?, opts: { live: boolean, kind: integer }?)
function M.items_at(bufnr, row, col, callback)
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''

    local sigil, query, start_col = sigil_query(line, col)
    if sigil == '@' then
        mention_items(query, function(items)
            callback(items, start_col, { live = true, kind = KIND[arcanist.config.completion.mention_kind] })
        end)
        return
    elseif sigil == '#' then
        project_items(query, function(items)
            callback(items, start_col, { live = true, kind = KIND[arcanist.config.completion.project_kind] })
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
    if not (field and field.write and field.write.complete) or col < prefix_len then
        callback(nil)
        return
    end

    field.write.complete(function(items)
        callback(items, prefix_len, { live = false, kind = KIND.EnumMember })
    end)
end

return M
