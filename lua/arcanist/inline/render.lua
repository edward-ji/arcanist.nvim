-- `file.inline.render`: download each referenced file and hand it to a
-- renderer (a function, or a bundled preset) to draw below the reference.

local snacks = require('arcanist.inline.snacks')
local state = require('arcanist.inline.state')

local M = {}

--- Bundled `inline.render` presets, each `fun(spec): handle?`, selected by
--- name.
--- @type table<string, fun(spec: arcanist.InlineSpec): arcanist.InlineHandle?>
local RENDER_PRESETS = {
    snacks = snacks.place,
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
        state.warn_once('err', string.format('file.inline.render: unknown preset %q', tostring(render)))
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
    local r = state.bufs[buf]
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
    if not state.enabled(buf) then
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
    local r = state.rec(buf)
    local kept, claimed, unmatched = {}, {}, {}
    for _, st in ipairs(r.placed or {}) do
        if
            state.claim(current, claimed, function(ref)
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
            and state.claim(current, claimed, function(ref)
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
                    return state.remove_where(state.bufs[buf] and state.bufs[buf].placed, function(e)
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
    state.schedule(buf, 'gen', function(b)
        render(b, incremental)
    end)
end

M.clear = clear_render
M.schedule = schedule_render

return M
