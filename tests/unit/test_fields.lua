local fields_mod = require('arcanist.fields')

-- A title + two tight 'line' fields + a 'block' field + a trailing 'line'
-- field, so render()'s three blank-line branches (prev is title, current is
-- block, prev is block) each fire at least once.
local function make_fields()
    return {
        { key = 'name', kind = 'title', read = function(f) return f.name end, write = fields_mod.TEXT },
        { key = 'status', kind = 'line', label = 'Status', read = function(f) return f.status end, write = fields_mod.TEXT },
        { key = 'priority', kind = 'line', label = 'Priority', read = function(f) return f.priority end, write = fields_mod.TEXT },
        {
            key = 'description',
            kind = 'block',
            label = 'Description',
            read = function(f) return f.description end,
            write = fields_mod.TEXT,
        },
        { key = 'assignee', kind = 'line', label = 'Assigned', read = function(f) return f.assignee end, write = fields_mod.TEXT },
    }
end

local OBJ = {
    fields = {
        name = 'Fix bug',
        status = 'Open',
        priority = 'High',
        description = 'Line one\nLine two',
        assignee = 'Alice',
    },
}

local EXPECTED_LINES = {
    'Fix bug',
    '',
    'Status: Open',
    'Priority: High',
    '',
    'Description:',
    'Line one',
    'Line two',
    '',
    'Assigned: Alice',
}

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['render()'] = MiniTest.new_set()

T['render()']['renders the title, tight lines, and a separated block'] = function()
    eq(fields_mod.render(make_fields(), OBJ), EXPECTED_LINES)
end

T['parse()'] = MiniTest.new_set()

T['parse()']['round-trips render() output back into the source values'] = function()
    local values = fields_mod.parse(make_fields(), EXPECTED_LINES)
    eq(values, {
        name = 'Fix bug',
        status = 'Open',
        priority = 'High',
        description = 'Line one\nLine two',
        assignee = 'Alice',
    })
end

T['parse()']['omits a field whose label was deleted, distinct from empty'] = function()
    local lines = { 'Fix bug', '', 'Priority: High' }
    local values = fields_mod.parse(make_fields(), lines)
    eq(values.status, nil)
    eq(values.priority, 'High')
end

T['parse()']["a block value extends to the next label, blank lines included"] = function()
    local lines = {
        'Fix bug',
        'Description:',
        'first paragraph',
        '',
        'second paragraph',
        'Status: Open',
    }
    local values = fields_mod.parse(make_fields(), lines)
    eq(values.description, 'first paragraph\n\nsecond paragraph')
    eq(values.status, 'Open')
end

T['parse()']['errors on a duplicate label'] = function()
    local lines = { 'Fix bug', 'Status: Open', 'Status: Closed' }
    local values, err = fields_mod.parse(make_fields(), lines)
    eq(values, nil)
    eq(err, 'duplicate "Status:" label')
end

T['parse()']['errors on text before any field label'] = function()
    local lines = { 'Fix bug', 'stray text', 'Status: Open' }
    local values, err = fields_mod.parse(make_fields(), lines)
    eq(values, nil)
    eq(err, 'text before any field label: "stray text"')
end

T['raw_values()'] = MiniTest.new_set()

T['raw_values()']['matches render() -> parse() for a fresh object'] = function()
    eq(fields_mod.raw_values(make_fields(), OBJ), {
        name = 'Fix bug',
        status = 'Open',
        priority = 'High',
        description = 'Line one\nLine two',
        assignee = 'Alice',
    })
end

T['title_field()'] = MiniTest.new_set()

T['title_field()']['finds the one title-kind field among mixed kinds'] = function()
    eq(fields_mod.title_field(make_fields()).key, 'name')
end

T['field_for_line()'] = MiniTest.new_set()

T['field_for_line()']['matches a line field by its exact label prefix'] = function()
    local field, len = fields_mod.field_for_line(make_fields(), 'Status: Open')
    eq(field.key, 'status')
    eq(len, #'Status: ')
end

T['field_for_line()']['returns nil for a block field label'] = function()
    eq(fields_mod.field_for_line(make_fields(), 'Description:'), nil)
end

T['field_for_line()']['returns nil for an unmatched line'] = function()
    eq(fields_mod.field_for_line(make_fields(), 'stray text'), nil)
end

T['write_value() / changed()'] = MiniTest.new_set()

T['write_value() / changed()']['M.TEXT writes the raw text as-is'] = function()
    eq(fields_mod.write_value({ write = fields_mod.TEXT }, 'Open'), 'Open')
end

T['write_value() / changed()']['M.TEXT is unchanged when raw equals loaded'] = function()
    eq(fields_mod.changed({ write = fields_mod.TEXT }, 'Open', 'Open'), false)
end

T['write_value() / changed()']['M.TEXT is changed when raw differs from loaded'] = function()
    eq(fields_mod.changed({ write = fields_mod.TEXT }, 'Open', 'Closed'), true)
end

T['write_value() / changed()']['M.TEXT is changed when there is no baseline yet'] = function()
    eq(fields_mod.changed({ write = fields_mod.TEXT }, nil, 'Open'), true)
end

return T
