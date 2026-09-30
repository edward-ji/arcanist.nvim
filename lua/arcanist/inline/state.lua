-- Per-buffer inline-preview state shared by arcanist.inline's `render`
-- and `text` halves, and the helpers both use to keep it in step with the
-- buffer.

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

M.bufs = bufs
M.rec = rec
M.schedule = schedule
M.claim = claim
M.remove_where = remove_where
M.enabled = enabled
M.warn_once = warn_once

return M
