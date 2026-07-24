# cljbang-org

Org files as Clojure data, for [cljbang.el][cljbang]. Query headings, source
blocks and keywords with Clojure's sequence functions; edit with a small set of
explicit effect functions. Integrates [org-ql][org-ql] for queries and
[org-transclusion][org-transclusion] for included content.

[cljbang]: https://github.com/kpassapk/cljbang.el
[org-ql]: https://github.com/alphapapa/org-ql
[org-transclusion]: https://github.com/nobiot/org-transclusion

## Why?

[Org][org-syntax] is an excellent, widely-used, information-dense format. If
you want to parse org files or make small edits from scripts (construct
agendas, flip TODO states, collect source code blocks), there are a few
options:

1. Regular expressions and freeform text edits. Gets complicated quickly, and
   can produce invalid syntax.

2. Embed tree-sitter. Robust, and independent of Emacs, but takes some
   experience — and editing support is unclear.

3. Use elisp: `org` and `org-ql` together provide an extensive API. They use
   regular expressions internally, but at least you don't see them.

This library takes the third approach and puts a functional face on it: you
write Clojure — threading macros, `map`, `filter` — over plain data extracted
from org buffers. Side-effectful functions always end in `!`.

[org-syntax]: https://orgmode.org/worg/org-syntax.html

## Example

Say `server.org` tangles some quadlet files, and pulls one more in from
another file via transclusion:

```org
* Quadlets

** caddy.container

#+begin_src systemd :tangle ~/.config/containers/systemd/caddy.container
[Container]
Image=caddy
#+end_src

#+transclude: [[file:common.org::*Qux][Qux]]  ; provides qux.container
```

Listing every tangle target under "Quadlets", transclusions included, in raw
elisp — not the easiest API :)

```elisp
(let ((targets
       (apply #'append
              (org-ql-select (find-file-noselect "server.org")
                '(and (heading "Quadlets") (level 1))
                :action (lambda ()
                          (save-restriction
                            (org-narrow-to-subtree)
                            (org-transclusion-add-all)
                            (let (acc)
                              (org-babel-map-src-blocks nil
                                (let ((tangle (cdr (assq :tangle
                                                         (nth 2 (org-babel-get-src-block-info 'light))))))
                                  (unless (member tangle '(nil "no"))
                                    (push tangle acc))))
                              (nreverse acc))))))))
  (message "%s" (string-join (delete-dups targets) "\n")))
```

The same query with cljbang-org:

```clj
(require '[clojure.string :as str]
         '[cljbang.org :as org]
         '[cljbang.org.ql :as ql])

(->> (ql/src-blocks "server.org"
                    '(and (heading "Quadlets") (level 1))
                    {:expand-transclusions? true})
     org/tangle-targets
     (str/join "\n")
     println)
```

## Design

**Queries return snapshots, not handles.** Headings, source blocks and file
keywords arrive as flat read-only maps, extracted at point with org's cheap
APIs — never the raw org-element AST. The `:begin` and `:end` positions in
those maps are provenance, not handles: they tell you where a thing was found,
and nothing trusts them afterwards.

**Effects re-locate from scratch.** Every effect function (the `!` names)
takes a *selector* and searches for its heading fresh, so stale positions
cannot corrupt an edit. Effects modify the visiting buffer only; `save!` is
the separate, explicit step that touches disk, and `revert!` discards buffer
edits.

**Transclusion expansion is scoped.** Passing `{:expand-transclusions? true}`
to a query expands transclusions for the duration of that query, removes them
again, and leaves the buffer as found — modified flag included. Effects refuse
to run while an expansion is active, because positions in expanded text do not
belong to the file.

**The package is the namespace.** cljbang resolves a qualified name like
`cljbang.org/headings` to the munged elisp symbol `cljbang-org-headings`, so
`cljbang-org.el` *is* the `cljbang.org` namespace — there is nothing else to
register. Likewise `cljbang-org-ql.el` is `cljbang.org.ql`.

## API

### Queries — `cljbang.org`

| Function | Returns |
|---|---|
| `(headings file & [opts])` | every heading in the file, as a vector of heading maps |
| `(heading file selector)` | first heading matching the selector, or nil |
| `(keywords file)` | file keywords (`#+KEY: value` lines) as a map of lowercase keyword to vector of values, so repeated keywords like `#+TARGET:` all arrive |
| `(properties file selector)` | drawer properties of the first matching heading |
| `(entry-get file selector prop)` | one property of the first matching heading; `prop` is a string or keyword |
| `(src-blocks file & [opts])` | source blocks as a vector of block maps; `{:under selector}` restricts to a subtree |
| `(tangle-targets blocks)` | pure: distinct `:tangle` targets of a collection of block maps, in file order, `"no"` and absent dropped |

Query opts also accept `{:expand-transclusions? true}` to scan transcluded
content.

A **heading map** has `:title :level :tags :todo :priority :properties :begin
:end :file`. A **block map** has `:language :name :headers :body :begin :end
:file`, where `:headers` is the resolved header-arg map with defaults
included — an untangled block carries `:tangle "no"`.

### Queries — `cljbang.org.ql`

| Function | Returns |
|---|---|
| `(select file query & [opts])` | headings matching an [org-ql][org-ql] query sexp, as heading maps |
| `(src-blocks file query & [opts])` | source blocks under each matching heading, one flat vector |

The query sexp goes to org-ql verbatim; the action is always this library's
extractor, so results are the same maps `cljbang.org` returns — no imperative
lambda at point.

### Selectors

Anywhere a `selector` is expected, pass:

- a title string — `"Quadlets"`
- `{:custom-id "quadlets"}` — matches on the `CUSTOM_ID` property
- `{:title "Quadlets" :level 1}` — `:level` optional
- a heading map returned by a query — its `CUSTOM_ID` wins, else title and level

### Effects — `cljbang.org`

| Function | Does |
|---|---|
| `(cut-subtree! file selector)` | cuts every matching subtree, re-locating before each cut; returns the count |
| `(save! file)` | saves the visiting buffer if modified |
| `(revert! file)` | reloads from disk, discarding buffer edits |
| `(tangle! file)` | tangles the file; returns the tangled file names |

## Installing

```elisp
(use-package cljbang-org
  :ensure t
  :vc (:url "https://github.com/kpassapk/cljbang-org"))
```

The org-ql bridge lives in the same repository as a second package; it needs
[org-ql][org-ql] installed:

```elisp
(use-package cljbang-org-ql
  :ensure t
  :vc (:url "https://github.com/kpassapk/cljbang-org"
       :main-file "cljbang-org-ql.el"))
```
