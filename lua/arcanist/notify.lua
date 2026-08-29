-- The "arcanist.nvim: " prefix every module's messages carry, so they all
-- look like they came from the same plugin. (arcanist.paste, .upload,
-- .completion and the ftplugin still spell it inline -- not yet moved.)
--
-- One function per level rather than one taking a level: three levels are
-- all this has ever needed, and naming them keeps `vim.log.levels` out of
-- the call sites.

local M = {}

--- @param level integer vim.log.levels.*
--- @param msg string
local function notify(level, msg)
    vim.notify('arcanist.nvim: ' .. msg, level)
end

--- Progress and success: what happened, on a path that worked.
--- @param msg string
function M.info(msg)
    notify(vim.log.levels.INFO, msg)
end

--- The action mostly worked, but the result is not what was asked for.
--- @param msg string
function M.warn(msg)
    notify(vim.log.levels.WARN, msg)
end

--- The action did not happen.
--- @param msg string
function M.err(msg)
    notify(vim.log.levels.ERROR, msg)
end

return M
