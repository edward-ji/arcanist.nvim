;; queries/injections.scm
;;
;; Enables language injection for `lang=xxx` fenced code blocks, e.g.:
;;
;;   ```lang=html, name=example.html, lines=12
;;   <a href="#">...</a>
;;   ```
;;
;; Unlike Markdown (where the bare word right after the fence IS the
;; language, e.g. ```html), Remarkup embeds it inside a comma-separated
;; option list after `lang=`. Neovim's injection query engine can't run
;; that extraction with core predicates (#match?/#eq? only test, they
;; don't transform captured text) -- it needs nvim-treesitter's `#gsub!`
;; directive to pull the language name out and feed it to
;; `injection.language`.

(fenced_code_block
  info: (info_string) @_info
  content: (code_content) @injection.content
  (#match? @_info "lang=")
  (#gsub! @_info "^.*lang=([%w_+-]+).*$" "%1")
  (#set! injection.language @_info))

;; Plain, un-annotated code fences without lang=xxx get no injection --
;; there's nothing to inject, and this is intentional so they're left as
;; opaque literal content.
