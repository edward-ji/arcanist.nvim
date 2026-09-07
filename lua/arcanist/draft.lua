-- Local draft files for "arcanist://" objects when the drafts feature is on.
-- A draft is a plain, extensionless Remarkup document on disk: once one
-- exists, opening the object hands the buffer straight to that file, so `:w`
-- is an ordinary local write and only `:ArcWrite` talks to Phorge. The file is
-- self-describing -- its identity line names the object -- so nothing else is
-- stored beside it; `register_filetype()` is what makes it Remarkup.
--
-- Pure file I/O here: no Conduit, no field schema. arcanist.reference owns the
-- policy of when to seed a draft and when to read one back.

local M = {}

--- The `drafts` config table (see arcanist.Config).
--- @return arcanist.DraftsConfig
local function config()
    return require('arcanist').config.drafts
end

--- Whether drafts are enabled.
--- @return boolean
function M.enabled()
    return config().enabled
end

--- The on-disk path a draft for `ref` ("T123") lives at. Normalized (`~` and
--- `//` resolved) so it compares equal to the name Neovim gives the buffer
--- after `:edit`.
--- @param ref string
--- @return string
function M.path(ref)
    return vim.fs.normalize(vim.fs.joinpath(config().dir, ref))
end

--- Register a filetype rule so every file under the drafts directory opens as
--- Remarkup -- highlighting, completion and `gf` -- whichever way it is
--- reached (the redirect, a session restore, `:e` on the path by hand), and
--- without leaning on the content-sniffing `detect.identity` rule. Called from
--- `setup()` when drafts are enabled.
function M.register_filetype()
    vim.filetype.add({
        pattern = { [vim.pesc(vim.fs.normalize(config().dir)) .. '/.*'] = 'remarkup' },
    })
end

--- Whether a draft for `ref` exists on disk.
--- @param ref string
--- @return boolean
function M.exists(ref)
    return vim.uv.fs_stat(M.path(ref)) ~= nil
end

--- Seed `ref`'s draft with `lines` (the freshly-rendered object). Goes through
--- a temp file in the same directory and an atomic rename, so a crash mid-write
--- can't leave a half-written draft behind. After this, the file is the user's
--- -- their own `:w` maintains it.
--- @param ref string
--- @param lines string[]
--- @return boolean? ok
--- @return string? err
function M.write(ref, lines)
    local dir = config().dir
    local mk_ok, mk_err = pcall(vim.fn.mkdir, dir, 'p')
    if not mk_ok then
        return nil, string.format('could not create draft directory %s: %s', dir, mk_err)
    end

    local file = M.path(ref)
    local tmp = file .. '.tmp'
    local ok, err = pcall(vim.fn.writefile, lines, tmp)
    if not ok then
        return nil, string.format('could not write draft %s: %s', file, err)
    end

    local ren_ok, ren_err = vim.uv.fs_rename(tmp, file)
    if not ren_ok then
        pcall(vim.uv.fs_unlink, tmp)
        return nil, string.format('could not save draft %s: %s', file, ren_err)
    end
    return true
end

return M
