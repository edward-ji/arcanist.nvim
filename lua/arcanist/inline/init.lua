-- Inline preview: render a referenced file object ("{F123}", "F123") in
-- place, in any Remarkup buffer. A per-buffer mode, like 'spell':
-- `config.file.inline` is the state a buffer opens with, and the
-- enable/disable/toggle API flips one buffer at runtime.
--
-- Two independent, separately-driven knobs (`config.file.inline`'s own
-- `text` and `render` fields -- see arcanist.InlineConfig), because they
-- act on different real estate (the monogram's own text vs. the line
-- below it) and cost very differently:
--
-- `text` conceals the monogram itself and replaces it with Phorge's own
-- description of the file, reappearing as raw text while the cursor is on
-- that line, the same way a `code span` conceals its backticks in a `:h`
-- file -- no download, only a single lightweight Conduit call. Cheap
-- enough to track the buffer live: it re-syncs on 'TextChanged'/
-- 'TextChangedI', diffing the current monogram set against what is
-- already shown so an edit that doesn't touch a reference touches
-- nothing, one that adds one fetches just that one, and one that removes
-- one just closes its placement.
--
-- `render` downloads the file and draws it on the line below the
-- reference -- "snacks" does that through snacks.image (which picks what
-- it can draw), or a function drives any renderer, returning a handle
-- with a `close`, or nil to leave the monogram as-is. A download is not
-- something to redo on every keystroke, so `render` stays on the
-- coarser, pre-existing cadence: buffer open, `:w`, and explicit
-- enable/disable/toggle -- where `:w`, like `text`'s re-sync, only places
-- added references and closes removed ones. Quiet and bounded by `file.max_bytes`; `text` is
-- unaffected by it since it never downloads.
--
-- An embed's "{F123, size=full, width=200}" options (see arcanist.reference's
-- monograms_in) reach a `render` function as `spec.options`. The "snacks"
-- preset maps `size`/`width`/`height` onto a placement size the same way
-- Phorge's own web rendering does; anything else with no usable size option
-- gets boxed to `file.inline.thumb_width`/`thumb_height`, mirroring Phorge's
-- own default file preview thumbnail. `text` ignores embed options entirely
-- -- there's nothing to size.

local render = require('arcanist.inline.render')
local state = require('arcanist.inline.state')
local text = require('arcanist.inline.text')

local M = {}

--- @param buf integer?
--- @return integer
local function resolve_buf(buf)
    return (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
end

--- Turn inline preview on for `buf` (default: current) and render it --
--- whatever `config.file.inline`'s `text`/`render` are set to, however
--- sparse; neither set draws nothing.
--- @param buf integer?
function M.enable(buf)
    buf = resolve_buf(buf)
    state.rec(buf).override = true
    render.schedule(buf, false)
    text.schedule(buf)
end

--- Turn inline preview off for `buf` (default: current) and remove its placements.
--- @param buf integer?
function M.disable(buf)
    buf = resolve_buf(buf)
    local r = state.rec(buf)
    r.override = false
    r.gen = r.gen + 1 -- drop a scheduled, not yet run render
    r.text_gen = r.text_gen + 1
    render.clear(buf)
    text.clear(buf)
end

--- Flip inline preview for `buf` (default: current); returns the new state.
--- @param buf integer?
--- @return boolean
function M.toggle(buf)
    buf = resolve_buf(buf)
    local on = not state.enabled(buf)
    if on then
        M.enable(buf)
    else
        M.disable(buf)
    end
    return on
end

--- Whether inline preview is on for `buf` (default: current).
--- @param buf integer?
--- @return boolean
function M.is_enabled(buf)
    return state.enabled(resolve_buf(buf))
end

local installed = false

--- Install the session-wide autocmds. From plugin/ at startup, not
--- after/ftplugin: a FileType autocmd registered from the ftplugin would miss
--- the session's first remarkup buffer. Idempotent; the toggle API works even
--- with `config.file.inline` unset.
function M.setup()
    if installed then
        return
    end
    installed = true

    local augroup = vim.api.nvim_create_augroup('arcanist.inline', { clear = true })

    -- `load_reference` sets an "arcanist://" buffer's 'filetype' before
    -- filling it, so both are deferred (via schedule_render/
    -- schedule_text_sync) to a tick when the content is there.
    vim.api.nvim_create_autocmd('FileType', {
        group = augroup,
        pattern = 'remarkup',
        callback = function(args)
            if state.enabled(args.buf) then
                render.schedule(args.buf, false)
                text.schedule(args.buf)
            end
        end,
    })

    -- `render` downloads, so it only redoes that on buffer open and `:w`
    -- (a save may add or remove a monogram), never on every keystroke.
    -- `text` re-syncs here too, for programmatic edits (e.g. a draft
    -- reload) that skip the 'TextChanged' family below.
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = augroup,
        pattern = '*',
        callback = function(args)
            if vim.bo[args.buf].filetype == 'remarkup' and state.enabled(args.buf) then
                render.schedule(args.buf, true)
                text.schedule(args.buf)
            end
        end,
    })

    -- `text` only ever costs one lightweight Conduit call per new
    -- reference, so it stays live as you type instead of waiting for a
    -- save. 'TextChangedI' is Neovim's own idle-debounced "you paused
    -- while editing" event (see 'updatetime'), not a per-keystroke one;
    -- 'InsertLeave' is a backstop in case the very last change before
    -- leaving Insert mode didn't get one.
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'InsertLeave' }, {
        group = augroup,
        pattern = '*',
        callback = function(args)
            if vim.bo[args.buf].filetype == 'remarkup' and state.enabled(args.buf) then
                text.schedule(args.buf)
            end
        end,
    })

    -- One dispatcher for every "text" placement in whichever buffer the
    -- cursor just moved in, instead of one autocmd per placement -- see
    -- `sync_text_reveal`. Cheap to leave unconditional: it bails
    -- immediately for a buffer with no "text" placements.
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
        group = augroup,
        pattern = '*',
        callback = function(args)
            text.sync_reveal(args.buf)
        end,
    })

    -- 'conceallevel' is a window option: a window that starts showing this
    -- buffer later (e.g. switching back to it after visiting another
    -- buffer) does not inherit it from any other window already on it.
    -- One check here for the whole buffer, instead of one per placement.
    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = augroup,
        pattern = '*',
        callback = function(args)
            local r = state.bufs[args.buf]
            if vim.bo[args.buf].filetype == 'remarkup' and r and r.text and #r.text > 0 then
                text.ensure_conceallevel(args.buf)
            end
        end,
    })

    -- Teardown; a reload re-renders through FileType.
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        group = augroup,
        pattern = '*',
        callback = function(args)
            render.clear(args.buf)
            text.clear(args.buf)
            state.bufs[args.buf] = nil
        end,
    })
end

return M
