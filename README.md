# cljbang-org

Org mode as Clojure data for [cljbang.el][cljbang].

This library lets you query and edit org files with a more Clojure-friendly API. It optionally integrates with [org-ql][org-ql] and [org-transclusion][org-transclusion].

[cljbang]: https://github.com/kpassapk/cljbang.el
[org-ql]: https://github.com/alphapapa/org-ql
[org-transclusion]: https://github.com/nobiot/org-transclusion

## Why?

[Org][org-syntax] is an excellent, widely-used, information-dense format. If
you want to parse org files or make small edits from scripts (construct
agendas, flip `TODO` states), you have a few options:

1. Use regular expressions and freeform text edits. This gets complicated quickly, and
   can produce invalid syntax.

2. Embed tree-sitter. Robust, and independent of Emacs; but takes some
   experience. Not sure about editing.

3. Use elisp: `org` and `org-ql` together provide an extensive API. They use
   regular expressions internally, but at least you don't see them.

This library takes the third approach, and provides a functional interface
over the elisp API. This makes it easier to write Clojure over plain data extracted 
from org buffers. Oh, and side-effectful functions always end in `!` for good measure.

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

Suppose we want to get a list of the files being tangled under "Quadlets", [transclusions](https://github.com/nobiot/org-transclusion) included, in raw elisp:

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

Not the easiest API :)

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

This relies on an [org-ql](https://github.com/alphapapa/org-ql) query to select the "Quadlets" heading at level 1. Although org-ql provides the most powerful query interface, and we recommend using it, it's not a hard dependency. Neither is org-transclusion. 

Go ahead and check out the full [API](./doc/api.md), noticing how it's split between `org-ql` and plain `org` counterparts many most operations.

## Notes

- Queries return flat read-only maps.

- Every effect function (the `!` names) takes a selector and searches for its
  heading fresh, so stale positions cannot corrupt an edit.

- Effects modify the visiting buffer only. `save!` persists to disk; `revert!` discards buffer edits.

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
