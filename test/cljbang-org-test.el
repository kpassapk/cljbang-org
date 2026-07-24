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
                 (cljbang-org-test--eval
                  "(:todo (cljbang.org/heading %S \"State checks\"))"
                  (cljbang-org-test--fixture "server.org"))))
  (should (= 2 (cljbang-org-test--eval
                "(:level (cljbang.org/heading %S \"caddy.container\"))"
                (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-heading-by-map-selector ()
  (should (equal "Quadlets"
                 (cljbang-org-test--eval
                  "(:title (cljbang.org/heading %S {:custom-id \"quadlets\"}))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-heading-miss-is-nil ()
  (should (null (cljbang-org-test--eval
                 "(cljbang.org/heading %S \"no such heading\")"
                 (cljbang-org-test--fixture "server.org")))))

;;; Keywords and properties

(ert-deftest cljbang-org-test-keywords ()
  (should (equal ["Test server"]
                 (cljbang-org-test--eval
                  "(:title (cljbang.org/keywords %S))"
                  (cljbang-org-test--fixture "server.org"))))
  (should (equal [".. (project)" "/ssh:app@example: (server)"]
                 (cljbang-org-test--eval
                  "(:target (cljbang.org/keywords %S))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-test-properties-and-entry-get ()
  (should (equal "quadlets"
                 (cljbang-org-test--eval
                  "(:CUSTOM_ID (cljbang.org/properties %S \"Quadlets\"))"
                  (cljbang-org-test--fixture "server.org"))))
  (should (equal "quadlets"
                 (cljbang-org-test--eval
                  "(cljbang.org/entry-get %S \"Quadlets\" :CUSTOM_ID)"
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

(ert-deftest cljbang-org-test-tangle-targets ()
  "Drops :tangle no and headerless blocks, keeps order, dedupes."
  (should (equal ["~/.config/containers/systemd/caddy.container"
                  "~/.config/containers/systemd/caddy_data.volume"]
                 (cljbang-org-test--eval
                  "(cljbang.org/tangle-targets
                     (cljbang.org/src-blocks %S {:under \"Quadlets\"}))"
                  (cljbang-org-test--fixture "server.org")))))

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
    (should (null (cljbang-org-test--eval
                   "(cljbang.org/heading %S \"aly-odoo-16-demo.container\")"
                   file)))
    ;; idempotent: nothing left to cut
    (should (= 0 (cljbang-org-test--eval
                  "(cljbang.org/cut-subtree! %S \"aly-odoo-16-demo.container\")"
                  file)))))

(ert-deftest cljbang-org-test-revert-discards ()
  (cljbang-org-test--with-temp-fixture file "server.org"
    (cljbang-org-test--eval "(cljbang.org/cut-subtree! %S \"Demo\")" file)
    (should (null (cljbang-org-test--eval
                   "(cljbang.org/heading %S \"Demo\")" file)))
    (cljbang-org-test--eval "(cljbang.org/revert! %S)" file)
    (should (equal "Demo"
                   (cljbang-org-test--eval
                    "(:title (cljbang.org/heading %S \"Demo\"))" file)))))

;;; Transclusion expansion

(ert-deftest cljbang-org-test-transclusion-expansion ()
  (skip-unless (require 'org-transclusion nil t))
  (cljbang-org-test--with-temp-fixture file "transcluding.org"
    (copy-file (cljbang-org-test--fixture "common.org")
               (expand-file-name "common.org"
                                 (file-name-directory file)))
    ;; without expansion, only the local block
    (should (equal ["~/.config/containers/systemd/local.container"]
                   (cljbang-org-test--eval
                    "(cljbang.org/tangle-targets
                       (cljbang.org/src-blocks %S {:under \"Quadlets\"}))"
                    file)))
    ;; with expansion, the transcluded block appears too
    (should (equal 2
                   (cljbang-org-test--eval
                    "(count (cljbang.org/tangle-targets
                              (cljbang.org/src-blocks
                                %S {:under \"Quadlets\"
                                    :expand-transclusions? true})))"
                    file)))
    ;; and the query left the file's buffer unmodified
    (should-not (buffer-modified-p (find-buffer-visiting file)))))

(provide 'cljbang-org-test)
;;; cljbang-org-test.el ends here
