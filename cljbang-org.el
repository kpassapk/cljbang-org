;;; cljbang-org.el --- Functional org-mode access for cljbang -*- lexical-binding: t; -*-

;; Author: Kyle S Passarelli
;; URL: https://github.com/kpassapk/cljbang-org
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (cljbang "0.0.9"))
;; Keywords: outlines, languages

;;; Commentary:

;; The namespace cljbang.org for cljbang: org files as Clojure data.
;;
;; cljbang resolves a qualified name like cljbang.org/headings to the
;; munged elisp symbol cljbang-org-headings, so this package *is* the
;; namespace; there is nothing else to register.
;;
;;   (require '[cljbang.org :as org])
;;   (->> (org/headings "servers/box.org")
;;        (filter #(contains? (:tags %) "project"))
;;        (map :title))
;;
;; Queries return read-only snapshots: flat maps for headings, source
;; blocks, call lines, tables and the file's own keywords, extracted at
;; point with org's APIs or org-element AST.
;;
;; Effects edit the visiting buffer;
;; `cljbang-org-save!' is the separate, explicit step that touches disk.
;;
;; A selector names a heading you already mean; it is a reference, not
;; a search.  Selectors deliberately do not grow query features (no
;; :tags, no :todo, no regexps): filtering is Clojure's job over the
;; data `cljbang-org-headings' returns, or org-ql's job via
;; cljbang.org.ql.
;;
;; A setter reaches org through org's own command for the field --
;; org-todo, org-schedule, org-set-tags -- never through the headline
;; text, so a repeating task re-schedules itself and a state change
;; reaches the logbook.  Anything taking a selector edits every heading
;; that matches and answers how many; no match is 0, not an error.
;;
;; Transclusion expansion (:expand-transclusions? in query opts) is
;; scoped: expanded for the duration of the query, removed again, the
;; buffer left as found.  Effects refuse to run while it is active.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-table)
(require 'ob-core)
(require 'ob-lob)
(require 'ob-tangle)
(require 'seq)
(require 'subr-x)
(require 'cljbang-core)

;;; Buffer discipline

(defvar-local cljbang-org--transcluded nil
  "Non-nil while a query has transclusions expanded.
Effects check this and refuse to edit, because positions in expanded
text do not belong to the file.")

(defvar cljbang-org--index-of nil
  "Positions of the file's runnable blocks to their index, or nil.
Built on demand by `cljbang-org--index-at' and bound afresh below, so
one query numbers against one state of the buffer.")

(defun cljbang-org--buffer (file)
  "The buffer visiting FILE, opening it if need be."
  (let ((buf (find-file-noselect (expand-file-name file))))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode) (org-mode)))
    buf))

(defmacro cljbang-org--with-file (file &rest body)
  "Run BODY in the buffer visiting FILE, widened, preserving point."
  (declare (indent 1))
  `(with-current-buffer (cljbang-org--buffer ,file)
     (save-excursion
       (save-restriction
         (widen)
         (let ((cljbang-org--index-of nil))
           ,@body)))))

(defun cljbang-org--str (s)
  "S without its text properties, or nil."
  (and s (substring-no-properties s)))

(defun cljbang-org--opt (opts key)
  "Value of KEY in OPTS, a cljbang map or nil."
  (and opts (cljbang-get opts key)))

(defmacro cljbang-org--with-transclusions (expand &rest body)
  "Run BODY, with transclusions expanded in the current buffer when EXPAND.
Read-only from the file's point of view: the expansion is removed again
and the buffer's modified flag restored, whatever BODY does."
  (declare (indent 1))
  `(if (not ,expand)
       (progn ,@body)
     (unless (require 'org-transclusion nil t)
       (error "cljbang-org: :expand-transclusions? needs org-transclusion"))
     (let ((cljbang-org--was-modified (buffer-modified-p)))
       (setq cljbang-org--transcluded t)
       (unwind-protect
           (progn (org-transclusion-add-all)
                  ,@body)
         (org-transclusion-remove-all)
         (setq cljbang-org--transcluded nil)
         (set-buffer-modified-p cljbang-org--was-modified)))))

(defun cljbang-org--scan (file opts collect)
  "COLLECT over FILE, honoring the opts every element query shares.
COLLECT takes no arguments, runs in FILE's buffer over the accessible
portion, and returns a vector; results concatenate in file order.
OPTS: {:under selector} runs COLLECT narrowed to every matching subtree
instead of once over the file; {:expand-transclusions? true} expands
transclusions for the scan and removes them again."
  (cljbang-org--with-file file
    (let ((under (cljbang-org--opt opts :under))
          (expand (cljbang-org--opt opts :expand-transclusions?)))
      (if (not under)
          (cljbang-org--with-transclusions expand
            (funcall collect))
        (apply #'vconcat
               (mapcar (lambda (pos)
                         (goto-char pos)
                         (save-restriction
                           (org-narrow-to-subtree)
                           (cljbang-org--with-transclusions expand
                             (funcall collect))))
                       (cljbang-org--locate-all
                        (cljbang-org--selector-pred under))))))))

;;; Extraction at point

(defvar cljbang-org--include-body nil
  "Non-nil while a query asked for :body on its heading maps.
Bound by the query, read by `cljbang-org--heading-at-point', so
`cljbang-org-ql-select' gets the option for free.")

(defun cljbang-org--body-at-point ()
  "Text of the entry at point, or nil when it has none.
The heading's own prose: planning line, drawers and subheadings are
not part of it."
  (save-excursion
    ;; The entry ends at the next heading, measured from this one.  Measuring
    ;; it after `org-end-of-meta-data' would be a heading too late whenever
    ;; the entry is empty: skipping the meta data then lands on the next
    ;; heading, and this entry would claim that one's text as its own.
    (let ((end (save-excursion (outline-next-heading) (point))))
      (org-end-of-meta-data t)
      (let* ((beg (min (point) end))
             (body (string-trim (buffer-substring-no-properties beg end))))
        (unless (string-empty-p body) body)))))

(defun cljbang-org--properties-at-point ()
  "Drawer properties of the heading at point, as a map with keyword keys."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (kv (org-entry-properties nil 'standard) h)
      (puthash (intern (concat ":" (car kv))) (cdr kv) h))))

(defun cljbang-org--title-at-point ()
  (substring-no-properties (or (nth 4 (org-heading-components)) "")))

(defun cljbang-org--heading-at-point ()
  "Heading at point as a map: :title :level :tags :todo :priority
:scheduled :deadline :properties :begin :end :file.  :scheduled and
:deadline hold the timestamp as the file writes it, or nil.  :body is
there too when the query asked for it."
  (let* ((comps (org-heading-components))
         (priority (nth 3 comps))
         (heading
          (cljbang-hash-map
           :title (cljbang-org--title-at-point)
           :level (nth 0 comps)
           :todo (nth 2 comps)
           :priority (and priority (char-to-string priority))
           :tags (apply #'cljbang-hash-set
                        (mapcar #'substring-no-properties (org-get-tags nil t)))
           :scheduled (cljbang-org--str (org-entry-get nil "SCHEDULED"))
           :deadline (cljbang-org--str (org-entry-get nil "DEADLINE"))
           :properties (cljbang-org--properties-at-point)
           :begin (point)
           :end (save-excursion (org-end-of-subtree t t) (point))
           :file (buffer-file-name))))
    (when cljbang-org--include-body
      (puthash :body (cljbang-org--body-at-point) heading))
    heading))

;;; Selectors

;; How an effect names the heading it means.  Anywhere a selector is
;; expected, pass one of:
;;
;; - a title string, `"Quadlets"' -- the whole title, matched exactly
;; - {:custom-id "quadlets"}, the heading's CUSTOM_ID property
;; - {:title "Quadlets"}, the same as the string form
;; - {:title "Quadlets" :level 1}, that title at that level and no other
;; - a heading map a query returned: its CUSTOM_ID wins, else its title
;;   and level
;;
;; A selector is a reference to a heading you already mean, not a
;; search: there is no :tags, no :todo, no regexp, and there will not
;; be.  Selecting on what a heading *is* rather than what it is called
;; is a query, and a query is `cljbang-org-headings' filtered in
;; Clojure, or an org-ql sexp through cljbang.org.ql.

(defun cljbang-org--selector-pred (selector)
  "Predicate of no arguments, run with point at a heading, for SELECTOR.
SELECTOR is a title string, or a map with :custom-id, or :title and
optionally :level.  A heading map returned by a query works: its
CUSTOM_ID property wins, else its title and level.

A selector is a reference to a heading you already mean, not a query
language: it stays this small on purpose.  To search, filter the data
`cljbang-org-headings' returns, or use cljbang.org.ql."
  (cond
   ((stringp selector)
    (lambda () (equal selector (cljbang-org--title-at-point))))
   ((hash-table-p selector)
    (let* ((custom-id (or (cljbang-get selector :custom-id)
                          (let ((props (cljbang-get selector :properties)))
                            (and props (cljbang-get props :CUSTOM_ID)))))
           (title (cljbang-get selector :title))
           (level (cljbang-get selector :level)))
      (cond
       (custom-id
        (lambda () (equal custom-id (org-entry-get (point) "CUSTOM_ID"))))
       (title
        (lambda ()
          (and (equal title (cljbang-org--title-at-point))
               (or (null level)
                   (equal level (nth 0 (org-heading-components)))))))
       (t (error "cljbang-org: selector map needs :title or :custom-id")))))
   (t (error "cljbang-org: bad selector %S" selector))))

(defun cljbang-org--locate-first (pred)
  "Position of the first heading satisfying PRED, or nil."
  (let (found)
    (org-map-entries
     (lambda () (when (and (not found) (funcall pred))
                  (setq found (point)))))
    found))

(defun cljbang-org--locate-all (pred)
  "Positions of every heading satisfying PRED, in file order."
  (let (acc)
    (org-map-entries
     (lambda () (when (funcall pred) (push (point) acc))))
    (nreverse acc)))

;;; Queries

;; A query opens the file, reads it, and hands back flat read-only
;; maps: nothing it returns is a handle on the buffer, and nothing it
;; does changes the file.
;;
;; Every query takes {:expand-transclusions? true}, which needs
;; org-transclusion: the transclusions are expanded for the length of
;; that one query, the content they pull in is scanned as if it were
;; written in the file, and the expansion is removed again with the
;; buffer's modified flag as it was found.  Effects refuse to run while
;; an expansion is active, because positions in expanded text do not
;; belong to the file.

;;;###autoload
(defun cljbang-org-headings (file &optional opts)
  "All headings in FILE as a vector of heading maps.
A heading map holds :title :level :tags :todo :priority :scheduled
:deadline :properties :begin :end :file, and :body when asked for.
:scheduled and :deadline are the timestamp as the file writes it, or
nil; :tags is a set; :properties is keyed by the upcased property
name.

OPTS: {:body? true} adds each heading's own text as :body -- its own
prose, with the planning line, the drawers and anything belonging to a
subheading left out; {:expand-transclusions? true} to scan transcluded
content too.

There is no :max-level, and no other filter: the vector is the whole
outline, and narrowing it is Clojure's job.

  (filter #(<= (:level %) 2) (org/headings f))"
  (cljbang-org--with-file file
    (let ((cljbang-org--include-body (cljbang-org--opt opts :body?)))
      (cljbang-org--with-transclusions
          (cljbang-org--opt opts :expand-transclusions?)
        (let (acc)
          (org-map-entries
           (lambda () (push (cljbang-org--heading-at-point) acc)))
          (apply #'vector (nreverse acc)))))))

;;; Runnable blocks and the index

;; A src block and a `#+call:' line are both things
;; `cljbang-org-execute!' can run, so they share one numbering over the
;; whole file.  That number, not a position, is the handle: a block
;; that writes its results back moves every position after it, while
;; the indices stay put.

(defun cljbang-org--call-begin (el)
  "Position of the `#+call:' line of babel-call element EL.
Its :post-affiliated, which skips a leading `#+name:' -- the line
`cljbang-org-execute!' must run from."
  (or (org-element-property :post-affiliated el)
      (org-element-property :begin el)))

(defun cljbang-org--runnable-positions ()
  "Positions of every runnable block in the file, in document order.
A runnable block is a src block or a `#+call:' line.  Collected over the
widened buffer, so an index does not depend on what a query narrowed to."
  (save-excursion
    (save-restriction
      (widen)
      (let (srcs)
        (org-babel-map-src-blocks nil (push beg-block srcs))
        (sort (append srcs
                      (org-element-map (org-element-parse-buffer 'element)
                          'babel-call #'cljbang-org--call-begin))
              #'<)))))

(defun cljbang-org--index-at (pos)
  "Index of the runnable block beginning at POS, or nil."
  (unless cljbang-org--index-of
    (setq cljbang-org--index-of (make-hash-table :test #'eql))
    (let ((i 0))
      (dolist (p (cljbang-org--runnable-positions))
        (puthash p i cljbang-org--index-of)
        (setq i (1+ i)))))
  (gethash pos cljbang-org--index-of))

;;; Source blocks

(defun cljbang-org--block-at-point ()
  "Src block at point as a map: :type :language :name :headers :body
:index :begin :end :file.  :headers is the resolved header-arg map,
defaults included, so an untangled block carries :tangle \"no\"."
  (let* ((info (org-babel-get-src-block-info 'light))
         (headers (let ((h (make-hash-table :test #'equal)))
                    (dolist (kv (nth 2 info) h)
                      (puthash (car kv) (cdr kv) h)))))
    (cljbang-hash-map
     :type :src
     :language (nth 0 info)
     :name (nth 4 info)
     :headers headers
     :body (nth 1 info)
     :index (cljbang-org--index-at (point))
     :begin (point)
     :end (save-excursion
            (re-search-forward "^[ \t]*#\\+end_src" nil t)
            (line-end-position))
     :file (buffer-file-name))))

(defun cljbang-org--collect-blocks ()
  "Src blocks in the accessible portion, as a vector of block maps."
  (let (acc)
    (org-babel-map-src-blocks nil
      (goto-char beg-block)
      (push (cljbang-org--block-at-point) acc))
    (apply #'vector (nreverse acc))))

;;;###autoload
(defun cljbang-org-src-blocks (file &optional opts)
  "Src blocks in FILE as a vector of block maps.
A block map holds :type :language :name :headers :body :index :begin
:end :file.  :headers is the resolved header-arg map, defaults
included, so an untangled block carries :tangle \"no\".

OPTS: {:under selector} restricts to every matching subtree, in
document order; {:expand-transclusions? true} scans transcluded content
too.

An :index counts blocks in the document, not in the result, so it still
names the block under :under -- but not under
:expand-transclusions?, where most blocks are not this file's to run."
  (cljbang-org--scan file opts #'cljbang-org--collect-blocks))

;;; Call lines

(defun cljbang-org--call-block (el)
  "Babel-call element EL as a map: :type :name :call :arguments :value
:index :begin :end :file.  :call names the block being invoked and
:arguments the text inside its parens; :value is the call verbatim,
e.g. \"deploy(HOST=web1)\"."
  (let ((begin (cljbang-org--call-begin el)))
    (cljbang-hash-map
     :type :call
     :name (cljbang-org--str (org-element-property :name el))
     :call (cljbang-org--str (org-element-property :call el))
     :arguments (cljbang-org--str (org-element-property :arguments el))
     :value (cljbang-org--str (org-element-property :value el))
     :index (cljbang-org--index-at begin)
     :begin begin
     :end (save-excursion (goto-char begin) (line-end-position))
     :file (buffer-file-name))))

(defun cljbang-org--collect-calls ()
  "Call lines in the accessible portion, as a vector of call maps."
  (apply #'vector
         (org-element-map (org-element-parse-buffer 'element) 'babel-call
           #'cljbang-org--call-block)))

;;;###autoload
(defun cljbang-org-call-blocks (file &optional opts)
  "The `#+call:' lines in FILE as a vector of call maps.
A call map holds :type :name :call :arguments :value :index :begin :end
:file.  :call names the block being invoked and :arguments the text
inside its parens; :value is the call verbatim.

Takes the same opts `cljbang-org-src-blocks' does.

A call line invokes a block named elsewhere -- another heading, another
org file, the library of babel -- so `cljbang-org-src-blocks' does not
see it.  The two share one :index, and every runnable step in the
document is:

  (sort-by :index (concat (org/src-blocks f) (org/call-blocks f)))"
  (cljbang-org--scan file opts #'cljbang-org--collect-calls))

;;; Tables

(defun cljbang-org--caption (begin end)
  "The #+CAPTION: text among the affiliated keywords in BEGIN..END, or nil.
Read from the text rather than the element, whose :caption is a parsed
secondary string; a query returns what the file says."
  (and (> end begin)
       (save-excursion
         (goto-char begin)
         (when (re-search-forward
                "^[ \t]*#\\+caption:[ \t]*\\(.*?\\)[ \t]*$" end t)
           (match-string-no-properties 1)))))

(defun cljbang-org--table-at-point (el)
  "Table element EL as a map: :name :rows :caption :formulas :begin
:end :file.  :rows holds every row in file order, a vector of trimmed
cell strings, with :hline for each horizontal rule -- lossless, so
`cljbang-org-rows' and `cljbang-org-table->maps' can take the shape from
here.  :formulas holds the #+TBLFM: lines verbatim."
  (let ((begin (org-element-property :begin el))
        (post (org-element-property :post-affiliated el)))
    (cljbang-hash-map
     :name (org-element-property :name el)
     :rows (apply #'vector
                  (mapcar (lambda (row)
                            (if (cljbang-org--hline-p row) :hline
                              (cljbang-org--row row)))
                          (save-excursion
                            (goto-char post)
                            (org-table-to-lisp))))
     :caption (cljbang-org--caption begin post)
     :formulas (apply #'vector (org-element-property :tblfm el))
     :begin begin
     :end (save-excursion
            (goto-char (org-element-property :end el))
            (skip-chars-backward " \t\n")
            (point))
     :file (buffer-file-name))))

(defun cljbang-org--collect-tables ()
  "Org tables in the accessible portion, as a vector of table maps.
Every candidate line is checked against the element at point, so pipes
inside a src or example block are text, not a table.  table.el tables
are not org data and are skipped."
  (let (acc)
    (goto-char (point-min))
    (while (re-search-forward org-table-line-regexp nil t)
      (beginning-of-line)
      (let ((el (org-element-at-point)))
        (when (and (eq (org-element-type el) 'table)
                   (eq (org-element-property :type el) 'org))
          (push (cljbang-org--table-at-point el) acc))
        ;; past the whole element, table or not, so its remaining lines
        ;; are not re-examined; never backwards, so the scan terminates
        (goto-char (max (org-element-property :end el)
                        (line-beginning-position 2)))))
    (apply #'vector (nreverse acc))))

;;;###autoload
(defun cljbang-org-tables (file &optional opts)
  "Org tables in FILE as a vector of table maps.
A table map holds :name :rows :caption :formulas :begin :end :file.
:rows is every row in document order, a vector of trimmed cell strings,
with :hline for each horizontal rule -- lossless, so
`cljbang-org-rows' and `cljbang-org-table->maps' take their input
straight from it.  :formulas holds the `#+TBLFM:' lines verbatim.

Pipes inside a src or example block are text, not a table, and
`table.el' tables are skipped.

OPTS: {:under selector} restricts to every matching subtree, in
document order; {:expand-transclusions? true} scans transcluded content
too."
  (cljbang-org--scan file opts #'cljbang-org--collect-tables))

;;; File keywords

;; The `#+TITLE:' lines: org's in-buffer settings, and whatever else a
;; file has taken to writing at the top.  They are read through
;; org-element rather than a regexp over the `#+' lines, because
;; `#+name:' and `#+caption:' look exactly the same and are not
;; keywords at all: they are affiliated to the block or the table below
;; them and belong to it.  org-element knows the difference, and a
;; query already returns those as that block's :name and that table's
;; :caption.

(defun cljbang-org--collect-keywords ()
  "Keywords in the accessible portion as a map, keyed by upcased name.
A name written more than once holds its values in file order, one per
line: a keyword's value cannot contain a newline, so nothing is lost
and `cljbang-org-lines' splits them apart again."
  (let ((acc (make-hash-table :test #'equal)))
    (dolist (el (org-element-map (org-element-parse-buffer 'element)
                    'keyword #'identity))
      (let ((key (intern (concat ":" (org-element-property :key el))))
            (value (or (cljbang-org--str (org-element-property :value el)) "")))
        (puthash key
                 (let ((prev (gethash key acc)))
                   (if prev (concat prev "\n" value) value))
                 acc)))
    acc))

;;;###autoload
(defun cljbang-org-keywords (file &optional opts)
  "The `#+KEYWORD:' lines of FILE as a map, keyed by upcased name.

  (:TITLE (org/keywords \"server.org\"))  ;=> \"Test server\"

A keyword the file writes more than once holds every value, in file
order, one per line, which `cljbang-org-lines' splits apart:

  (org/lines (:TARGET (org/keywords \"server.org\")))
  ;=> [\".. (project)\" \"/ssh:app@example: (server)\"]

Only the file's own keywords are here.  A `#+name:' or `#+caption:'
line looks the same and is not one: it is affiliated to the block or
the table below it, and a query returns it there, as that block's :name
or that table's :caption.

The whole file is read, not only the lines above the first heading.
Org takes an in-buffer setting wherever it is written, so a `#+TITLE:'
inside a subtree still titles the file, and leaving it out here would
have the map say something the file does not.

OPTS: {:expand-transclusions? true} to read transcluded content too.

There is no :under: a keyword is the file's, not a subtree's."
  (cljbang-org--with-file file
    (cljbang-org--with-transclusions
        (cljbang-org--opt opts :expand-transclusions?)
      (cljbang-org--collect-keywords))))

;;; Effects

;; An effect edits the buffer visiting the file and stops there.
;; `cljbang-org-save!' is the separate step that writes the buffer to
;; disk, and `cljbang-org-revert!' is the one that throws the edits
;; away; nothing here saves on its own, so a script that goes wrong
;; halfway leaves the file on disk untouched.
;;
;; Every effect that takes a selector searches for its heading afresh
;; when it runs, so a position from an earlier query cannot corrupt an
;; edit, and edits *every* heading that matches, answering how many it
;; touched.  No match is 0, not an error.  Within one call the matches
;; are found once and held as markers, so an edit that shifts the
;; buffer does not move the headings still to visit.

(defun cljbang-org--check-editable ()
  (when cljbang-org--transcluded
    (error "cljbang-org: refusing to edit while transclusions are expanded")))

;;; Effects: fields of a heading

;; Every setter goes through org's own command for the field -- `org-todo',
;; `org-schedule', `org-set-tags', `org-priority', `org-entry-put' -- rather
;; than rewriting the headline itself.  That is the whole point of these
;; being here: marking a repeating task DONE re-schedules it and moves it
;; back to TODO, a DONE gets its CLOSED stamp, a state change reaches the
;; logbook, and tags land aligned.  A regexp over the headline gets none of
;; that right, and every caller would get it wrong differently.
;;
;; A setter takes the same selector the rest of the API does, so it edits
;; *every* matching heading and answers how many it touched; no match is 0,
;; not an error.

(defun cljbang-org--edit-selected (file selector fn)
  "Call FN with point on each heading in FILE matching SELECTOR; the count.
The headings are found once, before the first edit, and held as markers,
so an edit that lengthens the buffer does not move the ones still to
visit.  Re-locating from the top before each edit would not work: a
setter leaves its heading in place and still matching SELECTOR, so the
search would return the same one forever."
  (cljbang-org--with-file file
    (cljbang-org--check-editable)
    (let ((markers (mapcar #'copy-marker
                           (cljbang-org--locate-all
                            (cljbang-org--selector-pred selector)))))
      (unwind-protect
          (progn
            (dolist (m markers)
              (goto-char m)
              (funcall fn))
            (length markers))
        (dolist (m markers) (set-marker m nil))))))

(defun cljbang-org--field-name (x)
  "X, a keyword, symbol or string, as a plain string, or nil."
  (cond ((null x) nil)
        ((stringp x) x)
        ((symbolp x) (cljbang-name x))
        (t (format "%s" x))))

(defun cljbang-org--log-without-note (log)
  "LOG, one of org's logging settings, with note-taking made a timestamp.
A note opens a buffer and waits for prose.  Nothing is going to type it:
these run from a script, and org would leave the note pending on
`post-command-hook' for whoever touches the buffer next."
  (if (eq log 'note) 'time log))

(defun cljbang-org--todo-at-point (state)
  "Set the TODO state of the heading at point to STATE, or clear it."
  (let ((org-inhibit-logging 'note))
    (org-todo (or (cljbang-org--field-name state) 'none))))

(defun cljbang-org--plan-at-point (type time)
  "Set TYPE, `scheduled' or `deadline', of the heading at point to TIME.
A nil TIME removes the planning entry."
  (let ((org-log-reschedule (cljbang-org--log-without-note org-log-reschedule))
        (org-log-redeadline (cljbang-org--log-without-note org-log-redeadline))
        (set (if (eq type 'deadline) #'org-deadline #'org-schedule)))
    (if time
        (funcall set nil time)
      (funcall set '(4)))))

(defun cljbang-org--priority-value (priority)
  "PRIORITY as `org-priority' takes it, or nil to remove the cookie.
A string or keyword gives its first character upcased, so \"a\", \"A\"
and :A all name one cookie; an integer passes through, for a file whose
priorities are numeric."
  (cond ((null priority) nil)
        ((integerp priority) priority)
        (t (let ((s (cljbang-org--field-name priority)))
             (if (string-empty-p s)
                 (error "cljbang-org: empty priority")
               (upcase (aref s 0)))))))

(defun cljbang-org--priority-at-point (value)
  "Set the priority cookie of the heading at point to VALUE, or remove it.
Removing a cookie that is not there is not an error here, though
`org-priority' makes it one: a script setting a field to nil is saying
what it wants the heading to look like, not asserting what it looks like
now."
  (if value
      (org-priority value)
    (when (nth 3 (org-heading-components))
      (org-priority 'remove))))

(defun cljbang-org--property-name (key)
  "KEY as a property name: its name, upcased.
Org reads property names case-insensitively and `cljbang-org-headings'
returns them upcased, so :owner and :OWNER have to name one property or
what a query returns could not be written back."
  (upcase (or (cljbang-org--field-name key)
              (error "cljbang-org: a property needs a name"))))

(defun cljbang-org--property-at-point (name value)
  "Set property NAME on the heading at point to VALUE, or remove it."
  (if (null value)
      (org-entry-delete nil name)
    (org-entry-put nil name (if (stringp value) value (format "%s" value)))))

(defun cljbang-org--tag-list (tags)
  "TAGS as `org-set-tags' takes them: a list of strings, or nil, or a string.
A set -- the shape `cljbang-org-headings' returns under :tags -- has no
order of its own, so it sorts, and the same set always writes the same
line."
  (cond ((null tags) nil)
        ((stringp tags) tags)
        ((cljbang--set-p tags)
         (sort (mapcar #'cljbang-org--field-name
                       (hash-table-keys (cljbang--set-table tags)))
               #'string<))
        ((sequencep tags)
         (mapcar #'cljbang-org--field-name (append tags nil)))
        (t (error "cljbang-org: bad tags %S" tags))))

;;;###autoload
(defun cljbang-org-set-todo! (file selector state)
  "Set the TODO state of every heading in FILE matching SELECTOR; the count.
STATE is a keyword of the file's own, as a string -- \"DONE\" -- or nil
to leave the heading with no state at all.  A keyword the file does not
declare is an error, which is `org-todo' talking and worth keeping.

Marking a repeating task DONE does what org does: the SCHEDULED stamp
rolls forward, LAST_REPEAT goes in, and the state comes back to TODO.
Logging that would ask for a note is written as a timestamp instead.

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (cljbang-org--edit-selected file selector
                              (lambda () (cljbang-org--todo-at-point state))))

;;;###autoload
(defun cljbang-org-schedule! (file selector time)
  "Set SCHEDULED on every heading in FILE matching SELECTOR; the count.
TIME is anything `org-schedule' reads: a stamp \"<2026-09-10 Thu>\", a
date \"2026-09-10\", one with a time of day, or a delta \"+2d\" from the
stamp already there.  A repeater in TIME is kept; without one the old
stamp's repeater carries over, so re-scheduling a weekly task leaves it
weekly.  A nil TIME removes the SCHEDULED line.

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (cljbang-org--edit-selected
   file selector (lambda () (cljbang-org--plan-at-point 'scheduled time))))

;;;###autoload
(defun cljbang-org-deadline! (file selector time)
  "Set DEADLINE on every heading in FILE matching SELECTOR; the count.
TIME takes the same forms `cljbang-org-schedule!' describes, and nil
removes the DEADLINE line.

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (cljbang-org--edit-selected
   file selector (lambda () (cljbang-org--plan-at-point 'deadline time))))

;;;###autoload
(defun cljbang-org-set-property! (file selector key value)
  "Set property KEY to VALUE on every heading in FILE matching SELECTOR.
The count.  KEY is a keyword, symbol or string and is upcased, the shape
`cljbang-org-headings' returns properties in.  A nil VALUE removes the
property; anything else that is not a string is printed.

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (let ((name (cljbang-org--property-name key)))
    (cljbang-org--edit-selected
     file selector (lambda () (cljbang-org--property-at-point name value)))))

;;;###autoload
(defun cljbang-org-set-tags! (file selector tags)
  "Set the tags of every heading in FILE matching SELECTOR; the count.
TAGS is a set, a vector, a list, an org tag string, or nil for none.

Tags replace, they do not merge, and there is no `add-tags!' to go with
this: the :tags a query returns is a set, so adding and removing one is
`conj' and `disj' before the call, where Clojure can see it.

  (org/set-tags! f h (conj (:tags h) \"urgent\"))

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (cljbang-org--edit-selected
   file selector (lambda () (org-set-tags (cljbang-org--tag-list tags)))))

;;;###autoload
(defun cljbang-org-set-priority! (file selector priority)
  "Set the priority of every heading in FILE matching SELECTOR; the count.
PRIORITY is \"A\", :A, ?A or an integer where the file uses numeric
priorities; nil removes the cookie, and removing one that is not there
is not an error.

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (let ((value (cljbang-org--priority-value priority)))
    (cljbang-org--edit-selected
     file selector (lambda () (cljbang-org--priority-at-point value)))))

;;; Effects: structure

;; Writing a heading and moving one.  There is no delete: a subtree
;; leaves where it is by being refiled somewhere else, which is what
;; org means by archiving anyway, so no effect here can silently lose
;; text.

(defconst cljbang-org--computed-properties '("CATEGORY")
  "Property names org computes, which a heading map carries regardless.
Writing one back would put in the file something the file never said.")

(defun cljbang-org--fill-heading-at-point (heading)
  "Give the heading at point every field HEADING carries beyond its title.
Order is org's own: the state, the cookie and the tags rewrite the
headline, the planning line goes under it and the drawer under that.
Property names sort, so the drawer does not depend on hash order."
  (let ((todo (cljbang-get heading :todo))
        (priority (cljbang-get heading :priority))
        (tags (cljbang-get heading :tags))
        (scheduled (cljbang-get heading :scheduled))
        (deadline (cljbang-get heading :deadline))
        (properties (cljbang-get heading :properties)))
    (when todo (cljbang-org--todo-at-point todo))
    (when priority
      (cljbang-org--priority-at-point (cljbang-org--priority-value priority)))
    (when tags (org-set-tags (cljbang-org--tag-list tags)))
    (when scheduled (cljbang-org--plan-at-point 'scheduled scheduled))
    (when deadline (cljbang-org--plan-at-point 'deadline deadline))
    (when (hash-table-p properties)
      (dolist (key (sort (hash-table-keys properties)
                         (lambda (a b) (string< (format "%s" a) (format "%s" b)))))
        (let ((name (cljbang-org--property-name key)))
          (unless (member name cljbang-org--computed-properties)
            (cljbang-org--property-at-point name (cljbang-get properties key))))))))

(defun cljbang-org--blank-line-p ()
  "Whether the line point is on is blank."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \t]*$")))

(defun cljbang-org--insert-heading-at-point (heading level)
  "Insert HEADING at point as a heading of LEVEL, and fill in its fields.
Blank lines go in front and behind unless they are already there, so
what lands reads like the rest of the file rather than like generated
text stapled to its neighbours."
  (unless (bolp) (insert "\n"))
  (unless (or (bobp)
              (save-excursion (forward-line -1) (cljbang-org--blank-line-p)))
    (insert "\n"))
  (let ((beg (point))
        (body (cljbang-get heading :body)))
    (insert (make-string level ?*) " " (cljbang-get heading :title) "\n")
    (when (org-string-nw-p body)
      (insert (string-trim-right body) "\n"))
    (unless (or (eobp) (cljbang-org--blank-line-p))
      (save-excursion (insert "\n")))
    (goto-char beg)
    (cljbang-org--fill-heading-at-point heading)))

(defun cljbang-org--child-point (pos level)
  "Where a child of the heading at POS goes, and at what level.
A cons of the position and the level: the end of that heading's subtree,
one level below it unless LEVEL says otherwise."
  (save-excursion
    (goto-char pos)
    (let ((parent (nth 0 (org-heading-components))))
      (org-end-of-subtree t t)
      (cons (point) (or level (1+ parent))))))

;;;###autoload
(defun cljbang-org-insert-heading! (file heading &optional opts)
  "Insert HEADING into FILE; the number of headings inserted.
HEADING is a map shaped like the ones `cljbang-org-headings' returns.
Only :title is required; :level :todo :priority :tags :scheduled
:deadline :properties and :body are used when present, each through
org's own command for it, so what lands is what org would have written.

OPTS: {:under selector} appends it as the last child of *every* matching
heading, one level below the parent unless :level says otherwise;
without it the heading goes at the end of the file, at its :level or at
level 1.

:CATEGORY is not written: org computes it, so a heading map carries one
whether the file said so or not.

  (org/insert-heading! f {:title \"Ship it\" :todo \"TODO\"
                          :scheduled \"<2026-09-10 Thu>\"}
                       {:under \"Sprint 4\"})

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (cljbang-org--with-file file
    (cljbang-org--check-editable)
    (unless (org-string-nw-p (cljbang-get heading :title))
      (error "cljbang-org: a heading needs a :title"))
    (let ((level (cljbang-get heading :level))
          (under (cljbang-org--opt opts :under)))
      (if (not under)
          (progn
            (goto-char (point-max))
            (cljbang-org--insert-heading-at-point heading (or level 1))
            1)
        (let ((markers (mapcar #'copy-marker
                               (cljbang-org--locate-all
                                (cljbang-org--selector-pred under)))))
          (unwind-protect
              (progn
                (dolist (m markers)
                  (let ((where (cljbang-org--child-point (marker-position m) level)))
                    (goto-char (car where))
                    (cljbang-org--insert-heading-at-point heading (cdr where))))
                (length markers))
            (dolist (m markers) (set-marker m nil))))))))

(defun cljbang-org--refile-point (buffer under level)
  "Where a refiled subtree goes in BUFFER, and at what level.
A cons of a marker and the level.  UNDER selects the heading it becomes
the last child of; without it the subtree goes at the end of BUFFER.
A marker rather than a position because the caller finds this before it
cuts, and the cut can be in this very buffer."
  (with-current-buffer buffer
    (org-with-wide-buffer
     (let ((where
            (if (not under)
                (cons (point-max) (or level 1))
              (cljbang-org--child-point
               (or (cljbang-org--locate-first (cljbang-org--selector-pred under))
                   (error "cljbang-org: no heading matching %S in %s"
                          under (buffer-file-name)))
               level))))
       (cons (copy-marker (car where)) (cdr where))))))

;;;###autoload
(defun cljbang-org-refile! (file selector target)
  "Move every subtree in FILE matching SELECTOR to TARGET; the count moved.
TARGET is a map.  {:file \"archive.org\"} is the file it lands in, this
one by default; {:under selector} is the heading it becomes the last
child of -- the first match, since a subtree lands in one place -- and
the end of that file by default; {:level n} overrides the level it is
re-levelled to.

Moving is the only way a subtree leaves where it is: there is no
delete.  Archiving a heading is a refile to the file it belongs in,
which is what org means by archiving anyway, and nothing here can
silently lose text.

Both files are left modified and neither is saved.  `cljbang-org-save!'
takes one file, so a cross-file move needs it on each.

  (doseq [h (ql/select f \\='(and (todo \"DONE\") (tags \"archive\")))]
    (org/refile! f h {:file \"archive.org\" :under \"2026\"}))"
  (cljbang-org--with-file file
    (cljbang-org--check-editable)
    (let* ((source (current-buffer))
           (target-file (cljbang-org--opt target :file))
           (dest (if target-file (cljbang-org--buffer target-file) source))
           (under (cljbang-org--opt target :under))
           (level (cljbang-org--opt target :level))
           (markers (mapcar #'copy-marker
                            (cljbang-org--locate-all
                             (cljbang-org--selector-pred selector))))
           (count 0))
      (with-current-buffer dest (cljbang-org--check-editable))
      (unwind-protect
          (dolist (m markers count)
            (goto-char m)
            (org-back-to-heading t)
            (let* ((beg (point))
                   (end (save-excursion (org-end-of-subtree t t) (point)))
                   (text (buffer-substring-no-properties beg end))
                   ;; Found before the cut, and held as a marker across it:
                   ;; when source and target are one buffer, removing the
                   ;; subtree moves everything after it.
                   (where (cljbang-org--refile-point dest under level))
                   (at (car where)))
              (when (and (eq dest source)
                         (<= beg (marker-position at))
                         (< (marker-position at) end))
                (set-marker at nil)
                (error "cljbang-org: refile target is inside the subtree being moved"))
              (unwind-protect
                  (progn
                    (delete-region beg end)
                    (with-current-buffer dest
                      (org-with-wide-buffer
                       (goto-char at)
                       (unless (bolp) (insert "\n"))
                       (org-paste-subtree (cdr where) text)))
                    (setq count (1+ count)))
                (set-marker at nil))))
        (dolist (m markers) (set-marker m nil))))))

;;; Effects: file keywords

;; Writing a `#+KEYWORD:' line.  This is the one field org has no
;; command of its own for -- there is no `org-set-keyword' to go with
;; `org-todo' and `org-set-tags' -- so the line is written here, and
;; located through org-element for the same reason the query reads it
;; there: a `#+name:' belongs to the block below it, and a setter that
;; matched on text would overwrite one.

(defun cljbang-org--keyword-name (key)
  "KEY as the name of a file keyword: its name, upcased.
org-element upcases the keys it parses and `cljbang-org-keywords'
returns them that way, so :title and :TITLE have to name one keyword or
what a query returns could not be written back."
  (upcase (or (cljbang-org--field-name key)
              (error "cljbang-org: a keyword needs a name"))))

(defun cljbang-org--keyword-begins (name)
  "Beginning of every `#+NAME:' line in the buffer, in file order."
  (org-element-map (org-element-parse-buffer 'element) 'keyword
    (lambda (el)
      (and (equal name (org-element-property :key el))
           (org-element-property :begin el)))))

(defun cljbang-org--keyword-point ()
  "Where a keyword the file does not have yet goes.
After the run of keywords and comments the file opens with, which is
where the ones it does have are, and before whatever it says next."
  (let ((section (car (org-element-contents
                       (org-element-parse-buffer 'element))))
        (pos (point-min)))
    (when (eq (org-element-type section) 'section)
      (catch 'done
        (dolist (el (org-element-contents section))
          (unless (memq (org-element-type el) '(keyword comment))
            (throw 'done nil))
          ;; The element's own last line, not its :end, which has
          ;; already crossed the blank lines that follow it.
          (setq pos (save-excursion
                      (goto-char (org-element-property :end el))
                      (skip-chars-backward " \t\n")
                      (line-beginning-position 2))))))
    pos))

;;;###autoload
(defun cljbang-org-set-keyword! (file key value)
  "Set the `#+KEY:' lines of FILE to VALUE; the number of lines written.
KEY is a keyword, symbol or string and is upcased, the shape
`cljbang-org-keywords' returns.  VALUE is a string, a vector or a list
of them, or nil to remove the keyword; a value of several lines writes
one `#+KEY:' line each, so what a query joined goes back as it came.

The keyword replaces.  Every `#+KEY:' line in the file gives way to the
new ones, written where the first of them was; a keyword the file does
not have yet goes after the ones it opens with.  There is no
`add-keyword!' to go with this: adding a value is `conj' on what the
query returned, where Clojure can see it.

  (org/set-keyword! f :TARGET
                    (conj (org/lines (:TARGET (org/keywords f)))
                          \"/ssh:web@example: (web)\"))

Edits the visiting buffer only; `cljbang-org-save!' persists."
  (let ((name (cljbang-org--keyword-name key))
        (values (and value (cljbang-org--lines value))))
    (cljbang-org--with-file file
      (cljbang-org--check-editable)
      (let ((markers (mapcar #'copy-marker (cljbang-org--keyword-begins name))))
        (unwind-protect
            ;; Found before the first line goes: a marker at the start of
            ;; a deleted region stays where the region was, which is where
            ;; the replacement belongs.
            (let ((at (copy-marker (or (car markers)
                                       (cljbang-org--keyword-point)))))
              (unwind-protect
                  (progn
                    (dolist (m (reverse markers))
                      (goto-char m)
                      (delete-region (line-beginning-position)
                                     (line-beginning-position 2)))
                    (goto-char at)
                    (unless (bolp) (insert "\n"))
                    (dolist (value values)
                      (insert "#+" name ": " value "\n"))
                    (length values))
                (set-marker at nil)))
          (dolist (m markers) (set-marker m nil)))))))

;;; Effects: the file

;; The effects that take a file and no selector at all.
;; `cljbang-org-save!' takes one file, so a refile that lands a subtree
;; in another one needs saving on each.

;;;###autoload
(defun cljbang-org-save! (file)
  "Save FILE's visiting buffer if modified; the file name."
  (with-current-buffer (cljbang-org--buffer file)
    (when (buffer-modified-p) (save-buffer))
    (buffer-file-name)))

;;;###autoload
(defun cljbang-org-revert! (file)
  "Reload FILE from disk, discarding buffer edits; the file name."
  (with-current-buffer (cljbang-org--buffer file)
    (revert-buffer :ignore-auto :noconfirm)
    ;; `revert-buffer' swaps the text out from under org-element's cache,
    ;; which then never converges: the next scan of the buffer spins.
    ;; Throw the cache away, since every byte it described is gone.
    (when (fboundp 'org-element-cache-reset) (org-element-cache-reset))
    (buffer-file-name)))

;;;###autoload
(defun cljbang-org-tangle! (file)
  "Tangle FILE; the tangled file names as a vector."
  (cljbang-org--with-file file
    (apply #'vector (org-babel-tangle))))

;;; Executing a block

(defun cljbang-org--require-lang (lang)
  "Load the org-babel backend for LANG, a string, unless it is there.
A batch Emacs loads no babel languages, so a block's backend has to be
required before the block can run."
  (when lang
    (let* ((lang (downcase lang))
           (feature (pcase lang
                      ((or "sh" "bash" "shell" "zsh" "fish" "csh" "ksh") 'ob-shell)
                      ((or "elisp" "emacs-lisp") 'ob-emacs-lisp)
                      (_ (intern (concat "ob-" lang))))))
      (unless (fboundp (intern (concat "org-babel-execute:" lang)))
        (require feature nil t)))))

(defun cljbang-org--find-named-runnable (name)
  "Position of the runnable block named NAME, or nil.
Src blocks first, then `#+call:' lines, which carry a `#+name:' of
their own."
  (or (org-babel-find-named-block name)
      (org-element-map (org-element-parse-buffer 'element) 'babel-call
        (lambda (el)
          (and (equal name (org-element-property :name el))
               (cljbang-org--call-begin el)))
        nil t)))

(defun cljbang-org--goto-runnable (file selector)
  "Move point to the runnable block in FILE named by SELECTOR.
SELECTOR is a block name, a map with :name or :index, or nil for the
file's only runnable block.  A block map from `cljbang-org-src-blocks'
or `cljbang-org-call-blocks' works: its :name wins, else its :index.

Like every selector here this is a reference, not a search: it is
resolved against the buffer as it is now, so a block that has since
written its results back is still found."
  (let* ((name (cond ((stringp selector) selector)
                     ((hash-table-p selector) (cljbang-get selector :name))))
         (index (and (hash-table-p selector) (cljbang-get selector :index)))
         (positions (unless name (cljbang-org--runnable-positions))))
    (cond
     (name
      (goto-char (or (cljbang-org--find-named-runnable name)
                     (error "cljbang-org: no block named %s in %s" name file))))
     (index
      (unless (and (integerp index) (>= index 0) (< index (length positions)))
        (error "cljbang-org: block index %s out of range; %s has %d"
               index file (length positions)))
      (goto-char (nth index positions)))
     ((null selector)
      (pcase (length positions)
        (0 (error "cljbang-org: no runnable blocks in %s" file))
        (1 (goto-char (car positions)))
        (n (error "cljbang-org: %d runnable blocks in %s; pass a name or an index"
                  n file))))
     (t (error "cljbang-org: bad block selector %S" selector)))))

(defun cljbang-org--execute-at-point ()
  "Run the runnable block at point; its result.
The element at point decides which executor runs, so a `#+call:' line
works as well as a src block -- a call inherits the language of the
block it names, which is the one that has to be loaded."
  (let ((datum (org-element-context)))
    (if (not (eq 'babel-call (org-element-type datum)))
        (progn
          (cljbang-org--require-lang (car (org-babel-get-src-block-info 'light)))
          (org-babel-execute-src-block))
      ;; A call line runs the block it names, and inherits that block's
      ;; language, so that is the backend to load.  `org-babel-lob-
      ;; execute-maybe' answers whether it ran something and drops what
      ;; the block returned, so go the one step under it -- which grew
      ;; an EXECUTOR-TYPE argument in org 9.6, and does not take one on
      ;; the org 9.5 that ships with emacs 28.
      (let ((info (or (org-babel-lob-get-info datum)
                      (error "cljbang-org: call line names no block: %s"
                             (org-element-property :call datum)))))
        (cljbang-org--require-lang (car info))
        (if (>= (cdr (func-arity 'org-babel-execute-src-block)) 4)
            (org-babel-execute-src-block nil info nil 'babel-call)
          (org-babel-execute-src-block nil info))))))

;;;###autoload
(defun cljbang-org-execute! (file &optional selector)
  "Execute the runnable block in FILE named by SELECTOR; its result.
SELECTOR is a block name, a map with :name or :index, or nil for the
file's only runnable block; a block map from a query is one.  :index
counts src blocks and `#+call:' lines together, in file order.

An effect, because a block can do anything and its results land in the
buffer: `cljbang-org-save!' writes them to disk, `cljbang-org-revert!'
throws them away.

A block that exits non-zero raises, carrying the exit code and what it
wrote to stderr -- org-babel would otherwise pop up a buffer, return
the partial output, and let the caller think it worked.  Output on
stderr with a zero exit is not a failure and does not raise.

  (org/execute! f)                    ; the only block
  (org/execute! f \"deploy\")           ; the block named deploy
  (org/execute! f {:index 2})         ; the third runnable block
  (->> (org/src-blocks f) (filter ...) first (org/execute! f))"
  (cljbang-org--with-file file
    (cljbang-org--check-editable)
    ;; `org-babel-eval' swallows a failing process: it pops an error
    ;; buffer, `message's, and returns the partial output.  Turn that
    ;; notification into a signal -- but only for a real failure, since
    ;; stderr output with a zero exit notifies too.
    (cl-letf* ((notify (symbol-function 'org-babel-eval-error-notify))
               ((symbol-function 'org-babel-eval-error-notify)
                (lambda (exit-code stderr)
                  (if (or (not (numberp exit-code)) (> exit-code 0))
                      (let ((stderr (string-trim (or stderr ""))))
                        (error "cljbang-org: block exited with code %s%s"
                               (if (numberp exit-code) exit-code "?")
                               (if (string-empty-p stderr) ""
                                 (concat ": " stderr))))
                    (funcall notify exit-code stderr)))))
      (let ((org-confirm-babel-evaluate nil))
        (cljbang-org--goto-runnable file selector)
        (cljbang-org--execute-at-point)))))

;;; Shaping results

;; Org is not fussy about the shape of what it hands over, and a caller
;; that has to be is a caller writing the same three lines again.  A
;; shaping function takes whatever arrived -- a map a query returned,
;; the :rows inside it, or the value org-babel bound to a :var -- and
;; answers one shape.

;;;###autoload
(defun cljbang-org-tree (headings)
  "HEADINGS nested by :level, as a vector of the roots.
Each map is a copy of the one handed in with a :children vector added,
so the input is untouched and a leaf's :children is empty rather than
missing.  Every heading map has a :level, so this nests whatever
produced them:

  (org/tree (org/headings \"box.org\"))
  (org/tree (ql/select \"box.org\" \\='(todo \"TODO\")))

A heading deeper than its predecessor by more than one level is still
that heading's child; org files skip levels and the shape has to say
something.  Headings that arrive out of file order nest by the order
given, not by position."
  (let (roots stack nodes)
    (dolist (heading (append headings nil))
      (let ((level (or (cljbang-get heading :level) 1))
            (node (copy-hash-table heading)))
        (push node nodes)
        (puthash :children nil node)
        (while (and stack (>= (caar stack) level)) (pop stack))
        (if stack
            (let ((parent (cdar stack)))
              (puthash :children (cons node (cljbang-get parent :children)) parent))
          (push node roots))
        (push (cons level node) stack)))
    (dolist (node nodes)
      (puthash :children
               (apply #'vector (nreverse (cljbang-get node :children)))
               node))
    (apply #'vector (nreverse roots))))

(defun cljbang-org--lines (x)
  "Lines of X as a list, flattening nested sequences."
  (cond ((stringp x)
         (let (acc)
           (dolist (line (split-string x "\n"))
             (let ((line (string-trim line)))
               (unless (string-empty-p line) (push line acc))))
           (nreverse acc)))
        ((sequencep x)
         (apply #'append (mapcar #'cljbang-org--lines (append x nil))))
        (t (list (format "%s" x)))))

;;;###autoload
(defun cljbang-org-lines (x)
  "X as a vector of non-blank, trimmed lines, whatever shape it arrived in.

The same list of names reaches a block as text, as a vector of
strings, or as a table -- a vector of one-element rows -- depending
on how the block that produced it was run.  Org does not say which:
a :var naming another block re-runs that block with :results none,
which overrides the block's own :results, so a shell block that
displays as text is handed over as a table.  Coerce and the caller
stops caring.

  (org/lines \"a\\nb\")          ;=> [\"a\" \"b\"]
  (org/lines [\"a\" \"b\"])       ;=> [\"a\" \"b\"]
  (org/lines [[\"a\"] [\"b\"]])   ;=> [\"a\" \"b\"]"
  (apply #'vector (cljbang-org--lines x)))

(defun cljbang-org--hline-p (row)
  "Whether ROW is a horizontal rule rather than data.
Org writes one `hline' when babel hands a table to a :var and :hline
when `cljbang-org-tables' reads the same table; the caller of a
coercion should not have to know which arrived."
  (memq row '(hline :hline)))

(defun cljbang-org--table-rows (x)
  "Rows of X as a list, whatever shape X arrived in.
X is a table map, its :rows, or the table a :var handed over."
  (append (if (hash-table-p x) (cljbang-get x :rows) x) nil))

(defun cljbang-org--cell (x)
  "Cell X as a trimmed string; org tables have no types."
  (if x (string-trim (format "%s" x)) ""))

(defun cljbang-org--row (row)
  (apply #'vector (mapcar #'cljbang-org--cell (append row nil))))

;;;###autoload
(defun cljbang-org-rows (x)
  "X as a vector of data rows, each a vector of trimmed cell strings.
Horizontal rules are dropped.  X is a table map from
`cljbang-org-tables', its :rows, or the list a :var naming a table
hands over.

  (org/rows [[\"a\" \"b\"] :hline [\"1\" \"2\"]])  ;=> [[\"a\" \"b\"] [\"1\" \"2\"]]"
  (apply #'vector
         (delq nil
               (mapcar (lambda (row)
                         (unless (cljbang-org--hline-p row)
                           (cljbang-org--row row)))
                       (cljbang-org--table-rows x)))))

(defun cljbang-org--header-key (cell i)
  "Keyword naming column I (zero-based), whose header cell is CELL."
  (let* ((s (downcase (cljbang-org--cell cell)))
         (s (replace-regexp-in-string "[^[:alnum:]]+" "-" s))
         (s (string-trim s "-+" "-+")))
    (intern (concat ":" (if (string-empty-p s) (format "col-%d" (1+ i)) s)))))

(defun cljbang-org--split-header (rows)
  "Cons of the header row and the data rows of ROWS.
The header is the row above the first horizontal rule, or the first row
when there is none -- org's own :colnames rule.  Rules are dropped from
the data either way."
  (let ((rule (seq-position rows nil (lambda (row _) (cljbang-org--hline-p row)))))
    (if (and rule (> rule 0))
        (cons (nth (1- rule) rows)
              (seq-remove #'cljbang-org--hline-p (nthcdr (1+ rule) rows)))
      (let ((data (seq-remove #'cljbang-org--hline-p rows)))
        (cons (car data) (cdr data))))))

;;;###autoload
(defun cljbang-org-table->maps (x)
  "X as a vector of row maps keyed by the table's column names.
X takes the same shapes `cljbang-org-rows' does.

The header is the row above the first horizontal rule, or the first row
when the table has none.  Keys are its cells as keywords, downcased with
runs of non-alphanumerics collapsed to a single dash, so \"Host Name\"
keys :host-name; an empty header cell keys :col-N by position, and a
repeated one keeps the last column it names.  A row shorter than the
header pads with empty strings, a longer one loses its extra cells.

  (org/table->maps [[\"Host Name\"] :hline [\"caddy\"]])
  ;=> [{:host-name \"caddy\"}]"
  (let* ((split (cljbang-org--split-header (cljbang-org--table-rows x)))
         (keys (seq-map-indexed (lambda (cell i) (cljbang-org--header-key cell i))
                                (append (car split) nil))))
    (apply #'vector
           (mapcar (lambda (row)
                     (let ((cells (append row nil))
                           (h (make-hash-table :test #'equal)))
                       (seq-do-indexed
                        (lambda (key i) (puthash key (cljbang-org--cell (nth i cells)) h))
                        keys)
                       h))
                   (cdr split)))))

(provide 'cljbang-org)
;;; cljbang-org.el ends here
