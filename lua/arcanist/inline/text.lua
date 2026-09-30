-- `file.inline.text`: conceal each referenced file monogram and show
-- Phorge's own description of the file in its place.

local state = require('arcanist.inline.state')

local M = {}

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
--- `BufWinEnter` re-arm in arcanist.inline's `setup`) act on this data
--- directly, so one cursor move or buffer redisplay costs one pass over
--- `bufs[buf].text` rather than N autocmd firings for N placements.
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
    local r = state.bufs[buf]
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
    local r = state.bufs[buf]
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
    if not (state.enabled(buf) and require('arcanist').config.file.inline.text) then
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

    local r = state.rec(buf)
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
                    match = state.claim(current, claimed, function(ref)
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
        local match = state.claim(current, claimed, function(ref)
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
    -- `BufWinEnter` too -- see the single dispatcher in arcanist.inline's
    -- `setup`.
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
                    state.remove_where(state.bufs[buf] and state.bufs[buf].text, function(e)
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
    state.schedule(buf, 'text_gen', sync_text)
end

M.clear = clear_text
M.schedule = schedule_text_sync
M.sync_reveal = sync_text_reveal
M.ensure_conceallevel = ensure_conceallevel

return M
