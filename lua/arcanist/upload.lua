-- Uploads a local file to Phorge and resolves it to a Remarkup monogram.
--
-- Shells out to `arc upload` rather than driving Conduit's file.allocate /
-- file.querychunks / file.uploadchunk flow ourselves: `arc` already knows
-- how to chunk large files, resume, and dedup by content hash, and
-- reimplementing that against the raw methods is only worth it if we need
-- something `arc upload` can't give us (e.g. progress -- it only draws its
-- bar to a real terminal, so a piped invocation like this gets no
-- mid-upload feedback at all).

local arc = require('arcanist.arc')

local M = {}

--- Upload a file to Phorge and resolve it to a Remarkup monogram (e.g.
--- "F123", for use as "{F123}").
--- @param path string Absolute path to a file on disk.
--- @param callback fun(ok: boolean, monogram_or_err: string)
--- @return fun() cancel Abandon the upload: kills `arc` if it is still
--- running, and stops `callback` and its notification from ever firing.
function M.upload(path, callback)
    local cancelled = false

    --- This is the only place that knows exactly what went wrong, so it
    --- also owns telling the user -- callers just get `ok = false` to know
    --- to clean up after themselves.
    --- @param msg string
    local function fail(msg)
        vim.notify(string.format('arcanist.nvim: upload of %s failed: %s', path, msg), vim.log.levels.ERROR)
        callback(false, msg)
    end

    local argv = { 'arc', 'upload', '--json', '--', path }
    local proc, spawn_err = arc.spawn(argv, { text = true }, function(obj)
        if cancelled then
            return
        end

        if obj.code ~= 0 then
            local msg = arc.error_message(obj.stderr)
            if msg == '' then
                msg = string.format('arc exited with code %d', obj.code)
            end
            fail(msg)
            return
        end

        local ok, decoded = pcall(vim.json.decode, obj.stdout)
        local file = ok and type(decoded) == 'table' and decoded[1]
        if not file or not file.id then
            fail('failed to parse arc upload output: ' .. obj.stdout)
            return
        end

        callback(true, 'F' .. file.id)
    end)
    if not proc then
        fail(spawn_err)
    end

    return function()
        cancelled = true
        -- kill() throws if `arc` has already exited on its own.
        if proc then
            pcall(proc.kill, proc, 'sigterm')
        end
    end
end

return M
