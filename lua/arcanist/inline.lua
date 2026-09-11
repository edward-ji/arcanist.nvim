-- Inline preview: draw a referenced file object ("{F123}", "F123") on the
-- line below its monogram, in any Remarkup buffer. A per-buffer mode, like
-- 'spell': `config.preview.inline` is the state a buffer opens with, and the
-- enable/disable/toggle API flips one buffer at runtime.
--
-- The "snacks" preset renders through snacks.image, which picks what it can
-- draw. `config.preview.inline` may instead be a function driving any
-- renderer; it returns a handle with a `close`, or nil to leave the monogram
-- as text. Downloads are quiet and bounded by `preview.max_bytes`.

local notify = require('arcanist.notify')

local M = {}

--- Per-buffer state, keyed by bufnr. `override` is an explicit enable/disable
--- (nil = follow `config.preview.inline`); `handles` are the placements now on
--- screen; `shown` is the sorted monogram list they were built from, so a
--- `:w` that changed nothing can skip the re-render; `gen` is bumped on every
--- (re)render so a superseded `file.fetch` callback bails.
--- @type table<integer, { override: boolean?, handles: arcanist.InlineHandle[]?, shown: string[]?, gen: integer }>
local bufs = {}

--- @param buf integer
local function rec(buf)
    local r = bufs[buf]
    if not r then
        r = { gen = 0 }
        bufs[buf] = r
    end
    return r
end

--- @param buf integer?
--- @return integer
local function resolve_buf(buf)
    return (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
end

--- Whether inline preview is on for `buf`: its explicit override, else
--- whether `config.preview.inline` is set at all.
--- @param buf integer
--- @return boolean
local function enabled(buf)
    local r = bufs[buf]
    if r and r.override ~= nil then
        return r.override
    end
    return not not require('arcanist').config.preview.inline
end

local warned = {}

--- @param level "warn"|"err"
--- @param msg string
local function warn_once(level, msg)
    if not warned[msg] then
        warned[msg] = true
        notify[level](msg)
    end
end

--- Bundled "snacks" renderer: `snacks.image.supports_file` decides whether the
--- file can be drawn (unsupported -> left as text); the image anchors to the
--- monogram and draws on the line below. Warns once if snacks.nvim is absent.
--- @param spec arcanist.InlineSpec
--- @return arcanist.InlineHandle?
local function snacks_preset(spec)
    local ok, image = pcall(require, 'snacks.image')
    if not ok then
        warn_once('warn', 'preview.inline = "snacks" needs snacks.nvim with its image module')
        return nil
    end
    if not image.supports_file(spec.path) then
        return nil
    end

    -- snacks takes a 1-indexed, end-inclusive row range; node:range() is
    -- 0-indexed and end-exclusive. A range ending at column 0 belongs to the
    -- previous line's end.
    local sr, sc, er, ec = spec.range[1], spec.range[2], spec.range[3], spec.range[4]
    if er > sr and ec == 0 then
        er = er - 1
        ec = #(vim.api.nvim_buf_get_lines(spec.buf, er, er + 1, false)[1] or '')
    end

    local placement = image.placement.new(spec.buf, spec.path, {
        range = { sr + 1, sc, er + 1, ec },
        pos = { sr + 1, sc },
        inline = true,
        auto_resize = true,
    })

    -- Re-show the placement whenever this buffer gets a window again (e.g.
    -- switching back to it after visiting another buffer).
    local autocmd = vim.api.nvim_create_autocmd('BufWinEnter', {
        buffer = spec.buf,
        callback = function()
            vim.schedule(function()
                pcall(placement.show, placement)
            end)
        end,
    })

    return {
        close = function()
            pcall(vim.api.nvim_del_autocmd, autocmd)
            pcall(placement.close, placement)
        end,
    }
end

--- Resolve `config.preview.inline` to the `fun(spec)` that places one image,
--- or nil if nothing should draw.
--- @return (fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?)?
local function renderer()
    local inline = require('arcanist').config.preview.inline
    if inline == nil or inline == 'snacks' then
        return snacks_preset
    end
    if type(inline) == 'function' then
        return inline
    end
    warn_once('err', string.format('preview.inline: unknown preset %q', tostring(inline)))
    return nil
end

--- Close and forget every placement for `buf`.
--- @param buf integer
local function clear(buf)
    local r = bufs[buf]
    if not r then
        return
    end
    for _, handle in ipairs(r.handles or {}) do
        pcall(handle.close)
    end
    r.handles = nil
    r.shown = nil
end

--- (Re)place every file monogram in `buf` the renderer accepts.
--- `skip_unchanged` (the `:w` path) bails when the referenced-file set is
--- unchanged. `g` is the render generation; a stale `file.fetch` callback
--- compares against it.
--- @param buf integer
--- @param g integer
--- @param skip_unchanged boolean
local function render(buf, g, skip_unchanged)
    if not enabled(buf) then
        return clear(buf)
    end
    local place = renderer()
    if not place then
        return clear(buf)
    end

    local file = require('arcanist.file')
    local reference = require('arcanist.reference')

    local items, monos = {}, {}
    for _, ref in ipairs(reference.monograms_in(buf)) do
        if file.file_id(ref.monogram) then
            items[#items + 1] = ref
            monos[#monos + 1] = ref.monogram
        end
    end
    table.sort(monos)

    local r = rec(buf)
    if skip_unchanged and r.shown and vim.deep_equal(r.shown, monos) then
        return
    end

    clear(buf)
    r.shown = monos
    r.handles = {}

    for _, ref in ipairs(items) do
        file.fetch(ref.monogram, { quiet = true }, function(path, info)
            local cur = bufs[buf]
            if not cur or cur.gen ~= g or not path or not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            local handle = place({ buf = buf, range = ref.range, path = path, info = info })
            if handle and cur.handles then
                table.insert(cur.handles, handle)
            end
        end)
    end
end

--- @param buf integer
--- @param skip_unchanged boolean
local function schedule_render(buf, skip_unchanged)
    local r = rec(buf)
    r.gen = r.gen + 1
    local g = r.gen
    vim.schedule(function()
        local r = bufs[buf]
        if r and r.gen == g and vim.api.nvim_buf_is_valid(buf) then
            render(buf, g, skip_unchanged)
        end
    end)
end

--- Turn inline preview on for `buf` (default: current) and render it.
--- @param buf integer?
function M.enable(buf)
    buf = resolve_buf(buf)
    rec(buf).override = true
    schedule_render(buf, false)
end

--- Turn inline preview off for `buf` (default: current) and remove its images.
--- @param buf integer?
function M.disable(buf)
    buf = resolve_buf(buf)
    local r = rec(buf)
    r.override = false
    r.gen = r.gen + 1 -- invalidate in-flight file.fetch callbacks
    clear(buf)
end

--- Flip inline preview for `buf` (default: current); returns the new state.
--- @param buf integer?
--- @return boolean
function M.toggle(buf)
    buf = resolve_buf(buf)
    local on = not enabled(buf)
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
    return enabled(resolve_buf(buf))
end

local installed = false

--- Install the session-wide autocmds. From plugin/ at startup, not
--- after/ftplugin: a FileType autocmd registered from the ftplugin would miss
--- the session's first remarkup buffer. Idempotent; the toggle API works even
--- with `config.preview.inline` unset.
function M.setup()
    if installed then
        return
    end
    installed = true

    local augroup = vim.api.nvim_create_augroup('arcanist.inline', { clear = true })

    -- `load_reference` sets an "arcanist://" buffer's 'filetype' before
    -- filling it, so the render is deferred (in schedule_render) to a tick
    -- when the content is there.
    vim.api.nvim_create_autocmd('FileType', {
        group = augroup,
        pattern = 'remarkup',
        callback = function(args)
            if enabled(args.buf) then
                schedule_render(args.buf, false)
            end
        end,
    })

    -- A save may add or remove a monogram.
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = augroup,
        pattern = '*',
        callback = function(args)
            if vim.bo[args.buf].filetype == 'remarkup' and enabled(args.buf) then
                schedule_render(args.buf, true)
            end
        end,
    })

    -- Teardown; a reload re-renders through FileType.
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        group = augroup,
        pattern = '*',
        callback = function(args)
            clear(args.buf)
            bufs[args.buf] = nil
        end,
    })
end

return M
