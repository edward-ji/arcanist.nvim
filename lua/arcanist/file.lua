-- Download a Phorge file object ("F123") into a local cache and hand it to a
-- viewer. Phorge files are content-immutable -- an id resolves to the exact
-- same bytes for as long as it exists -- so a file cached under its monogram
-- never needs revalidating; ":ArcFile!" forces a re-fetch regardless.
--
-- Shells out to `arc download` rather than Conduit's file.download (base64
-- inside a JSON envelope): `arc` streams the bytes straight to disk and
-- reassembles chunked files, so nothing large passes through the editor.

local conduit = require('arcanist.conduit')
local notify = require('arcanist.notify')

local M = {}

--- Cache root. Each file gets its own directory, "<CACHE>/F<id>/", holding
--- one download under its original name: `arc download --as` wants an exact
--- path in a directory that already exists (it refuses to overwrite and
--- won't create parents), and `file.search` always gives us the name, so a
--- directory per id keeps the real filename without a scheme of our own.
local CACHE = vim.fs.joinpath(vim.fn.stdpath('cache'), 'arcanist', 'files')

--- Fetches still running, keyed by numeric id, each the list of callbacks
--- waiting on it: a second fetch of a file already loading joins the first
--- instead of racing it for the same staging file.
--- @type table<integer, fun(path: string?, info: arcanist.FileInfo?, err: string?)[]>
local in_flight = {}

--- The numeric id of a file monogram ("F123", "{F123}"), or nil for anything
--- else -- also the "is this previewable" test `:ArcFile` and the `gf` map
--- gate on.
--- @param monogram string
--- @return integer?
function M.file_id(monogram)
    return tonumber(tostring(monogram):match('^{?F(%d+)}?$'))
end

--- "72 B", "916.0 KB", "1.4 MB".
--- @param bytes integer
--- @return string
local function human(bytes)
    local units = { 'B', 'KB', 'MB', 'GB', 'TB' }
    local n, i = bytes, 1
    while n >= 1024 and i < #units do
        n, i = n / 1024, i + 1
    end
    return i == 1 and string.format('%d B', n) or string.format('%.1f %s', n, units[i])
end

--- A human message out of `arc download`'s stderr, which leads each line with
--- a marker (" DATA ", " USAGE EXCEPTION ", ...).
--- @param stderr string
--- @return string
local function arc_error(stderr)
    stderr = vim.trim(stderr or '')
    if stderr == '' then
        return 'arc download failed'
    end
    return stderr:match('USAGE EXCEPTION%s+([^\n]+)') or vim.split(stderr, '\n', { plain = true })[1]
end

--- The completed download for `id`, if one is cached -- a leftover ".part"
--- from an interrupted fetch does not count.
--- @param id integer
--- @return string? path
--- @return string? name
local function cached(id)
    local dir = vim.fs.joinpath(CACHE, 'F' .. id)
    for name, typ in vim.fs.dir(dir) do
        if typ == 'file' and not name:match('%.part$') then
            return vim.fs.joinpath(dir, name), name
        end
    end
    return nil
end

--- Fetch F<id>'s metadata over Conduit -- no download, so it works
--- regardless of size and isn't subject to `config.file.max_bytes`. Not
--- cached: unlike a file's bytes, its `name` (and so its `alt` text) is
--- not content-immutable -- it can be renamed on Phorge without changing
--- the object -- and a `file.search` call is cheap next to `arc
--- download`, so `inline.text` (the only repeat caller) just asks fresh
--- every render rather than risk showing a stale name. `cb` runs on the
--- main loop, `(nil, err)` on failure.
--- @param monogram string  "F123" (also accepts "{F123}").
--- @param opts? { quiet: boolean }  quiet: no error message -- `cb` still
---   gets the error string.
--- @param cb fun(info: arcanist.FileInfo?, err: string?)
function M.info(monogram, opts, cb)
    opts = opts or {}
    local function fail(msg)
        if not opts.quiet then
            notify.err(msg)
        end
        return cb(nil, msg)
    end

    local id = M.file_id(monogram)
    if not id then
        return fail(string.format('%q is not a file monogram', tostring(monogram)))
    end

    conduit.call('file.search', { constraints = { ids = { id } } }, function(ok, result, err)
        if not ok then
            return fail(string.format('F%d: %s', id, err))
        end
        local file = result and result.data and result.data[1]
        if not file then
            return fail(string.format('F%d not found', id))
        end

        local name = vim.fs.basename(file.fields.name or '')
        if name == '' then
            name = 'F' .. id
        end
        cb({
            monogram = 'F' .. id,
            name = name,
            bytes = file.fields.size,
            alt = file.fields.alt and file.fields.alt.default,
        })
    end)
end

--- Fetch F<id> into the cache and call `cb` with the local path. No viewer --
--- `preview()` adds that; a caller that only wants the file uses this
--- directly. `cb` runs on the main loop, `(nil, nil, err)` on failure; a
--- fetch for a file already loading gets that fetch's result.
--- @param monogram string  "F123" (also accepts "{F123}").
--- @param opts? { force: boolean, quiet: boolean }  force: re-download past
---   the cache and ignore `config.file.max_bytes` (the ":ArcFile!" bang).
---   quiet: no progress or error messages -- for inline preview, where an
---   oversized or missing file just does not draw. `cb` still gets the
---   error string.
--- @param cb fun(path: string?, info: arcanist.FileInfo?, err: string?)
function M.fetch(monogram, opts, cb)
    opts = opts or {}

    -- `quiet` (inline preview) silences every message; the caller still gets
    -- the error string through `cb`.
    local function progress(msg)
        if not opts.quiet then
            notify.info(msg)
        end
    end
    local function report(msg)
        if not opts.quiet then
            notify.err(msg)
        end
    end

    local id = M.file_id(monogram)
    if not id then
        local msg = string.format('%q is not a file monogram', tostring(monogram))
        report(msg)
        return cb(nil, nil, msg)
    end
    if in_flight[id] then
        progress(string.format('F%d is already loading', id))
        table.insert(in_flight[id], cb)
        return
    end
    if not opts.force then
        local path, name = cached(id)
        if path then
            return cb(path, { monogram = 'F' .. id, name = name })
        end
    end

    local waiters = { cb }
    in_flight[id] = waiters
    local function done(path, info, err)
        in_flight[id] = nil
        for _, waiter in ipairs(waiters) do
            waiter(path, info, err)
        end
    end
    local function fail(msg)
        report(msg)
        return done(nil, nil, msg)
    end

    M.info(monogram, { quiet = true }, function(info, err)
        if not info then
            return fail(err)
        end

        local name, bytes = info.name, info.bytes

        local cap = require('arcanist').config.file.max_bytes
        if not opts.force and bytes and cap and bytes > cap then
            return fail(
                string.format(
                    'F%d is %s (cap %s) -- :ArcFile! to fetch it anyway',
                    id,
                    human(bytes),
                    human(cap)
                )
            )
        end

        -- Inline preview fetches every reference at once, so two downloads can
        -- be creating CACHE concurrently and `mkdir(..., 'p')` throws E739 if
        -- the directory appears between its own check and mkdir(2).
        local dir = vim.fs.joinpath(CACHE, 'F' .. id)
        local mk_ok, mk_err = pcall(vim.fn.mkdir, dir, 'p')
        if not mk_ok and not vim.uv.fs_stat(dir) then
            return fail(string.format('could not create cache directory %s: %s', dir, mk_err))
        end
        local dest = vim.fs.joinpath(dir, name)
        local part = dest .. '.part'
        -- `arc download --as` refuses a path that already exists, so clear a
        -- stale staging file and, on a forced re-fetch, the cached copy.
        pcall(os.remove, part)
        if opts.force then
            pcall(os.remove, dest)
        end

        progress(string.format('loading F%d (%s, %s)...', id, name, bytes and human(bytes) or '?'))

        vim.system(
            { 'arc', 'download', '--as', part, '--', 'F' .. id },
            { text = true },
            vim.schedule_wrap(function(obj)
                if obj.code ~= 0 then
                    pcall(os.remove, part)
                    return fail(string.format('F%d: %s', id, arc_error(obj.stderr)))
                end
                -- Same directory, so this is atomic; a partial download never
                -- sits where `cached()` would find it.
                local renamed, rename_err = os.rename(part, dest)
                if not renamed then
                    pcall(os.remove, part)
                    return fail(string.format('F%d: %s', id, rename_err))
                end
                done(dest, info)
            end)
        )
    end)
end

--- Open `path` with the OS handler. A machine with no opener -- headless, no
--- xdg-open -- keeps the file and is told where it landed.
--- @param path string
--- @param info arcanist.FileInfo
local function system_open(path, info)
    local proc, err = vim.ui.open(path)
    if not proc then
        notify.warn(string.format('%s saved to %s (%s)', info.monogram, path, err))
    end
end

--- Bundled `file.open` handlers, each `fun(path, info)`, selected by name.
local presets = {
    --- Render whatever snacks.image can (image, video frame, PDF page) as an
    --- ":edit" buffer -- its own BufReadCmd draws it inline -- and leave the
    --- rest to the system app.
    snacks = function(path, info)
        local ok, image = pcall(require, 'snacks.image')
        if ok and image.supports_file and image.supports_file(path) then
            vim.cmd.edit(vim.fn.fnameescape(path))
        else
            system_open(path, info)
        end
    end,
}

--- Hand a downloaded file to `config.file.open` -- a `fun(path, info)` or
--- the name of a bundled preset -- or to `vim.ui.open`.
--- @param path string
--- @param info arcanist.FileInfo
local function open(path, info)
    local hook = require('arcanist').config.file.open
    if type(hook) == 'string' then
        if not presets[hook] then
            notify.err(string.format('file.open: unknown preset %q', hook))
            return
        end
        hook = presets[hook]
    end
    if hook then
        return hook(path, info)
    end
    system_open(path, info)
end

--- Download a file object and open it. `opts.force` (the ":ArcFile!" bang)
--- re-downloads past the cache and ignores `config.file.max_bytes`.
--- @param monogram string
--- @param opts? { force: boolean }
function M.preview(monogram, opts)
    M.fetch(monogram, opts, function(path, info)
        if path then
            open(path, info)
        end
    end)
end

return M
