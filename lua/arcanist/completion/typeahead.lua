-- Phorge-style typeahead matching, ported from
-- PhabricatorTypeaheadDatasource: a query matches a candidate when it is
-- a case-insensitive *prefix of some word* of the candidate's strings --
-- "linc" finds "Abraham Lincoln", "lncoln" does not. The server indexes
-- username+realname for users and display-name+every-slug for projects,
-- so passing those same strings here reproduces the web UI's matching.
--
-- Pure string functions -- no vim.api, no Conduit -- shared by both of
-- arcanist.completion's sigil sources.

local M = {}

-- tokenizeString splits on whitespace and "[]()-" ("splitting on '(' and
-- ')' is important for milestones", per the PHP source). Complemented
-- into a capture set here since Lua has gmatch, not preg_split.
local TOKEN = '[^%s%[%]%(%)%-]+'

--- The first word across `strings` that `query` is a case-insensitive
--- prefix of, in its original casing -- or nil if no word matches
--- (Phorge would not return such a candidate at all).
--- @param query string
--- @param strings string[]
--- @return string?
function M.match(query, strings)
    local needle = query:lower()
    for _, s in ipairs(strings) do
        for token in s:gmatch(TOKEN) do
            if token:lower():sub(1, #needle) == needle then
                return token
            end
        end
    end
    return nil
end

--- A filterText that survives the client's own re-filtering: the typed
--- query with the matched word's remainder grafted on. The client
--- matches filterText against whatever is currently typed after the
--- sigil -- which may already be *more* than `query` by the time a
--- debounced response lands -- so the query alone goes stale instantly,
--- and the raw label ("alincoln") never matched "linc" to begin with.
--- "linc" + "Lincoln" => "lincoln" keeps matching for as long as the
--- user keeps typing the word that produced the hit.
--- @param query string
--- @param token string
--- @return string
function M.graft(query, token)
    return query .. token:sub(#query + 1)
end

--- LSP sortText reproducing Phorge's result ordering: whole-name prefix
--- matches above word matches (the PHASE_PREFIX/PHASE_CONTENT split),
--- open results above closed (disabled/archived) ones, then
--- alphabetical.
--- @param prefix boolean[] whole-name prefix tiers, most significant first
--- @param closed boolean disabled user / archived project
--- @param label string
--- @return string
function M.sort_text(prefix, closed, label)
    local head = ''
    for _, tier in ipairs(prefix) do
        head = head .. (tier and '0' or '1')
    end
    return head .. (closed and '1' or '0') .. label:lower()
end

return M
