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
;; blocks and file keywords, extracted at point with org's cheap APIs,
;; never the raw org-element AST.  Positions in those maps (:begin
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
(require 'ob-core)
(require 'ob-tangle)
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
  (cljbang-org--with-file file
    (let ((under (cljbang-org--opt opts :under))
          (expand (cljbang-org--opt opts :expand-transclusions?)))
      (if (not under)
          (cljbang-org--with-transclusions expand
            (cljbang-org--collect-blocks))
        (apply #'vconcat
               (mapcar (lambda (pos)
                         (goto-char pos)
                         (save-restriction
                           (org-narrow-to-subtree)
                           (cljbang-org--with-transclusions expand
                             (cljbang-org--collect-blocks))))
                       (cljbang-org--locate-all
                        (cljbang-org--selector-pred under))))))))

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
