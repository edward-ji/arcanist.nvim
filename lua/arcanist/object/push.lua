-- Pushing a buffer's text to the Phorge object it names: `:w` on an
-- "arcanist://" buffer (via arcanist.object.scheme) and ":ArcWrite".

local conduit = require('arcanist.arc.conduit')
local document = require('arcanist.object.document')
local fields = require('arcanist.object.fields')
local notify = require('arcanist.notify')
local types = require('arcanist.object.types')

local M = {}

--- Whether `bufnr` is `prefix`+`key`'s own "arcanist://" buffer, and the
--- baseline it carries of that object as loaded, if any.
--- @param bufnr integer
--- @param prefix string
--- @param key integer|string
--- @param ref_name string
--- @return boolean is_own
--- @return table? baseline
local function target_of(bufnr, prefix, key, ref_name)
    -- Two separate questions. Whether this is the object's own buffer
    -- (`is_own`) decides what happens to the buffer, 'modified' above all.
    -- Whether it carries a record of the object as loaded (`baseline`)
    -- decides what gets sent and whether a conflict is checked for. A copy
    -- saved out with ":sav" answers no to the first and yes to the second.
    --
    -- Compared via `parse_uri` (both sides run through `handler.parse`)
    -- rather than raw name equality, since a buffer's literal name is never
    -- rewritten to its canonical form (see HANDLERS.W's `parse`).
    local buf_prefix, buf_key = types.parse_uri(vim.api.nvim_buf_get_name(bufnr))
    local is_own = buf_prefix == prefix and buf_key == key
    local loaded = vim.b[bufnr].arcanist_loaded
    return is_own, loaded and loaded.ref == ref_name and loaded or nil
end

--- Cross-check `bufnr`'s identity line against the target. Whether the
--- text names this object at all (so its "Last Modified:" line dates it),
--- or nil and the message refusing the push.
--- @param bufnr integer
--- @param prefix string
--- @param key integer|string
--- @param ref_name string
--- @return boolean? named
--- @return string? err
local function check_identity(bufnr, prefix, key, ref_name)
    local id_prefix, id_key, id_err = document.identity_of(bufnr)
    if id_err then
        return nil, string.format('failed to update %s: %s', ref_name, id_err)
    end
    if id_prefix and not (id_prefix == prefix and id_key == key) then
        -- A copy about to go over the object it was copied from. `!` doesn't
        -- override this -- it means "ignore the staleness check" -- but
        -- deleting the line does.
        return nil,
            string.format(
                '%s: this text is labelled %s. Delete the "%s:" line to push it elsewhere',
                ref_name,
                types.get(id_prefix).format(id_key),
                types.get(id_prefix).identity
            )
    end
    return id_prefix ~= nil
end

--- One transaction per field whose parsed text in `values` differs from
--- `baseline` -- every field present, without one -- or nil and an error.
--- @param handler table one of HANDLERS' values
--- @param values table<string, string> from `fields.parse`
--- @param baseline table?
--- @return table[]? transactions
--- @return string? err
local function transactions_for(handler, values, baseline)
    local transactions = {}
    for _, field in ipairs(handler.fields) do
        local raw = values[field.key]
        -- No `write` is the identity line: nothing to send for it.
        if
            field.write
            and raw ~= nil
            and fields.changed(field, baseline and baseline.values[field.key], raw)
        then
            local value, err = fields.write_value(field, raw)
            if not value then
                return nil, err
            end
            table.insert(transactions, { type = field.key, value = value })
        end
    end
    return transactions
end

--- The staleness guard: refuse the push if the server's copy moved on since
--- the buffer's text was taken from it -- compared field by field against
--- `baseline`, or by `dateModified` against `last_modified` without one.
--- The freshly fetched object, or nil and the message refusing the push.
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param key integer|string
--- @param ref_name string
--- @param baseline table?
--- @param last_modified string?
--- @return table? obj
--- @return string? err
local function check_drift(handler, prefix, key, ref_name, baseline, last_modified)
    local obj, err = types.fetch_sync(handler, key)
    if err then
        return nil, string.format('failed to check %s for changes: %s', ref_name, err)
    end
    if not obj then
        return nil, string.format('%s no longer exists', ref_name)
    end
    -- Compared field by field rather than by dateModified, which has
    -- one-second resolution and moves for a write that changed nothing.
    -- Fields with no `write` are left out: a write cannot reach them, so
    -- a change to one is not a change this write could lose.
    if baseline then
        local current = fields.raw_values(handler.fields, obj)
        for _, field in ipairs(handler.fields) do
            if field.write and fields.changed(field, baseline.values[field.key], current[field.key]) then
                -- `:e` alone won't work here -- the buffer is modified, so Vim
                -- refuses with E37 -- and `:e!` discards the edits, hence the
                -- nudge to save them off somewhere first. `!` overwrites the
                -- server's version instead, same as any other Vim write.
                return nil,
                    string.format(
                        '%s changed on the server since it was loaded. Your edits are still here; '
                            .. ':w {file} to keep a copy, then :e! to reload -- or :w!/:ArcWrite! '
                            .. 'to overwrite the server\'s version',
                        ref_name
                    )
            end
        end
    elseif obj.fields.dateModified and types.iso8601(obj.fields.dateModified) > last_modified then
        -- No fields to compare, so dateModified is all there is.
        return nil,
            string.format(
                '%s changed on the server since %s. Your edits are still here; '
                    .. ':w {file} to keep a copy, then :e! %s to refetch -- or :ArcWrite! '
                    .. 'to overwrite the server\'s version',
                ref_name,
                last_modified,
                types.uri(prefix, key)
            )
    end
    return obj
end

--- Send `transactions` as however many Conduit calls `handler` needs.
--- @param handler table one of HANDLERS' values
--- @param key integer|string
--- @param transactions table[]
--- @param known_obj table? see `build_edit_calls`
--- @return boolean ok
--- @return string? err
local function apply(handler, key, transactions, known_obj)
    local calls, calls_err = handler.build_edit_calls(key, transactions, known_obj)
    if not calls then
        return false, calls_err
    end
    local timeout = require('arcanist').config.conduit_timeout
    for _, call in ipairs(calls) do
        local ok, _, err = conduit.call_sync(call.method, call.params, timeout)
        if not ok then
            return false, err
        end
    end
    return true
end

--- After a push lands, re-fetch for a baseline and a "Last Modified:"
--- matching what the server now holds. Content bar that one line is
--- deliberately left alone so the cursor and undo history survive the save.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param key integer|string
--- @param ref_name string
--- @param is_own boolean
--- @param baseline table?
--- @param last_modified string?
local function refresh(bufnr, handler, key, ref_name, is_own, baseline, last_modified)
    local obj, refresh_err = types.fetch_sync(handler, key)
    if obj and last_modified and obj.fields.dateModified then
        document.set_last_modified(bufnr, ref_name, types.iso8601(obj.fields.dateModified))
    end
    if is_own then
        vim.bo[bufnr].modified = false
    end
    if obj then
        if baseline then
            vim.b[bufnr].arcanist_loaded = {
                ref = ref_name,
                values = fields.raw_values(handler.fields, obj),
            }
        end
        notify.info('updated ' .. ref_name)
    elseif baseline then
        notify.warn(
            string.format(
                'updated %s, but could not refresh it (%s); :e to reload',
                ref_name,
                refresh_err or 'not found'
            )
        )
    else
        notify.warn(
            string.format(
                'updated %s, but could not read back its new %s (%s); the next :ArcWrite may need !',
                ref_name,
                types.LAST_MODIFIED,
                refresh_err or 'not found'
            )
        )
    end
end

--- Push `lines` (from `bufnr`) to `prefix`+`key` over Conduit. When `bufnr`
--- is itself the "arcanist://<ref>" buffer being updated, runs the
--- staleness guard first (unless `force`) and refreshes its
--- baseline/'modified' afterward. Synchronous: the caller needs a definite
--- success/failure before it can decide whether to clear 'modified', and
--- leaving it set on failure is what keeps Vim's own E37 guard protecting
--- unsaved edits.
---
--- Only fields that actually changed become transactions -- diffed against
--- `arcanist_loaded`, the baseline recorded at load (or after the last
--- successful push), which names the object it was taken from. A buffer
--- carrying a baseline for some other object, or none at all (`:w
--- arcanist://T1` from an unrelated buffer), sends every field present in
--- it -- there's nothing to diff against. Either way, a field whose label
--- was deleted from the buffer is simply absent from the parse, and left
--- untouched on the server.
---
--- Without a baseline, a "Last Modified:" line under a matching identity
--- line (a draft's) is the staleness guard instead: the server's
--- `dateModified` having moved past it refuses the push, and a push that
--- lands moves the line up to the new one.
---
--- An identity line is cross-checked against the target first, whichever
--- entry point got here, so no path can push one object's text over
--- another's.
---
--- Shared by two entry points: `:w` on an "arcanist://" buffer (via
--- arcanist.object.scheme), and the ":ArcWrite" command, which pushes
--- the current buffer's content directly over Conduit instead of asking
--- Vim to write to a name -- the only way to push when the target's own
--- buffer is already open elsewhere, since Vim's own E139 ("file is loaded
--- in another buffer") blocks `:w {name}` for that case before our
--- BufWriteCmd ever runs, and `!` does not override it.
--- @param bufnr integer
--- @param handler table one of HANDLERS' values
--- @param prefix string
--- @param key integer|string
--- @param lines string[]
--- @param force boolean skip the staleness guard (from `:w!`/`:ArcWrite!`)
--- and overwrite the server's version even if it changed since load.
--- @return boolean pushed whether the object now matches the buffer.
function M.push(bufnr, handler, prefix, key, lines, force)
    local ref_name = handler.format(key)

    --- @param err string
    --- @return false
    local function fail(err)
        notify.err(string.format('failed to update %s: %s', ref_name, err))
        return false
    end

    local is_own, baseline = target_of(bufnr, prefix, key, ref_name)
    if is_own and not baseline then
        notify.err(string.format('%s has not loaded successfully; nothing to update', ref_name))
        return false
    end

    local named, id_err = check_identity(bufnr, prefix, key, ref_name)
    if id_err then
        notify.err(id_err)
        return false
    end

    local values, parse_err = fields.parse(handler.fields, lines)
    if not values then
        return fail(parse_err)
    end

    -- Only under the identity line it dates: with that line deleted to push
    -- the text elsewhere, it dates some other object.
    local last_modified
    if named then
        local lm_err
        last_modified, lm_err = document.last_modified_of(bufnr, ref_name, values.last_modified)
        if lm_err then
            return fail(lm_err)
        end
    end

    local transactions, tx_err = transactions_for(handler, values, baseline)
    if not transactions then
        return fail(tx_err)
    end

    if #transactions == 0 then
        notify.info(ref_name .. ': no changes to update')
        if is_own then
            vim.bo[bufnr].modified = false
        end
        return true
    end

    -- Blocking Conduit calls follow; say so before the UI freezes, not
    -- after. nvim_echo (what vim.notify's default handler calls) flushes to
    -- the message area synchronously, before this function's own call
    -- returns, so this is visible before the wait.
    notify.info('updating ' .. ref_name .. '...')

    -- Skipped entirely with `force` (":w!"/":ArcWrite!") -- the round-trip
    -- exists to catch a conflict, and force means overwrite regardless of
    -- one, so there's nothing to check for. `fresh_obj` is kept around
    -- (rather than let go once the drift check is done with it): it's
    -- handed to `build_edit_calls` below, which for some handlers (Wiki)
    -- would otherwise have to re-fetch the very same object just to read
    -- something off it (see HANDLERS.W).
    local fresh_obj
    if (baseline or last_modified) and not force then
        local drift_err
        fresh_obj, drift_err = check_drift(handler, prefix, key, ref_name, baseline, last_modified)
        if not fresh_obj then
            notify.err(drift_err)
            return false
        end
    end

    local applied, apply_err = apply(handler, key, transactions, fresh_obj)
    if not applied then
        return fail(apply_err)
    end

    if baseline or last_modified then
        refresh(bufnr, handler, key, ref_name, is_own, baseline, last_modified)
    else
        notify.info('updated ' .. ref_name)
    end
    return true
end

--- Handle ":ArcWrite[!] [ref]". `ref` defaults to the current buffer's own
--- reference if it's an "arcanist://" buffer, and otherwise to whatever its
--- identity line names (see identity_of). This is the way to push when the
--- target's own buffer is already open elsewhere -- see push()'s doc comment
--- for why `:w` can't do that.
--- @param cmd_args table nvim_create_user_command callback args
function M.command(cmd_args)
    local bufnr = vim.api.nvim_get_current_buf()
    local ref_arg = vim.trim(cmd_args.args)
    local prefix, key, target

    if ref_arg ~= '' then
        prefix, key = types.parse_ref(ref_arg)
        target = 'arcanist://' .. ref_arg
        if not prefix then
            notify.err('invalid reference: ' .. ref_arg)
            return
        end
    else
        target = vim.api.nvim_buf_get_name(bufnr)
        prefix, key = types.parse_uri(target)
        if not prefix then
            -- Nothing in the name to go on, so fall back to what the text
            -- says it is.
            local id_prefix, id_key, id_err = document.identity_of(bufnr)
            if id_err then
                notify.err(':ArcWrite: ' .. id_err)
                return
            end
            prefix, key = id_prefix, id_key
            if not prefix then
                notify.err(
                    ':ArcWrite needs a reference: this is not an "arcanist://" buffer, and its '
                        .. 'last line does not name a Phorge object'
                )
                return
            end
            target = types.uri(prefix, key)
        end
    end

    local handler = types.resolve_handler(prefix, target, 'push')
    if not handler then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    M.push(bufnr, handler, prefix, key, lines, cmd_args.bang)
end

return M
