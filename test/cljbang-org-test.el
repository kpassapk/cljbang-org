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

(ert-deftest cljbang-org-test-headings-planning ()
  (let ((steps (cljbang-org-test--heading
                (cljbang-org-test--fixture "runnable.org") "Steps")))
    (should (equal "<2026-01-01 Thu>" (cljbang-get steps :scheduled)))
    (should (equal "<2026-02-01 Sun>" (cljbang-get steps :deadline)))
    (should (null (cljbang-get steps :body)))))

(ert-deftest cljbang-org-test-headings-body ()
  ":body is the heading's own text: no planning line, no drawer, and
nothing belonging to a subheading."
  (should (equal ["The steps that run.\n\n#+name: greet\n#+begin_src sh :results output\necho hello\n#+end_src"
                  "#+begin_src sh :results output\necho second\n#+end_src\n\n#+call: greet()"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S {:body? true})
                        (keep :body)
                        (take 2)
                        vec)"
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-test-headings-body-of-an-empty-entry ()
  "An entry with no text of its own does not take the next heading's:
skipping the meta data of an empty entry lands on that heading."
  (should (equal [nil "text"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S {:body? true})
                        (filter #(#{\"Empty\" \"After the empty one\"} (:title %%)))
                        (mapv :body))"
                  (cljbang-org-test--fixture "runnable.org")))))

;;; Tree

(ert-deftest cljbang-org-test-tree-nests-by-level ()
  (should (equal [["Quadlets" ["caddy.container" "caddy_data.volume" "notes"]]
                  ["Demo" ["aly-odoo-16-demo.container"]]
                  ["State checks" []]]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S)
                        cljbang.org/tree
                        (mapv #(vector (:title %%) (mapv :title (:children %%)))))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-tree-leaves-and-input ()
  "A leaf's :children is empty rather than missing, and the headings
handed in keep none of it."
  (let* ((headings (cljbang-org-headings
                    (cljbang-org-test--fixture "server.org")))
         (roots (cljbang-org-tree headings)))
    (should (equal [] (cljbang-get (aref (cljbang-get (aref roots 0) :children) 0)
                                   :children)))
    (should (null (cljbang-get (aref headings 0) :children)))))

(ert-deftest cljbang-org-test-tree-of-a-query ()
  "Anything with a :level nests, so a filtered outline does too."
  (should (equal ["Quadlets" "Demo" "State checks"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/headings %S)
                        (filter #(= 1 (:level %%)))
                        cljbang.org/tree
                        (mapv :title))"
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

;;; Call lines

(ert-deftest cljbang-org-test-call-blocks ()
  (should (equal [["greet" "greet()"]]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/call-blocks %S)
                        (mapv #(vector (:call %%) (:value %%))))"
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-test-call-blocks-under ()
  (should (= 1 (cljbang-org-test--eval
                "(count (cljbang.org/call-blocks %S {:under \"Steps\"}))"
                (cljbang-org-test--fixture "runnable.org"))))
  (should (equal []
                 (cljbang-org-test--eval
                  "(vec (cljbang.org/call-blocks %S {:under \"Failing\"}))"
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-test-runnable-index-is-shared ()
  "Src blocks and call lines are numbered together, so merging them
gives every runnable step of the file in order."
  (should (equal [[:src 0] [:src 1] [:call 2] [:src 3]]
                 (cljbang-org-test--eval
                  "(->> (concat (cljbang.org/src-blocks %S)
                                (cljbang.org/call-blocks %S))
                        (sort-by :index)
                        (mapv #(vector (:type %%) (:index %%))))"
                  (cljbang-org-test--fixture "runnable.org")
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-test-index-counts-the-file-not-the-result ()
  ":under narrows what comes back, never how the blocks are numbered."
  (should (equal [3]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org/src-blocks %S {:under \"Failing\"})
                        (mapv :index))"
                  (cljbang-org-test--fixture "runnable.org")))))

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

;;; Executing a block

(ert-deftest cljbang-org-test-execute-by-name ()
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (should (equal "hello\n"
                   (cljbang-org-test--eval
                    "(cljbang.org/execute! %S \"greet\")" file)))))

(ert-deftest cljbang-org-test-execute-by-index ()
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (should (equal "second\n"
                   (cljbang-org-test--eval
                    "(cljbang.org/execute! %S {:index 1})" file)))))

(ert-deftest cljbang-org-test-execute-a-call-line ()
  "A `#+call:' line runs the block it names and hands back its result,
which is the whole reason `call-blocks' exists next to `src-blocks'."
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (should (equal "hello\n"
                   (cljbang-org-test--eval
                    "(->> (cljbang.org/call-blocks %S)
                          first
                          (cljbang.org/execute! %S))"
                    file file)))))

(ert-deftest cljbang-org-test-execute-a-block-map ()
  "A block map is a selector: its :name when it has one, else its :index."
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (should (equal "hello\n"
                   (cljbang-org-test--eval
                    "(->> (cljbang.org/src-blocks %S)
                          first
                          (cljbang.org/execute! %S))"
                    file file)))
    (should (equal "second\n"
                   (cljbang-org-test--eval
                    "(->> (cljbang.org/src-blocks %S)
                          second
                          (cljbang.org/execute! %S))"
                    file file)))))

(ert-deftest cljbang-org-test-execute-the-only-block ()
  (cljbang-org-test--with-temp-fixture file "single.org"
    (should (equal "only\n"
                   (cljbang-org-test--eval "(cljbang.org/execute! %S)" file)))))

(ert-deftest cljbang-org-test-execute-index-outlives-results ()
  "The point of numbering rather than pointing: a block that writes
its results back moves every position after it, and the indices stay."
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (let ((begins (lambda ()
                    (cljbang-org-test--eval
                     "(->> (cljbang.org/src-blocks %S) (mapv :begin))" file)))
          (indices (lambda ()
                     (cljbang-org-test--eval
                      "(->> (cljbang.org/src-blocks %S) (mapv :index))" file))))
      (let ((before (funcall begins)))
        (cljbang-org-test--eval "(cljbang.org/execute! %S {:index 0})" file)
        (should-not (equal before (funcall begins)))
        (should (equal [0 1 3] (funcall indices)))
        (should (equal "second\n"
                       (cljbang-org-test--eval
                        "(cljbang.org/execute! %S {:index 1})" file)))))))

(ert-deftest cljbang-org-test-execute-writes-to-the-buffer-then-saves ()
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (cljbang-org-test--eval "(cljbang.org/execute! %S \"greet\")" file)
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (search-forward "#+RESULTS" nil t)))
    (cljbang-org-test--eval "(cljbang.org/save! %S)" file)
    (with-temp-buffer
      (insert-file-contents file)
      (should (search-forward "#+RESULTS" nil t)))))

(ert-deftest cljbang-org-test-execute-failure-raises ()
  "org-babel would pop a buffer and return the partial output; a
caller gets the exit code and stderr as an error instead."
  (cljbang-org-test--with-temp-fixture file "runnable.org"
    (let ((err (should-error
                (cljbang-org-test--eval
                 "(cljbang.org/execute! %S {:index 3})" file))))
      (should (string-match-p "code 3" (error-message-string err)))
      (should (string-match-p "to-stderr" (error-message-string err))))))

(ert-deftest cljbang-org-test-execute-bad-selectors ()
  (let ((file (cljbang-org-test--fixture "runnable.org")))
    ;; more than one block and nothing said which
    (should-error (cljbang-org-test--eval "(cljbang.org/execute! %S)" file))
    (should-error (cljbang-org-test--eval
                   "(cljbang.org/execute! %S {:index 99})" file))
    (should-error (cljbang-org-test--eval
                   "(cljbang.org/execute! %S \"no such block\")" file))))

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
