;; queries/remarkup/highlights.scm
;;
;; Maps remarkup's grammar.js node types onto the standard Neovim
;; treesitter highlight groups (see `:h treesitter-highlight-groups`), so
;; any colorscheme with @markup.* support "just works" without remarkup-
;; specific theme config.
;;
;; Query patterns are matched top-to-bottom, later matches take priority
;; over earlier ones for overlapping ranges -- so whole-node captures are
;; listed first, and more specific/nested captures (delimiters, fields)
;; are listed after so they win inside that range.

;; ---------------------------------------------------------------------
;; Headers
;; ---------------------------------------------------------------------
;; `marker`/`underline` are anonymous tokens (bare regexes, not aliased to
;; a named node), and tree-sitter's `_` wildcard only matches *named*
;; nodes, so they can't be captured individually here -- the whole header
;; (marker text included) gets @markup.heading instead.
(atx_header) @markup.heading
(setext_header) @markup.heading

;; ---------------------------------------------------------------------
;; Dividers / thematic breaks
;; ---------------------------------------------------------------------
(divider) @punctuation.special

;; ---------------------------------------------------------------------
;; Code & literal blocks
;; ---------------------------------------------------------------------
(fenced_code_block "```" @punctuation.delimiter)
(fenced_code_block info: (info_string) @label)
;; Captured by node type, not via the `content:` field: a closing line with
;; content before the fence ("quack();```") and the one-line ```form``` are
;; also code_content nodes, but sit outside the field.
(fenced_code_block (code_content) @markup.raw.block)

(indented_code_block) @markup.raw.block

(literal_block "%%%" @punctuation.delimiter)
(literal_block (literal_content) @markup.raw.block)

;; ---------------------------------------------------------------------
;; Blockquotes & callouts
;; ---------------------------------------------------------------------
(blockquote) @markup.quote
(blockquote ">" @punctuation.special)

;; `type` (NOTE:/WARNING:/etc) is wrapped in a single token(choice(...))
;; in grammar.js, which collapses all its alternatives into one opaque
;; terminal with no queryable node type of its own (and node-types.json
;; doesn't even list it as a field) -- so it can't be captured separately
;; from the rest of the callout here. Whole-node @markup.quote it is.
(callout) @markup.quote

;; ---------------------------------------------------------------------
;; Lists
;; ---------------------------------------------------------------------
(list_item marker: (marker) @markup.list)

;; Default a checkbox to "unchecked", then override to "checked" when it
;; holds any non-space mark ([x], [X], [*], ... -- Phorge checks the mark
;; is non-whitespace, nothing more) -- #match? / #set! can't branch, so
;; the more-specific checked pattern simply comes second and wins.
(checkbox) @markup.list.unchecked
((checkbox) @markup.list.checked
  (#match? @markup.list.checked "\\[[^ ]\\]"))

;; ---------------------------------------------------------------------
;; Tables
;; ---------------------------------------------------------------------
(table_row "|" @punctuation.special)
(table_delimiter_row) @punctuation.special

;; ---------------------------------------------------------------------
;; Embeds: {D123}, {icon camera}, {nav ...}, standalone {meme ...} etc.
;; ---------------------------------------------------------------------
;; The opening '{' is lexed as part of `embed_kind` itself (see grammar.js
;; for why -- it's what keeps `{}` from being misparsed as an embed whose
;; kind/options run away into unrelated prose later on the line), so
;; there's no standalone '{' node to capture separately here; only the
;; closing '}' remains an anonymous token.
(embed "}" @punctuation.bracket)
(embed kind: (embed_kind) @function.macro)
(embed options: (embed_options) @string)

;; ---------------------------------------------------------------------
;; Inline emphasis
;; ---------------------------------------------------------------------
(bold) @markup.strong
(bold "**" @punctuation.delimiter)

(italic) @markup.italic
(italic "//" @punctuation.delimiter)

;; Atomic tokens (delimiters included in the node, see grammar.js), so
;; there are no inner backtick/hash nodes to capture separately.
(monospace) @markup.raw
(monospace_alt) @markup.raw

(strikethrough) @markup.strikethrough
(strikethrough "~~" @punctuation.delimiter)

(underline) @markup.underline
(underline "__" @punctuation.delimiter)

;; No stock capture group matches Phorge's "!!highlighted!!" (a <mark>-like
;; background highlight); @markup.strong is the closest visual stand-in.
(highlighted) @markup.strong
(highlighted "!!" @punctuation.delimiter)

;; ---------------------------------------------------------------------
;; Links & references
;; ---------------------------------------------------------------------
(wiki_link) @markup.link
(wiki_link "[[" @punctuation.bracket)
(wiki_link "]]" @punctuation.bracket)
(wiki_link target: (link_target) @markup.link.url)
(wiki_link label: (link_label) @markup.link.label)

(md_link) @markup.link
(md_link "[" @punctuation.bracket)
(md_link "]" @punctuation.bracket)
(md_link "(" @punctuation.bracket)
(md_link ")" @punctuation.bracket)
(md_link label: (link_label) @markup.link.label)
(md_link target: (link_target) @markup.link.url)

(angle_url) @markup.link.url
(angle_url "<" @punctuation.bracket)
(angle_url ">" @punctuation.bracket)

(bare_url) @markup.link.url

(mention) @markup.link
(project_tag) @markup.link

;; D123, T123, rXaf3192cd5, ... -- cross-references to other Phorge objects.
(object_reference) @markup.link

;; {#f00} / {#ff0000} color chips.
(hex_color) @constant

;; ---------------------------------------------------------------------
;; Spell checking
;; ---------------------------------------------------------------------
;; With treesitter highlighting on, Neovim only spell-checks text under an
;; @spell capture -- without this `:set spell` does nothing here. Headers,
;; list items, quotes and callouts alias their whole content line to one
;; `text` node, so @spell is broad and the non-prose nodes opt back out
;; with @nospell (which outranks an enclosing @spell).
(text) @spell
(link_label) @spell

(monospace) @nospell
(monospace_alt) @nospell
(bare_url) @nospell
(angle_url) @nospell
(link_target) @nospell
(mention) @nospell
(project_tag) @nospell
(object_reference) @nospell
(embed) @nospell
(hex_color) @nospell
