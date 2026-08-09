;;; gendoc.el --- Generate doc/api.md from the sources -*- lexical-binding: t; -*-

;;; Commentary:

;; The API reference is the sources' own comments, rearranged:
;;
;;   emacs -Q --batch -l doc/gendoc.el -f gendoc-write
;;
;; Everything a reader needs is already written next to the code it
;; describes -- a `;;; Section' comment and the prose under it, a
;; docstring per function -- so this reads that and emits markdown
;; rather than asking anyone to keep a second copy in step.  `make doc'
;; writes it; `make doc-check' fails when the file on disk has drifted.
;;
;; The sources are read as text and never loaded, so this needs neither
;; cljbang nor org-ql nor a matching Emacs: `read' over a buffer gets
;; the name, arglist and docstring of every autoloaded defun, and a
;; line scan gets the sections around them.
;;
;; What crosses over, and how:
;;
;;   cljbang-org-set-todo!    ->  org/set-todo!    (cljbang's own munging,
;;   cljbang-org-ql-select    ->  ql/select         backwards)
;;   (file &optional opts)    ->  (file & [opts])
;;   FILE                     ->  `file'
;;   `cljbang-org-save!'      ->  a link to that function's entry
;;   a two-space indented run ->  a fenced clojure block
;;
;; Anchors are GitHub's slug of the heading -- lowercased, everything
;; but alphanumerics, dash and underscore dropped -- which is what Hugo
;; computes too, so one link works on github.com and on the site.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst gendoc-files
  '((:file "cljbang-org.el" :intro t)
    (:file "cljbang-org-ql.el" :section "org-ql queries"))
  "Sources to document, in order.
:intro puts the file's Commentary at the top of the page; :section
gives the file's functions a section of their own, prose and all,
for a file that declares no `;;; Section' comments itself.")

(defconst gendoc-namespaces
  '(("cljbang-org-ql-" . "ql")
    ("cljbang-org-" . "org"))
  "Elisp prefix to cljbang namespace alias, longest prefix first.")

(defconst gendoc-output "doc/API.md"
  "Where `gendoc-write' writes, relative to the project root.
The name is the page's title on the site, which takes it from the file
when the file carries no front matter -- and it carries none so that
github.com renders it as the markdown it is.")

(defconst gendoc-title "API"
  "The page's own heading.")


;;; Names

(defun gendoc--clj-name (name)
  "The cljbang name for elisp NAME, a string, or nil if it has none.
Private names -- the ones with a double dash -- have none on purpose:
they are not API, so a docstring mentioning one gets plain code
formatting and no link."
  (unless (string-match-p "--" name)
    (cl-loop for (prefix . alias) in gendoc-namespaces
             when (string-prefix-p prefix name)
             return (concat alias "/" (substring name (length prefix))))))

(defun gendoc--anchor (heading)
  "GitHub's anchor for HEADING."
  (downcase (replace-regexp-in-string "[^a-zA-Z0-9_-]" "" heading)))

(defun gendoc--signature (clj-name arglist)
  "The call CLJ-NAME takes, written the way a caller writes it.
ARGLIST is the elisp one: `&optional' becomes Clojure's trailing
destructured vector, `&rest' its rest argument."
  (let (required optional rest (mode 'required))
    (dolist (arg arglist)
      (cond ((eq arg '&optional) (setq mode 'optional))
            ((eq arg '&rest) (setq mode 'rest))
            ((eq mode 'required) (push (symbol-name arg) required))
            ((eq mode 'optional) (push (symbol-name arg) optional))
            (t (push (symbol-name arg) rest))))
    (concat
     (string-join
      (delq nil
            (list (concat "(" clj-name)
                  (and required (string-join (nreverse required) " "))
                  (and optional
                       (format "& [%s]" (string-join (nreverse optional) " ")))
                  (and rest (concat "& " (string-join (nreverse rest) " ")))))
      " ")
     ")")))


;;; Docstrings

(defvar gendoc--links nil
  "Cljbang name to anchor, for the cross-references in a docstring.
Filled by the first pass over the sources, read by the second: a
function can refer to one declared after it.")

(defun gendoc--ref (name)
  "Markdown for a docstring's reference to elisp NAME."
  (let* ((clj (gendoc--clj-name name))
         (anchor (and clj (cdr (assoc clj gendoc--links)))))
    (if anchor
        (format "[`%s`](#%s)" clj anchor)
      (format "`%s`" (or clj name)))))

(defun gendoc--refs (text)
  "TEXT with every `symbol' reference turned into code, or into a link."
  (replace-regexp-in-string "`\\([^`' \n]+\\)'"
                            (lambda (m) (gendoc--ref (match-string 1 m)))
                            text t t))

(defun gendoc--outside-code (text fn)
  "TEXT with FN applied to the parts of it that are not code already.
Every pass here adds backticks, and the next pass must not reach inside
the ones the last one wrote."
  (let ((pos 0) (out ""))
    (while (string-match "`[^`]*`" text pos)
      (setq out (concat out
                        (funcall fn (substring text pos (match-beginning 0)))
                        (match-string 0 text))
            pos (match-end 0)))
    (concat out (funcall fn (substring text pos)))))

(defun gendoc--code-wrap (text regexp)
  "TEXT with every REGEXP match that is not code already set as code."
  (gendoc--outside-code
   text (lambda (s) (replace-regexp-in-string regexp "`\\&`" s t))))

(defun gendoc--args (text args)
  "TEXT with each of ARGS, which a docstring shouts, written as a caller writes it.
Word boundaries rather than symbol ones: a docstring's ARG is as likely
to be followed by a colon or a period, and those are symbol constituents."
  (let ((out text)
        ;; The shout is the whole point: a docstring writes the word
        ;; lowercase when it means the English one.
        (case-fold-search nil))
    (dolist (arg args)
      (let ((shout (format "\\b%s\\b" (regexp-quote (upcase arg))))
            (quiet (format "`%s`" arg)))
        (setq out (gendoc--outside-code
                   out (lambda (s)
                         (replace-regexp-in-string shout quiet s t t))))))
    out))

(defun gendoc--literals (text)
  "TEXT with the Clojure it mentions in passing set as code.
A map literal on one line, a keyword, and nil: the things a docstring
writes bare because elisp's own help renderer has no code face to put
them in.  The map goes first and the keywords inside it are then already
code, so `{:body? true}' comes out as one span rather than three."
  (let ((out text))
    (dolist (regexp '("{[^{}\n]*}"
                      "\"[^\"\n]*\""
                      ":[a-zA-Z][a-zA-Z0-9?!*+<>=-]*"
                      "\\bnil\\b"))
      (setq out (gendoc--code-wrap out regexp)))
    out))

(defun gendoc--dashes (text)
  "TEXT with the em dash a docstring spells as two hyphens.
Wherever the line happened to break around it."
  (replace-regexp-in-string " --\\($\\| \\)" " —\\1" text))

(defun gendoc--inline (text args)
  "TEXT as markdown, ARGS being the arguments of the docstring it came from."
  ;; Literals before arguments: a docstring's :FILE is the keyword, not
  ;; the argument, and the keyword pass claims it first.
  (let* ((out (gendoc--refs text))
         (out (gendoc--literals out))
         (out (gendoc--args out args)))
    (gendoc--outside-code out #'gendoc--dashes)))

(defun gendoc--indented-p (line)
  "Whether LINE is part of an indented example."
  (string-match-p "\\`  +[^ ]" line))

(defun gendoc--dedent (lines)
  "LINES with the indentation they share removed."
  (let ((width (cl-loop for line in lines
                        unless (string-blank-p line)
                        minimize (- (length line)
                                    (length (string-trim-left line))))))
    (mapcar (lambda (line)
              (if (string-blank-p line) "" (substring line width)))
            lines)))

(defun gendoc--blocks (lines)
  "LINES split into (prose . LINES) and (code . LINES) blocks, in order.
An example is a run of indented lines set off by a blank one, which is
how a docstring writes one.  Indentation alone is not enough: a list
item that runs onto a second line is indented too, and is prose."
  (let (blocks current kind (blank-before t))
    (cl-flet ((flush ()
                (when current
                  (push (cons kind (nreverse current)) blocks)
                  (setq current nil))))
      (dolist (line lines)
        (let* ((blank (string-blank-p line))
               (line-kind (cond (blank (or kind 'prose))
                                ((and (gendoc--indented-p line)
                                      (or (eq kind 'code) blank-before))
                                 'code)
                                (t 'prose))))
          (unless (eq line-kind kind) (flush) (setq kind line-kind))
          (push line current)
          (setq blank-before blank)))
      (flush))
    ;; A blank line that ended a code block belongs to neither.
    (mapcar (lambda (block)
              (cons (car block)
                    (let ((body (cdr block)))
                      (while (and body (string-blank-p (car (last body))))
                        (setq body (butlast body)))
                      body)))
            (nreverse blocks))))

(defun gendoc--render (lines args)
  "LINES as markdown, with ARGS the argument names to code-format."
  (let (out)
    (dolist (block (gendoc--blocks lines))
      (let ((body (cdr block)))
        (when body
          (if (eq (car block) 'code)
              (push (concat "```clojure\n"
                            (string-join (gendoc--dedent body) "\n")
                            "\n```")
                    out)
            (push (gendoc--inline (string-join body "\n") args) out)))))
    (string-join (nreverse out) "\n\n")))

(defun gendoc--docstring (doc args)
  "Elisp docstring DOC as markdown, ARGS being the function's arguments.
The `\\=' the reader leaves behind goes; it is elisp telling its own
help renderer to keep its hands off, which markdown has no use for."
  (gendoc--render (split-string (replace-regexp-in-string "\\\\=" "" doc)
                                "\n")
                  args))


;;; Reading a source file

(defun gendoc--strip-comment (line)
  "LINE without its leading `;;' and the one space after it."
  (cond ((string-match "\\`;; ?\\(.*\\)\\'" line) (match-string 1 line))
        (t line)))

(defun gendoc--commentary ()
  "The Commentary of the file in the current buffer, as its lines.
Point is left where it was."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^;;; Commentary:$" nil t)
      (forward-line 1)
      (let ((start (point)))
        (when (re-search-forward "^;;; Code:$" nil t)
          (goto-char (match-beginning 0))
          (let ((lines (mapcar #'gendoc--strip-comment
                               (split-string
                                (buffer-substring-no-properties start (point))
                                "\n"))))
            ;; The blank comment lines the block is padded with.
            (while (and lines (string-blank-p (car lines)))
              (setq lines (cdr lines)))
            (while (and lines (string-blank-p (car (last lines))))
              (setq lines (butlast lines)))
            lines))))))

(defun gendoc--prose-at-point ()
  "The `;;' block starting on the current line, as its lines, or nil.
Point ends after it."
  (let (lines)
    (while (looking-at "^;;\\(?: \\|$\\)")
      (push (gendoc--strip-comment
             (buffer-substring-no-properties (point) (line-end-position)))
            lines)
      (forward-line 1))
    (nreverse lines)))

(defun gendoc--entry-at-point ()
  "The autoloaded defun on the following lines, as a plist, or nil.
Point ends after the form."
  (when (looking-at "^(defun ")
    (let ((form (read (current-buffer))))
      (when (and (eq (car form) 'defun) (stringp (nth 3 form)))
        (let* ((name (symbol-name (nth 1 form)))
               (clj (gendoc--clj-name name)))
          (and clj (list :name clj
                         :arglist (nth 2 form)
                         :doc (nth 3 form))))))))

(defun gendoc--scan (file)
  "The sections FILE declares, each with the entries and prose under it.
A section is a plist of :title, :prose and :entries; a file's functions
before its first `;;; Section' comment land in a section with no title,
which the caller titles or drops."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((commentary (gendoc--commentary))
          (section (list :title nil :prose nil :entries nil))
          sections)
      (cl-flet ((close ()
                  (when (or (plist-get section :prose)
                            (plist-get section :entries))
                    (push (list :title (plist-get section :title)
                                :prose (plist-get section :prose)
                                :entries (nreverse (plist-get section :entries)))
                          sections))))
        (re-search-forward "^;;; Code:$" nil t)
        (while (not (eobp))
          (cond
           ;; A section heading, and the prose that introduces it.
           ((looking-at "^;;; \\(.+\\)$")
            (let ((title (match-string 1)))
              (close)
              (forward-line 1)
              (while (and (not (eobp)) (looking-at "^$")) (forward-line 1))
              (setq section (list :title title
                                  :prose (gendoc--prose-at-point)
                                  :entries nil))))
           ;; A function the package exports.
           ((looking-at "^;;;###autoload$")
            (forward-line 1)
            (let ((entry (gendoc--entry-at-point)))
              (when entry
                (plist-put section :entries
                           (cons entry (plist-get section :entries)))))
            (forward-line 1))
           (t (forward-line 1))))
        (close))
      (list :commentary commentary :sections (nreverse sections)))))


;;; Emitting

(defun gendoc--summary (doc)
  "The first sentence of docstring DOC, which is its one-line summary."
  (car (split-string doc "\n")))

(defun gendoc--index (entries)
  "A table of ENTRIES and what each does, or nil for a section too small.
Two functions are a list; one is just the entry that follows."
  (when (cdr entries)
    (string-join
     (append
      '("| Function | Does |" "|---|---|")
      (mapcar (lambda (entry)
                (let ((name (plist-get entry :name)))
                  (format "| [`%s`](#%s) | %s |"
                          name (gendoc--anchor name)
                          (gendoc--inline
                           (gendoc--summary (plist-get entry :doc))
                           (gendoc--arg-names (plist-get entry :arglist))))))
              entries))
     "\n")))

(defun gendoc--arg-names (arglist)
  "The names in ARGLIST a docstring might shout, `&optional' and friends out."
  (mapcar #'symbol-name
          (seq-remove (lambda (arg) (string-prefix-p "&" (symbol-name arg)))
                      arglist)))

(defun gendoc--entry (entry)
  "ENTRY as its own markdown section: the name, the call, the docstring."
  (let ((name (plist-get entry :name))
        (arglist (plist-get entry :arglist)))
    (string-join
     (list (format "### %s" name)
           (format "`%s`" (gendoc--signature name arglist))
           (gendoc--docstring (plist-get entry :doc)
                              (gendoc--arg-names arglist)))
     "\n\n")))

(defun gendoc--section (section)
  "SECTION as markdown: its heading, its prose, its index, its entries."
  (let ((entries (plist-get section :entries)))
    (string-join
     (delq nil
           (append
            (list (and (plist-get section :title)
                       (format "## %s" (plist-get section :title)))
                  (and (plist-get section :prose)
                       (gendoc--render (plist-get section :prose) nil))
                  (gendoc--index entries))
            (mapcar #'gendoc--entry entries)))
     "\n\n")))

(defun gendoc--file-sections (spec)
  "The sections SPEC's file contributes, its Commentary put where it belongs."
  (let* ((scan (gendoc--scan (plist-get spec :file)))
         (commentary (plist-get scan :commentary))
         (sections (plist-get scan :sections)))
    (cond
     ;; The file whose Commentary opens the page.
     ((plist-get spec :intro) sections)
     ;; A file with a section of its own: its Commentary introduces it,
     ;; and the untitled section its functions landed in takes the title.
     ((plist-get spec :section)
      (list (list :title (plist-get spec :section)
                  :prose commentary
                  :entries (apply #'append
                                  (mapcar (lambda (s) (plist-get s :entries))
                                          sections)))))
     (t sections))))

(defun gendoc--intro ()
  "The Commentary that opens the page, from the file claiming :intro."
  (let ((spec (seq-find (lambda (s) (plist-get s :intro)) gendoc-files)))
    (when spec
      (gendoc--render (plist-get (gendoc--scan (plist-get spec :file))
                                 :commentary)
                      nil))))

(defun gendoc--collect ()
  "Every section the sources contribute, in the order `gendoc-files' names."
  (apply #'append (mapcar #'gendoc--file-sections gendoc-files)))

(defun gendoc--link-table (sections)
  "SECTIONS' function names to their anchors, for cross-references."
  (mapcan (lambda (section)
            (mapcar (lambda (entry)
                      (let ((name (plist-get entry :name)))
                        (cons name (gendoc--anchor name))))
                    (plist-get section :entries)))
          sections))

(defun gendoc-render ()
  "The whole page, as a string."
  (let* ((sections (gendoc--collect))
         (gendoc--links (gendoc--link-table sections)))
    (concat
     "<!-- Generated by doc/gendoc.el from the elisp sources.  Do not edit;\n"
     "     edit the docstrings and `;;; Section' comments and run `make doc'. -->\n\n"
     (string-join
      (delq nil (append (list (format "# %s" gendoc-title) (gendoc--intro))
                        (mapcar #'gendoc--section sections)))
      "\n\n")
     "\n")))

(defun gendoc-write ()
  "Write the page to `gendoc-output'."
  (let ((text (gendoc-render)))
    (with-temp-file gendoc-output (insert text))
    (message "gendoc: wrote %s (%d lines)" gendoc-output
             (1+ (cl-count ?\n text)))))

(defun gendoc-check ()
  "Fail unless `gendoc-output' is what the sources say it should be."
  (let ((want (gendoc-render))
        (have (and (file-exists-p gendoc-output)
                   (with-temp-buffer
                     (insert-file-contents gendoc-output)
                     (buffer-string)))))
    (unless (equal want have)
      (message "gendoc: %s is out of date; run `make doc'" gendoc-output)
      (kill-emacs 1))
    (message "gendoc: %s is up to date" gendoc-output)))

(provide 'gendoc)
;;; gendoc.el ends here
