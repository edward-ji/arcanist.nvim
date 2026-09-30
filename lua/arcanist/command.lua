-- The ":ArcWrite", ":ArcLint", ":ArcList" and ":ArcFile" user commands.
-- CamelCase matches ":Inspect"/":InspectTree" in Neovim's own runtime.
--
-- Each command requires its module only when it runs: registering them is
-- what has to happen at startup, and a session that never lints or lists
-- would otherwise pay for pulling those in.

local M = {}

local installed = false

function M.setup()
    if installed then
        return
    end
    installed = true

    vim.api.nvim_create_user_command('ArcWrite', function(args)
        require('arcanist.object.push').command(args)
    end, {
        nargs = '?',
        bang = true,
        desc = 'Push the current buffer to a Phorge task/revision (defaults to the current '
            .. 'buffer\'s own reference). Unlike ":w arcanist://T123", works even if that '
            .. 'reference\'s own buffer is already open elsewhere. "!" overwrites even if the '
            .. 'object changed on the server since it was loaded.',
    })

    vim.api.nvim_create_user_command('ArcLint', function(args)
        require('arcanist.lint').command(args)
    end, {
        nargs = '*',
        bang = true,
        complete = 'file',
        desc = 'Run `arc lint` on the given paths and load the results into the '
            .. 'quickfix list. Accepts `arc lint` flags, which must use the '
            .. '"--flag=value" form. With "!", cancel a run already in progress '
            .. 'and start over.',
    })

    vim.api.nvim_create_user_command('ArcList', function(args)
        require('arcanist.list').command(args)
    end, {
        nargs = '*',
        complete = function(...)
            return require('arcanist.list').complete(...)
        end,
        desc = 'Browse Phorge tasks or revisions in a picker and open the chosen one. '
            .. 'Takes "[query] [type]", reading as English -- ":ArcList open tasks", '
            .. '":ArcList active revisions". The query defaults to "all" and the '
            .. 'type to revisions. Narrow further with "owner=" and "author=", '
            .. 'each a comma-separated list of usernames in which "me" stands for '
            .. 'you -- ":ArcList open tasks owner=me".',
    })

    vim.api.nvim_create_user_command('ArcFile', function(args)
        local monogram = vim.trim(args.args)
        if monogram == '' then
            monogram = require('arcanist.reference').monogram_at_cursor()
            if not monogram then
                require('arcanist.notify').err(
                    'ArcFile: no monogram under the cursor (pass one, e.g. :ArcFile F123)'
                )
                return
            end
        end

        require('arcanist').preview(monogram, { force = args.bang })
    end, {
        nargs = '?',
        bang = true,
        desc = 'Download a Phorge file object (F123, or the monogram under the cursor) '
            .. 'into a local cache and open it with the system handler. With "!", '
            .. 're-download even if cached and ignore the size limit.',
    })
end

return M
