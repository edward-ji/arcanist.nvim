-- Populates "arcanist://T123"-style buffers with a Phorge object's content,
-- fetched live over Conduit, writes edits back on `:w`, and detects the
-- object_reference (T123, D456, ...) or wiki_link ([[some/page]]) at a
-- given buffer position.
--
-- The buffer scheme itself is driven by BufReadCmd/BufWriteCmd autocmds on
-- "arcanist://*" -- the idiom fugitive.nvim uses for "fugitive://" -- so
-- reading and writing happen here regardless of how a buffer was reached:
-- `:e`/`:w arcanist://T123` typed by hand, `gf` on a reference or wiki_link
-- under the cursor (via the 'includeexpr' hook `M.gf()`, which resolves it
-- with `M.at()`/`M.wiki_at()`), or `:ArcWrite`.
--
-- Rendering and parsing are `arcanist.fields`' job -- see that module for
-- the plain-text format and why every declared field is fully editable.
--
-- HANDLERS (below) is the registry of supported object types; adding one
-- there is what makes most features -- open/write/read/:ArcWrite, drafts --
-- pick it up automatically. arcanist.list's picker is the one exception:
-- it still assumes a search result's own key is `obj.id`, which isn't true
-- of every handler (see HANDLERS.W's own note).

local conduit = require('arcanist.conduit')
local draft = require('arcanist.draft')
local fields = require('arcanist.fields')
local notify = require('arcanist.notify')
local source = require('arcanist.source')

local M = {}

--- One entry per supported object-reference kind ("T", "D", "W", ...).
--- @class arcanist.Handler
--- @field search string Conduit method to look an object up.
--- @field params fun(key: integer|string): table `search`'s params for
--- this handler's own key (a numeric id, a slug, ...).
--- @field format fun(key: integer|string): string This handler's key as
--- the ref-string that follows "arcanist://" ("T123", "w/some/slug/").
--- @field parse fun(ref_str: string): (integer|string)? The inverse of
--- `format` -- the key `ref_str` names, or nil if it isn't this handler's
--- shape.
--- @field key_of fun(obj: table): integer|string This handler's key, read
--- back out of one of `search`'s own results.
--- @field build_edit_calls fun(key: integer|string, transactions: table[], known_obj: table?): ({ method: string, params: table }[])?, string?
--- Every Conduit call `push()` should make to apply `transactions`, or nil
--- plus an error if they couldn't be built. Not every handler writes
--- through one call to one method (see W, whose Projects field needs a
--- second Conduit method), so this is the one write-shape every handler
--- implements, rather than a single-call default with an opt-in override
--- for the exception. `known_obj`, when the caller already fetched the
--- object moments earlier (its own staleness check), lets a handler avoid
--- re-fetching it just to read something off it (see W, which needs the
--- object's PHID).
--- @field filetype string Highlighting for the rendered buffer.
--- @field type string Phorge's own prose name for one ("task", "revision").
--- @field plural string `type`, pluralized (not just suffixed -- not every
--- noun inflects with an "s").
--- @field identity string The label naming this type on a document's last
--- line, spelled the way Phorge spells it.
--- @field query_keys string[] This type's search engine's builtin queries.
--- @field filters table<string, string> Filter word -> `constraints` key.
--- @field fields table[] The document schema (see arcanist.fields).

--- `params` for the common case: look an object up by its numeric id.
--- Every handler here has a Projects field, so every handler's `params`
--- requests the `projects` attachment -- see `resolve_projects`/
--- `resolve_projects_sync` below for why a second lookup still has to
--- follow before that attachment's bare PHIDs are anything a document can
--- round-trip as text.
--- @param id integer
--- @return table
local function by_id(id)
    return { constraints = { ids = { id } }, attachments = { projects = true } }
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

-- Every handler below has a Projects field, sharing one `write`
-- (fields.project_list) and one `read` -- both text-shaped, working purely
-- off `obj._project_tags`, the array of hashtags `resolve_projects`/
-- `resolve_projects_sync` stash there before render() ever sees the object.
-- Its transaction type is the literal wire value "projects.set" (not just
-- "projects") -- confirmed against maniphest.edit/differential.revision.edit/
-- phriction.document.edit's own error listings of valid transaction types,
-- all three of which take it verbatim (see HANDLERS.W's `build_edit_calls`
-- for why Wiki has to send it through a different Conduit call than its
-- other fields).
local PROJECTS = fields.project_list()

--- @param _ table (obj.fields; unused -- see `resolve_projects` above)
--- @param obj table
--- @return string
local function read_projects(_, obj)
    return table.concat(
        vim.tbl_map(function(tag)
            return '#' .. tag
        end, obj._project_tags or {}),
        ' '
    )
end

--- One shared field-list entry, reused verbatim by every handler below --
--- nothing here varies per handler, and nothing in arcanist.fields ever
--- mutates a field table in place (only `handler.fields`, the array it
--- sits in, gets appended to), so sharing the one table instance is safe.
local PROJECTS_FIELD = { key = 'projects.set', kind = 'line', label = 'Project Tags', write = PROJECTS, read = read_projects }

-- `type`/`query_keys` are what arcanist.list browses by (getBuiltinQueryNames()
-- for the latter); `filters` maps the words it narrows by to the
-- `constraints` key each is on this type's search method.
--
-- Field-by-field meaning is in the `arcanist.Handler` class doc above; what
-- follows here is the per-type "why", not repeated there:
--
-- `plural` is spelled out rather than suffixed -- not every noun inflects
-- with an "s", and "repositories" is next on the list below.
--
-- The two `query_keys` lists overlap only partly on purpose: Differential
-- has no "open", "assigned", "subscribed" or "reviewing" builtin, and
-- asking for one is a hard ERR-BAD-QUERYKEY, not an empty result.
--
-- Differential has no assignee, so it has no "owner" filter.
--
-- `key_of` differs by type because a handler's own "key" isn't always
-- `obj.id`: that's true for T/D (Conduit's numeric id doubles as how you
-- address the object), but Phriction addresses a document by slug, which
-- `phriction.document.search` returns as `obj.fields.path`, a sibling of
-- `obj.id` rather than it (see HANDLERS.W).
--
-- `build_edit_calls` differs by type similarly: T/D's edit methods are
-- EditEngine-shaped (`{objectIdentifier, transactions}`), one call for
-- every field, but `phriction.edit` takes `{slug, title?, content?}` with
-- each field inlined directly, and Projects needs a second call to a
-- different method entirely (see HANDLERS.W).
--
-- Only T/D/W for now -- P/F/M/C/r<repo> refs point at pastes, files,
-- macros, commits, and repositories respectively; left for later.

--- `format`/`parse`/`key_of`/`build_edit_calls` for a plain monogram+digits
--- type (T, D, ...): every one of the four is the same shape, parametrized
--- only by the letter and its edit method, since a monogram type's key *is*
--- the numeric Conduit id and its edit method is always EditEngine-shaped
--- -- one call, `{objectIdentifier, transactions}`. HANDLERS.W has none of
--- that in common -- no monogram, a slug for a key, Projects needing a
--- second call to a different method -- so it spells out its own
--- `build_edit_calls` instead of using this.
--- @param letter string
--- @param edit_method string
--- @return table
local function monogram_handler(letter, edit_method)
    return {
        format = function(key)
            return letter .. key
        end,
        parse = function(ref_str)
            local id = ref_str:match('^' .. letter .. '(%d+)$')
            return id and tonumber(id)
        end,
        key_of = function(obj)
            return obj.id
        end,
        build_edit_calls = function(key, transactions)
            return { { method = edit_method, params = { objectIdentifier = letter .. key, transactions = transactions } } }
        end,
    }
end

--- A wiki slug as Phorge stores it: trimmed, duplicate `/`s collapsed, no
--- leading `/`, exactly one trailing `/`. `phriction.document.search`'s
--- `paths` constraint matches this raw and unnormalized, unlike
--- `phriction.edit`'s `slug` param, which the server normalizes itself.
--- @param target string
--- @return string slug
local function normalize_slug(target)
    local slug = vim.trim(target):gsub('/+', '/'):gsub('^/', ''):gsub('/*$', '')
    return slug .. '/'
end

--- @type table<string, arcanist.Handler>
local HANDLERS = {
    T = vim.tbl_extend('force', monogram_handler('T', 'maniphest.edit'), {
        search = 'maniphest.search',
        params = by_id,
        filetype = 'remarkup',
        type = 'task',
        plural = 'tasks',
        identity = 'Maniphest Task',
        query_keys = { 'assigned', 'authored', 'subscribed', 'open', 'all' },
        filters = { owner = 'assigned', author = 'authorPHIDs' },
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
            PROJECTS_FIELD,
        },
    }),
    D = vim.tbl_extend('force', monogram_handler('D', 'differential.revision.edit'), {
        search = 'differential.revision.search',
        params = by_id,
        filetype = 'remarkup',
        type = 'revision',
        plural = 'revisions',
        identity = 'Differential Revision',
        query_keys = { 'active', 'authored', 'all' },
        filters = { author = 'authorPHIDs' },
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
            PROJECTS_FIELD,
        },
        -- Deliberately no Status field: differential.revision.edit has no
        -- transaction for it at all (confirmed live -- it errors "invalid
        -- type \"status\""). Status there only moves as a side effect of
        -- workflow verbs (accept/reject/abandon/...), which is a different
        -- feature from editing a text field, so it's left out rather than
        -- shown and silently rejected.
    }),
    -- Phriction wiki documents. Unlike every other type here, there's no
    -- monogram at all -- Phorge addresses one by slug path
    -- ("engineering/onboarding/"), so `format`/`parse` use a literal "w/"
    -- sigil (never sent to Conduit itself) rather than a single letter, to
    -- tell a slug-shaped ref-string apart from a monogram+digits one.
    --
    -- Read is `phriction.document.search` with the `content` attachment --
    -- title/body live there (`attachments.content.title`/`.content.raw`),
    -- not in `fields` like Maniphest/Differential's `fields.name`/etc.
    -- Write is the older, plain `phriction.edit` (`{slug, title?,
    -- content?}`), not the newer-looking `phriction.document.edit`: the
    -- latter's EditEngine has its own *create*-object policy hardcoded to
    -- POLICY_NOONE, and (confirmed against the Phorge source) exists mainly
    -- to support the comment UI action -- but that lockout is specific to
    -- *creating* documents through it, not editing an existing one, so
    -- `objectIdentifier`+`projects.set` against an already-loaded document
    -- works fine (confirmed live) and is Projects' own write path, wired up
    -- in `build_edit_calls` below: title/content still go through the plain
    -- `phriction.edit`, but Projects has no home there at all (its
    -- `defineParamTypes` has no such parameter), so it takes the second
    -- Conduit call instead.
    --
    -- arcanist.list's picker assumes a search result's own ref key is
    -- `obj.id`; W's is `obj.fields.path` instead (see `key_of` below).
    W = {
        search = 'phriction.document.search',
        params = function(slug)
            return {
                constraints = { paths = { slug } },
                attachments = { content = true, projects = true },
            }
        end,
        format = function(key)
            return 'w/' .. key
        end,
        -- Normalized (see normalize_slug above): every entry point (gf,
        -- :ArcWrite, push()'s own is_own/identity checks) sees the same
        -- canonical key regardless of how the ref-string was spelled.
        parse = function(ref_str)
            local slug = ref_str:match('^w/(.*)$')
            return slug and normalize_slug(slug)
        end,
        key_of = function(obj)
            return obj.fields.path
        end,
        -- Wiki is the one handler whose fields don't all write through the
        -- same Conduit method: every transaction except Projects goes to
        -- `phriction.edit` (`{slug, title?, content?}`, each field inlined
        -- directly rather than an EditEngine-shaped transactions array);
        -- Projects goes to `phriction.document.edit` instead, which needs
        -- the document's PHID as `objectIdentifier` -- not `key` (the slug).
        -- `known_obj`, when push() already fetched the document moments
        -- earlier (its own staleness check), saves resolving that PHID with
        -- a second, otherwise-redundant `phriction.document.search`.
        build_edit_calls = function(key, transactions, known_obj)
            local params, projects_transaction
            for _, t in ipairs(transactions) do
                if t.type == 'projects.set' then
                    projects_transaction = t
                else
                    params = params or { slug = key }
                    params[t.type] = t.value
                end
            end

            local calls = {}
            if params then
                table.insert(calls, { method = 'phriction.edit', params = params })
            end

            if projects_transaction then
                local phid = known_obj and known_obj.phid
                if not phid then
                    local config = require('arcanist').config
                    local ok, response, err = conduit.call_sync(
                        'phriction.document.search',
                        { constraints = { paths = { key } } },
                        config.conduit_timeout
                    )
                    if not ok then
                        return nil, string.format('failed to resolve w/%s: %s', key, err)
                    end
                    local doc = response.data[1]
                    if not doc then
                        return nil, string.format('w/%s no longer exists', key)
                    end
                    phid = doc.phid
                end
                table.insert(calls, {
                    method = 'phriction.document.edit',
                    params = { objectIdentifier = phid, transactions = { projects_transaction } },
                })
            end

            return calls
        end,
        filetype = 'remarkup',
        type = 'wiki',
        plural = 'wikis',
        identity = 'Wiki Document',
        query_keys = { 'active', 'all' },
        filters = {},
        fields = {
            {
                key = 'title',
                kind = 'title',
                write = fields.TEXT,
                read = function(_, obj)
                    return obj.attachments.content.title
                end,
            },
            {
                key = 'content',
                kind = 'block',
                label = 'Content',
                write = fields.TEXT,
                read = function(_, obj)
                    return obj.attachments.content.content.raw
                end,
            },
            PROJECTS_FIELD,
        },
    },
}

--- Parse a bare reference like "T123" or "w/some/slug/" into the HANDLERS
--- key that owns its shape ("T", "W") plus that handler's own notion of a
--- key (a numeric id for T/D, a slug string for W), or nil if it matches no
--- handler at all. Generic over HANDLERS -- adding an entry with its own
--- `parse` is what makes a new ref-string shape recognized here.
--- @param str string
--- @return string? prefix
--- @return integer|string? key
local function parse_ref(str)
    for prefix, handler in pairs(HANDLERS) do
        local key = handler.parse(str)
        if key ~= nil then
            return prefix, key
        end
    end
    return nil
end

--- The same, for an "arcanist://<ref>" URI.
--- @param uri string
--- @return string? prefix
--- @return integer|string? key
local function parse_uri(uri)
    local ref = uri:match('^arcanist://(.+)$')
    if not ref then
        return nil
    end
    return parse_ref(ref)
end

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
    -- `separate = true` marks it a trailer for M.render (blank-separated
    -- from whatever precedes it, regardless of that field's own kind).
    -- `handler.key_of(obj)` (rather than `obj.id` directly) is what lets
    -- this be generic over a handler whose own key isn't the numeric
    -- Conduit id -- see HANDLERS.W.
    table.insert(handler.fields, {
        key = 'identity',
        kind = 'line',
        label = handler.identity,
        separate = true,
        read = function(_, obj)
            return handler.format(handler.key_of(obj))
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
--- @param key integer|string
--- @return string
function M.uri(prefix, key)
    return 'arcanist://' .. HANDLERS[prefix].format(key)
end

--- Every handler's `params` requests the `projects` attachment, but Conduit
--- only ever hands that back as bare PHIDs -- never the hashtag text a
--- document round-trips as. This turns a `project.search` fetch (via
--- `arcanist.source`, so it's cached the same way Status/Priority are) for
--- those PHIDs into the tag list `read_projects` reads, in the same order
--- as `phids`; a PHID the lookup couldn't explain (a failed request, or --
--- in principle -- a project deleted between the two calls) is kept as-is
--- rather than dropped, so a failure here degrades to an odd-looking tag
--- rather than silently losing one.
--- @param items table[]?
--- @param phids string[]
--- @return string[]
local function tags_from_projects(items, phids)
    local slug_by_phid = {}
    for _, project in ipairs(items or {}) do
        slug_by_phid[project.phid] = project.fields.slug
    end
    return vim.tbl_map(function(phid)
        return slug_by_phid[phid] or phid
    end, phids)
end

--- Populate `obj._project_tags` (read_projects' own input) by resolving its
--- `attachments.projects.projectPHIDs`, if any -- async, so `load_reference`
--- can chain it after `handler.search` without ever blocking the editor.
--- @param obj table
--- @param callback fun()
local function resolve_projects(obj, callback)
    local phids = vim.tbl_get(obj, 'attachments', 'projects', 'projectPHIDs')
    if not phids or #phids == 0 then
        obj._project_tags = {}
        callback()
        return
    end
    source.fetch_async('project.search', { constraints = { phids = phids } }, function(items)
        obj._project_tags = tags_from_projects(items, phids)
        callback()
    end)
end

--- `resolve_projects`, blocking -- for the call sites (`fetch_sync`'s own
--- callers) that are already synchronous by design.
--- @param obj table
local function resolve_projects_sync(obj)
    local phids = vim.tbl_get(obj, 'attachments', 'projects', 'projectPHIDs')
    if not phids or #phids == 0 then
        obj._project_tags = {}
        return
    end
    local items = source.fetch('project.search', { constraints = { phids = phids } })
    obj._project_tags = tags_from_projects(items, phids)
end

--- Fetch `prefix`+`key` synchronously.
--- @param handler table one of HANDLERS' values
--- @param key integer|string
--- @return table? obj
--- @return string? err
local function fetch_sync(handler, key)
    local config = require('arcanist').config
    local ok, response, err = conduit.call_sync(handler.search, handler.params(key), config.conduit_timeout)
    if not ok then
        return nil, err
    end
    local obj = response.data[1]
    if obj then
        resolve_projects_sync(obj)
    end
    return obj, nil
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

--- Hand `bufnr` -- an "arcanist://<ref>" buffer whose BufReadCmd just fired --
--- over to `ref`'s draft file. The draft is a plain Remarkup file, so from
--- here on `:w` is an ordinary local write and the object lives on only in the
--- identity line `:ArcWrite` reads back. `keepalt` keeps the alternate file
--- off the husk, which wipes itself the moment we leave it.
---
--- `force` (`:e!`, after the file was just overwritten from the server) drops
--- a draft buffer that is already open first, so the reopen reads the new
--- file rather than switching back to the stale, possibly-modified buffer --
--- switching to an existing buffer never reloads it.
--- @param bufnr integer
--- @param ref string
--- @param force boolean
local function redirect_to_draft(bufnr, ref, force)
    vim.bo[bufnr].bufhidden = 'wipe'
    local path = draft.path(ref)
    vim.schedule(function()
        -- The fetch is async; the user may have left the husk before it
        -- landed. The draft file is written either way, so the next open
        -- picks it up -- just don't yank them into a window they left.
        if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end
        if force then
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if b ~= bufnr and vim.api.nvim_buf_get_name(b) == path then
                    pcall(vim.api.nvim_buf_delete, b, { force = true })
                end
            end
        end
        vim.cmd('keepalt edit ' .. vim.fn.fnameescape(path))
    end)
end

--- Populate `bufnr` (already named "arcanist://<ref>") by fetching
--- `prefix`+`key` over Conduit. Asynchronous -- there's no reason to block
--- the editor while a buffer loads; only `:w` blocks.
---
--- With drafts on, an "arcanist://" buffer is never a resting buffer: an
--- existing draft is opened straight from disk with no network (`:e`), and
--- otherwise the fetched object is written to the draft file and the buffer
--- handed to it. `:e!` (`overwrite`) skips the existing draft and refetches.
---
--- Progress and failures are reported through `vim.notify` rather than
--- written into the buffer: a buffer holding the text "Loading T1..." looks
--- exactly like a buffer whose content genuinely is that, and it would be
--- yanked, searched and saved as though it were real content.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param key integer|string
--- @param overwrite boolean from `:e!`
local function load_reference(bufnr, handler, prefix, key, overwrite)
    local ref = handler.format(key)

    if draft.enabled() and not overwrite and draft.exists(ref) then
        redirect_to_draft(bufnr, ref, false)
        return
    end

    scheme_buffer(bufnr, true)
    -- Non-editable while loading: this is what backstops a write racing the
    -- fetch (see push()), and an absent arcanist_loaded is what tells push()
    -- the buffer never received content.
    vim.b[bufnr].arcanist_loaded = nil
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    notify.info(string.format('loading %s...', ref))
    -- A BufReadCmd stands in for the whole read, the BufReadPre/BufReadPost
    -- either side of it included, so they are fired here or not at all.
    -- Post waits for the fetch: it means "this buffer now holds the object".
    vim.api.nvim_exec_autocmds('BufReadPre', { buffer = bufnr })

    conduit.call(handler.search, handler.params(key), function(ok, response, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if not ok then
            -- Content, not just the "loading" state, might be stale here --
            -- this fetch could be a reload of a previously-loaded buffer --
            -- so it's explicitly cleared rather than left as-is.
            set_lines(bufnr, {}, false)
            notify.err(string.format('failed to load %s: %s', ref, err))
            return
        end

        local obj = response.data[1]
        if not obj then
            set_lines(bufnr, {}, false)
            notify.err(string.format('%s not found', ref))
            return
        end

        -- One more round trip before render() can run: the `projects`
        -- attachment above is bare PHIDs, and read_projects needs the
        -- hashtags they resolve to (see resolve_projects). Chained rather
        -- than fetched alongside, so a Projects-free object (no PHIDs to
        -- resolve) never pays for it.
        resolve_projects(obj, function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end

            local rendered = fields.render(handler.fields, obj)

            if draft.enabled() then
                local wrote, write_err = draft.write(ref, rendered)
                if not wrote then
                    set_lines(bufnr, {}, false)
                    notify.err(write_err)
                    return
                end
                redirect_to_draft(bufnr, ref, overwrite)
                return
            end

            vim.bo[bufnr].filetype = handler.filetype
            set_lines(bufnr, rendered, true)
            vim.b[bufnr].arcanist_loaded = {
                ref = ref,
                values = fields.raw_values(handler.fields, obj),
            }
            vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr })
        end)
    end)
end

--- The object `bufnr` says it is: its last non-blank line, labelled with one
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
--- @param bufnr integer
--- @return string? prefix
--- @return integer|string? key
--- @return string? err
local function identity_of(bufnr)
    -- prevnonblank() answers "last line with anything on it" in one step,
    -- for the current buffer -- hence nvim_buf_call, which switches to
    -- `bufnr` without firing autocmds. Line 1 is always the title (see
    -- fields.parse), so a lone identity line is a title that looks like one.
    local lnum = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.prevnonblank(vim.api.nvim_buf_line_count(bufnr))
    end)
    if lnum < 2 then
        return nil
    end

    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local label, value = vim.trim(line):match('^([^:]+):%s*(.*)$')
    local want = label and IDENTITY[label]
    if not want then
        return nil
    end

    -- `arc` writes a revision's URI ("https://phorge.example.com/D456");
    -- Phorge's own parser takes that or the bare monogram, so both do here.
    local monogram = value:match('^%S+/([^/%s]+)$') or value
    local prefix, key = parse_ref(monogram)
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

    return prefix, key
end

--- The filetype for the object `bufnr`'s identity line names, if it names
--- one: the same HANDLERS entry an "arcanist://" buffer of it would get.
--- @param bufnr integer
--- @return string?
function M.filetype_of(bufnr)
    local prefix = identity_of(bufnr)
    return prefix and HANDLERS[prefix].filetype
end

--- Push `lines` (from `bufnr`) to `prefix`+`key` over Conduit. When `bufnr`
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
--- @param key integer|string
--- @param lines string[]
--- @param force boolean skip the staleness guard (from `:w!`/`:ArcWrite!`)
--- and overwrite the server's version even if it changed since load.
--- @return boolean pushed whether the object now matches the buffer.
local function push(bufnr, handler, prefix, key, lines, force)
    local ref_name = handler.format(key)
    local config = require('arcanist').config
    -- Two separate questions. Whether this is the object's own buffer
    -- (`is_own`) decides what happens to the buffer, 'modified' above all.
    -- Whether it carries a record of the object as loaded (`baseline`)
    -- decides what gets sent and whether a conflict is checked for. A copy
    -- saved out with ":sav" answers no to the first and yes to the second.
    --
    -- Compared via `parse_uri` (both sides run through `handler.parse`)
    -- rather than raw name equality, since a buffer's literal name is never
    -- rewritten to its canonical form (see HANDLERS.W's `parse`).
    local buf_prefix, buf_key = parse_uri(vim.api.nvim_buf_get_name(bufnr))
    local is_own = buf_prefix == prefix and buf_key == key
    local loaded = vim.b[bufnr].arcanist_loaded
    local baseline = loaded and loaded.ref == ref_name and loaded or nil

    if is_own and not baseline then
        notify.err(string.format('%s has not loaded successfully; nothing to update', ref_name))
        return false
    end

    local id_prefix, id_key, id_err = identity_of(bufnr)
    if id_err then
        notify.err(string.format('failed to update %s: %s', ref_name, id_err))
        return false
    end
    if id_prefix and not (id_prefix == prefix and id_key == key) then
        -- A copy about to go over the object it was copied from. `!` doesn't
        -- override this -- it means "ignore the staleness check" -- but
        -- deleting the line does.
        notify.err(
            string.format(
                '%s: this text is labelled %s. Delete the "%s:" line to push it elsewhere',
                ref_name,
                HANDLERS[id_prefix].format(id_key),
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
    -- one, so there's nothing to check for. `fresh_obj` is kept around
    -- (rather than let go once the drift check is done with it): it's
    -- handed to `build_edit_calls` below, which for some handlers (Wiki)
    -- would otherwise have to re-fetch the very same object just to read
    -- something off it (see HANDLERS.W).
    local fresh_obj
    if baseline and not force then
        local obj, err = fetch_sync(handler, key)
        if err then
            notify.err(string.format('failed to check %s for changes: %s', ref_name, err))
            return false
        end
        if not obj then
            notify.err(string.format('%s no longer exists', ref_name))
            return false
        end
        fresh_obj = obj
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

    local calls, calls_err = handler.build_edit_calls(key, transactions, fresh_obj)
    if not calls then
        notify.err(string.format('failed to update %s: %s', ref_name, calls_err))
        return false
    end

    for _, call in ipairs(calls) do
        local ok, _, err = conduit.call_sync(call.method, call.params, config.conduit_timeout)
        if not ok then
            notify.err(string.format('failed to update %s: %s', ref_name, err))
            return false
        end
    end

    if not baseline then
        notify.info('updated ' .. ref_name)
        return true
    end

    -- Re-fetch for a baseline matching what the server now holds. Content
    -- is deliberately left alone so the cursor and undo history survive the
    -- save.
    local obj, refresh_err = fetch_sync(handler, key)
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
    local prefix, key = parse_uri(args.match)
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
    if push(bufnr, handler, prefix, key, lines, vim.v.cmdbang == 1) then
        vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    end
end

--- Handle ":[line]r arcanist://<ref>": insert the object's document into
--- another buffer, after the line `:read` puts its '[ mark on. Blocking,
--- like a write: `:read` has to leave the inserted text and its marks in
--- place by the time the command returns.
--- @param args table autocmd callback args
local function read_reference(args)
    local prefix, key = parse_uri(args.match)
    local handler = resolve_handler(prefix, args.match, 'read')
    if not handler then
        return
    end

    vim.api.nvim_exec_autocmds('FileReadPre', { buffer = args.buf })
    local obj, err = fetch_sync(handler, key)
    if not obj then
        notify.err(string.format('failed to read %s: %s', handler.format(key), err or 'not found'))
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
--- identity line names (see identity_of). This is the way to push when the
--- target's own buffer is already open elsewhere -- see push()'s doc comment
--- for why `:w` can't do that.
--- @param cmd_args table nvim_create_user_command callback args
local function push_command(cmd_args)
    local bufnr = vim.api.nvim_get_current_buf()
    local ref_arg = vim.trim(cmd_args.args)
    local prefix, key, target

    if ref_arg ~= '' then
        prefix, key = parse_ref(ref_arg)
        target = 'arcanist://' .. ref_arg
        if not prefix then
            notify.err('invalid reference: ' .. ref_arg)
            return
        end
    else
        target = vim.api.nvim_buf_get_name(bufnr)
        prefix, key = parse_uri(target)
        if not prefix then
            -- Nothing in the name to go on, so fall back to what the text
            -- says it is.
            local id_prefix, id_key, id_err = identity_of(bufnr)
            if id_err then
                notify.err(':ArcWrite: ' .. id_err)
                return
            end
            prefix, key = id_prefix, id_key
            if not prefix then
                notify.err(
                    ':ArcWrite needs a reference: this is not an "arcanist://" buffer, and its '
                        .. 'last line does not name a Phorge object'
                )
                return
            end
            target = M.uri(prefix, key)
        end
    end

    local handler = resolve_handler(prefix, target, 'push')
    if not handler then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    push(bufnr, handler, prefix, key, lines, cmd_args.bang)
end

--- The bare monogram in an `object_reference` node's text: drop the leading
--- "{" of a braced reference and a trailing "#123" comment anchor (as in
--- "T123#456") -- the object itself; jumping to an anchored comment is
--- future work.
--- @param node TSNode
--- @param bufnr integer
--- @return string?
local function bare_monogram(node, bufnr)
    return vim.treesitter.get_node_text(node, bufnr):match('^{?([^#]+)')
end

--- Parse a "{F123, size=full, width=200}" embed's option text (everything
--- after the monogram, e.g. ", size=full") into a dict, the same rules
--- Phorge's own PhutilSimpleOptions uses: comma-separated "key=value" or a
--- bare "key" (-> true), keys folded to lowercase. No quoting support --
--- none of the keys this plugin acts on (size/width/height) ever need it.
--- @param text string
--- @return table<string, string|boolean>
local function parse_embed_options(text)
    local out = {}
    for _, segment in ipairs(vim.split(text, ',', { plain = true, trimempty = true })) do
        segment = vim.trim(segment)
        if segment ~= '' then
            local key, value = segment:match('^([^=]+)=(.*)$')
            if key then
                out[vim.trim(key):lower()] = vim.trim(value)
            else
                out[segment:lower()] = true
            end
        end
    end
    return out
end

--- The treesitter node at the (0-indexed, byte-offset) `row`/`col` in
--- `bufnr`'s "remarkup" parse tree, or nil if the buffer has none (parser
--- not built, wrong filetype, ...). The shared first step of
--- `monogram_at_node`/`wiki_at_node` below -- kept separate so `M.gf`
--- can look it up once and try both instead of re-parsing/re-walking the
--- same position twice on a miss.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return TSNode?
local function node_at(bufnr, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'remarkup')
    if not ok then
        return nil
    end
    -- get_node() needs an up-to-date tree; a caller may reach this before
    -- any redraw has triggered a parse.
    parser:parse()
    return vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
end

--- `monogram_at`'s own walk, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? monogram
local function monogram_at_node(node, bufnr)
    -- "{T123}" keeps its reference in an object_embed's `ref` field, and the
    -- cursor may be on the options or the closing brace instead.
    if node and node:type() == 'embed_options' then
        node = node:parent()
    end
    if node and node:type() == 'object_embed' then
        node = node:field('ref')[1]
    end
    if not node or node:type() ~= 'object_reference' then
        return nil
    end

    return bare_monogram(node, bufnr)
end

--- The object monogram at the (0-indexed, byte-offset) `row`/`col` in
--- `bufnr` -- "T123" for a bare reference, "D4" for "{D4}" -- for any
--- reference the remarkup grammar recognises, or nil if there isn't one
--- there. Whether the plugin can *open* that monogram is the caller's to
--- decide; `M.at` layers the HANDLERS gate and the "arcanist://" prefix on
--- top.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? monogram
function M.monogram_at(bufnr, row, col)
    return monogram_at_node(node_at(bufnr, row, col), bufnr)
end

--- Lazily compiled: `query.parse` needs the `remarkup` parser registered first.
--- @type vim.treesitter.Query?
local refs_query

--- Every object monogram in `bufnr`, in document order, each with the
--- 0-indexed byte range { start_row, start_col, end_row, end_col } of its
--- node -- for a caller acting on all of them at once (inline preview). Same
--- recognition as `monogram_at`; a braced "{F1}" is included via its inner
--- `object_reference` node. `options` is that embed's parsed "{F1, key=value,
--- ...}" option list (see parse_embed_options) -- empty for a bare "F1" or a
--- braced embed with none, since only the embed syntax carries options.
--- `embed_range` is the same as `range` for a bare "F1", but for a braced
--- "{F1, ...}" covers the whole embed -- opening "{" through closing "}" --
--- for a caller that wants to conceal/replace the reference wholesale
--- rather than anchor to the monogram inside it.
--- @param bufnr integer
--- @return { monogram: string, range: integer[], embed_range: integer[], options: table<string, string|boolean> }[]
function M.monograms_in(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'remarkup')
    if not ok then
        return {}
    end
    if not refs_query then
        local parsed_ok, query = pcall(vim.treesitter.query.parse, 'remarkup', '(object_reference) @ref')
        if not parsed_ok then
            return {}
        end
        refs_query = query
    end

    local tree = parser:parse()[1]
    if not tree then
        return {}
    end

    local out = {}
    for _, node in refs_query:iter_captures(tree:root(), bufnr) do
        local monogram = bare_monogram(node, bufnr)
        if monogram then
            local options = {}
            local range = { node:range() }
            local embed_range = range
            local parent = node:parent()
            if parent and parent:type() == 'object_embed' then
                embed_range = { parent:range() }
                local opts_node = parent:field('options')[1]
                if opts_node then
                    options = parse_embed_options(vim.treesitter.get_node_text(opts_node, bufnr))
                end
            end
            out[#out + 1] = { monogram = monogram, range = range, embed_range = embed_range, options = options }
        end
    end
    return out
end

--- `monogram_at` for the cursor in window `win` (default: current).
--- @param win integer?
--- @return string? monogram
function M.monogram_at_cursor(win)
    win = win or 0
    local pos = vim.api.nvim_win_get_cursor(win)
    return M.monogram_at(vim.api.nvim_win_get_buf(win), pos[1] - 1, pos[2])
end

--- `M.at`'s own resolution, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? uri
local function at_node(node, bufnr)
    local text = monogram_at_node(node, bufnr)
    if not text then
        return nil
    end
    local prefix, key = parse_ref(text)
    if not (prefix and HANDLERS[prefix]) then
        return nil
    end

    return M.uri(prefix, key)
end

--- Return the "arcanist://<ref>" URI for the object reference at the
--- (0-indexed, byte-offset) `row`/`col` in `bufnr` -- bare ("T123") or
--- braced ("{T123}") -- or nil if there isn't one there, or it's a type we
--- don't support opening yet.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? uri
function M.at(bufnr, row, col)
    return at_node(node_at(bufnr, row, col), bufnr)
end

--- Whether Phorge would render a wiki_link's raw `target` as a plain
--- hyperlink rather than resolve it as a wiki-slug lookup.
---
--- Replicates PhutilRemarkupDocumentLinkRule::markupDocumentLink's is_uri
--- check, which runs -- and, if it matches, claims the "[[...]]" outright,
--- rendering it as an ordinary link -- *before* PhrictionRemarkupRule (the
--- one that actually does the wiki-slug lookup) ever sees the text:
--- confirmed against the real rule order, ascending by priority
--- (`PhutilRemarkupBlockRule::getPriority()`'s own docstring: "smaller
--- priority numbers execute sooner"), which puts the generic 150 ahead of
--- Phriction's own 175.
---
--- A leading-slash target ("[[/some/page]]") is therefore a site-root-
--- relative hyperlink, not a wiki-slug lookup either -- Phriction documents
--- live under "/w/<slug>" (`PhrictionDocument::getSlugURI`), never at a
--- bare root path.
--- @param target string
--- @return boolean
local function is_uri(target)
    if target == '/' then
        return false
    end
    return target:match('^/') ~= nil
        or target:find('://', 1, true) ~= nil
        or target:match('^#') ~= nil
        or target:match('^mailto:') ~= nil
        or target:match('^tel:') ~= nil
end

--- Collapse a run of possibly-empty, `/`-separated path segments the way
--- `table.concat` would want them, dropping trailing slashes first so
--- splitting never yields a bogus empty final segment.
--- @param path string
--- @return string[]
local function path_segments(path)
    local segments = {}
    for segment in path:gsub('/+$', ''):gmatch('[^/]+') do
        segments[#segments + 1] = segment
    end
    return segments
end

--- Resolve a `./`/`../`-relative wiki_link `target` against `base` (the
--- current buffer's own slug), the same segment-by-segment walk Phorge's
--- own `PhrictionRemarkupRule::markupDocumentLink` does. Only meaningful
--- with a `base` -- see M.wiki_at.
--- @param target string
--- @param base string
--- @return string slug
local function resolve_relative(target, base)
    local parts = path_segments(base)
    for _, part in ipairs(path_segments(target)) do
        if part == '.' then
            -- consumed, contributes nothing
        elseif part == '..' then
            parts[#parts] = nil
        else
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, '/') .. '/'
end

--- The slug `bufnr` is itself loaded as, if it names one -- the base a
--- relative wiki_link resolves against. nil everywhere else, same as
--- Phorge, whose relative-link resolution only ever runs while rendering
--- *inside* a Phriction document (`PhrictionRemarkupRule::getRelativeBaseURI`).
---
--- Goes through `identity_of` (the buffer's own last line), not
--- `arcanist_loaded`: the latter is only ever set on a *live*
--- "arcanist://" buffer's own render, never on the draft file
--- `redirect_to_draft` hands it off to -- so with drafts on, the buffer a
--- relative link is actually resolved from is almost always the draft, and
--- `arcanist_loaded` alone would make this silently never fire there.
--- @param bufnr integer
--- @return string?
local function wiki_base(bufnr)
    local prefix, key = identity_of(bufnr)
    return prefix == 'W' and key or nil
end

--- `wiki_at`'s own walk, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? uri
local function wiki_at_node(node, bufnr)
    -- Unlike a bare "object_reference" (a leaf token, so the cursor lands on
    -- it directly), "target"/"label" are wiki_link's own child fields --
    -- the cursor typically sitting inside the link text lands on one of
    -- those, not wiki_link itself.
    if node and (node:type() == 'link_target' or node:type() == 'link_label') then
        node = node:parent()
    end
    if not node or node:type() ~= 'wiki_link' then
        return nil
    end
    local target_node = node:field('target')[1]
    if not target_node then
        return nil
    end

    local target = vim.treesitter.get_node_text(target_node, bufnr)
    if is_uri(target) then
        return nil
    end
    -- A same-page "#anchor" has no meaning for a navigation target; dropped
    -- rather than jumped to, like the rest of the target after it.
    target = target:match('^([^#]*)')

    local slug
    if target:sub(1, 2) == './' or target:sub(1, 3) == '../' then
        local base = wiki_base(bufnr)
        if not base then
            return nil
        end
        slug = resolve_relative(target, base)
    else
        slug = normalize_slug(target)
    end

    return M.uri('W', slug)
end

--- Return the "arcanist://w/<slug>" URI for the wiki_link at the
--- (0-indexed, byte-offset) `row`/`col` in `bufnr`, or nil if there isn't
--- one there, it's a target Phorge would treat as a plain hyperlink rather
--- than a wiki page (see is_uri), or it's a `./`/`../`-relative link with no
--- buffer of origin to resolve it against.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? uri
function M.wiki_at(bufnr, row, col)
    return wiki_at_node(node_at(bufnr, row, col), bufnr)
end

--- 'includeexpr' hook for Remarkup buffers. Returns the "arcanist://" URI
--- for an object reference or wiki_link under the cursor -- `gf` and the
--- rest of its family then open that via the BufReadCmd (see M.setup) --
--- or `fname` unchanged, so Vim's own file lookup handles anything else.
---
--- Vim only evaluates 'includeexpr' when the raw <cfile> is not already an
--- existing file, so a real path under the cursor never reaches here. The
--- node is resolved once here and handed to both `at_node`/`wiki_at_node`
--- rather than calling `M.at`/`M.wiki_at`, which would each reparse and
--- rewalk the same position on their own.
--- @param fname string Vim's extracted <cfile>, and the fallback.
--- @return string
function M.gf(fname)
    local bufnr = vim.api.nvim_get_current_buf()
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1] - 1, pos[2]
    local node = node_at(bufnr, row, col)
    return at_node(node, bufnr) or wiki_at_node(node, bufnr) or fname
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
            local prefix, key = parse_uri(args.match)
            local handler = resolve_handler(prefix, args.match, 'open')
            if handler then
                load_reference(args.buf, handler, prefix, key, vim.v.cmdbang == 1)
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
