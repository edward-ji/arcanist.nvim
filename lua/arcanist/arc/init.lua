-- Running `arc` itself: spawning it, and reading why it failed. Everything
-- that shells out -- Conduit calls, lint, upload, download -- goes through
-- here, so a missing `arc` and its noisy stderr are handled one way.

local M = {}

--- `vim.system(argv, opts, on_exit)`, with `on_exit` run on the main loop.
---
--- vim.system() throws synchronously (rather than calling back) if `arc`
--- itself can't be spawned at all, e.g. it's missing from PATH; that comes
--- back here as nil plus the error, rather than escaping from whatever
--- autocmd or command happened to start it. Lua's "<chunk>:<line>: " prefix
--- is stripped -- the useful part is what follows (typically ENOENT).
--- @param argv string[]
--- @param opts vim.SystemOpts
--- @param on_exit fun(obj: vim.SystemCompleted)?
--- @return vim.SystemObj? proc
--- @return string? err
function M.spawn(argv, opts, on_exit)
    local ok, res = pcall(vim.system, argv, opts, on_exit and vim.schedule_wrap(on_exit))
    if not ok then
        return nil, (vim.trim(tostring(res)):gsub('^[^%s]-:%d+:%s*', ''))
    end
    return res
end

--- Pull the one useful line out of `arc`'s stderr, or "" if there is none.
---
--- `arc` logs PHP deprecation warnings and a stack trace to stderr even on
--- runs that succeed completely, so a non-empty stderr means nothing on its
--- own. PhutilErrorHandler writes every one of those as "[<time>] <LABEL>:";
--- the "EXCEPTION:" dump a failed `arc upload` leaves is the member of that
--- family worth reporting, so it's matched ahead of the rest.
---
--- A workflow's own failure arrives as "Usage Exception: <msg>", as
--- " USAGE EXCEPTION <msg>" from `arc download` (which leads each line with
--- a marker like that), or as a message under a bare "Exception" banner --
--- all that survives of "<bg:red>** Exception **</bg>" once
--- phutil_console_format strips the bold and colour it can't send down a
--- pipe.
--- @param stderr string?
--- @return string
function M.error_message(stderr)
    local fallback
    for line in vim.gsplit(stderr or '', '\n', { plain = true }) do
        line = vim.trim(line)
        if line ~= '' then
            local usage = line:match('^Usage Exception:%s*(.+)$') or line:match('^USAGE EXCEPTION%s+(.+)$')
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

return M
