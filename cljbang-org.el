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
;; blocks, tables and file keywords, extracted at point with org's cheap
;; APIs, never the raw org-element AST.  Positions in those maps (:begin
;; :end) are provenance, not handles: effect functions (the ! names)
;; take a selector and re-locate from scratch, so stale positions
;; cannot corrupt an edit.  Effects edit the visiting buffer; save! is
;; the separate, explicit step that touches disk.
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

(require 'org)
(require 'org-element)
(require 'org-table)
(require 'ob-core)
(require 'ob-tangle)
(require 'seq)
(require 'subr-x)
(require 'cljbang-core)

;;; Buffer discipline

(defvar-local cljbang-org--transcluded nil
  "Non-nil while a query has transclusions expanded.
Effects check this and refuse to edit, because positions in expanded
text do not belong to the file.")

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
         ,@body))))

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

(defun cljbang-org--properties-at-point ()
  "Drawer properties of the heading at point, as a map with keyword keys."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (kv (org-entry-properties nil 'standard) h)
      (puthash (intern (concat ":" (car kv))) (cdr kv) h))))

(defun cljbang-org--title-at-point ()
  (substring-no-properties (or (nth 4 (org-heading-components)) "")))

(defun cljbang-org--heading-at-point ()
  "Heading at point as a map: :title :level :tags :todo :priority
:properties :begin :end :file."
  (let* ((comps (org-heading-components))
         (priority (nth 3 comps)))
    (cljbang-hash-map
     :title (cljbang-org--title-at-point)
     :level (nth 0 comps)
     :todo (nth 2 comps)
     :priority (and priority (char-to-string priority))
     :tags (apply #'cljbang-hash-set
                  (mapcar #'substring-no-properties (org-get-tags nil t)))
     :properties (cljbang-org--properties-at-point)
     :begin (point)
     :end (save-excursion (org-end-of-subtree t t) (point))
     :file (buffer-file-name))))

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
OPTS: {:expand-transclusions? true} to scan transcluded content too."
  (cljbang-org--with-file file
    (cljbang-org--with-transclusions
        (cljbang-org--opt opts :expand-transclusions?)
      (let (acc)
        (org-map-entries
         (lambda () (push (cljbang-org--heading-at-point) acc)))
        (apply #'vector (nreverse acc))))))

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

;;; Source blocks

(defun cljbang-org--block-at-point ()
  "Src block at point as a map: :language :name :headers :body :begin
:end :file.  :headers is the resolved header-arg map, defaults included,
so an untangled block carries :tangle \"no\"."
  (let* ((info (org-babel-get-src-block-info 'light))
         (headers (let ((h (make-hash-table :test #'equal)))
                    (dolist (kv (nth 2 info) h)
                      (puthash (car kv) (cdr kv) h)))))
    (cljbang-hash-map
     :language (nth 0 info)
     :name (nth 4 info)
     :headers headers
     :body (nth 1 info)
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
order; {:expand-transclusions? true} scans transcluded content too."
  (cljbang-org--scan file opts #'cljbang-org--collect-blocks))

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

(provide 'cljbang-org)
;;; cljbang-org.el ends here
