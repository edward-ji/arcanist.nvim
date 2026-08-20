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
    local ok, response, err = conduit.call_sync(method, params, timeout)
    if not ok then
        return nil, err
    end
    cache[key] = response.data
    return response.data
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

    conduit.call(method, params, function(ok, response, err)
        local waiters = pending[key]
        pending[key] = nil
        if not ok then
            for _, waiter in ipairs(waiters) do
                waiter(nil, err)
            end
            return
        end
        cache[key] = response.data
        for _, waiter in ipairs(waiters) do
            waiter(response.data)
        end
    end)
end

return M
