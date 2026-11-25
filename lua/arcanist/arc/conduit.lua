-- Thin wrapper around `arc call-conduit`.

local arc = require('arcanist.arc')

local M = {}

--- `arc` refuses ambiguous noninteractive argument lists (we have no TTY to
--- prompt on) unless `--` terminates the flags.
--- @param method string
--- @return string[]
local function cmd(method)
    return { 'arc', 'call-conduit', method, '--' }
end

--- @param obj vim.SystemCompleted
--- @return boolean
local function is_timeout_result(obj)
    -- Neovim versions report a terminated blocking process differently:
    -- SIGKILL normally arrives as 124/9, while SIGTERM may arrive as 143/15
    -- or 124/15 depending on the Neovim/runner version.
    local stderr = obj.stderr or ''
    return (obj.code == 124 and (obj.signal == 9 or obj.signal == 15))
        or (obj.code == 143 and obj.signal == 15)
        or stderr:find("Nvim: Caught deadly signal 'SIGTERM'", 1, true) ~= nil
        or stderr:find("Nvim: Caught deadly signal 'SIGKILL'", 1, true) ~= nil
end

--- Turn a finished `vim.system()` result into this module's
--- `(ok, result, err)` shape.
---
--- `arc` reports Conduit-level failures (bad parameters, missing objects)
--- with exit code 0 and an `error`/`errorMessage` pair in its JSON output,
--- not a nonzero exit code. A blocking call that hit its timeout arrives
--- as a version-dependent terminated process result, so that is called out
--- explicitly rather than reported as a bare exit-code error.
--- @param obj vim.SystemCompleted
--- @return boolean ok
--- @return any result
--- @return string? err
local function decode_result(obj)
    if obj.code ~= 0 then
        if is_timeout_result(obj) then
            return false, nil, 'arc call-conduit timed out'
        end
        local msg = arc.error_message(obj.stderr)
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
    -- A failed spawn is routed into `callback` too, so it runs later
    -- either way.
    local opts = { stdin = vim.json.encode(params), text = true }
    local proc, spawn_err = arc.spawn(cmd(method), opts, function(obj)
        callback(decode_result(obj))
    end)
    if not proc then
        vim.schedule(function()
            callback(false, nil, spawn_err)
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
    local proc, spawn_err = arc.spawn(cmd(method), { stdin = vim.json.encode(params), text = true })
    if not proc then
        return false, nil, spawn_err
    end
    local result = proc:wait(timeout)
    if not result then
        return false, nil, 'arc call-conduit timed out'
    end
    return decode_result(result)
end

return M
