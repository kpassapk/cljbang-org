# API

Queries return flat read-only maps. (Alas, they are not immutable data structures, which are not part of the design of cljbang.

Every effect function (the `!` names) takes a selector and searches for its heading fresh, so stale positions cannot corrupt an edit.

Effects modify the visiting buffer only. `save!` persists to disk; `revert!` discards buffer edits.

Passing `{:expand-transclusions? true}` to a query expands transclusions for the duration of that query, removes them again, and leaves the buffer as found.  Effects refuse to run while an expansion is active, because positions in expanded  text do not belong to the file.

## Selectors

Anywhere a `selector` is expected, pass:

- a title string — `"Quadlets"`
- `{:custom-id "quadlets"}`
- `{:title "Quadlets" :level 1}` — `:level` optional
- a heading map returned by a `ql/select`

Example:

```clj
(require '[cljbang.org.ql :as ql])

(->> (ql/select f '(and (todo "DONE") (tags "archive")))
     (map #(org/refile! f % {:file "archive.org"}))
     doall)
(org/save! f)
(org/save! "archive.org")
```

## Queries — `cljbang.org`

| Function | Returns |
|---|---|
| `(headings file & [opts])` | every heading in the file, as a vector of heading maps |
| `(keywords file)` | file keywords (`#+KEY: value` lines) as a map of lowercase keyword to vector of values |
| `(src-blocks file & [opts])` | source blocks as a vector of block maps; `{:under selector}` restricts to every matching subtree |
| `(call-blocks file & [opts])` | the `#+call:` lines as a vector of call maps; takes the same opts |
| `(tables file & [opts])` | org tables as a vector of table maps; takes the same opts |

Query opts also accept `{:expand-transclusions? true}` to scan transcluded
content.

**headings** 

Available keys:  `:title :level :tags :todo :priority :scheduled :deadline
:properties :begin :end :file`

With `{:body? true}`, `:body`  contains the heading's own text, with the planning line, drawer and
anything belonging to a subheading left out.

Example looking for level 2 headings:

```clojure
(filter #(<= (:level %) 2) (org/headings f))
```

**src-blocks** (`#+BEGIN_SRC` .. `#END_SRC`)

Available keys: `:type :language :name :headers :body :index :begin :end
:file`

`:headers` is the resolved header-arg map with defaults
included 

**call-blocks**

Keys: `:type :name :call :arguments :value :index :begin :end :file`

`:call` names the block being invoked, `:arguments` is the text inside its parens, and `:value` is the
call verbatim.

`src-blocks` and `call-blocks` share an `:index` which counts src blocks and call lines 
together in file order

Example:

```clojure
(sort-by :index (concat (org/src-blocks f) (org/call-blocks f)))
```

`:index` counts blocks in the *file*, not in the result, so it still names the
block under `{:under ...}`.

**tables** 

`:name :rows :caption :formulas :begin :end :file`.

`:rows` is every row in file order — a vector of trimmed cell strings, with
`:hline` for each horizontal rule — so it is lossless and the shaping functions
below can take their input straight from it. `:formulas` holds the `#+TBLFM:` lines
verbatim. Pipes inside a src or example block are text, not a table, and
`table.el` tables are skipped.

## Queries — `cljbang.org.ql`

| Function | Returns |
|---|---|
| `(select file query & [opts])` | headings matching an [org-ql][org-ql] query sexp, as heading maps |
| `(src-blocks file query & [opts])` | source blocks under each matching heading, one flat vector |
| `(call-blocks file query & [opts])` | `#+call:` lines under each matching heading, one flat vector |
| `(tables file query & [opts])` | org tables under each matching heading, one flat vector |

The query sexp goes to org-ql verbatim; the action is always this library's
extractor, so results are the same maps `cljbang.org` returns — no imperative
lambda at point. `src-blocks` and `tables` are `cljbang.org`'s `{:under
selector}` with a search where the selector would be: one heading you already
mean becomes every heading matching a query, and the shaping functions apply
unchanged.

## Effects — `cljbang.org`

Every effect that takes a selector edits **each** matching heading and returns
how many it touched. `0` = no match.

### Fields of a heading

| Function | Does |
|---|---|
| `(set-todo! file selector state)` | sets the TODO keyword; `nil` clears it |
| `(schedule! file selector time)` | sets `SCHEDULED`; `nil` removes it |
| `(deadline! file selector time)` | sets `DEADLINE`; `nil` removes it |
| `(set-priority! file selector priority)` | sets the priority cookie; `nil` removes it |
| `(set-tags! file selector tags)` | replaces the tags; `nil` removes them all |
| `(set-property! file selector key value)` | sets a drawer property; `nil` removes it |

These go through org's own command for each field — `org-todo`, `org-schedule`,
`org-set-tags` — rather than rewriting the headline. That is the reason they
exist: marking a repeating task `DONE` rolls its `SCHEDULED` stamp forward,
writes `LAST_REPEAT` and puts the state back to `TODO`; a `DONE` gets its
`CLOSED` stamp; a state change reaches the logbook. A regexp over the headline
gets none of that right, and every caller gets it wrong differently.

```clj
(->> (ql/select f '(and (todo "TODO") (deadline :to today)))
     (map #(org/set-todo! f % "DONE"))
     doall)
(org/save! f)
```

A TODO keyword the file does not declare is an error. Logging that would open a
note buffer and wait for prose is written as a timestamp instead — nothing is
going to type it.

`time` is anything `org-schedule` reads: `"<2026-09-10 Thu>"`, `"2026-09-10"`,
one with a time of day, or a delta `"+2d"` from the stamp already there. A
repeater in the new stamp is kept; without one the old stamp's repeater carries
over, so re-scheduling a weekly task leaves it weekly.

`priority` is `"A"`, `:A`, `?A`, or an integer where the file's priorities are
numeric. Removing a cookie that is not there is not an error, though
`org-priority` makes it one: a script setting a field to `nil` is saying what it
wants the heading to look like, not asserting what it looks like now.

Property keys are upcased, the shape queries return them in, so `:owner` and
`:OWNER` name one property.

Tags **replace**, they do not merge, and there is no `add-tags!` to go with
`set-tags!`: `:tags` is a set, so adding and removing one is `conj` and `disj`
before the call, where Clojure can see it.

```clj
(let [h (first (ql/select f '(heading "Deploy")))]
  (org/set-tags! f h (conj (:tags h) "urgent")))
```

### Structure

| Function | Does |
|---|---|
| `(insert-heading! file heading & [opts])` | writes a new heading; returns how many were inserted |
| `(refile! file selector target)` | moves every matching subtree to `target` |

`insert-heading!` takes a map shaped like the ones queries return. Only `:title`
is required; `:level :todo :priority :tags :scheduled :deadline :properties` and
`:body` are used when present, each through org's own command for it, so what
lands is what org would have written. `{:under selector}` appends it as the last
child of every matching heading, one level below the parent unless `:level` says
otherwise; without it the heading goes at the end of the file at its `:level`, or
at level 1.

```clj
(org/insert-heading! f {:title "Renew passport" :todo "TODO"
                        :deadline "<2026-10-01 Thu>" :tags #{"admin"}
                        :body "Book the appointment."}
                     {:under "Inbox"})
```

`:CATEGORY` is skipped: org computes it, so a heading map carries one whether the
file wrote one or not, and a queried heading re-inserted elsewhere should not
grow a drawer entry the file never had.

`refile!` is how a subtree leaves where it is, and the only way: **there is no
delete**. Archiving a heading is a refile to the file it belongs in, which is
what org means by archiving anyway, and no effect here can silently lose text.
`target` is a map: `{:file "archive.org"}` is the file it lands in, this one by default;
`{:under selector}` is the heading it becomes the last child of — the first
match, since a subtree lands in one place — and the end of that file by default;
`{:level n}` overrides the level it is re-levelled to. A target
inside the subtree being moved is an error rather than a corrupted file.

```clj
(doseq [h (ql/select f '(and (todo "DONE") (tags "archive")))]
  (org/refile! f h {:file "archive.org" :under "2026"}))
(org/save! f)
(org/save! "archive.org")
```

Both files are left modified and neither is saved; `save!` takes one file, so a
cross-file move needs it on each.

### The file

| Function | Does |
|---|---|
| `(execute! file & [selector])` | runs one src block or `#+call:` line; returns its result |
| `(save! file)` | saves the visiting buffer if modified |
| `(revert! file)` | reloads from disk, discarding buffer edits |
| `(tangle! file)` | tangles the file; returns the tangled file names |

## Shaping results

| Function | Returns |
|---|---|
| `(tree headings)` | those headings nested by `:level`, as a vector of the roots |
| `(lines x)` | `x` as a vector of non-blank, trimmed lines, whatever shape it arrived in |
| `(rows x)` | the data rows of a table, horizontal rules dropped |
| `(table->maps x)` | the data rows as maps keyed by column name |

`tree` copies each heading and adds a `:children` vector, so the input is
untouched and a leaf's `:children` is empty rather than missing. Every heading
map has a `:level`, so it nests whatever produced them — the whole outline, a
filtered one, or an org-ql result:

```clojure
(org/tree (org/headings "box.org"))
(org/tree (ql/select "box.org" '(todo "TODO")))
```

The same list of names reaches a block as text, as a vector of strings, or as a
table — a vector of one-element rows — depending on how the block that produced
it was run, and Org does not say which. A `:var` naming another block **re-runs**
that block with `:results none`, which overrides the block's own `:results`, so
a shell block that displays as text is handed over as a table. The visible
`#+RESULTS:` does not tell you what the var will hold.

```clojure
(org/lines "a\nb")        ;=> ["a" "b"]
(org/lines ["a" "b"])     ;=> ["a" "b"]
(org/lines [["a"] ["b"]]) ;=> ["a" "b"]
```

`rows` and `table->maps` do the same job for tables. Both take a table map, its
`:rows`, or the list a `:var` naming a table hands over — org writes a rule as
`hline` there and `:hline` here, and neither caller should have to know which.

```clojure
(->> (org/tables "hosts.org")
     (filter #(= "hosts" (:name %)))
     first
     org/table->maps
     (map :ip))
```

`table->maps` takes the row above the first rule as the header, or the first row
when the table has none — org's own `:colnames` rule. Column names become
keywords, downcased with runs of non-alphanumerics collapsed to one dash, so
`Host Name` keys `:host-name`; an empty header cell keys `:col-N` by position.


## Running blocks

`execute!` takes a block name, a map with `:name` or `:index`, or nothing at all
when the file holds exactly one runnable block. A block map or call map from a
query is a selector too — its `:name` wins, else its `:index`.

```clojure
(org/execute! f)                    ; the only block
(org/execute! f "deploy")           ; the block named deploy
(org/execute! f {:index 2})         ; the third runnable block
(->> (org/src-blocks f) (filter #(= "sh" (:language %))) first (org/execute! f))
```

Selecting by `:index` rather than by position is the point. A block that writes
its results back moves every position after it, so running a file's blocks in
turn would invalidate the `:begin` of every block still to run — the indices do
not move.

Results land in the buffer, and `save!` is the separate step that writes them to
disk; `revert!` throws them away. A block that exits non-zero raises, carrying
the exit code and what it wrote to stderr — org-babel would otherwise pop up a
buffer, hand back the partial output, and let the caller think it worked. Output
on stderr with a zero exit is not a failure and does not raise.

