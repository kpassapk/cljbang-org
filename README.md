# cljbang-org

Org mode as Clojure data for [cljbang.el][cljbang].

This library lets you query and edit org files with a more clojure-friendly API. It optionally integrates with [org-ql][org-ql] and [org-transclusion][org-transclusion].

[cljbang]: https://github.com/kpassapk/cljbang.el
[org-ql]: https://github.com/alphapapa/org-ql
[org-transclusion]: https://github.com/nobiot/org-transclusion

## Why?

[Org][org-syntax] is an excellent, widely-used, information-dense format. If
you want to parse org files or make small edits from scripts (construct
agendas, flip `TODO` states), you have a few options:

1. Use regular expressions and freeform text edits. This gets complicated quickly, and
   can produce invalid syntax.

2. Embed tree-sitter. Robust, and independent of Emacs, but takes some
   experience. Not sure about editing.

3. Use elisp: `org` and `org-ql` together provide an extensive API. They use
   regular expressions internally, but at least you don't see them.

This library takes the third approach, and provides a functional interface
over the elisp API. This makes it easier to write Clojure — threading macros, `map`, `filter` 
— over plain data extracted from org buffers. Side-effectful functions always end in `!`.

[org-syntax]: https://orgmode.org/worg/org-syntax.html

## Example

Say `server.org` tangles some files, and pulls one more in from
another file via transclusion:

```org
* Quadlets

#+begin_src systemd :tangle foo.container
[Unit]
...
#+end_src

#+transclude: [[file:common.org::*Bar][Bar]]  ; provides bar.container
```

Suppose we want to get a list of the files being tangled under "Quadlets", transclusions included, in raw
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

If you tried to use `cljbang` directly, things would not get much better. There is just too much mutation going on. 
The result would look almost the same as the original elisp, but with some `el/` and `el!` thrown in.

`cljbang.org.ql` provides a `src-blocks` function that returns data structures, which makes this query easier to express:

```clj
  (require '[cljbang.org.ql :as ql])

  (->> (ql/src-blocks "servers/aly-2602-suite.org"
                      '(and (heading "Quadlets") (level 1))
                      {:expand-transclusions? true})
       (keep (comp :tangle :headers))
       (remove #{"no"})
       (map vector))
```

## API

### Queries — `cljbang.org`

| Function | Returns |
|---|---|
| `(headings file & [opts])` | every heading in the file, as a vector of heading maps |
| `(keywords file)` | file keywords (`#+KEY: value` lines) as a map of lowercase keyword to vector of values, so repeated keywords like `#+TARGET:` all arrive |
| `(src-blocks file & [opts])` | source blocks as a vector of block maps; `{:under selector}` restricts to every matching subtree |

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

Every map returned by `ql/select`  is a selector.

```clj
(->> (ql/select f '(and (todo "DONE") (tags "archive")))
     (map #(org/cut-subtree! f %))
     doall)
(org/save! f)
```

Selectors will not grow `:tags`, `:todo` or regexp matching. To find headings,
`filter` over `(org/headings f)` or write an org-ql query.

### Effects — `cljbang.org`

| Function | Does |
|---|---|
| `(cut-subtree! file selector)` | cuts every matching subtree, re-locating before each cut; returns the count |
| `(save! file)` | saves the visiting buffer if modified |
| `(revert! file)` | reloads from disk, discarding buffer edits |
| `(tangle! file)` | tangles the file; returns the tangled file names |

## Notes

- Queries return flat read-only maps.

- Every effect function (the `!` names) takes a selector and searches for its
  heading fresh, so stale positions cannot corrupt an edit.

- Effects modify the visiting buffer only. use `save!` is the separate, explicit
  step that touches disk; `revert!` discards buffer edits.

- Passing `{:expand-transclusions? true}` to a query expands transclusions for 
  the duration of that query, removes them again, and leaves the buffer as found. 
  Effects refuse to run while an expansion is active, because positions in expanded 
  text do not belong to the file.

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
