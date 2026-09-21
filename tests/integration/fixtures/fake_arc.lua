-- The fake `arc`. Run by tests/integration/fixtures/bin/arc via `nvim -l`,
-- so vim.json/vim.fn are available without depending on jq/python/node.
--
-- $ARC_FAKE_DIR (set per test child by tests/integration/helpers.lua) holds:
--   responses.json  { [key] = value }             -- what to answer with
--   calls.jsonl     one JSON object per call, appended -- what was asked
--   .calls/<key>    a plain integer, for {__sequence = {...}} fixtures
--
-- A fixture value is returned as-is on every matching call, unless it's a
-- table shaped `{__sequence = {v1, v2, ...}}`, in which case each call
-- advances through the list (repeating the last entry once exhausted) --
-- lets a test answer the same method differently across a
-- read-edit-reread sequence without a stateful fake DB. Plain values are
-- never table-sniffed for this, so a real Conduit response that happens to
-- be a JSON array (e.g. `arc upload`'s) is never misread as a sequence.

local dir = assert(os.getenv('ARC_FAKE_DIR'), 'fake arc: $ARC_FAKE_DIR is not set')
vim.fn.mkdir(dir .. '/.calls', 'p')

local function read_json(path)
    local f = io.open(path, 'r')
    if not f then
        return nil
    end
    local text = f:read('*a')
    f:close()
    if text == '' then
        return nil
    end
    return vim.json.decode(text)
end

local function log_call(key, params)
    local f = assert(io.open(dir .. '/calls.jsonl', 'a'))
    f:write(vim.json.encode({ key = key, argv = arg, params = params }) .. '\n')
    f:close()
end

--- The response fixtured for `key`, advancing a `{__sequence = ...}`
--- fixture's counter if that's what it is. Exits loudly if nothing was
--- fixtured -- a missing fixture is a test bug, not an empty result.
--- @param key string
--- @return any
local function next_response(key)
    local responses = read_json(dir .. '/responses.json') or {}
    local entry = responses[key]
    if entry == nil then
        io.stderr:write(string.format('fake arc: no fixture for %q\n', key))
        os.exit(1)
    end

    if type(entry) == 'table' and entry.__sequence ~= nil then
        local sequence = entry.__sequence
        local counter_path = dir .. '/.calls/' .. key:gsub('[^%w%.]', '_')
        local f = io.open(counter_path, 'r')
        local count = f and tonumber(f:read('*a')) or 0
        if f then
            f:close()
        end
        local index = math.min(count + 1, #sequence)
        local out = assert(io.open(counter_path, 'w'))
        out:write(tostring(index))
        out:close()
        return sequence[index]
    end

    return entry
end

local subcommand = arg[1]

if subcommand == 'call-conduit' then
    -- 'call-conduit', <method>, '--'
    -- A plain fixture value is the literal Conduit "response" payload.
    -- `{__control = {delay_ms=, value=}}` (same reserved key as `upload`)
    -- opts into a delay -- for testing `config.conduit_timeout`'s blocking
    -- `call_sync` path, which kills a still-running call past its timeout
    -- (see conduit.lua's decode_result: code 124 + SIGKILL).
    local method = arg[2]
    local key = 'call-conduit ' .. method
    local stdin = io.read('*a') or ''
    local ok, params = pcall(vim.json.decode, stdin ~= '' and stdin or '{}')
    log_call(key, ok and params or nil)
    local response = next_response(key)
    if type(response) == 'table' and response.__control then
        local control = response.__control
        if control.delay_ms then
            vim.wait(control.delay_ms)
        end
        response = control.value
    end
    io.write(vim.json.encode({
        error = vim.NIL,
        errorMessage = vim.NIL,
        response = response,
    }))
    os.exit(0)
elseif subcommand == 'lint' then
    -- The fixture is normally the literal stdout `arc lint --output json`
    -- would produce (a newline-delimited stream of per-file JSON
    -- documents, or plain prose for "nothing to report") -- not
    -- reconstructed from a table, since qf.lua parses that exact shape.
    -- For a usage error or a deliberately slow run (to test qf.lua's
    -- "already running"/cancel-and-replace logic), fixture a table
    -- instead: {stdout=?, stderr=?, exit_code=?, delay_ms=?}.
    log_call('lint', nil)
    local response = next_response('lint')
    if type(response) == 'table' then
        if response.delay_ms then
            -- vim.wait() (not vim.uv.sleep(), a hard blocking C sleep) pumps
            -- this process's own event loop while it waits, so a SIGTERM
            -- delivered mid-delay (qf.lua killing a still-running lint to
            -- start another) actually gets to take effect promptly.
            vim.wait(response.delay_ms)
        end
        io.write(response.stdout or '')
        io.stderr:write(response.stderr or '')
        os.exit(response.exit_code or 0)
    end
    io.write(response)
    os.exit(0)
elseif subcommand == 'upload' then
    -- 'upload', '--json', '--', <path>
    -- A plain fixture value is the literal success array (e.g. {{id=1}}),
    -- unwrapped -- upload.lua's own success shape is itself an array, so
    -- (unlike lint's stdout-vs-table fixtures) there's no ambiguity to
    -- guard against here. `{__control = {...}}` opts into a delay and/or
    -- a nonzero exit, for testing cancellation and failure parsing.
    log_call('upload', { path = arg[4] })
    local response = next_response('upload')
    if type(response) == 'table' and response.__control then
        local control = response.__control
        if control.delay_ms then
            vim.wait(control.delay_ms)
        end
        if control.exit_code and control.exit_code ~= 0 then
            io.stderr:write(control.stderr or '')
            os.exit(control.exit_code)
        end
        response = control.value
    end
    io.write(vim.json.encode(response))
    os.exit(0)
elseif subcommand == 'download' then
    -- 'download', '--as', <part>, '--', 'F<id>'
    local part, monogram = arg[3], arg[5]
    log_call('download', { monogram = monogram })
    local response = next_response('download')
    if response.ok == false then
        io.stderr:write(response.stderr or 'fake arc: download failed\n')
        os.exit(response.code or 1)
    end
    local out = assert(io.open(part, 'wb'))
    out:write(response.bytes or '')
    out:close()
    os.exit(0)
else
    io.stderr:write(string.format('fake arc: unhandled subcommand %q\n', tostring(subcommand)))
    os.exit(1)
end
