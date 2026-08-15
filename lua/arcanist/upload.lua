-- Uploads a local file to Phorge and resolves it to a Remarkup monogram.
--
-- Shells out to `arc upload` rather than driving Conduit's file.allocate /
-- file.querychunks / file.uploadchunk flow ourselves: `arc` already knows
-- how to chunk large files, resume, and dedup by content hash, and
-- reimplementing that against the raw methods is only worth it if we need
-- something `arc upload` can't give us (e.g. progress -- it only draws its
-- bar to a real terminal, so a piped invocation like this gets no
-- mid-upload feedback at all).

local M = {}

--- On failure, `arc upload` dumps a multi-line exception (timestamp, class,
--- stack trace) to stderr. Trim that down to just the exception message for
--- `callback`/`vim.notify`; falls back to the raw first line if the format
--- doesn't match (e.g. a future `arc` version rewords it).
--- @param stderr string
--- @return string
local function extract_error(stderr)
    local line = vim.trim(stderr or ''):match('^[^\n]*') or ''
    local msg = line:match('EXCEPTION:%s*%b()%s*(.-)%s+at%s+%[')
    return msg or line
end

--- Upload a file to Phorge and resolve it to a Remarkup monogram (e.g.
--- "F123", for use as "{F123}").
--- @param path string Absolute path to a file on disk.
--- @param callback fun(ok: boolean, monogram_or_err: string)
function M.upload(path, callback)
    --- This is the only place that knows exactly what went wrong, so it
    --- also owns telling the user -- callers just get `ok = false` to know
    --- to clean up after themselves.
    --- @param msg string
    local function fail(msg)
        vim.notify(string.format('arcanist.nvim: upload of %s failed: %s', path, msg), vim.log.levels.ERROR)
        callback(false, msg)
    end

    -- vim.system() throws synchronously (rather than calling back) if `arc`
    -- itself can't be spawned at all, e.g. it's missing from PATH.
    local spawn_ok, spawn_err = pcall(
        vim.system,
        { 'arc', 'upload', '--json', '--', path },
        { text = true },
        vim.schedule_wrap(function(obj)
            if obj.code ~= 0 then
                local msg = extract_error(obj.stderr)
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
    )
    if not spawn_ok then
        fail(vim.trim(tostring(spawn_err)))
    end
end

return M
