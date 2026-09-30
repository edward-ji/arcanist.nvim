-- Detects the object_reference (T123, D456, ...) or wiki_link
-- ([[some/page]]) at a given buffer position, and resolves it to the
-- "arcanist://" URI arcanist.object.scheme opens -- the 'includeexpr' hook
-- `M.gf()` is how `gf` reaches it.

local document = require('arcanist.object.document')
local types = require('arcanist.object.types')

local M = {}

--- The bare monogram in an `object_reference` node's text: drop the leading
--- "{" of a braced reference and a trailing "#123" comment anchor (as in
--- "T123#456") -- the object itself; jumping to an anchored comment is
--- future work.
--- @param node TSNode
--- @param bufnr integer
--- @return string?
local function bare_monogram(node, bufnr)
    return vim.treesitter.get_node_text(node, bufnr):match('^{?([^#]+)')
end

--- Parse a "{F123, size=full, width=200}" embed's option text (everything
--- after the monogram, e.g. ", size=full") into a dict, the same rules
--- Phorge's own PhutilSimpleOptions uses: comma-separated "key=value" or a
--- bare "key" (-> true), keys folded to lowercase. No quoting support --
--- none of the keys this plugin acts on (size/width/height) ever need it.
--- @param text string
--- @return table<string, string|boolean>
local function parse_embed_options(text)
    local out = {}
    for _, segment in ipairs(vim.split(text, ',', { plain = true, trimempty = true })) do
        segment = vim.trim(segment)
        if segment ~= '' then
            local key, value = segment:match('^([^=]+)=(.*)$')
            if key then
                out[vim.trim(key):lower()] = vim.trim(value)
            else
                out[segment:lower()] = true
            end
        end
    end
    return out
end

--- The treesitter node at the (0-indexed, byte-offset) `row`/`col` in
--- `bufnr`'s "remarkup" parse tree, or nil if the buffer has none (parser
--- not built, wrong filetype, ...). The shared first step of
--- `monogram_at_node`/`wiki_at_node` below -- kept separate so `M.gf`
--- can look it up once and try both instead of re-parsing/re-walking the
--- same position twice on a miss.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return TSNode?
local function node_at(bufnr, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'remarkup')
    if not ok then
        return nil
    end
    -- get_node() needs an up-to-date tree; a caller may reach this before
    -- any redraw has triggered a parse.
    parser:parse()
    return vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
end

--- `monogram_at`'s own walk, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? monogram
local function monogram_at_node(node, bufnr)
    -- "{T123}" keeps its reference in an object_embed's `ref` field, and the
    -- cursor may be on the options or the closing brace instead.
    if node and node:type() == 'embed_options' then
        node = node:parent()
    end
    if node and node:type() == 'object_embed' then
        node = node:field('ref')[1]
    end
    if not node or node:type() ~= 'object_reference' then
        return nil
    end

    return bare_monogram(node, bufnr)
end

--- The object monogram at the (0-indexed, byte-offset) `row`/`col` in
--- `bufnr` -- "T123" for a bare reference, "D4" for "{D4}" -- for any
--- reference the remarkup grammar recognises, or nil if there isn't one
--- there. Whether the plugin can *open* that monogram is the caller's to
--- decide; `M.at` layers the HANDLERS gate and the "arcanist://" prefix on
--- top.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? monogram
function M.monogram_at(bufnr, row, col)
    return monogram_at_node(node_at(bufnr, row, col), bufnr)
end

--- Lazily compiled: `query.parse` needs the `remarkup` parser registered first.
--- @type vim.treesitter.Query?
local refs_query

--- Every object monogram in `bufnr`, in document order, each with the
--- 0-indexed byte range { start_row, start_col, end_row, end_col } of its
--- node -- for a caller acting on all of them at once (inline preview). Same
--- recognition as `monogram_at`; a braced "{F1}" is included via its inner
--- `object_reference` node. `options` is that embed's parsed "{F1, key=value,
--- ...}" option list (see parse_embed_options) -- empty for a bare "F1" or a
--- braced embed with none, since only the embed syntax carries options.
--- `embed_range` is the same as `range` for a bare "F1", but for a braced
--- "{F1, ...}" covers the whole embed -- opening "{" through closing "}" --
--- for a caller that wants to conceal/replace the reference wholesale
--- rather than anchor to the monogram inside it.
--- @param bufnr integer
--- @return { monogram: string, range: integer[], embed_range: integer[], options: table<string, string|boolean> }[]
function M.monograms_in(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'remarkup')
    if not ok then
        return {}
    end
    if not refs_query then
        local parsed_ok, query = pcall(vim.treesitter.query.parse, 'remarkup', '(object_reference) @ref')
        if not parsed_ok then
            return {}
        end
        refs_query = query
    end

    local tree = parser:parse()[1]
    if not tree then
        return {}
    end

    local out = {}
    for _, node in refs_query:iter_captures(tree:root(), bufnr) do
        local monogram = bare_monogram(node, bufnr)
        if monogram then
            local options = {}
            local range = { node:range() }
            local embed_range = range
            local parent = node:parent()
            if parent and parent:type() == 'object_embed' then
                embed_range = { parent:range() }
                local opts_node = parent:field('options')[1]
                if opts_node then
                    options = parse_embed_options(vim.treesitter.get_node_text(opts_node, bufnr))
                end
            end
            out[#out + 1] = { monogram = monogram, range = range, embed_range = embed_range, options = options }
        end
    end
    return out
end

--- `monogram_at` for the cursor in window `win` (default: current).
--- @param win integer?
--- @return string? monogram
function M.monogram_at_cursor(win)
    win = win or 0
    local pos = vim.api.nvim_win_get_cursor(win)
    return M.monogram_at(vim.api.nvim_win_get_buf(win), pos[1] - 1, pos[2])
end

--- `M.at`'s own resolution, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? uri
local function at_node(node, bufnr)
    local text = monogram_at_node(node, bufnr)
    if not text then
        return nil
    end
    local prefix, key = types.parse_ref(text)
    if not prefix then
        return nil
    end

    return types.uri(prefix, key)
end

--- Return the "arcanist://<ref>" URI for the object reference at the
--- (0-indexed, byte-offset) `row`/`col` in `bufnr` -- bare ("T123") or
--- braced ("{T123}") -- or nil if there isn't one there, or it's a type we
--- don't support opening yet.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? uri
function M.at(bufnr, row, col)
    return at_node(node_at(bufnr, row, col), bufnr)
end

--- Whether Phorge would render a wiki_link's raw `target` as a plain
--- hyperlink rather than resolve it as a wiki-slug lookup.
---
--- Replicates PhutilRemarkupDocumentLinkRule::markupDocumentLink's is_uri
--- check, which runs -- and, if it matches, claims the "[[...]]" outright,
--- rendering it as an ordinary link -- *before* PhrictionRemarkupRule (the
--- one that actually does the wiki-slug lookup) ever sees the text:
--- confirmed against the real rule order, ascending by priority
--- (`PhutilRemarkupBlockRule::getPriority()`'s own docstring: "smaller
--- priority numbers execute sooner"), which puts the generic 150 ahead of
--- Phriction's own 175.
---
--- A leading-slash target ("[[/some/page]]") is therefore a site-root-
--- relative hyperlink, not a wiki-slug lookup either -- Phriction documents
--- live under "/w/<slug>" (`PhrictionDocument::getSlugURI`), never at a
--- bare root path.
--- @param target string
--- @return boolean
local function is_uri(target)
    if target == '/' then
        return false
    end
    return target:match('^/') ~= nil
        or target:find('://', 1, true) ~= nil
        or target:match('^#') ~= nil
        or target:match('^mailto:') ~= nil
        or target:match('^tel:') ~= nil
end

--- Resolve a `./`/`../`-relative wiki_link `target` against `base` (the
--- current buffer's own slug), the same segment-by-segment walk Phorge's
--- own `PhrictionRemarkupRule::markupDocumentLink` does. Only meaningful
--- with a `base` -- see M.wiki_at.
--- @param target string
--- @param base string
--- @return string slug
local function resolve_relative(target, base)
    local parts = types.slug_segments(base)
    for _, part in ipairs(types.slug_segments(target)) do
        if part == '.' then
            -- consumed, contributes nothing
        elseif part == '..' then
            parts[#parts] = nil
        else
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, '/') .. '/'
end

--- The slug `bufnr` is itself loaded as, if it names one -- the base a
--- relative wiki_link resolves against. nil everywhere else, same as
--- Phorge, whose relative-link resolution only ever runs while rendering
--- *inside* a Phriction document (`PhrictionRemarkupRule::getRelativeBaseURI`).
---
--- Goes through `identity_of` (the buffer's own last line), not
--- `arcanist_loaded`: the latter is only ever set on a *live*
--- "arcanist://" buffer's own render, never on the draft file
--- `redirect_to_draft` hands it off to -- so with drafts on, the buffer a
--- relative link is actually resolved from is almost always the draft, and
--- `arcanist_loaded` alone would make this silently never fire there.
--- @param bufnr integer
--- @return string?
local function wiki_base(bufnr)
    local prefix, key = document.identity_of(bufnr)
    return prefix == 'W' and key or nil
end

--- `wiki_at`'s own walk, from an already-resolved `node` (see node_at)
--- rather than a position.
--- @param node TSNode?
--- @param bufnr integer
--- @return string? uri
local function wiki_at_node(node, bufnr)
    -- Unlike a bare "object_reference" (a leaf token, so the cursor lands on
    -- it directly), "target"/"label" are wiki_link's own child fields --
    -- the cursor typically sitting inside the link text lands on one of
    -- those, not wiki_link itself.
    if node and (node:type() == 'link_target' or node:type() == 'link_label') then
        node = node:parent()
    end
    if not node or node:type() ~= 'wiki_link' then
        return nil
    end
    local target_node = node:field('target')[1]
    if not target_node then
        return nil
    end

    local target = vim.treesitter.get_node_text(target_node, bufnr)
    if is_uri(target) then
        return nil
    end
    -- A same-page "#anchor" has no meaning for a navigation target; dropped
    -- rather than jumped to, like the rest of the target after it.
    target = target:match('^([^#]*)')

    local slug
    if target:sub(1, 2) == './' or target:sub(1, 3) == '../' then
        local base = wiki_base(bufnr)
        if not base then
            return nil
        end
        slug = resolve_relative(target, base)
    else
        slug = types.normalize_slug(target)
    end

    return types.uri('W', slug)
end

--- Return the "arcanist://w/<slug>" URI for the wiki_link at the
--- (0-indexed, byte-offset) `row`/`col` in `bufnr`, or nil if there isn't
--- one there, it's a target Phorge would treat as a plain hyperlink rather
--- than a wiki page (see is_uri), or it's a `./`/`../`-relative link with no
--- buffer of origin to resolve it against.
--- @param bufnr integer
--- @param row integer
--- @param col integer
--- @return string? uri
function M.wiki_at(bufnr, row, col)
    return wiki_at_node(node_at(bufnr, row, col), bufnr)
end

--- 'includeexpr' hook for Remarkup buffers. Returns the "arcanist://" URI
--- for an object reference or wiki_link under the cursor -- `gf` and the
--- rest of its family then open that via the BufReadCmd (see arcanist.object.scheme) --
--- or `fname` unchanged, so Vim's own file lookup handles anything else.
---
--- Vim only evaluates 'includeexpr' when the raw <cfile> is not already an
--- existing file, so a real path under the cursor never reaches here. The
--- node is resolved once here and handed to both `at_node`/`wiki_at_node`
--- rather than calling `M.at`/`M.wiki_at`, which would each reparse and
--- rewalk the same position on their own.
--- @param fname string Vim's extracted <cfile>, and the fallback.
--- @return string
function M.gf(fname)
    local bufnr = vim.api.nvim_get_current_buf()
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1] - 1, pos[2]
    local node = node_at(bufnr, row, col)
    return at_node(node, bufnr) or wiki_at_node(node, bufnr) or fname
end

return M
