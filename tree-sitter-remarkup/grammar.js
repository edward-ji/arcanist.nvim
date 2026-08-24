// grammar.js
// Tree-sitter grammar for Phorge's "Remarkup" lightweight markup language.
//
// Source of truth is Phorge's own PHP implementation (paths relative to
// phorge/src):
//   - block rules:  infrastructure/markup/blockrule/PhutilRemarkup*BlockRule.php
//   - inline rules: infrastructure/markup/markuprule/PhutilRemarkup*Rule.php
//   - object refs:  infrastructure/markup/rule/PhabricatorObjectRemarkupRule.php
//     plus the per-application subclasses under applications/*/remarkup/
//   - mentions:     applications/people/markup/PhabricatorMentionRemarkupRule.php
//   - hashtags:     applications/project/remarkup/ProjectRemarkupRule.php
//
// Known, deliberate divergences from Phorge -- all forced by tree-sitter's
// deterministic lexer, which can't look ahead to end-of-line or behind the
// current token the way Phorge's regexes can:
//
//   - `#`-style ATX headers ("## Header") are not recognized; those lines
//     parse as `#` ordered-list items. Phorge itself is context-sensitive
//     here (a lone `#...` line is a header, a run of them is a list, see
//     PhutilRemarkupListBlockRule's is_one_line deferral); remarkup's
//     native `=` and setext headers are fully supported, so only
//     Markdown-compat headers are affected.
//   - Inline spans (**bold** etc.) don't cross line breaks; Phorge's
//     bold/italic/del/underline regexes use /s and can span lines within
//     one paragraph.
//   - Blockquote content is per-line inline text; Phorge recursively
//     re-parses quoted text as full blocks (headers/lists inside quotes).
//   - `***`, `___`, `* * *` and `- - -` horizontal rules are not
//     recognized: the starred/underscored forms collide with the bold and
//     underline delimiters in the lexer, and the spaced forms lex as list
//     items -- which is exactly what Phorge's own list rule would do if
//     the HR rule didn't preempt it at a higher priority. Plain `---`
//     (3+ adjacent dashes) is supported.
//   - "word##mono##" stays plain text: the word-'#' bonding that blocks
//     "word#tag" from becoming a hashtag (a real Phorge guard) also
//     swallows this much rarer glued-monospace construct.
//   - Unqualified commit hashes ("deadbeef42"-style) and bare repository
//     callsigns ("rABC") are not linked: far too many false positives on
//     ordinary prose for a parser that can't check object existence.
//   - HTML-ish `<table>` blocks and `name (opts) {{{...}}}` interpreter
//     blocks are not recognized.
//   - A lone `--` line with nothing above it renders as a divider; Phorge
//     treats it as a paragraph (as an underline under text it's a setext
//     header in both).
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
// (open-ended too, but a different quantifier form) are NOT affected.
function atLeast(min, char) {
  return seq(...Array(min).fill(char), repeat(char));
}

// Lexer precedence tiers. In tree-sitter, explicit lexical precedence is
// consulted BEFORE match length, so a tier-N token beats a longer tier-<N
// match at the same position. Named so that adding a new token at one of
// these tiers doesn't silently break an ordering relationship some other,
// unrelated rule depends on.
//
const PREC = {
  FALLBACK_TEXT: -1,
  OBJECT_REF: 1,
  BLOCK_MARKER: 2, // atx `=` marker, callout keywords, list-item marker
  // Strictly above OBJECT_REF: a "T123abc"-shaped word must lex as one
  // text token, not as objref "T123" + text "abc" (see the guard below).
  OBJECT_REF_GUARD: 2,
  // Strictly above BLOCK_MARKER: a full "==\n"/"--\n" underline line must
  // beat the atx `=` marker and the list-item marker (" -- " with trailing
  // space) when it closes a setext header. See `_setext_underline`.
  SETEXT_UNDERLINE: 3,
};

// ---------------------------------------------------------------------
// The `text` fallback token, built once here because `text` and
// `_table_text` need the same structure with different single-char
// fallbacks.
//
// The "clean" class excludes every char that can begin or delimit an
// inline rule, plus chars that must stay separate tokens so that a
// FOLLOWING token gets a chance to start there. That second group is why
// `(`, `)`, `"`, `'`, `:`, `,` and `;` are excluded even though no rule
// consumes them: a bare URL like "(http://x)" or "see: http://x" is only
// recognized if the lexer starts a fresh token at the `h` -- if `(` or
// `:` were "clean", the whole thing would glue into one text token and
// PhutilRemarkupHyperlinkRule's `(?<!\w)\w{3,32}://` equivalent below
// (`bare_url`) would never fire.
//
// `-` doesn't need escaping as the class's last character (unlike `[`,
// which tree-sitter's regex parser does require escaped, even inside a
// class).
//
// The fallback is `[^ \t\n]`, not `.`: `.` also matches space/tab, which
// beat `extras` for them (a real token rule always wins over extras) and
// let a leading space get glued onto the next token.
//
// The multi-char alternative is "clean" chars plus *bonding* alternatives
// that swallow a marker char rather than stopping right before it,
// whenever Phorge's own rules demand a boundary that the marker token
// (which can't see what preceded it) could never check itself:
//
//   - `[A-Za-z0-9][@#]+`: word char glued to '@'/'#' runs -- blocks
//     "mail@lists" / "word#tag" (PhabricatorMentionRemarkupRule and
//     ProjectRemarkupRule both require a non-word boundary before the
//     marker) and the "l@@k" construct.
//   - `[@#][@#]+`: two or more bare '@'/'#' with nothing word-attached
//     before them -- neither '@' in "@@joe" can start a mention.
//   - "[A-Za-z0-9]`+": word char glued to backticks -- Phorge's
//     monospace rule requires `\B` before the opening backtick, so
//     "don`t use`them" must stay plain prose.
//   - `[A-Za-z0-9]\[+`: word char glued to '[' -- both link rules
//     require `\B` before the bracket, so "x[0]" never opens a link.
//   - `-+[A-Za-z0-9]`: dash run glued to a following word -- object
//     references require `(?<![#@-])`, so "ABC-T1" contains no T1 ref
//     (and "D123-D125" links only D123, faithfully absurd).
//   - `:/+`: colon glued to slashes -- the italic rule requires
//     `(?<!:)//`, so a non-linkable "ab://x//y" (protocol too short for
//     `bare_url`) must not read as italic. Long protocols never get
//     here: `bare_url` outranks `text` (explicit precedence beats match
//     length), so "http://..." always lexes as a URL first.
//
// A single, boundary-clean '@' or '#' (etc.) is left alone, so "@joe"
// and "#tag" at a real word boundary still parse normally.
// ---------------------------------------------------------------------
const TEXT_CLEAN = "[^\\s*/`#~_!\\[\\]{}@<>|\\\\%=()\"':,;-]";
const TEXT_BONDS = [
  '[A-Za-z0-9][@#]+',
  '[@#][@#]+',
  '[A-Za-z0-9]`+',
  '[A-Za-z0-9]\\[+',
  '-+[A-Za-z0-9]',
  ':/+',
];
function textToken(fallback) {
  return token(prec(PREC.FALLBACK_TEXT, new RegExp(
    `(?:${TEXT_CLEAN}|${TEXT_BONDS.join('|')})+|${fallback}`)));
}

// The inline element types, in the same order `_inline_elt` lists them.
// Each `_inline_no_*` rule below is "every inline element except the one
// you're already inside" (so e.g. bold can't directly self-nest, but can
// still contain italic, which can itself contain bold, etc.) -- expressed
// once here and filtered per call site instead of hand-copied lists.
const INLINE_ELEMENTS = [
  'bold', 'italic', 'monospace', 'monospace_alt', 'strikethrough',
  'underline', 'highlighted', 'wiki_link', 'md_link', 'angle_url',
  'bare_url', 'mention', 'project_tag', 'object_reference', 'embed',
  'hex_color', 'text',
];

function inlineChoice($, excludeName) {
  return choice(
    ...INLINE_ELEMENTS.filter(name => name !== excludeName).map(name => $[name]),
    // "[foo]" with no following "(url)" -- reduced to plain bracketed
    // text instead of a parse error (see `_bracket_span`).
    $._bracket_span,
    // An opening delimiter whose closing half never arrives ("a ** b",
    // a pasted C++ "// comment", "don't [[ worry") is plain text in
    // Phorge, which simply finds no match. The lexer has already
    // committed to the delimiter token by then, so give the parser a
    // way to reduce it to text; the GLR fork this creates is resolved
    // by the prec.dynamic(1) on each paired construct, which makes the
    // real span win whenever it can complete.
    alias($._stray_delimiter, $.text),
  );
}

module.exports = grammar({
  name: 'remarkup',

  extras: $ => [/[ \t]/],

  conflicts: $ => [
    [$.embed_block, $._inline_elt],
    // Paired inline construct vs. its opening delimiter standing alone as
    // prose -- GLR explores both; prec.dynamic on the paired rule makes
    // the real span win whenever it can complete.
    [$._stray_delimiter, $.bold],
    [$._stray_delimiter, $.italic],
    [$._stray_delimiter, $.strikethrough],
    [$._stray_delimiter, $.underline],
    [$._stray_delimiter, $.highlighted],
    // "[label](target)" vs. "[label]" + prose parens -- only a real
    // conflict because '(' is also a _stray_delimiter alternative, which
    // is what allows the fallback parse to consume it as text when the
    // link target turns out invalid.
    [$.md_link, $._bracket_span],
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

    // = Header =   /  == Header ==  / ... trailing = signs optional.
    // Content is optional so a bare "==" line is an (empty) header, as in
    // PhutilRemarkupHeaderBlockRule's `^(={1,5}...).*$` (which also caps
    // the *level* at 5 but still matches longer runs, so `/=+/` here is
    // equivalent for structure).
    atx_header: $ => seq(
      field('marker', $._atx_marker),
      optional(field('content', alias($._line_text, $.text))),
      optional($._atx_marker),
      '\n',
    ),
    _atx_marker: $ => token(prec(PREC.BLOCK_MARKER, /=+/)),

    // Alternate/setext style:
    // Header text
    // ======  (or ------, or even mixed, at least 2 chars long, per the
    // header rule's `^([^\n]+)\n[-=]{2,}\s*$`)
    //
    // The underline token includes its own trailing newline. That's the
    // whole trick: it gives the lexer the end-of-line lookahead that an
    // LR(1) parser otherwise lacks, so a run of `=`/`-` is claimed as an
    // underline exactly when the rest of the line is blank. "==flag" after
    // a paragraph line fails this token, falls back to the plain
    // `_atx_marker`, and parses as paragraph + atx header (which is what
    // Phorge does); "--verbose" falls all the way to prose. Without the
    // newline inside the token, either those lines error out (a greedy
    // high-precedence underline steals their first chars) or every
    // paragraph line break needs a GLR fork, which measured ~30x slower
    // on paragraph-heavy documents.
    //
    // Known limitation: the underline is only recognized when the header
    // text starts a fresh block ("para line\nTitle\n==" greedily absorbs
    // "Title" into the paragraph first). Phorge would make "Title" a
    // header there; put a blank line before setext headers.
    setext_header: $ => seq(
      field('content', alias($._line_text, $.text)),
      '\n',
      field('underline', $._setext_underline),
    ),
    _setext_underline: $ => token(prec(PREC.SETEXT_UNDERLINE, /[=-][=-]+[ \t]*\n/)),

    // ---------------------------------------------------------------
    // Dividers: three or more dashes alone on a line
    // ---------------------------------------------------------------
    // FALLBACK_TEXT precedence, deliberately: at a line start, "---" has
    // no higher-tier competitor (the list marker token requires trailing
    // whitespace and can't match), so the dash run only competes with the
    // `text` bonding alternatives at the same tier -- and there the match
    // *length* decides, which is exactly right: "---" alone lexes as the
    // run (3 > 1-char fallback), while "--verbose" lexes as one text
    // token (9 > 2), keeping option-flag lines as prose instead of a
    // stranded divider/underline prefix followed by an error.
    divider: $ => seq($._dash_run, '\n'),
    _dash_run: $ => token(prec(PREC.FALLBACK_TEXT, atLeast(3, '-'))),

    // ---------------------------------------------------------------
    // Code blocks
    // ---------------------------------------------------------------
    // PhutilRemarkupCodeBlockRule: an opening ``` line (optionally with
    // trailing info text), then content up to the first line ENDING with
    // ``` -- the closer doesn't have to stand alone, "quack();```" closes
    // a block too, and content lines may be blank or start with
    // backticks. A one-line ```like this``` form also exists.
    fenced_code_block: $ => choice(
      // ```echo "one-liner";```  -- `^\s*(```)(.*)(```)\s*$`. One atomic
      // token: the interior may contain anything (including backticks),
      // and the lexer's longest-match against the plain '```' opener
      // picks this form exactly when a same-line closer exists.
      seq(field('content', alias($._fenced_oneline, $.code_content)), '\n'),
      seq(
        '```',
        choice(
          seq(field('info', alias(/[^\n]+/, $.info_string)), '\n'),
          // Phorge reads the option list off the FIRST LINE OF THE BLOCK,
          // which is the fence line's trailing text when it has any and
          // otherwise the line below it -- so ``` on its own line followed
          // by `lang=php` is the same block as ```lang=php.
          seq('\n', optional(seq(
            field('info', alias($._option_line, $.info_string)),
            '\n',
          ))),
        ),
        field('content', optional(alias(repeat1($._code_line), $.code_content))),
        $._fence_close,
        '\n',
      ),
    ),
    _fenced_oneline: $ => token(seq('```', /[^\n]*/, '```')),
    // The four options PhutilRemarkupCodeBlockRule knows, in the comma-
    // separated `key=value` form PhutilSimpleOptions lexes (keys are
    // case-insensitive; values may be quoted, and only then may they
    // contain a comma). ONE key it doesn't know voids the whole list and
    // Phorge keeps the line as code, so the token spells the keys out and
    // matches all-or-nothing.
    //
    // That's also what keeps it from stealing ordinary code lines: it and
    // `_code_line` below both match "lang=php" and the tie goes to the
    // rule declared FIRST, while on "lang=php, foo=1" `_code_line` matches
    // the longer span and wins outright. Declaration order matters here --
    // moving this below `_code_line` silently turns every option line into
    // content. (Lexical `prec` would be wrong: tree-sitter consults it
    // before length, so a tier-1 `_option_line` would take "lang=php" out
    // of "lang=php, foo=1" and leave ", foo=1" stranded.)
    //
    // The fence line stays permissive by contrast: whatever trails ``` is
    // an info_string, even the option lists Phorge rejects and keeps as
    // code. Telling those apart up there would put this token, a list of
    // known language words and a rest-of-line token in one lexer state,
    // all three ordered against each other -- and the fence line is the
    // one place the mistake costs nothing worse than a highlighted word
    // that injects nothing.
    _option_line: $ => {
      const key = /lang|name|lines|counterexample/i;
      const value = /"[^"\n]*"|'[^'\n]*'|[^,="'\n]+/;
      const option = seq(key, optional(seq(/[ \t]*=[ \t]*/, value)));
      return token(seq(
        /[ \t]*/,
        sepBy1(/[ \t]*,[ \t]*/, option),
        /[ \t]*/,
      ));
    },
    // A content line is any line NOT ending in ``` : either it ends in a
    // non-backtick (with up to two trailing backticks allowed), or it is
    // nothing but one or two backticks. Blank lines are the bare-'\n'
    // case of the optional().
    _code_line: $ => seq(
      optional(token(choice(/[^\n]*[^`\n]`{0,2}/, /`{1,2}/))),
      '\n',
    ),
    // The closer: a standalone "```" stays a plain anonymous token (so
    // highlight queries can keep capturing the string "```"; at equal
    // length the string literal beats the regex). A "content```" line
    // matches the regex alternative instead and is folded into the code
    // content, delimiter included -- Phorge keeps the prefix as content.
    _fence_close: $ => choice(
      '```',
      alias(token(/[^\n]*```/), $.code_content),
    ),

    // Two or more spaces/tabs of indentation (Phorge: `^(\s{2,}).+`).
    indented_code_block: $ => prec.right(repeat1(
      seq(token(/[ \t][ \t]/), /[^\n]*/, '\n'),
    )),

    // ---------------------------------------------------------------
    // Literal blocks: %%% ... %%%   (not processed by remarkup)
    // ---------------------------------------------------------------
    // PhutilRemarkupLiteralBlockRule is line-oriented the same way the
    // code rule is: `%%%` opens (content may follow on the same line),
    // and the first line ENDING in `%%%` closes -- so `%%%quack%%%` is a
    // one-line literal. Same token scheme as the fenced block above:
    // content lines are lines not ending in %%%, a standalone closing
    // "%%%" lexes as the string literal (delimiter), and a "content%%%"
    // line (including the whole one-line form's remainder) is folded
    // into literal_content, trailing delimiter included.
    literal_block: $ => seq(
      '%%%',
      choice(
        // Same-line close: "%%%content%%%" (or "%%%%%%" for empty).
        seq(alias($._literal_close_merged, $.literal_content), '\n'),
        seq(
          optional(alias($._literal_line, $.literal_content)),
          '\n',
          repeat(seq(optional(alias($._literal_line, $.literal_content)), '\n')),
          choice('%%%', alias($._literal_close_merged, $.literal_content)),
          '\n',
        ),
      ),
    ),
    _literal_line: $ => token(choice(/[^\n]*[^%\n]%{0,2}/, /%{1,2}/)),
    _literal_close_merged: $ => token(/[^\n]*%%%/),

    // ---------------------------------------------------------------
    // Blockquotes: lines beginning with >
    // ---------------------------------------------------------------
    blockquote: $ => prec.right(repeat1(
      seq('>', optional(alias($._line_text, $.text)), '\n'),
    )),

    // ---------------------------------------------------------------
    // Callouts: NOTE:, WARNING:, IMPORTANT: (also parenthesized forms)
    // ---------------------------------------------------------------
    // PhutilRemarkupNoteBlockRule consumes every following non-blank
    // line, so callouts continue until a blank line -- except that lines
    // opening some other block (a list item, a quote, ...) break off
    // here, because their higher-precedence marker tokens win the line
    // start; Phorge would swallow those too, but rendering them as what
    // they look like is kinder to the reader.
    callout: $ => prec.right(seq(
      field('type', token(prec(PREC.BLOCK_MARKER, choice(
        'NOTE:', 'WARNING:', 'IMPORTANT:',
        '(NOTE)', '(WARNING)', '(IMPORTANT)',
      )))),
      optional(alias($._line_text, $.text)),
      '\n',
      repeat(seq(alias($._line_text, $.text), '\n')),
    )),

    // ---------------------------------------------------------------
    // Lists (flat representation; the `marker` field carries nesting
    // depth via marker-repetition or leading spaces so downstream
    // tooling can reconstruct a tree)
    // ---------------------------------------------------------------
    list: $ => prec.right(repeat1($.list_item)),

    list_item: $ => seq(
      field('marker', alias($._indented_marker, $.marker)),
      optional(field('checkbox', $.checkbox)),
      optional(field('content', alias($._line_text, $.text))),
      '\n',
    ),

    // One atomic token covering Phorge's whole
    // `^\s*(?:[-*#]+|[1-9][0-9]*[.)]|\[\D?\])\s+` start-of-item pattern:
    //
    //   - Leading spaces are folded in (rather than a separate,
    //     possibly-zero-width `indent` rule) because standalone tokens
    //     that can match the empty string produce degenerate lexer
    //     states in tree-sitter and were corrupting lexing for every
    //     other rule that shared its parser state.
    //   - The mandatory trailing whitespace is folded in too, which is
    //     what Phorge requires ("-foo" is prose, not a list) and what
    //     lets bare dash/star runs fall through to the divider/underline
    //     and bold rules instead of half-matching as a marker.
    //   - `\[\D?\]` -- a checkbox with no other marker ("[ ] milk") is
    //     itself a valid list marker in Phorge.
    _indented_marker: $ => token(prec(PREC.BLOCK_MARKER, seq(
      / */,
      choice(
        /-+/,
        /\*+/,
        /#+/,
        /\d+[.)]/,
        seq('[', optional(/[^0-9\]\n]/), ']'),
      ),
      /[ \t]/,
    ))),

    // "[]", "[ ]", "[x]", "[*]" -- any single non-digit, or nothing
    // (Phorge: `\[(\D?)\]\s*`; digits stay footnotes like "[1]"). One
    // atomic token including the trailing space, so "- [x](url)" can
    // still become a markdown link: with separate bracket tokens the
    // lexer would have to commit before seeing whether "] " or "](
    // follows.
    checkbox: $ => token(seq('[', optional(/[^0-9\]\n]/), ']', /[ \t]/)),

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
      sepBy1('|', field('cell', alias(repeat1($._inline_elt), $.table_cell))),
      optional('|'),
      '\n',
    ),

    // Cell content is the ordinary inline element set: Phorge's real table
    // rule (PhutilRemarkupSimpleTableBlockRule) runs the ordinary inline
    // rule pipeline over each cell, so `{T123}`, `**bold**`, `@mentions`,
    // etc. all work inside a table exactly as they do in a paragraph. A
    // bare `|` still ends the cell rather than being absorbed as text:
    // the multi-char text alternative excludes `|` outright, and for the
    // single-char fallback the `|` cell-separator literal wins the lexer
    // tie on explicit precedence (0 vs FALLBACK_TEXT). Reusing
    // `_inline_elt` (rather than a parallel cell-specific element list)
    // also keeps the cell parse states shared with the paragraph ones,
    // which is what lets the stray-delimiter GLR forks resolve inside
    // cells exactly as they do in prose.
    //
    // Phorge quirk we don't replicate: its cell splitter runs on the raw
    // line *before* inline rules, so a `|` nested inside `**bold**` in a
    // real table would split the cell there too.

    // Cells of 2+ dashes mark the row above as a header
    // (`/^--+\z/` per cell in the block rule).
    table_delimiter_row: $ => seq(
      '|',
      sepBy1('|', /[ \t]*--+[ \t]*/),
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

    // Delimiters that can also stand alone as plain prose when unpaired;
    // reuses the exact same string literals as the paired rules below, so
    // no competing lexer token is created -- the choice is the parser's,
    // via GLR + the dynamic precedences.
    _stray_delimiter: $ => choice(
      '**', '//', '~~', '__', '!!', '##', '`', '[[', '(', ')',
    ),

    bold: $ => prec.dynamic(1, seq('**', repeat1($._inline_no_bold), '**')),
    _inline_no_bold: $ => inlineChoice($, 'bold'),

    // PhutilRemarkupItalicRule: `(?<!:)//(.+?)//`. The lookbehind's job
    // (don't let a URL's slashes open italics) is done by `bare_url`
    // outranking `text` and by `text`'s `:/+` bonding, see above.
    italic: $ => prec.dynamic(1, seq('//', repeat1($._inline_no_italic), '//')),
    _inline_no_italic: $ => inlineChoice($, 'italic'),

    // Atomic tokens, unlike the other paired constructs: their content is
    // opaque (no nested inline rules, matching Phorge's priority-100
    // monospace rule running before everything else), and keeping the
    // delimiters and content in one token means an *unpaired* '`' or '##'
    // simply never lexes as monospace -- it falls through to
    // `_stray_delimiter` as plain text. With a separate content token the
    // lexer would always commit to the monospace interpretation (explicit
    // token precedence beats the text fallback) and error out at the
    // missing closer.
    monospace: $ => token(seq('`', /[^`\n]+/, '`')),
    monospace_alt: $ => token(seq('##', /[^#\n]+/, '##')),

    strikethrough: $ => prec.dynamic(1, seq('~~', repeat1($._inline_no_strike), '~~')),
    _inline_no_strike: $ => inlineChoice($, 'strikethrough'),

    underline: $ => prec.dynamic(1, seq('__', repeat1($._inline_no_underline), '__')),
    _inline_no_underline: $ => inlineChoice($, 'underline'),

    highlighted: $ => prec.dynamic(1, seq('!!', repeat1($._inline_no_highlight), '!!')),
    _inline_no_highlight: $ => inlineChoice($, 'highlighted'),

    // [[wiki page]]  /  [[wiki page | name]]
    wiki_link: $ => prec.dynamic(1, seq(
      '[[',
      field('target', alias(/[^|\]\n]+/, $.link_target)),
      optional(seq('|', field('label', alias(/[^\]\n]+/, $.link_label)))),
      ']]',
    )),

    // [name](http://xyz/)
    //
    // PhutilRemarkupDocumentLinkRule's markupAlternateLink refuses
    // targets that contain neither "/" nor "@" and aren't tel: -- that's
    // what keeps "x[0][1](y)" in a C discussion from linking -- so the
    // target token requires the same. The label must be non-empty
    // ("[](y)" stays prose). When either constraint fails, the
    // `_bracket_span` fallback picks up the pieces as plain text.
    md_link: $ => prec.dynamic(1, seq(
      '[', field('label', alias($._bracket_text, $.link_label)), ']',
      '(', field('target', alias($._md_link_target, $.link_target)), ')',
    )),
    _bracket_text: $ => /[^\]\n]+/,
    _md_link_target: $ => token(choice(
      /[^)\n]*[/@][^)\n]*/,
      /tel:[^)\n]+/,
    )),

    // "[just brackets]" -- shares its interior token with md_link's
    // label, so the parser (not the lexer) decides between them when it
    // sees whether "(" follows; GLR + md_link's dynamic precedence make
    // the real link win whenever its target parses.
    _bracket_span: $ => seq('[', optional(alias($._bracket_text, $.text)), ']'),

    // <ssh://example.com/,>  -- forces the parser to consume the whole URI
    //
    // Protocol is any word of 3-32 chars, not just http(s) --
    // PhutilRemarkupHyperlinkRule's own bare/angle/curly patterns all use
    // `\w{3,32}://`, so `ssh://`, `git://`, `ftp://`, etc. are equally
    // valid URLs in real remarkup. This also matters structurally: without
    // it, a non-http(s) URL like `ssh://host/path` wouldn't be lexed as
    // one token, so its embedded '//' would instead be free to pair up
    // with any later '//' on the line and get misparsed as italic.
    angle_url: $ => seq('<', field('url', alias(/\w{3,32}:\/\/[^>\n]+/, $.url)), '>'),

    // The final character may not be sentence punctuation: Phorge's
    // "ungreedy" bare matcher strips trailing `[;,.:!?]+` so "go to
    // https://example.com/!" doesn't link the bang.
    bare_url: $ => field('url', alias(
      /\w{3,32}:\/\/[^\s<>\[\]()*]*[^\s<>\[\]()*;,.:!?]/, $.url)),

    // @username
    //
    // Not recognized when glued directly onto a preceding word (see
    // `text`'s bonding) -- PhabricatorMentionRemarkupRule requires a real
    // boundary before the marker, so "mail@lists" doesn't trigger.
    //
    // The '@' is merged atomically with the mandatory username content,
    // same technique as `_embed_open` below and for the same root cause: a
    // bare '@' literal token is always preferred by the lexer over
    // `text`'s regex at that position (explicit precedence and literal
    // status both outrank the fallback), so for doubled/invalid markers
    // like "@@joe", `mention` has to not offer a token there at all,
    // rather than shift the first '@' and then fail on the second one.
    //
    // Trailing '.' excluded from the final character (though periods are
    // fine mid-word) so "Hey, @joe." captures the username as "joe", not
    // "joe." -- matching PhabricatorMentionRemarkupRule's own reasoning
    // ("We forbid terminal periods so that we can correctly capture '@joe'
    // instead of '@joe.'").
    mention: $ => field('name', alias($._mention_word, $.username)),
    _mention_word: $ => token(seq('@', /[A-Za-z0-9_.-]*[A-Za-z0-9_-]/)),

    // #project (hashtag, not a header -- disambiguated by the header
    // marker being `=` and the list marker requiring trailing space).
    //
    // ProjectRemarkupRule's getObjectIDPattern is a *negative* charset: a
    // hashtag is any run of chars other than whitespace and
    // `?!,:;{}#()"'*/~`, not ending (either edge) in `.` -- so "#c++"
    // and "#v1.0" are all real hashtags. Same atomic-merge and word-
    // boundary bonding treatment as `mention` above.
    project_tag: $ => field('name', alias($._project_tag_word, $.project_name)),
    _project_tag_word: $ => token(seq(
      '#',
      /[^.\s?!,:;{}#()"'*/~]/,
      optional(seq(/[^\s?!,:;{}#()"'*/~]*/, /[^.\s?!,:;{}#()"'*/~]/)),
    )),

    // T123, D123#comment-4, rXYZ123, rXYZ:af3192cd5, R12:1000, ...
    //
    // One prefix letter per application that registers an object rule
    // (Maniphest T, Differential D, Files F, Pholio M, Paste P, Countdown
    // C, Calendar E, Conpherence Z, Dashboard W, Harbormaster B, Herald H,
    // Legalpad L, Owners O, Passphrase K, Phame J, Phurl U, Ponder Q,
    // Slowvote V, Diffusion R/r...), each followed by an id (`[1-9]\d*` --
    // no leading zero) and an optional `#anchor` (`[-\w]+`, e.g. T123#42
    // or T123#comment-9). Commits allow a numeric id or a >=5-char hex
    // hash after `rCALLSIGN`/`rCALLSIGN:`/`R123:`.
    //
    // Kept as a single atomic token (rather than separate type/id
    // terminals) so the lexer only ever proposes `object_reference` when a
    // real prefix is *immediately* followed by a valid id. Splitting this
    // into two terminals let the lexer commit to "this looks like an
    // object ref" for any bare word and then fail once no digit followed,
    // which broke plain-prose parsing entirely.
    object_reference: $ => token(prec(PREC.OBJECT_REF, seq(
      choice(
        seq(/[BCDEFHJKLMOPQTUVWZ]/, /[1-9]\d*/),
        seq('R', /[1-9]\d*/, optional(seq(':', choice(/[1-9]\d*/, /[a-f0-9]{5,40}/)))),
        seq('r', /[A-Z]+/, optional(':'), choice(/[1-9]\d*/, /[a-f0-9]{5,40}/)),
      ),
      optional(seq('#', /[A-Za-z0-9_-]+/)),
    ))),

    // {D123}, {F123, layout=left, alt="a duckling"}, {icon camera color=blue},
    // {key command option shift 3}, {nav ...}, {meme, ...}, {anchor #xyz}
    // The opening '{' is merged atomically with the mandatory first kind
    // character into one token (same fix as object_reference above): if
    // '{' were a separate literal token, the lexer would always shift it
    // to start an embed, then error-recover once `embed_kind` can't match
    // (e.g. `{}`, `{ x}`, `{9x}`) -- and that recovery skips forward
    // hunting for the next word that *does* look like a kind, swallowing
    // unrelated prose later on the line as bogus kind/options text. Tying
    // them into one token means the lexer never proposes `embed` at all
    // unless '{' is immediately followed by a real identifier, so `{`
    // alone falls through to plain `text` instead. The opening brace is
    // consequently part of `embed_kind`'s span rather than a separately
    // captured node (contrast the closing '}', which stays literal) --
    // see the highlights query for how that's handled.
    embed: $ => seq(
      field('kind', alias($._embed_open, $.embed_kind)),
      optional(field('options', alias(/[^}\n]*/, $.embed_options))),
      '}',
    ),
    _embed_open: $ => token(seq('{', /[A-Za-z][A-Za-z0-9]*/)),

    // {#f00} / {#ff0000} color chips (PhutilRemarkupHexColorCodeRule).
    hex_color: $ => token(seq(
      '{#', /[0-9a-fA-F]{3}/, optional(/[0-9a-fA-F]{3}/), '}',
    )),

    // See the long comment on textToken() at the top of this file.
    // A "T123abc"-shaped word needs its own higher-than-OBJECT_REF guard
    // alternative: Phorge's reference pattern ends in `(?!\w)`, and since
    // explicit lexer precedence beats match length, the plain fallback
    // (FALLBACK_TEXT) could never outbid the objref token no matter how
    // much more it matches.
    text: $ => choice(
      textToken('[^ \\t\\n]'),
      token(prec(PREC.OBJECT_REF_GUARD, /[BCDEFHJKLMOPQRTUVWZ][1-9]\d*[A-Za-z_]\w*/)),
    ),
  },
});
