-- Inline preview: draw a referenced file object ("{F123}", "F123") on the
-- line below its monogram, in any Remarkup buffer. A per-buffer mode, like
-- 'spell': `config.file.inline.render` is the state a buffer opens with, and
-- the enable/disable/toggle API flips one buffer at runtime.
--
-- The "snacks" preset renders through snacks.image, which picks what it can
-- draw. `config.file.inline.render` may instead be a function driving any
-- renderer; it returns a handle with a `close`, or nil to leave the monogram
-- as text. Downloads are quiet and bounded by `file.max_bytes`.
--
-- An embed's "{F123, size=full, width=200}" options (see arcanist.reference's
-- monograms_in) reach a renderer as `spec.options`. The "snacks" preset maps
-- `size`/`width`/`height` onto a placement size the same way Phorge's own web
-- rendering does; anything else with no usable size option gets boxed to
-- `file.inline.thumb_width`/`thumb_height`, mirroring Phorge's own default
-- file preview thumbnail.

local notify = require('arcanist.notify')

local M = {}

--- Per-buffer state, keyed by bufnr. `override` is an explicit enable/disable
--- (nil = follow `config.file.inline.render`); `handles` are the placements
--- now on screen; `shown` is the sorted monogram list they were built from,
--- so a `:w` that changed nothing can skip the re-render; `gen` is bumped on
--- every (re)render so a superseded `file.fetch` callback bails.
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
--- whether `config.file.inline.render` is set at all.
--- @param buf integer
--- @return boolean
local function enabled(buf)
    local r = bufs[buf]
    if r and r.override ~= nil then
        return r.override
    end
    return not not require('arcanist').config.file.inline.render
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

--- A "width"/"height" embed option ("200" or "50%"), parsed.
--- @class arcanist.Dimension
--- @field n number
--- @field pct boolean whether `n` is a percentage rather than pixels.

--- Parse a "width"/"height" embed option the way Phorge's own
--- PhabricatorEmbedFileRemarkupRule::parseDimension does: an unsigned
--- decimal, optionally followed by "%". Anything else -- including a bare
--- flag, i.e. `options.width == true` -- is not a dimension.
--- @param value string|boolean|nil
--- @return arcanist.Dimension?
local function parse_dimension(value)
    if type(value) ~= 'string' then
        return nil
    end
    local n, pct = value:match('^(%d*%.?%d+)(%%?)$')
    if not n then
        return nil
    end
    return { n = tonumber(n), pct = pct == '%' }
end

--- The terminal's px-per-cell, or nil if snacks.image isn't there to ask.
--- @return { cell_width: number, cell_height: number }?
local function terminal_size()
    local ok, terminal = pcall(require, 'snacks.image.terminal')
    return ok and terminal.size() or nil
end

--- `px` pixels, converted to terminal cells for `axis` ("w"/"h"), or nil if
--- the terminal's cell size isn't available.
--- @param px number
--- @param axis "w"|"h"
--- @return integer?
local function px_to_cells(px, axis)
    local size = terminal_size()
    if not size then
        return nil
    end
    local cell = axis == 'w' and size.cell_width or size.cell_height
    return math.max(1, math.ceil(px / cell))
end

--- A parsed dimension, in terminal cells for `axis` ("w"/"h"): a pixel value
--- converts through the terminal's own cell size; a percentage is relative
--- to the whole editor grid (`vim.o.columns`/`vim.o.lines`), not the specific
--- window the buffer happens to be shown in right now -- close enough, since
--- this only ever becomes a `max_width`/`max_height` *ceiling* layered on top
--- of snacks' own accurate, continuously live per-window clamp (see
--- `placement.lua`'s `auto_resize`), never the placement's size outright.
--- @param dim arcanist.Dimension
--- @param axis "w"|"h"
--- @return integer?
local function dim_to_cells(dim, axis)
    if dim.pct then
        local base = axis == 'w' and vim.o.columns or vim.o.lines
        return math.max(1, math.ceil(dim.n / 100 * base))
    end
    return px_to_cells(dim.n, axis)
end

--- The size cap (`image.placement.new`'s own `max_width`/`max_height` opts,
--- nil meaning "no cap on that axis") `options` asks for. Mirrors
--- PhabricatorEmbedFileRemarkupRule::getFileOptions's precedence: an explicit
--- "size" wins outright over "width"/"height" even when both are given; with
--- no "size", "width"/"height" are used if at least one parses; everything
--- else -- an unrecognized "size" (Phorge itself falls back to "thumb" for
--- one of those too), or a "width"/"height" that doesn't parse -- falls back
--- to the configured thumb default, the same way an embed with no options at
--- all gets Phorge's own default file-preview thumbnail rather than the full
--- image.
--- @param options table<string, string|boolean>
--- @return { max_width: integer?, max_height: integer? }
local function sizing(options)
    if options.size ~= nil then
        local size = type(options.size) == 'string' and options.size:lower() or nil
        if size == 'full' or size == 'wide' then
            return {}
        end
    else
        local w, h = parse_dimension(options.width), parse_dimension(options.height)
        if w or h then
            return {
                max_width = w and dim_to_cells(w, 'w') or nil,
                max_height = h and dim_to_cells(h, 'h') or nil,
            }
        end
    end

    local cfg = require('arcanist').config.file.inline
    return {
        max_width = cfg.thumb_width and px_to_cells(cfg.thumb_width, 'w') or nil,
        max_height = cfg.thumb_height and px_to_cells(cfg.thumb_height, 'h') or nil,
    }
end

--- Bundled "snacks" renderer: `snacks.image.supports_file` decides whether the
--- file can be drawn (unsupported -> left as text); the image anchors to the
--- monogram and draws on the line below. Warns once if snacks.nvim is absent.
--- @param spec arcanist.InlineSpec
--- @return arcanist.InlineHandle?
local function snacks_preset(spec)
    local ok, image = pcall(require, 'snacks.image')
    if not ok then
        warn_once('warn', 'file.inline.render = "snacks" needs snacks.nvim with its image module')
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

    local size = sizing(spec.options)

    local placement = image.placement.new(spec.buf, spec.path, {
        range = { sr + 1, sc, er + 1, ec },
        pos = { sr + 1, sc },
        inline = true,
        auto_resize = true,
        max_width = size.max_width,
        max_height = size.max_height,
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

--- Resolve `config.file.inline.render` to the `fun(spec)` that places one
--- image, or nil if nothing should draw.
--- @return (fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?)?
local function renderer()
    local render = require('arcanist').config.file.inline.render
    if render == nil or render == 'snacks' then
        return snacks_preset
    end
    if type(render) == 'function' then
        return render
    end
    warn_once('err', string.format('file.inline.render: unknown preset %q', tostring(render)))
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
            local handle = place({ buf = buf, range = ref.range, path = path, info = info, options = ref.options })
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
--- with `config.file.inline.render` unset.
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
