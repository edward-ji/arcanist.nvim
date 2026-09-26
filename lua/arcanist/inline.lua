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

local notify = require('arcanist.notify')

local M = {}

--- Per-buffer state, keyed by bufnr.
--- @class arcanist.InlineBufState
--- @field override boolean? Explicit enable/disable (nil = follow `config.file.inline`).
--- @field gen integer Bumped on every scheduled `render`, so a superseded
--- one collapses to just the last.
--- @field placed arcanist.RenderState[]? `render`'s placements, one per
--- reference occurrence, so a `:w` only adds or removes what changed.
--- @field text_gen integer Bumped on every scheduled text re-sync, so a
--- superseded one (several edits before its `vim.schedule` callback runs)
--- collapses to just the last.
--- @field text arcanist.TextState[]? `text`'s placements, one per
--- reference occurrence (not deduped by monogram -- the same file can be
--- referenced more than once) -- lets a re-sync add/remove only what
--- changed.
--- @type table<integer, arcanist.InlineBufState>
local bufs = {}

--- @param buf integer
--- @return arcanist.InlineBufState
local function rec(buf)
    local r = bufs[buf]
    if not r then
        r = { gen = 0, text_gen = 0 }
        bufs[buf] = r
    end
    return r
end

--- Debounce `fn(buf)` to the next tick, coalescing whatever calls land
--- before then into one: `field` (`"gen"`/`"text_gen"`) is the per-buffer
--- generation counter this bumps and later compares, so a call superseded
--- by a newer one (another edit before `vim.schedule`'s callback runs, or
--- the buffer disappearing) is dropped rather than run stale. Shared by
--- `render`'s and `sync_text`'s own scheduling -- same coalescing shape,
--- different counter and target.
--- @param buf integer
--- @param field "gen"|"text_gen"
--- @param fn fun(buf: integer)
local function schedule(buf, field, fn)
    local r = rec(buf)
    r[field] = r[field] + 1
    local g = r[field]
    vim.schedule(function()
        local r2 = bufs[buf]
        if r2 and r2[field] == g and vim.api.nvim_buf_is_valid(buf) then
            fn(buf)
        end
    end)
end

--- Mark and return the index of the first entry of `current` not yet in
--- `claimed` that satisfies `pred`, or nil -- how a re-sync pairs what is
--- already placed with the references now in the buffer.
--- @generic T
--- @param current T[]
--- @param claimed table<integer, true>
--- @param pred fun(c: T): boolean
--- @return integer?
local function claim(current, claimed, pred)
    for i, c in ipairs(current) do
        if not claimed[i] and pred(c) then
            claimed[i] = true
            return i
        end
    end
end

--- Remove the first entry of `list` (may be nil) that satisfies `pred`.
--- @generic T
--- @param list T[]?
--- @param pred fun(e: T): boolean
local function remove_where(list, pred)
    for i, e in ipairs(list or {}) do
        if pred(e) then
            table.remove(list, i)
            return
        end
    end
end

--- @param buf integer?
--- @return integer
local function resolve_buf(buf)
    return (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
end

--- Whether inline preview is on for `buf`: its explicit override, else
--- whether `config.file.inline.text` or `.render` is set at all.
--- @param buf integer
--- @return boolean
local function enabled(buf)
    local r = bufs[buf]
    if r and r.override ~= nil then
        return r.override
    end
    local inline = require('arcanist').config.file.inline
    return not not (inline.text or inline.render)
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
        warn_once('warn', 'file.inline.render = "snacks" needs snacks.nvim with its image module')
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
            remove_where(bufs[spec.buf] and bufs[spec.buf].placed, function(st)
                return st.handle == handle
            end)
        end,
    })

    return handle
end

--- Bundled `inline.render` presets, each `fun(spec): handle?`, selected by
--- name.
--- @type table<string, fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?>
local RENDER_PRESETS = {
    snacks = snacks_preset,
}

--- Resolve `config.file.inline.render` to the `fun(spec)` that places one
--- image, or nil if nothing should draw.
--- @return (fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?)?
local function resolve_render()
    local render = require('arcanist').config.file.inline.render
    if render == nil then
        return nil
    end
    if type(render) == 'function' then
        return render
    end
    local place = RENDER_PRESETS[render]
    if not place then
        warn_once('err', string.format('file.inline.render: unknown preset %q', tostring(render)))
    end
    return place
end

--- One `render` placement, tracked in `bufs[buf].placed`.
--- @class arcanist.RenderState
--- @field monogram string
--- @field options table<string, string|boolean> The embed options it was
--- placed with; a `:w` keeps a placement whose monogram and options match.
--- @field path string? What `handle` was placed from.
--- @field info arcanist.FileInfo?
--- @field handle arcanist.InlineHandle? Nil while the file downloads, or
--- if `render` declined to draw it.
--- @field closed boolean?

--- @param st arcanist.RenderState
local function close_render_state(st)
    st.closed = true
    if st.handle then
        pcall(st.handle.close)
    end
end

--- Close and forget `render`'s placements for `buf`.
--- @param buf integer
local function clear_render(buf)
    local r = bufs[buf]
    if not r or not r.placed then
        return
    end
    for _, st in ipairs(r.placed) do
        close_render_state(st)
    end
    r.placed = nil
end

--- Download and place every file monogram in `buf`, via
--- `config.file.inline.render`. `incremental` (the `:w` path) keeps every
--- placement whose reference is still there and only adds and removes the
--- difference, so the images already on screen don't blink; otherwise
--- everything is placed afresh. Matched by monogram and options, like
--- `sync_text` without the position check: the snacks preset tracks its
--- own. Does nothing to `text`'s own placements -- see `sync_text` for those.
--- @param buf integer
--- @param incremental boolean
local function render(buf, incremental)
    if not enabled(buf) then
        return clear_render(buf)
    end
    local place = resolve_render()
    if not place then
        return clear_render(buf)
    end

    local file = require('arcanist.file')
    local reference = require('arcanist.reference')

    local current = {}
    for _, ref in ipairs(reference.monograms_in(buf)) do
        if file.file_id(ref.monogram) then
            current[#current + 1] = ref
        end
    end

    if not incremental then
        clear_render(buf)
    end
    local r = rec(buf)
    local kept, claimed, unmatched = {}, {}, {}
    for _, st in ipairs(r.placed or {}) do
        if
            claim(current, claimed, function(ref)
                return ref.monogram == st.monogram and vim.deep_equal(ref.options, st.options)
            end)
        then
            kept[#kept + 1] = st
        else
            unmatched[#unmatched + 1] = st
        end
    end
    -- A reference whose options alone changed: resize it in place when the
    -- handle can, rather than closing it and placing it anew.
    for _, st in ipairs(unmatched) do
        local i = st.handle
            and st.handle.update
            and claim(current, claimed, function(ref)
                return ref.monogram == st.monogram
            end)
        if i then
            local ref = current[i]
            st.options = ref.options
            pcall(st.handle.update, { buf = buf, range = ref.range, path = st.path, info = st.info, options = ref.options })
            kept[#kept + 1] = st
        else
            close_render_state(st)
        end
    end
    r.placed = kept

    for i, ref in ipairs(current) do
        if not claimed[i] then
            local st = { monogram = ref.monogram, options = ref.options }
            table.insert(kept, st)
            file.fetch(ref.monogram, { quiet = true }, function(path, info)
                if st.closed or not vim.api.nvim_buf_is_valid(buf) then
                    return
                end
                if not path then
                    -- Forget it, so the next `:w` tries again.
                    return remove_where(bufs[buf] and bufs[buf].placed, function(e)
                        return e == st
                    end)
                end
                st.path, st.info = path, info
                st.handle = place({ buf = buf, range = ref.range, path = path, info = info, options = ref.options })
            end)
        end
    end
end

--- @param buf integer
--- @param incremental boolean
local function schedule_render(buf, incremental)
    schedule(buf, 'gen', function(b)
        render(b, incremental)
    end)
end

--- Namespace for the "text" preset's conceal/virtual-text extmarks.
local text_ns = vim.api.nvim_create_namespace('arcanist.inline.text')

--- Bump every window currently showing `buf` to at least `conceallevel` 2
--- (never lowering an already-higher value) -- needed for an extmark's
--- `conceal` field to hide anything at all. Re-applied on `BufWinEnter`
--- too: 'conceallevel' is a window option, not inherited by a window that
--- starts showing this buffer later.
--- @param buf integer
local function ensure_conceallevel(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.wo[win].conceallevel < 2 then
            vim.wo[win].conceallevel = 2
        end
    end
end

--- Below Neovim's own default extmark priority (4096), which is what
--- `render`'s "snacks" preset's own extmark uses for the small anchor icon
--- it draws inline right after the monogram, marking where the actual
--- image (drawn separately, in virt_lines below) belongs -- see
--- snacks.image's `placement.lua`. Two unrelated extmarks both wanting
--- `virt_text_pos = "inline"` at that exact spot need *some* explicit,
--- shared ordering rule between them, or their relative order is left to
--- fall back to insertion order -- and snacks recreates its own extmark
--- (a new id, inserted anew) every time its `BufWinEnter` hook re-shows a
--- placement (switching buffers away and back), while ours does not, so
--- that fallback visibly flips around. Priority order for `virt_text` is
--- documented and deterministic regardless of creation order ("item with
--- highest priority is drawn last" -- confirmed live), so pinning ours
--- explicitly below the untouched default is what keeps "the monogram,
--- then its description, then snacks' anchor icon" a fixed reading order
--- no matter how many times either side redraws. Must be set on every
--- `nvim_buf_set_extmark` call for this extmark, creation and
--- `set_revealed`'s updates alike -- re-setting an id replaces its options
--- outright, so leaving `priority` out on an update would silently drop
--- back to the (colliding) default.
local TEXT_PRIORITY = 100

--- One "text" placement's live state, tracked as an entry in
--- `bufs[buf].text` -- a plain list, not keyed by monogram: the same file
--- can legitimately be referenced more than once in a buffer, and each
--- occurrence needs its own placement, so the file's identity alone can't
--- be the key. Not `arcanist.InlineHandle`: a placement here owns no
--- closures or autocmds of its own (unlike `render`'s handles). The single
--- session-wide dispatchers below (`sync_text_reveal`, and the
--- `BufWinEnter` re-arm in `M.setup`) act on this data directly, so one
--- cursor move or buffer redisplay costs one pass over `bufs[buf].text`
--- rather than N autocmd firings for N placements.
--- @class arcanist.TextState
--- @field monogram string
--- @field conceal_id integer? Nil until its `file.info` callback returns a
--- description to place, or forever if it never does (see `sync_text`).
--- @field text_id integer?
--- @field text string?
--- @field revealed boolean?
--- @field closed boolean? Set by `close_text_state` -- lets an in-flight
--- `file.info` callback tell that its placement was superseded or removed
--- before the callback got a chance to finish it.

--- Tear down one placement's extmarks (a still-pending one has none yet)
--- and mark it closed, so an in-flight `file.info` callback for it knows
--- to bail instead of finishing a placement nothing points at any more.
--- @param buf integer
--- @param st arcanist.TextState
local function close_text_state(buf, st)
    st.closed = true
    if st.conceal_id then
        pcall(vim.api.nvim_buf_del_extmark, buf, text_ns, st.conceal_id)
        pcall(vim.api.nvim_buf_del_extmark, buf, text_ns, st.text_id)
    end
end

--- Conceals one monogram and shows Phorge's own description of the file in
--- its place, reappearing as raw text while the cursor is on it -- the
--- same way a `code span` reappears in a `:h` file. Only creates the
--- extmarks; the reveal toggle and the `conceallevel` re-arm are both
--- handled by the single session-wide dispatchers, not by this placement
--- itself.
--- @param buf integer
--- @param monogram string
--- @param embed_range integer[] { start_row, start_col, end_row, end_col },
--- 0-indexed -- the whole "{F123, ...}" for a braced embed, opening "{"
--- through closing "}", or just the bare monogram for an unbraced one.
--- @param text string The description to show, e.g. `info.alt`.
--- @return arcanist.TextState
local function place_text(buf, monogram, embed_range, text)
    local sr, sc, er, ec = embed_range[1], embed_range[2], embed_range[3], embed_range[4]

    -- Two extmarks, not one: `virt_text_pos = "inline"` always anchors at
    -- its own mark's *start*, and a single mark's `conceal` range and its
    -- virt_text share that same start point -- so a mark that both
    -- conceals "F123" and shows `text` would have `text` appear *before*
    -- the (revealed) monogram, not after. `conceal_id` spans the monogram
    -- and only ever conceals -- 'concealcursor's own cursor-line exemption
    -- reveals it natively, so it never needs touching again after this.
    -- `text_id` is a separate, zero-width point right at the monogram's
    -- *end*, carrying `text`; anchoring there instead of at the start is
    -- what makes a revealed monogram read as "F123 <description>", not the
    -- other way around (the same idiom Neovim's own LSP inlay hints use to
    -- show a type after a variable, not before it).
    --
    -- `right_gravity = false` on `text_id`: a point mark's gravity defaults
    -- to right (true) -- typing right at the mark's own position (e.g.
    -- continuing the line right after "F123}") shifts the mark itself
    -- forward to trail the newly typed text (confirmed live), dragging the
    -- description away one character at a time as you type. `false` pins
    -- it to stay put, so new text lands *after* the mark instead of moving
    -- it -- matching `conceal_id`'s own end, whose `end_right_gravity`
    -- already defaults to false for the same reason (typed text right
    -- after "}" must not get absorbed into the concealed range either).
    --
    -- `invalidate` on both: deleting the reference's line would otherwise
    -- slide them onto the next line for the frame before `sync_text` runs.
    local conceal_id = vim.api.nvim_buf_set_extmark(buf, text_ns, sr, sc, {
        end_row = er,
        end_col = ec,
        conceal = '',
        invalidate = true,
    })
    local text_id = vim.api.nvim_buf_set_extmark(buf, text_ns, er, ec, {
        virt_text = { { text, 'Conceal' } },
        virt_text_pos = 'inline',
        priority = TEXT_PRIORITY,
        right_gravity = false,
        invalidate = true,
    })

    return { monogram = monogram, conceal_id = conceal_id, text_id = text_id, text = text, revealed = false }
end

--- Show `st.text` after the (concealed) monogram, or hide it while the
--- monogram is revealed, only touching the extmark when the state
--- actually changes. `row`/`col` must be `st.text_id`'s *current*
--- position -- an extmark moves as the buffer is edited, so reusing a
--- stale creation-time coordinate here would misplace it.
--- @param buf integer
--- @param st arcanist.TextState
--- @param want boolean
--- @param row integer @param col integer
local function set_revealed(buf, st, want, row, col)
    if want == st.revealed then
        return
    end
    st.revealed = want
    -- Not `want and nil or {...}`: that "and/or" idiom breaks the moment
    -- its middle value can itself be falsy, which nil always is -- it
    -- would collapse to the `{...}` branch unconditionally.
    local virt_text, virt_text_pos
    if not want then
        virt_text = { { st.text, 'Conceal' } }
        virt_text_pos = 'inline'
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, text_ns, row, col, {
        id = st.text_id,
        virt_text = virt_text,
        virt_text_pos = virt_text_pos,
        priority = TEXT_PRIORITY,
        right_gravity = false,
        invalidate = true,
    })
end

--- Single per-session `CursorMoved`/`CursorMovedI` dispatcher for every
--- "text" placement in `buf`, replacing what would otherwise be one
--- autocmd per placement. Checks the cursor against each placement's own
--- live `conceal_id` range directly, rather than resolving "which
--- monogram is the cursor on" once via `reference.monogram_at_cursor` and
--- comparing that string to each placement -- the same file can be
--- referenced more than once, and a monogram string can't tell two
--- occurrences apart, so revealing by string match would (wrongly) reveal
--- every occurrence of a file at once whenever the cursor is on any one of
--- them. One batched `nvim_buf_get_extmarks` call for the whole
--- namespace, rather than two per placement, keeps this cheap regardless.
--- `conceal`'s own cursor-line exemption (see 'concealcursor') already
--- reveals the raw monogram natively -- this only toggles `text_id`'s
--- virtual text, which is not `concealcursor`-aware on its own.
--- @param buf integer
local function sync_text_reveal(buf)
    local r = bufs[buf]
    if not r or not r.text or #r.text == 0 then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local crow, ccol = cursor[1] - 1, cursor[2]

    local by_id = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, text_ns, 0, -1, { details = true })) do
        by_id[mark[1]] = mark
    end

    for _, st in ipairs(r.text) do
        local cm, tm = st.conceal_id and by_id[st.conceal_id], st.text_id and by_id[st.text_id]
        if cm and tm and not cm[4].invalid then
            local row, col, details = cm[2], cm[3], cm[4]
            local er2, ec2 = details.end_row or row, details.end_col or col
            local inside
            if crow < row or crow > er2 then
                inside = false
            elseif row == er2 then
                inside = ccol >= col and ccol < ec2
            elseif crow == row then
                inside = ccol >= col
            elseif crow == er2 then
                inside = ccol < ec2
            else
                inside = true
            end
            if inside ~= st.revealed then
                set_revealed(buf, st, inside, tm[2], tm[3])
            end
        end
    end
end

--- Close and forget every "text" placement for `buf`.
--- @param buf integer
local function clear_text(buf)
    local r = bufs[buf]
    if not r or not r.text then
        return
    end
    for _, st in ipairs(r.text) do
        close_text_state(buf, st)
    end
    r.text = nil
end

--- Diff `buf`'s current set of references against `text`'s own tracked
--- placements and add/remove only what changed: a reference an edit added
--- gets its metadata fetched and placed, one an edit removed has its
--- placement closed, and one still there is left untouched -- its extmark
--- keeps whatever reveal state it already had, and no redundant Conduit
--- call. The cheap side of inline preview (see the module doc above), so
--- this runs live on 'TextChanged'/'TextChangedI', not just on buffer
--- open/write like `render`.
---
--- Matches an existing placement to a current reference by *live position
--- and monogram together*, not by monogram string alone: the same file
--- can legitimately be referenced more than once in a buffer, so monogram
--- identity alone can't tell two occurrences apart (matching by it
--- collapsed every repeat but the last onto a single placement). A placed
--- entry's `conceal_id` extmark tracks its own position across edits, and
--- a fresh parse gives each reference's current position too, so
--- comparing those directly -- rather than a coordinate snapshot from the
--- last sync, which would go stale the moment anything shifts lines --
--- means an edit that doesn't touch a reference's own text leaves it
--- matched (and thus untouched) even if unrelated lines above it moved
--- it: both sides moved together. Position alone isn't enough, though:
--- editing an existing reference's monogram digits in place (e.g. "F262"
--- retyped as "F263" at the very same columns) leaves the extmark's range
--- exactly where it was, so the monogram is checked too -- otherwise a
--- position-only match would keep showing the old file's description
--- under the new monogram until something else nudges the position
--- (confirmed live: this is a real, not theoretical, way to get a stale
--- description). A `conceal_id` that no longer spans a real, non-inverted
--- range (a wholesale line replacement, e.g. from a formatter, can leave
--- one zero-width or -- confirmed live -- outright inverted even though
--- the monogram text is unchanged) simply matches nothing and is treated
--- as gone, forcing a fresh placement in its place. A still-pending entry
--- (no `conceal_id` yet, its `file.info` callback not back) has no
--- position to match on, so it claims any remaining unclaimed reference
--- with the same monogram instead -- which one doesn't matter, since
--- they're interchangeable until the fetch actually returns.
--- @param buf integer
local function sync_text(buf)
    if not (enabled(buf) and require('arcanist').config.file.inline.text) then
        return clear_text(buf)
    end

    local file = require('arcanist.file')
    local reference = require('arcanist.reference')

    local current = {}
    for _, ref in ipairs(reference.monograms_in(buf)) do
        if file.file_id(ref.monogram) then
            current[#current + 1] = ref
        end
    end

    local r = rec(buf)
    r.text = r.text or {}

    -- Two passes, not one: a placed entry's match is exact (its own
    -- tracked position), a pending one's is a fallback (any occurrence
    -- left over of the right monogram) -- doing placed entries first
    -- means a pending entry can never steal the specific ref a placed one
    -- needs out from under it just by coming first in `r.text`'s order.
    local claimed = {}
    local kept, pending = {}, {}
    for _, st in ipairs(r.text) do
        if st.conceal_id then
            local match
            local mark = vim.api.nvim_buf_get_extmark_by_id(buf, text_ns, st.conceal_id, { details = true })
            if mark[1] then
                local row, col, details = mark[1], mark[2], mark[3]
                local er2, ec2 = details.end_row or row, details.end_col or col
                if row < er2 or (row == er2 and col < ec2) then -- not degenerate/inverted
                    match = claim(current, claimed, function(ref)
                        return ref.monogram == st.monogram
                            and ref.embed_range[1] == row
                            and ref.embed_range[2] == col
                            and ref.embed_range[3] == er2
                            and ref.embed_range[4] == ec2
                    end)
                end
            end
            if match then
                kept[#kept + 1] = st
            else
                close_text_state(buf, st)
            end
        else
            pending[#pending + 1] = st
        end
    end
    for _, st in ipairs(pending) do
        local match = claim(current, claimed, function(ref)
            return ref.monogram == st.monogram
        end)
        if match then
            kept[#kept + 1] = st
        else
            close_text_state(buf, st)
        end
    end
    r.text = kept

    -- A window showing `buf` does not inherit 'conceallevel' from any
    -- other window already on it, so this needs re-applying on
    -- `BufWinEnter` too -- see the single dispatcher in `M.setup`.
    if #current > 0 then
        ensure_conceallevel(buf)
    end

    for i, ref in ipairs(current) do
        if not claimed[i] then
            local st = { monogram = ref.monogram }
            r.text[#r.text + 1] = st
            file.info(ref.monogram, { quiet = true }, function(info)
                if st.closed or not vim.api.nvim_buf_is_valid(buf) then
                    return -- superseded, removed, or the buffer is gone
                end
                local text = info and (info.alt or info.name)
                if not text then
                    close_text_state(buf, st) -- nothing to show; drop the slot
                    remove_where(bufs[buf] and bufs[buf].text, function(e)
                        return e == st
                    end)
                    return
                end
                local placed = place_text(buf, ref.monogram, ref.embed_range, text)
                st.conceal_id, st.text_id, st.text, st.revealed = placed.conceal_id, placed.text_id, placed.text, false
                if buf == vim.api.nvim_get_current_buf() then
                    sync_text_reveal(buf)
                end
            end)
        end
    end
end

--- @param buf integer
local function schedule_text_sync(buf)
    schedule(buf, 'text_gen', sync_text)
end

--- Turn inline preview on for `buf` (default: current) and render it --
--- whatever `config.file.inline`'s `text`/`render` are set to, however
--- sparse; neither set draws nothing.
--- @param buf integer?
function M.enable(buf)
    buf = resolve_buf(buf)
    rec(buf).override = true
    schedule_render(buf, false)
    schedule_text_sync(buf)
end

--- Turn inline preview off for `buf` (default: current) and remove its placements.
--- @param buf integer?
function M.disable(buf)
    buf = resolve_buf(buf)
    local r = rec(buf)
    r.override = false
    r.gen = r.gen + 1 -- drop a scheduled, not yet run render
    r.text_gen = r.text_gen + 1
    clear_render(buf)
    clear_text(buf)
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
            if enabled(args.buf) then
                schedule_render(args.buf, false)
                schedule_text_sync(args.buf)
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
            if vim.bo[args.buf].filetype == 'remarkup' and enabled(args.buf) then
                schedule_render(args.buf, true)
                schedule_text_sync(args.buf)
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
            if vim.bo[args.buf].filetype == 'remarkup' and enabled(args.buf) then
                schedule_text_sync(args.buf)
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
            sync_text_reveal(args.buf)
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
            local r = bufs[args.buf]
            if vim.bo[args.buf].filetype == 'remarkup' and r and r.text and #r.text > 0 then
                ensure_conceallevel(args.buf)
            end
        end,
    })

    -- Teardown; a reload re-renders through FileType.
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        group = augroup,
        pattern = '*',
        callback = function(args)
            clear_render(args.buf)
            clear_text(args.buf)
            bufs[args.buf] = nil
        end,
    })
end

return M
