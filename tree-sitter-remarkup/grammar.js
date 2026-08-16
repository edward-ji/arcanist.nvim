// grammar.js
// Tree-sitter grammar for Phorge's "Remarkup" lightweight markup language.
// Reference: https://projects.clusterlabs.org/book/phorge/article/remarkup/
//
// Newlines are NOT extras (they are structurally significant, as in most
// line-oriented markup languages), only inline whitespace is.

// One or more `rule`s separated by (but not necessarily trailed by) `sep`.
function sepBy1(sep, rule) {
  return seq(rule, repeat(seq(sep, rule)));
}

// `char` repeated `min` or more times. Deliberately NOT written as a regex
// like /-{3,}/: tree-sitter 0.26.12's regex compiler mishandles open-ended
// `{n,}` quantifiers (confirmed in isolation -- a grammar containing only
// `token(prec(1, /-{3,}/))` matches exactly 3 chars of a 10-char run and
// errors on the rest). Bounded quantifiers like `{3,10}` compile fine, as
// does this seq+repeat form, which is what we use instead. Regex `+`/`*`
// (open-ended too, but a different quantifier form) are NOT affected --
// `_indented_marker` and `table_delimiter_row` below use plain `/-+/`-style
// regexes on purpose, not an oversight.
function atLeast(min, char) {
  return seq(...Array(min).fill(char), repeat(char));
}

// Lexer precedence tiers. Higher wins ties when multiple tokens could match
// the same input (see setext_header/divider below for why LINE_RULE must
// stay above BLOCK_MARKER). Named so that adding a new token at one of
// these tiers doesn't silently break an ordering relationship some other,
// unrelated rule depends on.
const PREC = {
  FALLBACK_TEXT: -1,
  OBJECT_REF: 1,
  BLOCK_MARKER: 2, // atx `=` marker, callout keywords, list-item marker
  LINE_RULE: 3, // setext underline, divider -- must beat BLOCK_MARKER
};

// The inline element types, in the same order `_inline_elt` lists them.
// Each `_inline_no_*` rule below is "every inline element except the one
// you're already inside" (so e.g. bold can't directly self-nest, but can
// still contain italic, which can itself contain bold, etc.) -- expressed
// once here and filtered per call site instead of five hand-copied lists.
const INLINE_ELEMENTS = [
  'bold', 'italic', 'monospace', 'monospace_alt', 'strikethrough',
  'underline', 'highlighted', 'wiki_link', 'md_link', 'angle_url',
  'bare_url', 'mention', 'project_tag', 'object_reference', 'embed', 'text',
];

function inlineChoice($, excludeName) {
  return choice(...INLINE_ELEMENTS.filter(name => name !== excludeName).map(name => $[name]));
}

module.exports = grammar({
  name: 'remarkup',

  extras: $ => [/[ \t]/],

  conflicts: $ => [
    [$.embed_block, $._inline_elt],
  ],

  rules: {
    document: $ => repeat(choice($._block, $._blank_line)),

    _blank_line: $ => '\n',

    _block: $ => choice(
      $.atx_header,
      $.setext_header,
      $.divider,
      $.fenced_code_block,
      $.indented_code_block,
      $.literal_block,
      $.table,
      $.blockquote,
      $.callout,
      $.list,
      $.embed_block,
      $.paragraph,
    ),

    // ---------------------------------------------------------------
    // Headers
    // ---------------------------------------------------------------

    // = Header =   /  == Header ==  / ... trailing = signs optional
    atx_header: $ => seq(
      field('marker', $._atx_marker),
      field('content', alias($._line_text, $.text)),
      optional($._atx_marker),
      '\n',
    ),
    _atx_marker: $ => token(prec(PREC.BLOCK_MARKER, /=+/)),

    // Alternate/setext style:
    // Header text
    // ======  (or ------)
    setext_header: $ => prec.dynamic(1, seq(
      field('content', alias($._line_text, $.text)),
      '\n',
      // LINE_RULE, strictly above BLOCK_MARKER: a run of dashes here is
      // also a legal (if absurdly deep) list-item marker, and at equal
      // precedence the lexer's longest-match tie broke towards `marker`
      // instead of `underline`. Precedence forces dashes-as-underline to
      // win whenever both are in play. (`=` needs no such tie-break --
      // nothing else matches a bare run of `=` -- so plain repeat1 is
      // enough there; only the dash alternative needs `atLeast`, for
      // min=3, see the comment on `atLeast` above.)
      field('underline', token(prec(PREC.LINE_RULE, choice(repeat1('='), atLeast(3, '-'))))),
      '\n',
    )),

    // ---------------------------------------------------------------
    // Dividers: three or more dashes alone on a line
    // ---------------------------------------------------------------
    // LINE_RULE for the same reason as setext_header's underline above:
    // ties with BLOCK_MARKER otherwise.
    divider: $ => seq(token(prec(PREC.LINE_RULE, atLeast(3, '-'))), '\n'),

    // ---------------------------------------------------------------
    // Code blocks
    // ---------------------------------------------------------------
    fenced_code_block: $ => seq(
      '```',
      optional(field('info', alias(/[^\n]+/, $.info_string))),
      '\n',
      field('content', optional(alias(repeat1($._code_line), $.code_content))),
      '```',
      '\n',
    ),
    _code_line: $ => seq(/[^\n`][^\n]*/, '\n'),

    indented_code_block: $ => prec.right(repeat1(seq('  ', /[^\n]*/, '\n'))),

    // ---------------------------------------------------------------
    // Literal blocks: %%% ... %%%   (not processed by remarkup)
    // ---------------------------------------------------------------
    literal_block: $ => seq(
      '%%%', '\n',
      field('content', optional(alias(repeat1(seq(/[^\n]*/, '\n')), $.literal_content))),
      '%%%', '\n',
    ),

    // ---------------------------------------------------------------
    // Blockquotes: lines beginning with >
    // ---------------------------------------------------------------
    blockquote: $ => prec.right(repeat1(
      seq('>', optional(alias($._line_text, $.text)), '\n'),
    )),

    // ---------------------------------------------------------------
    // Callouts: NOTE:, WARNING:, IMPORTANT: (also parenthesized forms)
    // ---------------------------------------------------------------
    callout: $ => seq(
      field('type', token(prec(PREC.BLOCK_MARKER, choice('NOTE:', 'WARNING:', 'IMPORTANT:', '(NOTE)', '(WARNING)', '(IMPORTANT)')))),
      optional(alias($._line_text, $.text)),
      '\n',
    ),

    // ---------------------------------------------------------------
    // Lists (flat representation; `indent` field carries nesting depth
    // via marker-repetition or leading spaces so downstream tooling can
    // reconstruct a tree)
    // ---------------------------------------------------------------
    list: $ => prec.right(repeat1($.list_item)),

    list_item: $ => seq(
      field('marker', alias($._indented_marker, $.marker)),
      ' ',
      optional(field('checkbox', $.checkbox)),
      field('content', alias($._line_text, $.text)),
      '\n',
    ),

    // Leading spaces are folded into the same atomic token as the marker
    // itself (rather than a separate, possibly-zero-width `indent` rule)
    // because standalone tokens that can match the empty string produce
    // degenerate lexer states in tree-sitter and were corrupting lexing
    // for every other rule that shared its parser state.
    _indented_marker: $ => token(prec(PREC.BLOCK_MARKER, seq(
      / */,
      choice(
        /-+/,
        /\*+/,
        /#+/,
        /\d+[.)]/,
      ),
    ))),

    checkbox: $ => seq('[', choice('X', 'x', ' '), ']', ' '),

    // ---------------------------------------------------------------
    // Tables (pipe-delimited)
    // ---------------------------------------------------------------
    table: $ => prec.right(seq(
      $.table_row,
      optional($.table_delimiter_row),
      repeat($.table_row),
    )),

    // The trailing '|' before the newline is optional (as in GFM tables) --
    // only the pipes *between* cells are required.
    table_row: $ => seq(
      '|',
      sepBy1('|', field('cell', alias($._table_cell_text, $.table_cell))),
      optional('|'),
      '\n',
    ),
    _table_cell_text: $ => /[^|\n]+/,

    table_delimiter_row: $ => seq(
      '|',
      sepBy1('|', /[ \t]*-+[ \t]*/),
      optional('|'),
      '\n',
    ),

    // ---------------------------------------------------------------
    // Standalone embed / macro blocks, e.g. {nav ...}, {meme ...}
    // when they occupy their own line.
    // ---------------------------------------------------------------
    embed_block: $ => prec.dynamic(1, seq($.embed, '\n')),

    // ---------------------------------------------------------------
    // Paragraphs: fallback run of inline content
    // ---------------------------------------------------------------
    paragraph: $ => prec.right(seq(
      $._line_text,
      repeat(seq('\n', $._line_text)),
      '\n',
    )),

    // "Rest of the physical line" as a run of inline elements -- used both
    // for a paragraph's own lines and, via the `alias(..., $.text)` call
    // sites above, as the convenience alias for header/blockquote/list/
    // callout content.
    _line_text: $ => repeat1($._inline_elt),

    // ---------------------------------------------------------------
    // Inline elements
    // ---------------------------------------------------------------
    _inline_elt: $ => inlineChoice($),

    bold: $ => seq('**', repeat1($._inline_no_bold), '**'),
    _inline_no_bold: $ => inlineChoice($, 'bold'),

    italic: $ => seq('//', repeat1($._inline_no_italic), '//'),
    _inline_no_italic: $ => inlineChoice($, 'italic'),

    monospace: $ => seq('`', field('content', alias(/[^`\n]+/, $.text)), '`'),
    monospace_alt: $ => seq('##', field('content', alias(/[^#\n]+/, $.text)), '##'),

    strikethrough: $ => seq('~~', repeat1($._inline_no_strike), '~~'),
    _inline_no_strike: $ => inlineChoice($, 'strikethrough'),

    underline: $ => seq('__', repeat1($._inline_no_underline), '__'),
    _inline_no_underline: $ => inlineChoice($, 'underline'),

    highlighted: $ => seq('!!', repeat1($._inline_no_highlight), '!!'),
    _inline_no_highlight: $ => inlineChoice($, 'highlighted'),

    // [[wiki page]]  /  [[wiki page | name]]
    wiki_link: $ => seq(
      '[[',
      field('target', alias(/[^|\]\n]+/, $.link_target)),
      optional(seq('|', field('label', alias(/[^\]\n]+/, $.link_label)))),
      ']]',
    ),

    // [name](http://xyz/)
    md_link: $ => seq(
      '[', field('label', alias(/[^\]\n]*/, $.link_label)), ']',
      '(', field('target', alias(/[^)\n]+/, $.link_target)), ')',
    ),

    // <http://example.com/,>  -- forces the parser to consume the whole URI
    angle_url: $ => seq('<', field('url', alias(/https?:\/\/[^>\n]+/, $.url)), '>'),

    bare_url: $ => field('url', alias(/https?:\/\/[^\s<>\[\]()*]+/, $.url)),

    // @username
    mention: $ => seq('@', field('name', alias($._word, $.username))),

    // #project or #project_tag  (hashtag, not a header -- disambiguated by
    // not being at start-of-line-only; here matched anywhere inline)
    project_tag: $ => seq('#', field('name', alias($._word, $.project_name))),

    // D123, T123, rX123, rXaf3192cd5, T123#412
    //
    // Kept as a single atomic token (rather than separate type/id terminals)
    // so the lexer only ever proposes `object_reference` when a real object
    // prefix (D/T/F/M/P/C or r<repo>) is *immediately* followed by digits.
    // Splitting this into two terminals let the lexer commit to "this looks
    // like an object ref" for any bare word and then fail once no digit
    // followed, which broke plain-prose parsing entirely.
    object_reference: $ => token(prec(PREC.OBJECT_REF, seq(
      choice('D', 'T', 'F', 'M', 'P', 'C', seq('r', /[A-Za-z]+/)),
      /\d+/,
      optional(seq('#', /\d+/)),
    ))),

    // {D123}, {F123, layout=left, alt="a duckling"}, {icon camera color=blue},
    // {key command option shift 3}, {nav ...}, {meme, ...}, {anchor #xyz}
    embed: $ => seq(
      '{',
      field('kind', alias(/[A-Za-z][A-Za-z0-9]*/, $.embed_kind)),
      optional(field('options', alias(/[^}\n]*/, $.embed_options))),
      '}',
    ),

    _word: $ => /[A-Za-z0-9_.-]+/,

    // `-` doesn't need escaping as the class's last character (unlike `[`,
    // which tree-sitter's regex parser does require escaped, even inside
    // a class).
    //
    // Fallback is `[^ \t\n]`, not `.`: `.` also matches space/tab, which
    // beat `extras` for them (a real token rule always wins over extras)
    // and let a leading space get glued onto the next token -- e.g. "
    // D123" instead of " " + "D123".
    text: $ => token(prec(PREC.FALLBACK_TEXT, /[^\s*/`#~_!\[\]{}@<>|\\%=-]+|[^ \t\n]/)),
  },
});
