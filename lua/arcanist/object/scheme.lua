-- The "arcanist://T123" buffer scheme: BufReadCmd/BufWriteCmd autocmds on
-- "arcanist://*" -- the idiom fugitive.nvim uses for "fugitive://" -- so
-- reading and writing happen here regardless of how a buffer was reached:
-- `:e`/`:w arcanist://T123` typed by hand, `gf` on a reference or wiki_link
-- under the cursor (via arcanist.reference's 'includeexpr' hook), or
-- `:ArcWrite`.

local draft = require('arcanist.object.draft')
local fields = require('arcanist.object.fields')
local notify = require('arcanist.notify')
local push = require('arcanist.object.push')
local types = require('arcanist.object.types')

local M = {}

--- Replace `bufnr`'s content without leaving it dirty.
---
--- For a failed/loading buffer (`editable = false`), explicitly clears
--- 'readonly' before flipping 'modifiable' on (rather than assuming it's
--- already off) and only sets 'readonly' back once 'modifiable' is off
--- again -- the two are never both true at the same time -- since either
--- ordering mistake trips Vim's "W10: Warning: Changing a readonly file"
--- on our own writes, including on a revisit of an already-loaded buffer.
--- @param bufnr integer
--- @param lines string[]
--- @param editable boolean
local function set_lines(bufnr, lines, editable)
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    if not editable then
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
    end
end

--- Make `bufnr` an "arcanist://" buffer, or (`scheme = false`) an ordinary
--- file buffer again.
---
--- A swapfile can't do its job here and actively gets in the way: the
--- BufReadCmd repopulates the buffer from the server on every open, so
--- recovered content is overwritten the moment the buffer opens, while a
--- swapfile left behind by a crash makes the next open fail with E325
--- against a "file" that "CANNOT BE FOUND". netrw disables them for its
--- remote buffers for the same reason.
---
--- 'bufhidden' keeps the buffer loaded when you navigate away -- cursor,
--- scroll and buffer-list position all stay put when you come back. The
--- tradeoff: revisiting it via `:e`/`:b` does not re-fire BufReadCmd (same
--- as any real file), so you see whatever was last fetched. `:e!` forces a
--- fresh fetch when that matters.
--- @param bufnr integer
--- @param scheme boolean
local function scheme_buffer(bufnr, scheme)
    -- Not `scheme and X or Y` per option: one value wanted here is `false`,
    -- which that idiom turns into Y.
    if scheme then
        vim.bo[bufnr].buftype = 'acwrite'
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].bufhidden = 'hide'
    else
        vim.bo[bufnr].buftype = ''
        vim.bo[bufnr].swapfile = vim.go.swapfile
        vim.bo[bufnr].bufhidden = ''
    end
end

--- Hand `bufnr` -- an "arcanist://<ref>" buffer whose BufReadCmd just fired --
--- over to `ref`'s draft file. The draft is a plain Remarkup file, so from
--- here on `:w` is an ordinary local write and the object lives on only in the
--- identity line `:ArcWrite` reads back. `keepalt` keeps the alternate file
--- off the husk, which wipes itself the moment we leave it.
---
--- `force` (`:e!`, after the file was just overwritten from the server) drops
--- a draft buffer that is already open first, so the reopen reads the new
--- file rather than switching back to the stale, possibly-modified buffer --
--- switching to an existing buffer never reloads it.
--- @param bufnr integer
--- @param ref string
--- @param force boolean
local function redirect_to_draft(bufnr, ref, force)
    vim.bo[bufnr].bufhidden = 'wipe'
    local path = draft.path(ref)
    vim.schedule(function()
        -- The fetch is async; the user may have left the husk before it
        -- landed. The draft file is written either way, so the next open
        -- picks it up -- just don't yank them into a window they left.
        if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end
        if force then
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if b ~= bufnr and vim.api.nvim_buf_get_name(b) == path then
                    pcall(vim.api.nvim_buf_delete, b, { force = true })
                end
            end
        end
        vim.cmd('keepalt edit ' .. vim.fn.fnameescape(path))
    end)
end

--- Populate `bufnr` (already named "arcanist://<ref>") by fetching
--- `prefix`+`key` over Conduit. Asynchronous -- there's no reason to block
--- the editor while a buffer loads; only `:w` blocks.
---
--- With drafts on, an "arcanist://" buffer is never a resting buffer: an
--- existing draft is opened straight from disk with no network (`:e`), and
--- otherwise the fetched object is written to the draft file and the buffer
--- handed to it. `:e!` (`overwrite`) skips the existing draft and refetches.
---
--- Progress and failures are reported through `vim.notify` rather than
--- written into the buffer: a buffer holding the text "Loading T1..." looks
--- exactly like a buffer whose content genuinely is that, and it would be
--- yanked, searched and saved as though it were real content.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param key integer|string
--- @param overwrite boolean from `:e!`
local function load_reference(bufnr, handler, prefix, key, overwrite)
    local ref = handler.format(key)

    if draft.enabled() and not overwrite and draft.exists(ref) then
        redirect_to_draft(bufnr, ref, false)
        return
    end

    scheme_buffer(bufnr, true)
    -- Non-editable while loading: this is what backstops a write racing the
    -- fetch (see push()), and an absent arcanist_loaded is what tells push()
    -- the buffer never received content.
    vim.b[bufnr].arcanist_loaded = nil
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
    notify.info(string.format('loading %s...', ref))
    -- A BufReadCmd stands in for the whole read, the BufReadPre/BufReadPost
    -- either side of it included, so they are fired here or not at all.
    -- Post waits for the fetch: it means "this buffer now holds the object".
    vim.api.nvim_exec_autocmds('BufReadPre', { buffer = bufnr })

    types.fetch(handler, key, function(obj, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        if err then
            -- Content, not just the "loading" state, might be stale here --
            -- this fetch could be a reload of a previously-loaded buffer --
            -- so it's explicitly cleared rather than left as-is.
            set_lines(bufnr, {}, false)
            notify.err(string.format('failed to load %s: %s', ref, err))
            return
        end

        if not obj then
            set_lines(bufnr, {}, false)
            notify.err(string.format('%s not found', ref))
            return
        end

        local rendered = fields.render(handler.fields, obj)

        if draft.enabled() then
            local wrote, write_err = draft.write(ref, rendered)
            if not wrote then
                set_lines(bufnr, {}, false)
                notify.err(write_err)
                return
            end
            redirect_to_draft(bufnr, ref, overwrite)
            return
        end

        vim.bo[bufnr].filetype = handler.filetype
        set_lines(bufnr, rendered, true)
        vim.b[bufnr].arcanist_loaded = {
            ref = ref,
            values = fields.raw_values(handler.fields, obj),
        }
        vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr })
    end)
end

--- Handle `:w`/`:w!` on an "arcanist://<ref>" target. `v:cmdbang` (rather
--- than `args`, which carries no bang info) is how autocmd callbacks learn
--- whether `!` was given.
--- @param args table autocmd callback args
local function write_reference(args)
    local prefix, key = types.parse_uri(args.match)
    local handler = types.resolve_handler(prefix, args.match, 'write')
    if not handler then
        return
    end

    -- Read the buffer after BufWritePre, so anything that rewrites it there
    -- (a formatter, say) is part of what gets pushed, and announce the write
    -- only once it has actually landed.
    local bufnr = args.buf
    vim.api.nvim_exec_autocmds('BufWritePre', { pattern = args.match })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if push.push(bufnr, handler, prefix, key, lines, vim.v.cmdbang == 1) then
        vim.api.nvim_exec_autocmds('BufWritePost', { pattern = args.match })
    end
end

--- Handle ":[line]r arcanist://<ref>": insert the object's document into
--- another buffer, after the line `:read` puts its '[ mark on. Blocking,
--- like a write: `:read` has to leave the inserted text and its marks in
--- place by the time the command returns.
--- @param args table autocmd callback args
local function read_reference(args)
    local prefix, key = types.parse_uri(args.match)
    local handler = types.resolve_handler(prefix, args.match, 'read')
    if not handler then
        return
    end

    vim.api.nvim_exec_autocmds('FileReadPre', { pattern = args.match })
    local obj, err = types.fetch_sync(handler, key)
    if not obj then
        notify.err(string.format('failed to read %s: %s', handler.format(key), err or 'not found'))
        return
    end

    local at = vim.fn.line("'[")
    local document = fields.render(handler.fields, obj)
    vim.api.nvim_buf_set_lines(args.buf, at, at, false, document)
    -- Doing the insertion by hand means setting the marks `:read` would
    -- leave around it, which is what "'[,']" after one addresses.
    vim.api.nvim_buf_set_mark(args.buf, '[', at + 1, 0, {})
    vim.api.nvim_buf_set_mark(args.buf, ']', at + #document, 0, {})
    vim.api.nvim_exec_autocmds('FileReadPost', { pattern = args.match })
end

local installed = false

--- Install the "arcanist://" buffer scheme handlers. Idempotent -- safe to
--- call from plugin/ at startup and again from every remarkup buffer, but
--- only does anything the first time: the autocmds and ":ArcWrite" are
--- session-wide, and nothing about them is per-buffer.
function M.setup()
    if installed then
        return
    end
    installed = true

    local augroup = vim.api.nvim_create_augroup('arcanist.object.scheme', { clear = true })

    vim.api.nvim_create_autocmd('BufReadCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            local prefix, key = types.parse_uri(args.match)
            local handler = types.resolve_handler(prefix, args.match, 'open')
            if handler then
                load_reference(args.buf, handler, prefix, key, vim.v.cmdbang == 1)
            end
        end,
    })

    vim.api.nvim_create_autocmd('FileReadCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = read_reference,
    })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = write_reference,
    })

    -- A partial write ("'<,'>w arcanist://T123") would parse as a document
    -- with most of its fields missing, and push that. Refused rather than
    -- half-done; without a FileWriteCmd of our own Vim would try to create a
    -- file literally called "arcanist://T123" and fail with E212.
    vim.api.nvim_create_autocmd('FileWriteCmd', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            notify.err(
                string.format(
                    'cannot write part of a buffer to %s -- a document is written whole, '
                        .. 'with ":w %s" or ":ArcWrite"',
                    args.match:gsub('^arcanist://', ''),
                    args.match
                )
            )
        end,
    })

    -- ":saveas" and ":file" change a buffer's name and none of its options,
    -- which would leave 'buftype' at "acwrite" under a name no BufWriteCmd
    -- matches -- E676, and nothing written. BufFilePre matches the name being
    -- left and BufFilePost the one being taken, so a rename lands on whichever
    -- applies and the buffer ends up as what its new name says it is.
    vim.api.nvim_create_autocmd('BufFilePre', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            scheme_buffer(args.buf, false)
        end,
    })

    vim.api.nvim_create_autocmd('BufFilePost', {
        group = augroup,
        pattern = 'arcanist://*',
        callback = function(args)
            scheme_buffer(args.buf, true)
        end,
    })

    vim.api.nvim_create_user_command('ArcWrite', push.command, {
        nargs = '?',
        bang = true,
        desc = 'Push the current buffer to a Phorge task/revision (defaults to the current '
            .. 'buffer\'s own reference). Unlike ":w arcanist://T123", works even if that '
            .. 'reference\'s own buffer is already open elsewhere. "!" overwrites even if the '
            .. 'object changed on the server since it was loaded.',
    })
end

return M
