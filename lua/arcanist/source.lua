-- Fetches a Conduit search method's full result list once per session and
-- caches it by method name -- Phorge's own "preloaded typeahead source"
-- strategy (see JX.TypeaheadPreloadedSource), appropriate here for the
-- same reason Phorge uses it there: small, fixed-ish lists with no live
-- substring search available server-side. Shared by `arcanist.fields`
-- (Status/Priority) and `arcanist.completion` (#project).

local conduit = require('arcanist.conduit')

local M = {}

--- @type table<string, table[]>
local cache = {}

--- @type table<string, fun(items: table[]?, err: string?)[]>
local pending = {}

--- Blocking fetch -- for call sites that need a definite answer before
--- continuing, i.e. the write path resolving a field's value during `:w`
--- (already synchronous by design, same as netrw's "scp://" writes).
---
--- If an M.fetch_async for this same method is already in flight (e.g.
--- completion prefetched it moments earlier), waits on that instead of
--- spawning a second, redundant `arc` process for the same data.
--- @param method string Conduit search method, e.g. "maniphest.status.search".
--- @return table[]? items
--- @return string? err
function M.fetch(method)
    if cache[method] then
        return cache[method]
    end
    local timeout = require('arcanist').config.conduit_timeout
    if pending[method] then
        vim.wait(timeout, function()
            return cache[method] ~= nil or not pending[method]
        end, 10)
        if cache[method] then
            return cache[method]
        end
        -- The in-flight fetch failed or didn't land in time -- fall
        -- through to a direct attempt of our own.
    end
    local ok, response, err = conduit.call_sync(method, {}, timeout)
    if not ok then
        return nil, err
    end
    cache[method] = response.data
    return response.data
end

--- Non-blocking fetch -- for interactive call sites (completion) where
--- blocking the editor on a cold cache would be noticeable. Shares the
--- same cache as M.fetch, so whichever runs first warms it for the other.
--- Concurrent callers for the same not-yet-cached method share one
--- in-flight request rather than each spawning their own.
--- @param method string
--- @param callback fun(items: table[]?, err: string?)
function M.fetch_async(method, callback)
    if cache[method] then
        callback(cache[method])
        return
    end
    if pending[method] then
        table.insert(pending[method], callback)
        return
    end
    pending[method] = { callback }

    conduit.call(method, {}, function(ok, response, err)
        local waiters = pending[method]
        pending[method] = nil
        if not ok then
            for _, waiter in ipairs(waiters) do
                waiter(nil, err)
            end
            return
        end
        cache[method] = response.data
        for _, waiter in ipairs(waiters) do
            waiter(response.data)
        end
    end)
end

return M
