-- Fetches a Conduit search method's full result list once per session and
-- caches it by method and params -- Phorge's own "preloaded typeahead
-- source" strategy (see JX.TypeaheadPreloadedSource), appropriate here for
-- the same reason Phorge uses it there: small, fixed-ish lists with no live
-- substring search available server-side. Shared by `arcanist.fields`
-- (Status/Priority) and `arcanist.completion` (#project).

local conduit = require('arcanist.conduit')

local M = {}

--- @type table<string, table[]>
local cache = {}

--- @type table<string, fun(items: table[]?, err: string?)[]>
local pending = {}

--- Cache/dedupe key -- the same method asked with different params is a
--- different list.
--- @param method string
--- @param params table
--- @return string
local function key_for(method, params)
    return method .. ' ' .. vim.json.encode(params)
end

--- Conduit `*.search` methods page at 100 results and hand back a
--- `cursor.after` id for the next page; a single un-paged request
--- silently truncates any list past 100 (the original "#project only
--- completes the first hundred projects" bug). Both fetch variants below
--- follow the cursor until it runs out, so the cache always holds the
--- full list. Capped at Phorge's own typeahead-browse hard limit (1000
--- results) as a runaway guard. Methods without cursors (e.g.
--- maniphest.status.search, which defines no parameters at all -- so
--- no `after`/`limit` may be sent unless a cursor came back) return no
--- `cursor` and stop after one page, unchanged.
local MAX_PAGES = 10

--- Params for the page following `after`, or the caller's own params
--- verbatim for the first page (see MAX_PAGES on why nothing extra may
--- be added to it).
--- @param params table
--- @param after string|integer|nil
--- @return table
local function page_params(params, after)
    if after == nil then
        return params
    end
    return vim.tbl_extend('force', params, { after = after, limit = 100 })
end

--- Blocking fetch -- for call sites that need a definite answer before
--- continuing, i.e. the write path resolving a field's value during `:w`
--- (already synchronous by design, same as netrw's "scp://" writes).
---
--- If an M.fetch_async for this same method and params is already in
--- flight (e.g. completion prefetched it moments earlier), waits on that
--- instead of spawning a second, redundant `arc` process for the same data.
--- @param method string Conduit search method, e.g. "maniphest.status.search".
--- @param params table? Extra method parameters, e.g. attachments to include.
--- @return table[]? items
--- @return string? err
function M.fetch(method, params)
    params = params or {}
    local key = key_for(method, params)
    if cache[key] then
        return cache[key]
    end
    local timeout = require('arcanist').config.conduit_timeout
    if pending[key] then
        vim.wait(timeout, function()
            return cache[key] ~= nil or not pending[key]
        end, 10)
        if cache[key] then
            return cache[key]
        end
        -- The in-flight fetch failed or didn't land in time -- fall
        -- through to a direct attempt of our own.
    end
    local items = {}
    local after = nil
    for _ = 1, MAX_PAGES do
        local ok, response, err = conduit.call_sync(method, page_params(params, after), timeout)
        if not ok then
            return nil, err
        end
        vim.list_extend(items, response.data)
        after = vim.tbl_get(response, 'cursor', 'after')
        if after == nil then
            break
        end
    end
    cache[key] = items
    return items
end

--- Non-blocking fetch -- for interactive call sites (completion) where
--- blocking the editor on a cold cache would be noticeable. Shares the
--- same cache as M.fetch, so whichever runs first warms it for the other.
--- Concurrent callers for the same not-yet-cached method share one
--- in-flight request rather than each spawning their own.
--- @param method string
--- @param params table? As in M.fetch.
--- @param callback fun(items: table[]?, err: string?)
function M.fetch_async(method, params, callback)
    params = params or {}
    local key = key_for(method, params)
    if cache[key] then
        callback(cache[key])
        return
    end
    if pending[key] then
        table.insert(pending[key], callback)
        return
    end
    pending[key] = { callback }

    local function finish(items, err)
        local waiters = pending[key]
        pending[key] = nil
        if items then
            cache[key] = items
        end
        for _, waiter in ipairs(waiters) do
            waiter(items, err)
        end
    end

    local items = {}
    local function fetch_page(after, pages_left)
        conduit.call(method, page_params(params, after), function(ok, response, err)
            if not ok then
                finish(nil, err)
                return
            end
            vim.list_extend(items, response.data)
            local next_after = vim.tbl_get(response, 'cursor', 'after')
            if next_after ~= nil and pages_left > 1 then
                fetch_page(next_after, pages_left - 1)
            else
                finish(items)
            end
        end)
    end
    fetch_page(nil, MAX_PAGES)
end

return M
