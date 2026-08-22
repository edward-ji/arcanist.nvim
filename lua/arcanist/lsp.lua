-- An in-process language server for remarkup buffers, exposing just enough
-- of the LSP surface -- textDocument/definition (T/D object references)
-- and textDocument/completion (@mention/#project, Status/Priority field
-- values) -- to reuse whatever `gd` keymap and completion setup you
-- already have, instead of bespoke keymaps/UI of our own.
--
-- Runs in-process (`cmd` is a Lua function, not a subprocess): each
-- "request" answers by inspecting the *live* client buffer directly via
-- arcanist.reference/arcanist.completion, so there's no document to keep
-- synced -- textDocument/didOpen and didChange are accepted and ignored.

local reference = require('arcanist.reference')
local completion = require('arcanist.completion')

local M = {}

--- Build the RPC client `vim.lsp.start()` talks to. See
--- `vim.lsp.rpc.PublicClient` for the exact contract this must satisfy.
--- @param dispatchers vim.lsp.rpc.Dispatchers
--- @return vim.lsp.rpc.PublicClient
local function start_server(dispatchers)
    local closing = false
    local next_id = 0

    --- @type vim.lsp.rpc.PublicClient
    return {
        request = function(method, params, callback)
            next_id = next_id + 1

            if method == 'initialize' then
                callback(nil, {
                    capabilities = {
                        -- Sidesteps LSP's default UTF-16 column encoding --
                        -- Neovim negotiates this, so positions below are
                        -- plain byte offsets, matching what
                        -- vim.treesitter/nvim_win_get_cursor already use.
                        positionEncoding = 'utf-8',
                        definitionProvider = true,
                        completionProvider = { triggerCharacters = { '@', '#' } },
                    },
                })
            elseif method == 'shutdown' then
                callback(nil, nil)
            elseif method == 'textDocument/definition' then
                local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
                local pos = params.position
                local uri = reference.at(bufnr, pos.line, pos.character)
                if not uri then
                    callback(nil, nil)
                else
                    callback(nil, {
                        uri = uri,
                        range = {
                            start = { line = 0, character = 0 },
                            ['end'] = { line = 0, character = 0 },
                        },
                    })
                end
            elseif method == 'textDocument/completion' then
                local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
                local pos = params.position
                -- @mention goes out over Conduit (debounced -- see
                -- arcanist.completion), so this resolves asynchronously
                -- even though `request()` itself has already returned.
                completion.items_at(bufnr, pos.line, pos.character, function(items, start_col, opts)
                    if not items then
                        callback(nil, nil)
                        return
                    end
                    -- An *empty* item list is still a real response, not
                    -- nil: with `isIncomplete = true` it tells the
                    -- client "nothing yet, but keep re-requesting as
                    -- more is typed" -- a null response instead lets the
                    -- client stop querying, so a momentarily-empty live
                    -- result would kill completion for the rest of the
                    -- word.
                    callback(nil, {
                        -- The sigil sources are live searches: matching
                        -- happens server-side per keystroke (see
                        -- arcanist.completion), so more typing warrants a
                        -- fresh request. Field values are a complete
                        -- list, so client-side filtering on further
                        -- keystrokes is already correct.
                        isIncomplete = opts.live,
                        items = vim.tbl_map(function(item)
                            return {
                                label = item.text,
                                kind = opts.kind,
                                detail = item.detail,
                                -- `filter`: what the client should match
                                -- typed text against -- the word that
                                -- actually matched (e.g. a real name),
                                -- not the label alone, or the client
                                -- would drop such items on re-filtering.
                                -- `sort`: Phorge's result ranking.
                                filterText = item.filter,
                                sortText = item.sort,
                                textEdit = {
                                    range = {
                                        start = { line = pos.line, character = start_col },
                                        ['end'] = { line = pos.line, character = pos.character },
                                    },
                                    newText = item.text,
                                },
                            }
                        end, items),
                    })
                end)
            else
                callback(nil, nil)
            end

            return true, next_id
        end,

        notify = function(method, _params)
            if method == 'exit' then
                closing = true
                if dispatchers.on_exit then
                    dispatchers.on_exit(0, nil)
                end
            end
            -- didOpen/didChange/didClose/initialized etc.: intentionally no-op.
            return true
        end,

        is_closing = function()
            return closing
        end,

        terminate = function()
            closing = true
        end,
    }
end

--- Attach the server to `bufnr` (default: current buffer). Safe to
--- call from every remarkup buffer's ftplugin -- vim.lsp.start() dedups
--- clients by name/cmd/root_dir on its own.
--- @param bufnr integer?
function M.setup(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    reference.setup()

    vim.lsp.start({
        name = 'arcanist',
        cmd = start_server,
        root_dir = vim.fs.root(bufnr, { '.arcconfig', '.git' }) or vim.fn.getcwd(),
    }, { bufnr = bufnr })
end

return M
