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

--- The on-disk path a draft for `ref` ("T123", "w/some/slug/") lives at.
--- Normalized (`~` and `//` resolved) so it compares equal to the name
--- Neovim gives the buffer after `:edit`.
---
--- A hierarchical ref -- one with a "/" in it, which only a wiki slug's ever
--- has -- becomes real nested directories for every segment but the last,
--- with "#" appended to the last one to turn it into a file
--- ("w/engineering/onboarding#"), rather than a flat file with every "/"
--- replaced ("w#engineering#onboarding#") or a bare "#" file inside a
--- directory per segment ("w/engineering/onboarding/#"): either of those
--- makes the *tail* of the path -- all a statusline/tabline commonly shows
--- -- either the whole mangled ref or nothing but "#", while
--- "onboarding#" alongside it still identifies the page on its own.
---
--- "#" is what a scheme with no reserved marker at all can't have: a
--- Phriction slug is simultaneously a page and the parent namespace of its
--- own children ("engineering/" is a page in its own right *and* the
--- parent of "engineering/onboarding/"), so the page's own content can't
--- live in a file *named* "engineering" once "engineering/onboarding" also
--- needs "engineering/" to be a directory -- but "engineering#" (file) and
--- "engineering/" (directory) are different names, so both coexist as
--- siblings with no collision. "#" is safe as that marker because
--- `PhabricatorSlug::normalize` bans it outright in any real slug (replaced
--- server-side with "_"), and unlike some of its other banned characters
--- ("?", "<", ...) needs no shell-quoting and is valid on every major
--- filesystem, so "<segment>#" can never equal an actual child segment's
--- own directory name.
--- @param ref string
--- @return string
function M.path(ref)
    local segments = vim.split(ref, '/', { plain = true, trimempty = true })
    if #segments > 1 then
        segments[#segments] = segments[#segments] .. '#'
    end
    return vim.fs.normalize(vim.fs.joinpath(config().dir, table.concat(segments, '/')))
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
---
--- `mkdir -p`s the file's own parent directory, not just `config().dir` --
--- for a wiki ref that's one or more slug segments deeper (see M.path).
--- @param ref string
--- @param lines string[]
--- @return boolean? ok
--- @return string? err
function M.write(ref, lines)
    local file = M.path(ref)
    local file_dir = vim.fn.fnamemodify(file, ':h')
    local mk_ok, mk_err = pcall(vim.fn.mkdir, file_dir, 'p')
    if not mk_ok then
        return nil, string.format('could not create draft directory %s: %s', file_dir, mk_err)
    end

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
