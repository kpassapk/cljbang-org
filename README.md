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

See the [API Documentation][api] for more.

[api]: ./doc/api.md

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
  (message "%s" (string-join (delete-dups targets) "\n")))
```

Not the easiest API :) (Granted, this is a contrived example to show just how bad it can get.)

If you tried to use [cljbang][cljbang] directly, things would not get much better. There is just too much mutation going on. 
The result would look almost the same as the original elisp, but with some `el/` and `el!` thrown in.

`cljbang.org.ql` provides a `src-blocks` function that returns data structures, which makes this query easier to express:

```clojure
  (->> (ql/src-blocks "file.org"
                      '(and (heading "Quadlets") (level 1))
                      {:expand-transclusions? true})
       (keep (comp :tangle :headers))
       (remove #{"no"})
       (map vector))
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

To mitigate this weirdness, at least partially, each effectful function takes a selector, and runs it right before performing an edit. Here's a special little snippet you might run when you've finished all of today's tasks.

```clojure
(->> (ql/select f '(and (todo "TODO") (deadline :to today)))
     (map #(org/set-todo! f % "DONE")) ;; <- re-run here
     doall)
```

Congratulations!

## Shaping results

Org is not very picky about data shapes. In org-babel, a list of names
reaches a block as text, as a vector of strings, or as a table — a vector of
one-element rows — depending on how the block that produced it was run. Worse,
a `:var` naming another block re-runs that block with `:results none`, which
overrides the block's own `:results`; so a shell block that displays as text is
handed over as a table. The visible `#+RESULTS:` does not tell you what the var
will actually hold.

Instead of branching on shape, use `lines`:

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

See the [API Documentation][api] for more.

## Installing

```elisp
(use-package cljbang-org
  :ensure t
  :vc (:url "https://github.com/kpassapk/cljbang-org"))
```


```elisp
(use-package cljbang-org-ql
  :ensure t
  :vc (:url "https://github.com/kpassapk/cljbang-org"
       :main-file "cljbang-org-ql.el"))
```

The latter needs [org-ql][org-ql] installed.

## Target audience and goals

This project is meant for the Clojure user who also uses emacs and org mode, and could merge those two worlds just a little bit better.

It may also work for people who work extensively with org mode, and who are Clojure-curious.

If you are an elisp expert, and routinely script org mode to your liking, this is probably not for you.

Goals:

- Be maximalist about org mode. We have emacs. It's not about a "subset" of org.
  - Includes org-babel, exports, etc
  - Treat transclusion and 
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
- file keywords (`#+TITLE:`, `#+TARGET:`), if they earn their place — via
  org-element, not a regex, so `#+name:` on a block stays the block's
- generate API docs from comment blocks to avoid drift
- :under re-parse whole buffer per match (not performant for large files)
- if user is hand-editing a file and changes accumulate, what will happen? any way to guard against that?
