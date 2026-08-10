![Status](https://img.shields.io/badge/status-alpha-blue)

# cljbang-org

Org mode as Clojure data for [cljbang.el][cljbang].

This library lets you query and edit org files with a more Clojure-friendly API. It optionally integrates with [org-ql][org-ql] and [org-transclusion][org-transclusion].

[cljbang]: https://github.com/borkdude/cljbang.el
[org-ql]: https://github.com/alphapapa/org-ql
[org-transclusion]: https://github.com/nobiot/org-transclusion

## Why?

[Org][org-syntax] is an excellent, widely-used, information-dense format. If
you want to parse org files or make small edits from scripts (modify deadlines, flip `TODO` states), you have a few options:

1. Use regular expressions and freeform text edits. This gets complicated quickly, and
   can produce invalid syntax.

2. Embed tree-sitter. Robust, and independent of Emacs; but takes some
   experience. Not sure about editing.

3. Use elisp: `org` and `org-ql` together provide an extensive API. They use
   regular expressions internally, but at least you don't see them.

This library takes the third approach, and provides a functional interface
over the elisp API. This makes it easier to write scripts over plain data extracted 
from org buffers. It also provides effectful functions, which always end in `!` for good measure.

[org-syntax]: https://orgmode.org/worg/org-syntax.html

## The API

Snippets in the following sections use these namespaces:

```
(require '[cljbang.org :as org])
(require '[cljbang.org.ql :as ql])
```

You can run this code in emacs using the `clj!` macro, or put it in a `.clj` file and use `cljbang-load-file`.

See the [API Documentation][api] for more, on [the site][site] or in the
repository. It is generated from the docstrings by `make doc`, so it says what
the code says.

[api]: ./doc/API.md
[site]: https://kpassapk.github.io/cljbang-org/

## Querying org data

Say `server.org` tangles some files, and pulls one more in from another file via [transclusion][org-transclusion]:

```org
* Quadlets

#+begin_src systemd :tangle foo.container
[Unit]
...
#+end_src

#+transclude: [[file:common.org::*Bar][Bar]]  ; provides bar.container
```

To get a list of the files being tangled under "Quadlets", transclusions included, in elisp:

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
  (delete-dups targets))
```

Not the friendliest API :) (Granted, this is a contrived example to show just how bad it can get.)

If you tried to use [cljbang][cljbang] directly, things would not get much better. There is just too much mutation going on. 
The result would look almost the same as the original elisp, but with some `el/` and `el!` thrown in.

`cljbang.org.ql` provides a `src-blocks` function that returns data structures, which makes this query easier to express:

```clojure
(->> (ql/src-blocks "file.org"
                    '(and (heading "Quadlets") (level 1))
                    {:expand-transclusions? true})
     (keep (comp :tangle :headers))
     (remove #{"no"}))
```

Nicer, right?

This relies on an [org-ql][org-ql] query to select the "Quadlets" heading at level 1. Then it transforms the resulting (Clojure) map. If we wanted to operate on headings, instead of the source blocks which are under them, we would pass the org-ql query to `ql/select` instead:

```clojure
(->> (ql/select "server.org"
                '(and (heading "Quadlets") (level 1)))
     (keep #(get-in % [:properties :CUSTOM_ID]))
     first)
```

A lot of org operations on schedules, deadlines, TODOs etc. operate at the heading level. If you don't use org-ql, there is a simpler `org/headings` version:

```clojure
(->> (org/headings "server.org")
	 (filter #(= (:level %) 1))
     (keep #(get-in % [:properties :CUSTOM_ID]))
     first)
```

[org-ql]: https://github.com/alphapapa/org-ql

The basic pattern is to start with some sort of selector, possibly obtained by an org-ql query, then do stuff.

## Selectors and effects

Effects are more tricky than queries, since they modify the underlying emacs buffer and make other things move around. Line-based editing is not super helpful when you can't see the buffer, like in a script.

To mitigate this weirdness, at least partially, each effectful function takes a selector and resolves it from scratch when it runs, so stale positions from an earlier query can't corrupt an edit. (Within one call the matches are found once
and held as markers, so edits that shift the buffer don't move the headings still to visit.)

```clojure
(->> (ql/select f '(and (todo "TODO") (deadline :to today)))
     (map #(org/set-todo! f % "DONE"))
     doall)
```

Congratulations for finishing your TODOs!

## File keywords

`keywords` reads the `#+TITLE:`-style lines as a map, and `set-keyword!` writes
them. Both go through org-element, so a `#+name:` or `#+caption:` line stays
the block's or the table's — it only looks like a file keyword.

```clojure
(:TITLE (org/keywords "server.org"))
;=> "Test server"

(org/lines (:TARGET (org/keywords "server.org")))
;=> [".. (project)" "/ssh:app@example: (server)"]

(org/set-keyword! "server.org" :TARGET "/ssh:web@example: (web)")
```

A keyword written more than once holds its values one per line, which is why
`lines` splits them; writing it back replaces every `#+TARGET:` line in the
file with what you pass.

## Shaping results

I have found these utility functions most useful when using [ob-cljbang][ob-cljbang]. They may be useful in other contexts too.

Org is not very picky about data shapes. In org-babel, a list of names
reaches a block as text, as a vector of strings, or as a table — a vector of
one-element rows — depending on how the block that produced it was run. 

Use `lines` to normalize:

```clojure
(org/lines "a\nb")        ;=> ["a" "b"]
(org/lines ["a" "b"])     ;=> ["a" "b"]
(org/lines [["a"] ["b"]]) ;=> ["a" "b"]
```

`rows` and `table->maps` do the same job for tables (with headings), outputting maps. 

```clojure
(->> (org/tables "hosts.org")
     (filter #(= "hosts" (:name %)))
     first
     org/table->maps
     (map :ip))
```

`tree` produces a nested data structure from a heading map.

```clojure
(org/tree (org/headings "box.org"))
(org/tree (ql/select "box.org" '(todo "TODO")))
```

[ob-cljbang]: https://github.com/kpassapk/ob-cljbang

See the [API Documentation][api] for more.

## Installing

This package works with Emacs 28.1 or later.

```elisp
(use-package cljbang
  :ensure t
  :vc (:url "https://github.com/borkdude/cljbang.el" :rev :newest))

(use-package cljbang-org
  :ensure t
  :vc (:url "https://github.com/kpassapk/cljbang-org" :rev :newest))
```

To use `cljbang-org-ql`,

```elisp
(use-package org-ql :ensure t)

(use-package cljbang-org-ql
  :after (cljbang-org org-ql))
```

## Target audience and goals

This project is meant for the Clojure user who also uses emacs and org mode, and could merge those two (three?) worlds just a little bit better.

It may also work for people who work extensively with org mode, and who are Clojure-curious.

If you are an elisp expert, and routinely script org mode to your liking, this is probably not for you.

**Goals**

- Be maximalist about org mode. We have emacs. It's not about a "subset" of org.
  - Includes org-babel, exports, etc
  - Treat transclusion and org-ql as an extended part of org
- The API should read like Clojure. (Even if it's less performant.)

## Roadmap

These two are probably important:

- timestamp parsing or conversion for deadlines and scheduled items
- Accept multiple files, just like org-ql.

The rest, in no particular order:
- Possibly accept a prebuilt `:agenda`?
- Add heading keys: :closed, :effort, 
- Support :id (right now only `:custom-id`)
- Org construction
- Add a navigator like `{:path ["Project" "Notes"]}` or `id` and separate cases where multiple matches are acceptable. 
- "current buffer" concept. pass nil or provide a different arity
- :under re-parse whole buffer per match (not performant for large files)
- if user is hand-editing a file and changes accumulate, what will happen? any way to guard against that?
  
