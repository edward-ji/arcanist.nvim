-- The registry of Phorge object types this plugin can open -- tasks,
-- revisions, wiki documents -- and everything keyed off it: parsing a
-- ref-string ("T123", "w/some/slug/") or "arcanist://" URI back to its
-- type, each type's document schema (see arcanist.object.fields), and
-- fetching one object with its Projects resolved to hashtags.
--
-- HANDLERS (below) is the registry of supported object types; adding one
-- there is what makes most features -- open/write/read/:ArcWrite, drafts --
-- pick it up automatically. arcanist.list's picker is the one exception:
-- it still assumes a search result's own key is `obj.id`, which isn't true
-- of every handler (see HANDLERS.W's own note).

local conduit = require('arcanist.arc.conduit')
local fields = require('arcanist.object.fields')
local notify = require('arcanist.notify')
local source = require('arcanist.arc.source')

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
--- @field identity string The label naming this type on a document's
--- identity line, spelled the way Phorge spells it.
--- @field dated boolean? Whether `search` reports `fields.dateModified`,
--- which is what a document's "Last Modified:" line records.
--- @field query_keys string[] This type's search engine's builtin queries.
--- @field filters table<string, string> Filter word -> `constraints` key.
--- @field fields table[] The document schema (see arcanist.object.fields).

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
--- nothing here varies per handler, and nothing in arcanist.object.fields ever
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
        dated = true,
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
        dated = true,
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
    --
    -- Not `dated`: neither `fields` nor the `content` attachment carries a
    -- timestamp (confirmed against the Phorge source), so a wiki document
    -- has no "Last Modified:" line.
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

--- The label of the line under the identity line recording the server's
--- `dateModified` as of the fetch. Below rather than above: Phorge's commit
--- message parser appends an unknown "Label:" line to whatever field
--- precedes it, and only "Differential Revision:" reads just its first line,
--- so this is the one place `arc diff` still accepts the document.
local LAST_MODIFIED = 'Last Modified'

--- `epoch` in UTC ISO 8601, which sorts as text in time order -- so a
--- "Last Modified:" value is compared as the string it is.
--- @param epoch integer
--- @return string
local function iso8601(epoch)
    return os.date('!%Y-%m-%dT%H:%M:%SZ', epoch) --[[@as string]]
end

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
    if handler.dated then
        table.insert(handler.fields, {
            key = 'last_modified',
            kind = 'line',
            label = LAST_MODIFIED,
            read = function(f)
                return f.dateModified and iso8601(f.dateModified)
            end,
        })
    end
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
--- `arcanist.arc.source`, so it's cached the same way Status/Priority are) for
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
--- `attachments.projects.projectPHIDs`, if any -- async, so `fetch` can
--- chain it after `handler.search` without ever blocking the editor.
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

--- `fetch_sync`, without blocking the editor. `callback` runs on the main
--- loop with the object, or nil and no error if there is no such object.
--- @param handler table one of HANDLERS' values
--- @param key integer|string
--- @param callback fun(obj: table?, err: string?)
local function fetch(handler, key, callback)
    conduit.call(handler.search, handler.params(key), function(ok, response, err)
        if not ok then
            callback(nil, err)
            return
        end
        local obj = response.data[1]
        if not obj then
            callback(nil, nil)
            return
        end
        -- One more round trip before the object can be rendered: the
        -- `projects` attachment is bare PHIDs, and read_projects needs the
        -- hashtags they resolve to (see resolve_projects). Chained rather
        -- than fetched alongside, so a Projects-free object (no PHIDs to
        -- resolve) never pays for it.
        resolve_projects(obj, function()
            callback(obj, nil)
        end)
    end)
end

--- The HANDLERS entry for monogram prefix `prefix`, or nil.
--- @param prefix string
--- @return table? handler
function M.get(prefix)
    return HANDLERS[prefix]
end

--- The monogram prefix an identity-line label names ("Maniphest Task" ->
--- "T"), or nil.
--- @param label string
--- @return string?
function M.prefix_for_identity(label)
    return IDENTITY[label]
end

M.LAST_MODIFIED = LAST_MODIFIED
M.iso8601 = iso8601
M.parse_ref = parse_ref
M.parse_uri = parse_uri
M.resolve_handler = resolve_handler
M.normalize_slug = normalize_slug
M.fetch = fetch
M.fetch_sync = fetch_sync

return M
