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
;; blocks, call lines, tables and file keywords, extracted at point with
;; org's cheap APIs, never the raw org-element AST.  Positions in those
;; maps (:begin :end) are provenance, not handles: effect functions (the
;; ! names) take a selector and re-locate from scratch, so stale
;; positions cannot corrupt an edit.  Effects edit the visiting buffer;
;; save! is the separate, explicit step that touches disk.
;;
;; A selector names a heading you already mean; it is a reference, not
;; a search.  Selectors deliberately do not grow query features (no
;; :tags, no :todo, no regexps): filtering is Clojure's job over the
;; data `headings' returns, or org-ql's job via cljbang.org.ql.
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

;;; Selectors: how an effect names the heading it means

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

;;; Coercion

;;;###autoload
(defun cljbang-org-tree (headings)
  "HEADINGS nested by :level, as a vector of the root headings.
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

;;; Queries

;;;###autoload
(defun cljbang-org-headings (file &optional opts)
  "All headings in FILE as a vector of heading maps.
OPTS: {:body? true} adds each heading's own text as :body;
{:expand-transclusions? true} to scan transcluded content too.

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

;;;###autoload
(defun cljbang-org-keywords (file)
  "File keywords (#+KEY: value lines) of FILE.
A map of lowercase keyword keys to vectors of values, in file order, so
repeated keywords like #+TARGET: all arrive."
  (cljbang-org--with-file file
    (goto-char (point-min))
    (let (acc)
      (while (re-search-forward
              "^[ \t]*#\\+\\([[:alnum:]_-]+\\):[ \t]*\\(.*?\\)[ \t]*$" nil t)
        (let ((key (downcase (match-string-no-properties 1)))
              (val (match-string-no-properties 2)))
          (unless (string-match-p "\\`\\(begin\\|end\\)_" key)
            (push val (alist-get key acc nil nil #'equal)))))
      (let ((h (make-hash-table :test #'equal)))
        (pcase-dolist (`(,k . ,vs) acc)
          (puthash (intern (concat ":" k)) (apply #'vector (nreverse vs)) h))
        h))))

;;; Runnable blocks: what an :index counts

;; A src block and a `#+call:' line are both things `execute!' can run,
;; so they share one numbering over the whole file.  That number, not a
;; position, is the handle: a block that writes its results back moves
;; every position after it, while the indices stay put.

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
OPTS: {:under selector} restricts to every matching subtree, in file
order; {:expand-transclusions? true} scans transcluded content too.

An :index counts blocks in the file, not in the result, so it still
names the block under :under -- but not under
:expand-transclusions?, where most blocks are not the file's to run."
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
Takes the same opts `cljbang-org-src-blocks' does.

A call line invokes a block named elsewhere -- another heading, another
file, the library of babel -- so `src-blocks' does not see it.  The two
share one :index, and every runnable step in a file is:

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
OPTS: {:under selector} restricts to every matching subtree, in file
order; {:expand-transclusions? true} scans transcluded content too."
  (cljbang-org--scan file opts #'cljbang-org--collect-tables))

;;; Effects

(defun cljbang-org--check-editable ()
  (when cljbang-org--transcluded
    (error "cljbang-org: refusing to edit while transclusions are expanded")))

;;;###autoload
(defun cljbang-org-cut-subtree! (file selector)
  "Cut every subtree in FILE matching SELECTOR; the count cut.
Edits the visiting buffer only: `cljbang-org-save!' persists,
`cljbang-org-revert!' discards.  Each cut re-locates from the top, so
positions never go stale."
  (cljbang-org--with-file file
    (cljbang-org--check-editable)
    (let ((pred (cljbang-org--selector-pred selector))
          (count 0)
          pos)
      (while (setq pos (cljbang-org--locate-first pred))
        (goto-char pos)
        (org-cut-subtree)
        (setq count (1+ count)))
      count)))

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
      ;; the block returned, so go the one step under it -- which org
      ;; renamed along the way.
      (let ((info (or (org-babel-lob-get-info datum)
                      (error "cljbang-org: call line names no block: %s"
                             (org-element-property :call datum)))))
        (cljbang-org--require-lang (car info))
        (if (fboundp 'org-babel-lob-execute)
            (org-babel-lob-execute info)
          (org-babel-execute-src-block nil info nil 'babel-call))))))

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

(provide 'cljbang-org)
;;; cljbang-org.el ends here
