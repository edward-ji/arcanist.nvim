local typeahead = require('arcanist.typeahead')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['match()'] = MiniTest.new_set()

T['match()']['matches a case-insensitive prefix of a later word'] = function()
    eq(typeahead.match('linc', { 'Abraham Lincoln' }), 'Lincoln')
end

T['match()']['returns the match in its original casing'] = function()
    eq(typeahead.match('LINC', { 'abraham lincoln' }), 'lincoln')
end

T['match()']['returns nil when the query is not a prefix of any word'] = function()
    eq(typeahead.match('lncoln', { 'Abraham Lincoln' }), nil)
end

T['match()']['returns nil for an empty candidate list'] = function()
    eq(typeahead.match('linc', {}), nil)
end

T['match()']['splits on brackets and hyphens, not just whitespace'] = function()
    eq(typeahead.match('mile', { 'sprint-1[milestone](2024)' }), 'milestone')
end

T['match()']['checks candidates in order and returns the first hit'] = function()
    eq(typeahead.match('a', { 'Bob', 'Alice' }), 'Alice')
end

T['graft()'] = MiniTest.new_set()

T['graft()']['appends the matched token remainder to the query'] = function()
    eq(typeahead.graft('linc', 'Lincoln'), 'lincoln')
end

T['graft()']['is the query itself when the token is already fully typed'] = function()
    eq(typeahead.graft('Lincoln', 'Lincoln'), 'Lincoln')
end

T['sort_text()'] = MiniTest.new_set()

T['sort_text()']['ranks a whole-name prefix hit above a word-content hit'] = function()
    local prefix_hit = typeahead.sort_text({ true }, false, 'alice')
    local word_hit = typeahead.sort_text({ false }, false, 'bob')
    MiniTest.expect.equality(prefix_hit < word_hit, true)
end

T['sort_text()']['ranks an open result above a closed one at the same tier'] = function()
    local open = typeahead.sort_text({ true }, false, 'alice')
    local closed = typeahead.sort_text({ true }, true, 'alice')
    MiniTest.expect.equality(open < closed, true)
end

T['sort_text()']['breaks ties alphabetically, case-insensitively'] = function()
    local a = typeahead.sort_text({ true }, false, 'Alice')
    local b = typeahead.sort_text({ true }, false, 'bob')
    MiniTest.expect.equality(a < b, true)
end

return T
