-- Shared scaffolding for tests/integration/*: a mini.test child Neovim
-- wired up to fixtures/fake_arc.lua instead of a real `arc`, plus helpers
-- to fixture its responses and inspect the calls it recorded.

local Helpers = {}

-- child.start()/restart() spawn via jobstart() with no explicit env, so the
-- child inherits *this* process's $PATH -- prepending fixtures/bin here is
-- what makes every "arc" the child spawns resolve to the fake.
local FIXTURES_BIN = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'integration', 'fixtures', 'bin')

--- Fixture a response for one child's fake `arc`. `key` is
--- "call-conduit <method>", "lint", "upload", or "download" (see
--- fixtures/fake_arc.lua); `response` is a plain value (returned every
--- call) or `{__sequence = {...}}` (consumed in order, one per call).
--- @param dir string a child's $ARC_FAKE_DIR, from Helpers.new_child()
--- @param key string
--- @param response any
function Helpers.fixture(dir, key, response)
    local path = dir .. '/responses.json'
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

--- Every call a child's fake `arc` received, oldest first -- the
--- assertion surface for "did arcanist.nvim send the right thing", not
--- just "did the buffer render right".
--- @param dir string a child's $ARC_FAKE_DIR, from Helpers.new_child()
--- @return table[]
function Helpers.calls(dir)
    local calls = {}
    local f = io.open(dir .. '/calls.jsonl', 'r')
    if not f then
        return calls
    end
    for line in f:lines() do
        if line ~= '' then
            table.insert(calls, vim.json.decode(line))
        end
    end
    f:close()
    return calls
end

--- A mini.test child Neovim with arcanist.nvim on its runtimepath (via
--- tests/integration/init.lua, or `opts.init` for a test that needs its own)
--- and a fresh scratch $ARC_FAKE_DIR so every `arc` it spawns hits the fake,
--- fixtured per test via Helpers.fixture().
--- @param opts { init: string? }?
--- @return table child a MiniTest child-Neovim handle
--- @return string dir its scratch $ARC_FAKE_DIR
function Helpers.new_child(opts)
    opts = opts or {}
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')

    if not vim.startswith(vim.env.PATH, FIXTURES_BIN .. ':') then
        vim.env.PATH = FIXTURES_BIN .. ':' .. vim.env.PATH
    end
    vim.env.ARC_FAKE_DIR = dir

    local child = MiniTest.new_child_neovim()
    child.start({ '-u', opts.init or 'tests/integration/init.lua' })

    return child, dir
end

--- Stop a child and remove its scratch $ARC_FAKE_DIR.
--- @param child table
--- @param dir string
function Helpers.stop(child, dir)
    child.stop()
    vim.fn.delete(dir, 'rf')
end

--- Start recording every `vim.notify()` call in `child` (arcanist.nvim's
--- own `notify.err`/`.warn`/`.info` all funnel through it, "arcanist.nvim: "
--- prefix included), so a test can assert on the message a code path
--- produced without depending on how it got displayed.
--- @param child table
function Helpers.capture_notify(child)
    child.lua([[
        _G.__notify_log = {}
        vim.notify = function(msg, level)
            table.insert(_G.__notify_log, { msg = msg, level = level })
        end
    ]])
end

--- Every message captured since `capture_notify()`, oldest first.
--- @param child table
--- @return { msg: string, level: integer }[]
function Helpers.notifications(child)
    return child.lua_get('_G.__notify_log') or {}
end

return Helpers
