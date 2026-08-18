-- Thin wrapper around `arc call-conduit`.

local M = {}

--- `arc` refuses ambiguous noninteractive argument lists (we have no TTY to
--- prompt on) unless `--` terminates the flags.
--- @param method string
--- @return string[]
local function cmd(method)
    return { 'arc', 'call-conduit', method, '--' }
end

--- Turn a finished `vim.system()` result into this module's
--- `(ok, result, err)` shape.
---
--- `arc` reports Conduit-level failures (bad parameters, missing objects)
--- with exit code 0 and an `error`/`errorMessage` pair in its JSON output,
--- not a nonzero exit code. A blocking call that hit its timeout arrives
--- here as code 124 with empty stderr (`vim.system():wait()`'s own
--- convention), so that's called out explicitly rather than reported as a
--- bare exit code.
--- @param obj vim.SystemCompleted
--- @return boolean ok
--- @return any result
--- @return string? err
local function decode_result(obj)
    if obj.code ~= 0 then
        if obj.code == 124 and obj.signal == 9 then
            return false, nil, 'arc call-conduit timed out'
        end
        local msg = vim.trim(obj.stderr or '')
        if msg == '' then
            msg = string.format('arc exited with code %d', obj.code)
        end
        return false, nil, msg
    end

    -- luanil: JSON `null` (e.g. a successful call's "error" field) must
    -- decode to Lua `nil`, not the truthy `vim.NIL` sentinel, or every
    -- successful call looks like a failure.
    local ok, decoded =
        pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
    if not ok then
        return false, nil, 'failed to parse arc call-conduit output: ' .. obj.stdout
    end

    if decoded.error then
        return false, nil, decoded.errorMessage or decoded.error
    end

    return true, decoded.response, nil
end

--- Call a Conduit API method asynchronously. `callback` always runs later,
--- on the main loop, whether the call succeeded or failed.
--- @param method string Conduit method name, e.g. "maniphest.search".
--- @param params table Method parameters, JSON-encodable.
--- @param callback fun(ok: boolean, result: any, err: string?)
function M.call(method, params, callback)
    -- vim.system() throws synchronously (rather than calling back) if `arc`
    -- itself can't be spawned at all, e.g. it's missing from PATH -- so that
    -- case has to be caught here and routed into `callback`, or it escapes
    -- as an error from whatever autocmd happened to trigger the call.
    local spawn_ok, spawn_err = pcall(
        vim.system,
        cmd(method),
        { stdin = vim.json.encode(params), text = true },
        vim.schedule_wrap(function(obj)
            callback(decode_result(obj))
        end)
    )
    if not spawn_ok then
        vim.schedule(function()
            callback(false, nil, vim.trim(tostring(spawn_err)))
        end)
    end
end

--- Call a Conduit API method synchronously, blocking until it finishes.
---
--- Used by the write path (`:w` on an "arcanist://" buffer), which needs a
--- definite success/failure before it can decide whether to clear
--- 'modified' -- the same blocking model netrw uses to write "scp://"
--- buffers.
--- @param method string Conduit method name, e.g. "maniphest.edit".
--- @param params table Method parameters, JSON-encodable.
--- @param timeout integer Milliseconds.
--- @return boolean ok
--- @return any result
--- @return string? err
function M.call_sync(method, params, timeout)
    local ok, obj = pcall(vim.system, cmd(method), { stdin = vim.json.encode(params), text = true })
    if not ok then
        return false, nil, vim.trim(tostring(obj))
    end
    return decode_result(obj:wait(timeout))
end

return M
