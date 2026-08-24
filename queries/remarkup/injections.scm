;; queries/injections.scm
;;
;; Enables language injection for code blocks that name their language, e.g.:
;;
;;   ```lang=html, name=example.html, lines=12
;;   <a href="#">...</a>
;;   ```
;;
;; Unlike Markdown (where the bare word right after the fence IS the
;; language, e.g. ```html), Remarkup usually embeds it inside a comma-
;; separated option list after `lang=`. Neovim's injection query engine
;; can't run that extraction with core predicates (#match?/#eq? only test,
;; they don't transform captured text) -- it needs the `#gsub!` directive,
;; which rewrites the capture's text in place; `@injection.language` is
;; then read back through that rewrite.
;;
;; PhutilSimpleOptions lowercases keys, so `LANG=php` is as valid as
;; `lang=php` -- hence the [lL][aA][nN][gG] spelling: these are Lua
;; patterns, which have no case-insensitive flag. Values keep their case
;; (Neovim lowercases them again when it resolves a parser name) and may be
;; quoted, which is the only way to get a comma into one.

;; lang=xxx: an explicit language beats every other clue, as in Phorge.
(fenced_code_block
  info: (info_string) @injection.language
  content: (code_content) @injection.content
  (#lua-match? @injection.language "[lL][aA][nN][gG]%s*=")
  (#gsub! @injection.language "^.*[lL][aA][nN][gG]%s*=%s*[\"']?([%w_+-]+).*$" "%1"))

;; name=xxx with no lang=: Phorge highlights these by the filename's
;; extension (guessFilenameExtension), and @injection.filename is that same
;; guess by a better route -- Neovim runs the text through
;; vim.filetype.match, which also knows extensionless names and extensions
;; that don't spell their language out ("Makefile", ".m").
;;
;; Deliberately a pattern of its own rather than a second capture on the one
;; above: LanguageTree walks a match's captures in unspecified order, so an
;; @injection.language that resolves to nothing could land last and wipe out
;; the answer the filename already produced.
(fenced_code_block
  info: (info_string) @injection.filename
  content: (code_content) @injection.content
  (#lua-match? @injection.filename "[nN][aA][mM][eE]%s*=")
  (#not-lua-match? @injection.filename "[lL][aA][nN][gG]%s*=")
  (#gsub! @injection.filename "^.*[nN][aA][mM][eE]%s*=%s*[\"']?([^,\"']+).*$" "%1")
  (#gsub! @injection.filename "%s+$" ""))

;; Phorge also accepts a bare "flavored markdown" language word right after
;; the fence (```php ... ```) -- but only a word on this list, which is
;; PhutilRemarkupCodeBlockRule::knownLanguageCodes(), a hand-picked subset
;; of Pygments' lexers. Anything else there is not a language tag at all:
;; Phorge renders it as the block's first line of code, so injecting on it
;; would be guessing at text the author never meant as one.
;;
;; Some of these have no Neovim parser (delphi, vba, ...); those inject
;; nothing, which is what Phorge does too when Pygments is off.
(fenced_code_block
  info: (info_string) @injection.language
  content: (code_content) @injection.content
  (#any-of? @injection.language
    "arduino" "assembly" "awk" "bash" "bat" "c"
    "cmake" "cobol" "cpp" "css" "csharp" "dart"
    "delphi" "fortran" "go" "groovy" "haskell" "java"
    "javascript" "kotlin" "lisp" "lua" "matlab" "make"
    "perl" "php" "powershell" "python" "r" "ruby"
    "rust" "scala" "sh" "sql" "typescript" "vba"))
