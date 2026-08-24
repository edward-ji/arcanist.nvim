-- Runs an `arc` workflow and routes its findings into Neovim's quickfix
-- list.
--
-- A plain piped `vim.system` works because lint is fully non-interactive;
-- the prompting workflows (`diff`, `land`, `patch`) go through
-- phutil_console_require_tty() and would need a real terminal.

local M = {}

--- @param level integer vim.log.levels.*
--- @param msg string
local function notify(level, msg)
    vim.notify('arcanist.nvim: ' .. msg, level)
end

--- @param msg string
function M.notify_err(msg)
    notify(vim.log.levels.ERROR, msg)
end

--- Pull the one useful line out of `arc`'s stderr.
---
--- `arc` logs PHP deprecation warnings and a stack trace to stderr even on
--- runs that succeed completely, so a non-empty stderr means nothing on its
--- own. PhutilErrorHandler writes every one of those as "[<time>] <LABEL>:";
--- the "EXCEPTION:" dump upload.lua also has to cope with is the member of
--- that family worth reporting, so it's matched ahead of the rest.
---
--- A workflow's own failure arrives as "Usage Exception: <msg>", or as a
--- message under a bare "Exception" banner -- all that survives of
--- "<bg:red>** Exception **</bg>" once phutil_console_format strips the bold
--- and colour it can't send down a pipe.
--- @param stderr string?
--- @return string
local function extract_error(stderr)
    local fallback
    for line in vim.gsplit(stderr or '', '\n', { plain = true }) do
        line = vim.trim(line)
        if line ~= '' then
            local usage = line:match('^Usage Exception:%s*(.+)$')
            if usage then
                return usage
            end
            local exception = line:match('EXCEPTION:%s*%b()%s*(.-)%s+at%s+%[')
            if exception then
                return exception
            end
            local is_noise = line == 'Exception'
                or line:match('^%[.-%]%s+%u+%s*%d*:')
                or line:match('^#%d+%s')
                or line:match('^arcanist%(head=')
            if not is_noise then
                fallback = fallback or line
            end
        end
    end
    return fallback or ''
end

--- The working copy `arc` should run in. `arc lint` reports paths relative
--- to the project root, so this doubles as the base they resolve against.
--- @param bufnr integer
--- @return string
function M.root(bufnr)
    return vim.fs.root(bufnr, { '.arcconfig', '.git' }) or vim.fn.getcwd()
end

--- The one in-flight run, or nil. One at a time: the quickfix list is a
--- single global, so concurrent runs race and whichever finishes last wins
--- -- not necessarily whichever started last.
--- @type { handle: table, label: string, started: integer }?
local active = nil

--- How long the in-flight run has been going, for the "already running"
--- message.
--- @param record table
--- @return string
local function elapsed(record)
    local seconds = math.floor((vim.uv.hrtime() - record.started) / 1e9)
    if seconds < 60 then
        return string.format('%ds', seconds)
    end
    return string.format('%dm%02ds', math.floor(seconds / 60), seconds % 60)
end

--- @class arcanist.QuickfixRun
--- @field argv string[] Full `arc` argument vector.
--- @field cwd string Working copy to run in.
--- @field command string User command name, for the "already running" hint.
--- @field force boolean Cancel an in-flight run instead of refusing.
--- @field parse fun(stdout: string): table[]?, string

--- Run an `arc` workflow and put whatever `parse` makes of its output into
--- the quickfix list.
---
--- With a run already in flight, a plain invocation refuses and points at
--- the bang; "!" cancels the running one and starts this one. Deliberately
--- not a prompt: this is a background job, so a prompt would arrive at a
--- moment the user didn't choose and swallow whatever they were typing.
--- @param opts arcanist.QuickfixRun
function M.run(opts)
    local label = opts.argv[1] .. ' ' .. opts.argv[2]
    local note = ''

    if active then
        if not opts.force then
            notify(
                vim.log.levels.WARN,
                string.format(
                    '%s is already running (%s) -- :%s! to cancel it and run this instead',
                    active.label,
                    elapsed(active),
                    opts.command
                )
            )
            return
        end

        -- Folded into the "running..." message below rather than notified
        -- separately: two notifies in the same tick means the second
        -- overwrites the first, so the confirmation would never be seen.
        note = string.format('cancelled after %s, ', elapsed(active))
        pcall(function()
            active.handle:kill('sigterm')
        end)
        active = nil
    end

    -- The run is asynchronous and takes seconds on a real working copy, so
    -- say something now or the command reads as not having registered.
    notify(vim.log.levels.INFO, label .. ': ' .. note .. 'running...')

    local record = { label = label, started = vim.uv.hrtime() }

    -- vim.system() throws synchronously (rather than calling back) if `arc`
    -- itself can't be spawned at all, e.g. it's missing from PATH -- so that
    -- has to be caught here or it escapes out of the user command.
    local spawn_ok, handle = pcall(
        vim.system,
        opts.argv,
        { text = true, cwd = opts.cwd },
        vim.schedule_wrap(function(obj)
            -- A cancelled run still calls back, having been killed. By then
            -- `active` is the run that replaced it, so these stale results
            -- must not land on the list that run now owns.
            if active ~= record then
                return
            end
            active = nil

            local stdout = obj.stdout or ''

            -- `arc` echoes an ArcanistNoEffectException ("No paths are
            -- lintable.") to stdout and exits 0, so a run that matched
            -- nothing arrives in prose on the channel the findings use. A
            -- JSON document can only open with "{" or "[", so output that
            -- doesn't is certainly not results; output that does still has
            -- to satisfy the parser.
            if not stdout:match('^%s*[%[{]') then
                -- Exit status reports findings, not failure: lint exits 1
                -- for warnings and 2 for errors (ArcanistLintWorkflow.php:8),
                -- and a usage error also exits 1. Output is what separates
                -- them.
                if obj.code ~= 0 then
                    local msg = extract_error(obj.stderr)
                    if msg == '' then
                        msg = string.format('exited with code %d', obj.code)
                    end
                    M.notify_err(label .. ': ' .. msg)
                    return
                end

                -- Replace rather than leave a stale list lying around.
                vim.fn.setqflist({}, ' ', { title = label, items = {} })
                local said = vim.trim(stdout)
                notify(
                    vim.log.levels.INFO,
                    label .. ': ' .. (said ~= '' and said or 'nothing to report')
                )
                return
            end

            local items, message = opts.parse(stdout)
            if not items then
                M.notify_err(label .. ': ' .. message)
                return
            end

            vim.fn.setqflist({}, ' ', { title = label, items = items })
            if #items > 0 then
                vim.cmd.copen()
            end
            notify(vim.log.levels.INFO, label .. ': ' .. message)
        end)
    )

    if not spawn_ok then
        -- Strip Lua's "<chunk>:<line>: " prefix; the useful part is what
        -- follows (typically ENOENT, i.e. `arc` isn't on PATH).
        local msg = vim.trim(tostring(handle)):gsub('^[^%s]-:%d+:%s*', '')
        M.notify_err(label .. ': ' .. msg)
        return
    end

    record.handle = handle
    active = record
end

return M
