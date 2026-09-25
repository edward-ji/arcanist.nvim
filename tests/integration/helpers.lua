-- Shared scaffolding for tests/integration/*: a mini.test child Neovim
-- wired up to fixtures/fake_arc.lua instead of a real `arc`, with methods
-- to fixture its responses and inspect the calls it recorded, plus
-- Conduit response builders shared across test files.

local Helpers = {}

-- child.start() spawns via jobstart() with no explicit env, so the child
-- inherits *this* process's $PATH -- prepending fixtures/bin here is what
-- makes every "arc" the child spawns resolve to the fake.
local FIXTURES_BIN = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'integration', 'fixtures', 'bin')

--- A mini.test child Neovim for one test file, not yet started. Use
--- `child.setup`/`child.teardown` as a set's `pre_case`/`post_case` hooks:
--- each case gets a fresh child with arcanist.nvim on its runtimepath (via
--- tests/integration/init.lua) and a fresh scratch `child.dir` as its
--- $ARC_FAKE_DIR, so every `arc` it spawns hits the fake, fixtured per
--- case via `child.fixture()`.
--- @return table child a MiniTest child-Neovim handle, extended below
function Helpers.new_child()
    local child = MiniTest.new_child_neovim()

    function child.setup()
        -- Resolved, because Neovim names a buffer by the file's resolved path
        -- and macOS reaches the temp dir through "/var" -> "/private/var": a
        -- path built from `child.dir` has to match those names.
        child.dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(child.dir, 'p')

        if not vim.startswith(vim.env.PATH, FIXTURES_BIN .. ':') then
            vim.env.PATH = FIXTURES_BIN .. ':' .. vim.env.PATH
        end
        vim.env.ARC_FAKE_DIR = child.dir

        child.start({ '-u', 'tests/integration/init.lua' })
    end

    --- Stop the child and remove its scratch dir.
    function child.teardown()
        child.stop()
        vim.fn.delete(child.dir, 'rf')
    end

    --- Fixture a response for the fake `arc`. `key` is
    --- "call-conduit <method>", "lint", "upload", or "download" (see
    --- fixtures/fake_arc.lua); `response` is a plain value (returned every
    --- call) or `{__sequence = {...}}` (consumed in order, one per call).
    --- @param key string
    --- @param response any
    function child.fixture(key, response)
        local path = child.dir .. '/responses.json'
        local existing = {}
        local f = io.open(path, 'r')
        if f then
            local text = f:read('*a')
            f:close()
            if text ~= '' then
                existing = vim.json.decode(text)
            end
        end
        existing[key] = response
        local out = assert(io.open(path, 'w'))
        out:write(vim.json.encode(existing))
        out:close()
    end

    --- Every call the fake `arc` received, oldest first, optionally only
    --- those matching `key` (e.g. "call-conduit maniphest.edit") -- the
    --- assertion surface for "did arcanist.nvim send the right thing", not
    --- just "did the buffer render right".
    --- @param key string?
    --- @return table[]
    function child.calls(key)
        local calls = {}
        local f = io.open(child.dir .. '/calls.jsonl', 'r')
        if not f then
            return calls
        end
        for line in f:lines() do
            if line ~= '' then
                local call = vim.json.decode(line)
                if key == nil or call.key == key then
                    table.insert(calls, call)
                end
            end
        end
        f:close()
        return calls
    end

    --- Block until `condition` is true, or 2s pass. A string is a Lua
    --- boolean expression evaluated inside the child (pumping its own
    --- event loop, so its async callbacks get a chance to run); a function
    --- is polled here, for state only this process sees, like
    --- `child.calls()`.
    --- @param condition string|fun(): boolean
    function child.wait_until(condition)
        if type(condition) == 'function' then
            vim.wait(2000, condition, 10)
        else
            child.lua(string.format('vim.wait(2000, function() return %s end, 10)', condition))
        end
    end

    --- Start recording every `vim.notify()` call (arcanist.nvim's own
    --- `notify.err`/`.warn`/`.info` all funnel through it, "arcanist.nvim: "
    --- prefix included), so a test can assert on the message a code path
    --- produced without depending on how it got displayed.
    function child.capture_notify()
        child.lua([[
            _G.__notify_log = {}
            vim.notify = function(msg, level)
                table.insert(_G.__notify_log, { msg = msg, level = level })
            end
        ]])
    end

    --- Every message captured since `capture_notify()`, oldest first.
    --- @return { msg: string, level: integer }[]
    function child.notifications()
        return child.lua_get('_G.__notify_log') or {}
    end

    --- Block until a captured message contains `substr`, or 2s pass.
    --- @param substr string
    function child.wait_for_notification(substr)
        child.wait_until(function()
            for _, entry in ipairs(child.notifications()) do
                if entry.msg:find(substr, 1, true) then
                    return true
                end
            end
            return false
        end)
    end

    return child
end

--- A `maniphest.search`-shaped response envelope for one task, matching
--- what HANDLERS.T's fields read from (lua/arcanist/reference.lua).
--- `projects` (project PHIDs) is the one field that isn't rendered from
--- this response alone -- see `resolve_projects` in reference.lua.
--- @param opts { id: integer, title: string, status: string?, priority: string?, description: string?, projects: string[]? }
--- @return table
function Helpers.task_response(opts)
    return {
        data = {
            {
                id = opts.id,
                fields = {
                    name = opts.title,
                    status = { name = opts.status or 'Open' },
                    priority = { name = opts.priority or 'Normal' },
                    description = { raw = opts.description or '' },
                },
                attachments = { projects = { projectPHIDs = opts.projects or {} } },
            },
        },
    }
end

--- A `differential.revision.search`-shaped response envelope for one
--- revision, matching HANDLERS.D's fields.
--- @param opts { id: integer, title: string, summary: string?, testPlan: string? }
--- @return table
function Helpers.revision_response(opts)
    return {
        data = {
            {
                id = opts.id,
                fields = {
                    title = opts.title,
                    summary = opts.summary or '',
                    testPlan = opts.testPlan or '',
                },
            },
        },
    }
end

--- A `phriction.document.search`-shaped response envelope for one wiki
--- document, matching HANDLERS.W's fields -- title/content live under the
--- `content` attachment (requested via `attachments.content`), not
--- top-level `fields` like Maniphest/Differential's `fields.name`/etc.
--- `phid` defaults to a fixed fake -- only Projects' write path
--- (build_edit_calls' own `objectIdentifier` lookup) ever reads it.
--- @param opts { id: integer, slug: string, title: string, content: string?, phid: string? }
--- @return table
function Helpers.wiki_response(opts)
    return {
        data = {
            {
                id = opts.id,
                phid = opts.phid or 'PHID-WIKI-fake',
                fields = { path = opts.slug },
                attachments = {
                    content = {
                        title = opts.title,
                        content = { raw = opts.content or '' },
                    },
                },
            },
        },
    }
end

--- A `file.search`-shaped response envelope for one file.
--- @param opts { name: string, size: integer, alt: string? }
--- @return table
function Helpers.file_response(opts)
    return {
        data = {
            { fields = { name = opts.name, size = opts.size, alt = opts.alt and { default = opts.alt } } },
        },
    }
end

return Helpers
