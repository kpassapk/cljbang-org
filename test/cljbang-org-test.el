;;; cljbang-org-test.el --- Tests for cljbang-org -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests go through the Clojure surface with `cljbang-eval-string',
;; the way cljbang's own suite does, so they prove both the behavior
;; and that cljbang.org/foo resolves to cljbang-org-foo and the return
;; shapes interoperate with get, filter and keyword lookup.

;;; Code:

(require 'ert)
(require 'cljbang)
(require 'cljbang-org)

(defvar cljbang-org-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun cljbang-org-test--fixture (name)
  (expand-file-name (concat "fixtures/" name) cljbang-org-test--dir))

(defun cljbang-org-test--eval (src &rest args)
  "Evaluate Clojure SRC, a format string filled with ARGS."
  (cljbang-eval-string (apply #'format src args)))

(defun cljbang-org-test--heading (file title)
  "The heading map titled TITLE in FILE, or nil.
There is no `cljbang.org/heading': finding one heading among many is
Clojure's job, so the tests do it the way a caller would."
  (cljbang-eval-string
   (format "(->> (cljbang.org/headings %S)
                 (filter #(= %S (:title %%)))
                 first)"
           file title)))

(defun cljbang-org-test--tangle-targets (src &rest args)
  "Distinct tangle targets of the block maps Clojure SRC returns.
SRC is a format string filled with ARGS."
  (cljbang-eval-string
   (format "(->> %s
                 (keep (comp :tangle :headers))
                 (remove #{\"no\"})
                 distinct
                 vec)"
           (apply #'format src args))))

(defmacro cljbang-org-test--with-temp-fixture (var name &rest body)
  "Copy fixture NAME into a temp dir, bind its path to VAR, run BODY.
Kills any visiting buffer and deletes the dir afterwards."
  (declare (indent 2))
  `(let* ((cljbang-org-test--tmp (make-temp-file "cljbang-org" t))
          (,var (expand-file-name ,name cljbang-org-test--tmp)))
     (copy-file (cljbang-org-test--fixture ,name) ,var)
     (unwind-protect
         (progn ,@body)
       (when-let ((buf (find-buffer-visiting ,var)))
         (with-current-buffer buf
           (set-buffer-modified-p nil)
           (kill-buffer)))
       (delete-directory cljbang-org-test--tmp t))))

;;; Headings

(ert-deftest cljbang-org-test-headings-count ()
  (should (= 7 (cljbang-org-test--eval
                "(count (cljbang.org/headings %S))"
                (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-headings-titles-filter ()
  "Heading maps compose with filter and keyword lookup."
  (should (equal ["Demo"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S)
                        (filter #(contains? (:tags %%) \"project\"))
                        (mapv :title))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-headings-todo-and-level ()
  (should (equal "TODO"
                 (cljbang-get (cljbang-org-test--heading
                               (cljbang-org-test--fixture "server.org")
                               "State checks")
                              :todo)))
  (should (= 2 (cljbang-get (cljbang-org-test--heading
                             (cljbang-org-test--fixture "server.org")
                             "caddy.container")
                            :level))))

(ert-deftest cljbang-org-test-headings-carry-properties ()
  "The heading map already holds the drawer, so there is no
`properties' or `entry-get' to duplicate it."
  (should (equal "quadlets"
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S)
                        (keep #(get-in %% [:properties :CUSTOM_ID]))
                        first)"
                  (cljbang-org-test--fixture "server.org")))))

;;; Keywords

(ert-deftest cljbang-org-test-keywords ()
  (should (equal ["Test server"]
                 (cljbang-org-test--eval
                  "(:title (cljbang.org/keywords %S))"
                  (cljbang-org-test--fixture "server.org"))))
  (should (equal [".. (project)" "/ssh:app@example: (server)"]
                 (cljbang-org-test--eval
                  "(:target (cljbang.org/keywords %S))"
                  (cljbang-org-test--fixture "server.org")))))

;;; Src blocks and tangle targets

(ert-deftest cljbang-org-test-src-blocks-all ()
  (should (= 5 (cljbang-org-test--eval
                "(count (cljbang.org/src-blocks %S))"
                (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-src-blocks-under ()
  (should (= 4 (cljbang-org-test--eval
                "(count (cljbang.org/src-blocks %S {:under \"Quadlets\"}))"
                (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-src-block-shape ()
  (should (equal "untangled"
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/src-blocks %S)
                        (keep :name)
                        first)"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-src-blocks-under-every-match ()
  ":under is not first-match: both Quadlets subtrees contribute."
  (should (equal ["~/.config/containers/systemd/a.container"
                  "~/.config/containers/systemd/b.container"]
                 (cljbang-org-test--tangle-targets
                  "(cljbang.org/src-blocks %S {:under \"Quadlets\"})"
                  (cljbang-org-test--fixture "repeated.org")))))

(ert-deftest cljbang-org-test-src-blocks-under-miss-is-empty ()
  (should (equal []
                 (cljbang-org-test--eval
                  "(vec (cljbang.org/src-blocks %S {:under \"no such heading\"}))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-tangle-targets ()
  "Block maps carry enough for Clojure to do the filtering: drops
:tangle no and headerless blocks, keeps order, dedupes."
  (should (equal ["~/.config/containers/systemd/caddy.container"
                  "~/.config/containers/systemd/caddy_data.volume"]
                 (cljbang-org-test--tangle-targets
                  "(cljbang.org/src-blocks %S {:under \"Quadlets\"})"
                  (cljbang-org-test--fixture "server.org")))))

;;; Tables

(ert-deftest cljbang-org-test-tables-skip-pipes-in-blocks ()
  "Three org tables; the markdown table inside a src block is text."
  (should (= 3 (cljbang-org-test--eval
                "(count (cljbang.org/tables %S))"
                (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-tables-names-and-caption ()
  (should (equal ["hosts"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S) (keep :name) vec)"
                  (cljbang-org-test--fixture "tables.org"))))
  (should (equal "Where things run"
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S) (keep :caption) first)"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-tables-rows-keep-hlines ()
  ":rows is lossless: the rule is there, so a caller that cares can see it."
  (should (equal [["Host Name" "IP"] :hline ["caddy" "10.0.0.1"] ["odoo" "10.0.0.2"]]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S)
                        (filter #(= \"hosts\" (:name %%)))
                        first
                        :rows)"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-tables-formulas ()
  (should (equal ["@5$2=vsum(@2..@3)"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S)
                        (map :formulas)
                        (remove empty?)
                        first)"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-tables-under ()
  ":under narrows to the subtree, and takes the nested table with it."
  (should (= 2 (cljbang-org-test--eval
                "(count (cljbang.org/tables %S {:under \"Hosts\"}))"
                (cljbang-org-test--fixture "tables.org"))))
  (should (equal []
                 (cljbang-org-test--eval
                  "(vec (cljbang.org/tables %S {:under \"no such heading\"}))"
                  (cljbang-org-test--fixture "tables.org")))))

;;; Coercion: tables

(ert-deftest cljbang-org-test-rows-drops-hlines ()
  (should (equal [["caddy" "10.0.0.1"] ["odoo" "10.0.0.2"]]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S)
                        (filter #(= \"hosts\" (:name %%)))
                        first
                        cljbang.org/rows
                        rest
                        vec)"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-rows-shapes-agree ()
  "A table map, its :rows, and the list a :var hands over coerce alike."
  (let ((from-var '(("a" "b") hline ("1" "2")))
        (from-query (vector (vector "a" "b") :hline (vector "1" "2"))))
    (should (equal [["a" "b"] ["1" "2"]] (cljbang-org-rows from-var)))
    (should (equal [["a" "b"] ["1" "2"]] (cljbang-org-rows from-query)))))

(ert-deftest cljbang-org-test-rows-stringifies-cells ()
  "Babel hands numbers over; org tables hold text either way."
  (should (equal [["2"]] (cljbang-org-rows '((2))))))

(ert-deftest cljbang-org-test-table->maps ()
  "Header above the rule names the columns, downcased and dashed."
  (should (equal [["caddy" "10.0.0.1"] ["odoo" "10.0.0.2"]]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S)
                        (filter #(= \"hosts\" (:name %%)))
                        first
                        cljbang.org/table->maps
                        (mapv #(vector (:host-name %%) (:ip %%))))"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-table->maps-without-a-rule ()
  "No rule: the first row is the header, org's own :colnames rule."
  (should (equal ["https"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/tables %S {:under \"Ports\"})
                        first
                        cljbang.org/table->maps
                        (mapv :http))"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-test-table->maps-pads-and-names-blanks ()
  "An empty header cell keys by position; a short row pads."
  (let ((row (aref (cljbang-org-table->maps '(("a" "") hline ("1"))) 0)))
    (should (equal "1" (cljbang-get row :a)))
    (should (equal "" (cljbang-get row :col-2)))))

;;; Effects

(ert-deftest cljbang-org-test-cut-subtree-buffer-only-then-save ()
  (cljbang-org-test--with-temp-fixture file "server.org"
    ;; cut edits the buffer, not the disk
    (should (= 1 (cljbang-org-test--eval
                  "(cljbang.org/cut-subtree! %S \"aly-odoo-16-demo.container\")"
                  file)))
    (with-temp-buffer
      (insert-file-contents file)
      (should (search-forward "aly-odoo-16-demo.container" nil t)))
    ;; save persists; the heading is gone from disk and from a re-query
    (cljbang-org-test--eval "(cljbang.org/save! %S)" file)
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (search-forward "aly-odoo-16-demo.container" nil t)))
    (should (null (cljbang-org-test--heading file "aly-odoo-16-demo.container")))
    ;; idempotent: nothing left to cut
    (should (= 0 (cljbang-org-test--eval
                  "(cljbang.org/cut-subtree! %S \"aly-odoo-16-demo.container\")"
                  file)))))

(ert-deftest cljbang-org-test-revert-discards ()
  (cljbang-org-test--with-temp-fixture file "server.org"
    (cljbang-org-test--eval "(cljbang.org/cut-subtree! %S \"Demo\")" file)
    (should (null (cljbang-org-test--heading file "Demo")))
    (cljbang-org-test--eval "(cljbang.org/revert! %S)" file)
    (should (equal "Demo"
                   (cljbang-get (cljbang-org-test--heading file "Demo")
                                :title)))))

;;; Transclusion expansion

(ert-deftest cljbang-org-test-transclusion-expansion ()
  (skip-unless (require 'org-transclusion nil t))
  (cljbang-org-test--with-temp-fixture file "transcluding.org"
    (copy-file (cljbang-org-test--fixture "common.org")
               (expand-file-name "common.org"
                                 (file-name-directory file)))
    ;; without expansion, only the local block
    (should (equal ["~/.config/containers/systemd/local.container"]
                   (cljbang-org-test--tangle-targets
                    "(cljbang.org/src-blocks %S {:under \"Quadlets\"})"
                    file)))
    ;; with expansion, the transcluded block appears too
    (should (= 2 (length (cljbang-org-test--tangle-targets
                          "(cljbang.org/src-blocks
                             %S {:under \"Quadlets\"
                                 :expand-transclusions? true})"
                          file))))
    ;; and the query left the file's buffer unmodified
    (should-not (buffer-modified-p (find-buffer-visiting file)))))

;;; Coercion

(ert-deftest cljbang-org-test-lines-from-text ()
  (should (equal ["a" "b"] (cljbang-org-test--eval "(cljbang.org/lines \"a\\nb\")"))))

(ert-deftest cljbang-org-test-lines-from-vector ()
  (should (equal ["a" "b"] (cljbang-org-test--eval "(cljbang.org/lines [\"a\" \"b\"])"))))

(ert-deftest cljbang-org-test-lines-from-table ()
  "A one-column table, the shape a :var naming a shell block arrives in."
  (should (equal ["a" "b"]
                 (cljbang-org-test--eval "(cljbang.org/lines [[\"a\"] [\"b\"]])"))))

(ert-deftest cljbang-org-test-lines-drops-blanks-and-pads ()
  (should (equal ["a" "b"]
                 (cljbang-org-test--eval "(cljbang.org/lines \"a\\n\\n  b  \\n\")"))))

(ert-deftest cljbang-org-test-lines-of-nothing ()
  (should (equal [] (cljbang-org-test--eval "(cljbang.org/lines nil)")))
  (should (equal [] (cljbang-org-test--eval "(cljbang.org/lines \"\")"))))

(ert-deftest cljbang-org-test-lines-shapes-agree ()
  "Every shape the same list of names can arrive in coerces alike."
  (should (cljbang-org-test--eval
           "(apply = (map cljbang.org/lines
                          [\"caddy.service\\ndbus.service\"
                           [\"caddy.service\" \"dbus.service\"]
                           [[\"caddy.service\"] [\"dbus.service\"]]]))")))

(provide 'cljbang-org-test)
;;; cljbang-org-test.el ends here
