-- Completion for the fake in-process LSP client (arcanist.lsp):
-- @mention/#project sigils in any remarkup buffer, and Status/Priority
-- values on their own line inside an editable "arcanist://T*" buffer.
--
-- Two different data strategies, chosen by the same criterion Phorge's
-- own web typeahead uses (see JX.TypeaheadOnDemandSource vs
-- JX.TypeaheadPreloadedSource): @mention live-queries user.search
-- (debounced so typing doesn't spawn an `arc` process per keystroke);
-- #project has no usable search available via Conduit, so it preloads
-- project.search once per session via arcanist.source, same as
-- Status/Priority already do.
--
-- Both sources match and rank candidates the way Phorge's typeahead
-- does (see arcanist.typeahead): the query is a prefix of some *word* of
-- the candidate -- for users the username and real name, for projects
-- the display name and every hashtag -- so "@linc" finds Abraham Lincoln
-- and "#quality" finds a project whose only hashtag is "qa".

local conduit = require('arcanist.conduit')
local reference = require('arcanist.reference')
local fields = require('arcanist.fields')
local source = require('arcanist.source')
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

--- Generation counter guarding in-flight @mention queries -- a direct
--- port of TypeaheadOnDemandSource's `lastChange`/`when` check: once a
--- newer keystroke bumps this, an older debounced/in-flight request's
--- result is simply dropped instead of clobbering a fresher one.
local generation = 0

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
        -- Ferret fulltext (`query`) with its `~` substring operator, not
        -- the more obvious `nameLike`: nameLike compiles to a plain LIKE
        -- over columns with *binary* collation, so it is case-sensitive
        -- -- "edward" fails to find "Edward Ji" (verified against a
        -- stock instance), which is most of "some users never show up".
        -- Ferret terms are normalized, so `~edw` matches any case, over
        -- the user document's title = "username (Real Name)".
        local params = { constraints = { query = '~' .. query }, limit = 100 }
        conduit.call('user.search', params, function(ok, response)
            if stale() then
                return
            end
            if not ok then
                callback({})
                return
            end
            local items = {}
            for _, user in ipairs(response.data) do
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
                            vim.startswith(username:lower(), query:lower()),
                            closed ~= nil,
                            username
                        ),
                    })
                end
            end
            callback(ranked(items))
        end)
    end, QUERY_DELAY_MS)
end

--- #project candidates: preloaded project.search list (all pages -- see
--- arcanist.source), matched client-side -- project.search has no
--- non-deprecated substring/prefix constraint (its `name` field is
--- explicitly "(Deprecated.)"; `query` is fulltext/whole-token only), so
--- there's no live search to defer to. Fetched via `source.fetch_async`
--- (not `fetch`) so a cold cache doesn't block the editor the first time
--- `#` is typed in a session -- only the write path needs the blocking
--- variant.
---
--- The query matches against the project *name* as well as every
--- hashtag, exactly like Phorge's project datasource (whose token table
--- is built from display name + all slugs) -- but where Phorge then
--- inserts only the primary slug, every hashtag stays its own candidate
--- here, so "#quality" can complete to either of a project's tags.
--- @param query string
--- @param callback fun(items: arcanist.CompletionItem[])
local function project_items(query, callback)
    -- The "slugs" attachment, not `fields.slug`: that's only a project's
    -- primary hashtag, and "#anything" resolves against all of them.
    -- `status = "all"`: project.search silently defaults to
    -- active-projects-only (its Status field has `setDefault('active')`),
    -- but Phorge's typeahead completes archived projects too -- greyed
    -- and sorted last, which the ranking below reproduces.
    local params = {
        attachments = { slugs = true },
        constraints = { status = 'all' },
    }
    source.fetch_async('project.search', params, function(projects)
        if not projects then
            callback({})
            return
        end
        local needle = query:lower()
        local items = {}
        for _, project in ipairs(projects) do
            local name = project.fields.name
            local archived = project.fields.status == 'archived'
            local strings = { name }
            local slugs = {}
            for _, entry in ipairs(vim.tbl_get(project, 'attachments', 'slugs', 'slugs') or {}) do
                table.insert(strings, entry.slug)
                table.insert(slugs, entry.slug)
            end
            local matched = query ~= '' and typeahead.match(query, strings) or nil
            if query == '' or matched then
                local detail = archived and (name .. ' (archived)') or name
                local name_prefix = query == '' or vim.startswith(name:lower(), needle)
                for _, slug in ipairs(slugs) do
                    local ok_slug = slug:match(HASHTAG_WORD)
                        and slug:sub(1, 1) ~= '.'
                        and slug:sub(-1) ~= '.'
                    if ok_slug then
                        -- Prefer the slug's own text as the filter word
                        -- when it matches: the user continuing to type
                        -- *this label* must keep matching this item even
                        -- if the project-name word they started with
                        -- diverges ("infra..." vs "Infrastructure").
                        local slug_prefix = vim.startswith(slug:lower(), needle)
                        local word = slug_prefix and slug or matched
                        table.insert(items, {
                            text = slug,
                            detail = detail,
                            filter = word and typeahead.graft(query, word) or slug,
                            sort = typeahead.sort_text(
                                name_prefix or slug_prefix,
                                archived,
                                slug
                            ),
                        })
                    end
                end
            end
        end
        callback(ranked(items))
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
---
--- Both sigil sources are live: @mention re-queries Conduit, #project
--- re-matches the cached list -- word-prefix matching can't be
--- reproduced by the client's own filterText filtering (one string per
--- item, but many words per candidate), so the server side has to re-run
--- it on every keystroke.
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
            callback(items, start_col, { live = true, kind = KIND.Folder })
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
