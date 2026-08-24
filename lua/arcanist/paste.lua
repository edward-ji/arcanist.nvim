-- Auto-upload files pasted into Remarkup buffers.
--
-- Uploads are async: a "{Uploading ...}" placeholder goes in immediately
-- (paste must return synchronously), tracked by extmark, and swapped for
-- the real reference when the upload finishes -- or removed, on failure,
-- in favor of a vim.notify error.

local arcanist = require('arcanist')
local upload = require('arcanist.upload')

local M = {}

local ns = vim.api.nvim_create_namespace('arcanist.paste')
local installed = false

-- Cancel functions for the uploads still in flight, by buffer.
local in_flight = {} ---@type table<integer, table<integer, function>>

--- Drop every placeholder in `bufnr` and cancel the uploads feeding them.
---
--- Bound to BufUnload, which fires on `:bdelete` and on every reload. A
--- reload is the reason this has to exist: `:e!` re-reads the buffer without
--- adjusting extmarks, so afterwards they point at stale byte offsets in
--- content nobody pasted into, and writing a reference there silently
--- overwrites it.
--- @param bufnr integer
local function abandon(bufnr)
    local tasks = in_flight[bufnr]
    in_flight[bufnr] = nil

    local cancelled = 0
    for _, cancel in pairs(tasks) do
        cancel()
        cancelled = cancelled + 1
    end

    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end

    if cancelled > 0 then
        vim.notify(
            string.format('arcanist.nvim: buffer unloaded -- cancelled %d upload(s)', cancelled),
            vim.log.levels.WARN
        )
    end
end

--- @param bufnr integer
--- @return table<integer, function> tasks
local function watch(bufnr)
    local tasks = in_flight[bufnr]
    if not tasks then
        tasks = {}
        in_flight[bufnr] = tasks
        vim.api.nvim_create_autocmd('BufUnload', {
            buffer = bufnr,
            once = true,
            callback = function()
                abandon(bufnr)
            end,
        })
    end
    return tasks
end

-- Accumulates lines across a streamed paste; nil when no stream is in
-- progress.
local pending_lines = nil ---@type string[]?

--- Merge a chunk into `pending_lines` the way Neovim concatenates streamed
--- paste chunks: a paste can split mid-line, so the last accumulated line
--- and the chunk's first line join into one.
--- @param lines string[]
local function merge_chunk(lines)
    if #lines == 0 then
        lines = { '' }
    end
    pending_lines[#pending_lines] = pending_lines[#pending_lines] .. lines[1]
    vim.list_extend(pending_lines, lines, 2)
end

--- Split a shell-quoted/escaped string into words: unescaped whitespace
--- separates words, "\<char>" is a literal char, and '...'/"..." group a
--- word without splitting it. This is how terminals join a multi-file
--- paste (e.g. WezTerm shlex-escapes each path).
--- @param line string
--- @return string[]
local function split_words(line)
    local words = {}
    local current = {}
    local in_quote = nil ---@type string?
    local i, n = 1, #line

    while i <= n do
        local c = line:sub(i, i)
        if in_quote then
            if c == in_quote then
                in_quote = nil
            else
                current[#current + 1] = c
            end
            i = i + 1
        elseif c == '\\' and i < n then
            current[#current + 1] = line:sub(i + 1, i + 1)
            i = i + 2
        elseif c == "'" or c == '"' then
            in_quote = c
            i = i + 1
        elseif c:match('%s') then
            if #current > 0 then
                words[#words + 1] = table.concat(current)
                current = {}
            end
            i = i + 1
        else
            current[#current + 1] = c
            i = i + 1
        end
    end
    if #current > 0 then
        words[#words + 1] = table.concat(current)
    end

    return words
end

--- Require an absolute path ("/" or "~"): terminals paste absolute paths,
--- and this stops a plain word of prose from matching a same-named file
--- in the current directory.
--- @param path string
--- @return boolean
local function is_existing_absolute_file(path)
    if not path:match('^[~/]') then
        return false
    end
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == 'file'
end

--- Return the existing absolute file path(s) `lines` is made up of, or nil
--- if it isn't only that.
--- @param lines string[]
--- @return string[]?
local function paths_in(lines)
    local line
    if #lines == 1 then
        line = lines[1]
    elseif #lines == 2 and lines[2] == '' then
        -- A path copied off a terminal line often carries its trailing
        -- newline along.
        line = lines[1]
    else
        return nil
    end

    -- Cheap bail-out before the full word-split scan below.
    if not line:match('^%s*[~/]') then
        return nil
    end

    local words = split_words(line)
    for _, word in ipairs(words) do
        if not is_existing_absolute_file(word) then
            return nil
        end
    end
    return words
end

--- Insert `text` at the cursor, the way a normal paste would: spliced
--- exactly at the cursor in Insert mode (as if typed), or after the
--- character under the cursor in Normal mode (matching `p`), leaving the
--- cursor after the inserted text (Insert) or on its last character
--- (Normal, which has no "gap" for the cursor to sit in).
--- @param bufnr integer
--- @param text string
--- @param mode string
--- @return integer row, integer start_col 0-indexed insertion point
local function insert_at_cursor(bufnr, text, mode)
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1
    local is_insert = mode:find('^i') ~= nil

    local start_col = col
    if not is_insert then
        local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
        -- `col` is a byte offset, so stepping past the character under the
        -- cursor means stepping its whole width -- "col + 1" splits a
        -- multibyte character down the middle.
        start_col = col < #line and (col + vim.str_utf_end(line, col + 1) + 1) or #line
    end

    vim.api.nvim_buf_set_text(bufnr, row, start_col, row, start_col, { text })
    local cursor_col = is_insert and (start_col + #text) or math.max(start_col + #text - 1, 0)
    vim.api.nvim_win_set_cursor(0, { row + 1, cursor_col })

    return row, start_col
end

--- Insert a placeholder for `path` at the cursor, track it with an extmark,
--- and swap it for the real "{F123}" reference once the upload finishes (or
--- remove it, on failure).
--- @param bufnr integer
--- @param path string
--- @param mode string
local function start_upload(bufnr, path, mode)
    local placeholder = string.format(arcanist.config.paste.placeholder, vim.fs.basename(path))
    local row, col = insert_at_cursor(bufnr, placeholder, mode)
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
        end_row = row,
        end_col = col + #placeholder,
    })

    local tasks = watch(bufnr)
    local finished = false

    -- upload.upload() always invokes this on the main loop, so it's safe to
    -- touch the buffer directly here.
    local cancel = upload.upload(path, function(ok, result)
        finished = true
        tasks[mark_id] = nil

        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark_id, { details = true })
        if vim.tbl_isempty(mark) then
            -- Deleting the placeholder collapses the extmark to zero width
            -- rather than removing it, so this only fires if something
            -- cleared the namespace.
            return
        end
        -- Dropped before the edit below, which can throw.
        vim.api.nvim_buf_del_extmark(bufnr, ns, mark_id)

        local srow, scol = mark[1], mark[2]
        local erow, ecol = mark[3].end_row, mark[3].end_col

        -- Deleting the buffer's last line leaves the collapsed extmark a row
        -- past the end, which nvim_buf_set_text() rejects.
        local last = vim.api.nvim_buf_line_count(bufnr) - 1
        if srow > last then
            srow = last
            scol = #(vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or '')
            erow, ecol = srow, scol
        end

        -- On failure, just remove the placeholder; upload.upload() has
        -- already notified about what went wrong.
        local replacement = ok and ('{' .. result .. '}') or ''
        local edited = pcall(vim.api.nvim_buf_set_text, bufnr, srow, scol, erow, ecol, { replacement })
        if not edited and ok then
            vim.notify(
                string.format('arcanist.nvim: uploaded %s as {%s}, but the buffer could not be edited', path, result),
                vim.log.levels.WARN
            )
        end
    end)
    -- `arc` failing to spawn at all calls back synchronously, before there
    -- is anything left to cancel.
    if not finished then
        tasks[mark_id] = cancel
    end
end

--- Install the paste interception. Idempotent -- safe to call from every
--- remarkup buffer's ftplugin, since `vim.paste` is a single global hook
--- rather than something bound per-buffer.
function M.setup()
    if installed then
        return
    end
    installed = true

    local overridden = vim.paste
    vim.paste = function(lines, phase)
        if vim.bo.filetype ~= 'remarkup' then
            return overridden(lines, phase)
        end

        local is_first = phase == -1 or phase == 1
        local is_last = phase == -1 or phase == 3

        if is_first then
            pending_lines = { '' }
        end
        if pending_lines == nil then
            -- Stream started before we saw its first chunk; let the
            -- default handler take it.
            return overridden(lines, phase)
        end

        merge_chunk(lines)
        if not is_last then
            return true
        end

        local full_lines = pending_lines
        pending_lines = nil

        local mode = vim.api.nvim_get_mode().mode
        if not (mode:find('^i') or mode:find('^n')) then
            return overridden(full_lines, -1)
        end

        local paths = paths_in(full_lines)
        if not paths then
            return overridden(full_lines, -1)
        end

        local bufnr = vim.api.nvim_get_current_buf()
        for i, path in ipairs(paths) do
            if i > 1 then
                insert_at_cursor(bufnr, ' ', mode)
            end
            start_upload(bufnr, path, mode)
        end

        return true
    end
end

return M
