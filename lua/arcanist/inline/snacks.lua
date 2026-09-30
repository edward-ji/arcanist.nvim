-- The bundled "snacks" `file.inline.render` preset: draws a referenced file
-- through snacks.image on the line below it, sized from the embed's
-- options the way Phorge's own web rendering sizes it.

local state = require('arcanist.inline.state')

local M = {}

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

--- `px` CSS pixels, converted to terminal cells for `axis` ("w"/"h"), or nil
--- if the terminal's cell size isn't available. Scaled by snacks' own HiDPI
--- guess, the factor it sizes images by too: dividing by the physical cell
--- size alone halves every cap on a 2x display.
--- @param px number
--- @param axis "w"|"h"
--- @return integer?
local function px_to_cells(px, axis)
    local size = terminal_size()
    if not size then
        return nil
    end
    local cell = axis == 'w' and size.cell_width or size.cell_height
    return math.max(1, math.ceil(px * (size.scale or 1) / cell))
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

--- Namespace for the "snacks" preset's anchor extmarks.
local anchor_ns = vim.api.nvim_create_namespace('arcanist.inline.anchor')

--- Bundled "snacks" renderer: `snacks.image.supports_file` decides whether the
--- file can be drawn (unsupported -> left as text); the image anchors to the
--- monogram and draws on the line below. Warns once if snacks.nvim is absent.
--- @param spec arcanist.InlineSpec
--- @return arcanist.InlineHandle?
local function snacks_preset(spec)
    local ok, image = pcall(require, 'snacks.image')
    if not ok then
        state.warn_once('warn', 'file.inline.render = "snacks" needs snacks.nvim with its image module')
        return nil
    end
    if not image.supports_file(spec.path) then
        return nil
    end

    -- snacks takes a 1-indexed, end-inclusive row range; node:range() is
    -- 0-indexed and end-exclusive. A range ending at column 0 belongs to the
    -- previous line's end.
    --
    -- Deliberately `spec.range` (the bare monogram), not `embed_range`: this
    -- is also what snacks derives its own small inline anchor icon's
    -- position *and* the image's left-padding from (see `placement.lua`) --
    -- one `range`, both jobs, no separate option for each. Anchoring it at
    -- the reference's end instead of its start (to put that icon after the
    -- monogram, matching where `text`'s own description now goes -- see
    -- `place_text`) also drags the image's own alignment down to that same
    -- end column instead of the reference's start, confirmed live: a
    -- reference with nothing after it on the line pushed the image dozens
    -- of columns right instead of sitting flush under it. `text`'s own
    -- placement has no such coupling -- it is our own extmark, so its
    -- ordering fix carries no side effect -- but snacks' own icon isn't a
    -- documented "anchor before/after" option we can steer independently
    -- of the image's own layout, so it stays anchored at the start, same
    -- as before.
    local sr, sc, er, ec = spec.range[1], spec.range[2], spec.range[3], spec.range[4]
    if er > sr and ec == 0 then
        er = er - 1
        ec = #(vim.api.nvim_buf_get_lines(spec.buf, er, er + 1, false)[1] or '')
    end

    local size = sizing(spec.options)

    -- snacks re-renders from `opts.range`/`opts.pos` on every resize or
    -- window change, but never moves them itself -- its own markdown driver
    -- re-feeds them on each buffer change. Without that, an edit above the
    -- reference snaps the image back to its creation-time row. This mark
    -- follows the monogram so `track` can re-feed them the same way.
    local anchor = vim.api.nvim_buf_set_extmark(spec.buf, anchor_ns, sr, sc, {
        end_row = er,
        end_col = ec,
        invalidate = true,
        undo_restore = false,
    })

    --- Point `p` at the monogram's current position; false once its line is gone.
    --- @return boolean
    local function track(p)
        local mark = vim.api.nvim_buf_get_extmark_by_id(spec.buf, anchor_ns, anchor, { details = true })
        if not mark[1] or mark[3].invalid then
            return false
        end
        p.opts.range = { mark[1] + 1, mark[2], mark[3].end_row + 1, mark[3].end_col }
        p.opts.pos = { mark[1] + 1, mark[2] }
        return true
    end

    local placement = image.placement.new(spec.buf, spec.path, {
        range = { sr + 1, sc, er + 1, ec },
        pos = { sr + 1, sc },
        inline = true,
        auto_resize = true,
        max_width = size.max_width,
        max_height = size.max_height,
        on_update_pre = track,
    })

    local augroup = vim.api.nvim_create_augroup('arcanist.inline.snacks.' .. anchor, { clear = true })
    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        pcall(vim.api.nvim_buf_del_extmark, spec.buf, anchor_ns, anchor)
        -- `placement:close()` deletes the image in the terminal straight away,
        -- ahead of the redraw that clears its placeholder cells: one frame of
        -- orphaned cells, a visible flicker. Drop the cells in this redraw
        -- and close once it has been flushed.
        for _, eid in ipairs(placement.eids) do
            pcall(vim.api.nvim_buf_del_extmark, spec.buf, image.placement.ns, eid)
        end
        placement.eids = {}
        vim.schedule(function()
            -- snacks' own delete sends the wrong placement id, leaving this
            -- one alive in the terminal while the image has other placements
            -- -- and since Neovim never sends the placement id with the cells,
            -- the terminal may then draw those with this one's stale size.
            pcall(image.terminal.request, { a = 'd', d = 'i', i = placement.img.id, p = placement.id })
            pcall(placement.close, placement)
        end)
    end
    local handle = {
        close = close,
        -- Same placement id, new size: snacks re-sends it and rewrites its
        -- extmarks in place, where close-and-place would blink.
        update = function(new)
            local resized = sizing(new.options)
            placement.opts.max_width, placement.opts.max_height = resized.max_width, resized.max_height
            placement:update()
        end,
    }

    -- Re-show the placement whenever this buffer gets a window again (e.g.
    -- switching back to it after visiting another buffer).
    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = augroup,
        buffer = spec.buf,
        callback = function()
            vim.schedule(function()
                pcall(placement.show, placement)
            end)
        end,
    })
    -- Also on edits, not just `on_update_pre`: snacks drops a placement
    -- whose stale row is past the buffer's end before that hook runs.
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = augroup,
        buffer = spec.buf,
        callback = function()
            if track(placement) then
                return
            end
            close()
            -- Forget it, so a `:w` after undoing the deletion draws it again.
            state.remove_where(state.bufs[spec.buf] and state.bufs[spec.buf].placed, function(st)
                return st.handle == handle
            end)
        end,
    })

    return handle
end

M.place = snacks_preset

return M
