;;; cljbang-org-ql-test.el --- Tests for cljbang-org-ql -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cljbang)
(require 'cljbang-org)
(require 'cljbang-org-test)

(ert-deftest cljbang-org-ql-test-select ()
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (equal ["Quadlets"]
                 (cljbang-org-test--eval
                  "(mapv :title
                     (cljbang.org.ql/select %S '(and (heading \"Quadlets\") (level 1))))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-ql-test-src-blocks ()
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (equal ["~/.config/containers/systemd/caddy.container"
                  "~/.config/containers/systemd/caddy_data.volume"]
                 (cljbang-org-test--tangle-targets
                  "(cljbang.org.ql/src-blocks
                     %S '(and (heading \"Quadlets\") (level 1)))"
                  (cljbang-org-test--fixture "server.org")))))

(ert-deftest cljbang-org-ql-test-select-body ()
  "The query opts cljbang.org takes, org-ql takes too."
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (equal ["The steps that run."]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org.ql/select %S '(heading \"Steps\") {:body? true})
                        (mapv #(first (cljbang.org/lines (:body %%)))))"
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-ql-test-call-blocks ()
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (equal ["greet"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org.ql/call-blocks %S '(heading \"Steps\"))
                        (mapv :call))"
                  (cljbang-org-test--fixture "runnable.org")))))

(ert-deftest cljbang-org-ql-test-tables ()
  "One subtree, its nested table included; the maps are cljbang.org's."
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (= 2 (cljbang-org-test--eval
                "(count (cljbang.org.ql/tables %S '(heading \"Hosts\")))"
                (cljbang-org-test--fixture "tables.org"))))
  (should (equal ["hosts"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org.ql/tables %S '(heading \"Hosts\"))
                        (keep :name) vec)"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-ql-test-tables-every-match ()
  "Every matching subtree contributes, in file order, one flat vector."
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (should (equal ["Host Name" "80" "item"]
                 (cljbang-org-test--eval
                  "(->> (cljbang.org.ql/tables
                          %S '(or (heading \"Hosts\") (heading \"Totals\")))
                        (mapv #(-> %% cljbang.org/rows first first)))"
                  (cljbang-org-test--fixture "tables.org")))))

(ert-deftest cljbang-org-ql-test-select-result-is-a-selector ()
  "The hinge between the two packages: org-ql searches, and every
heading map it returns is a selector cljbang.org's effects accept."
  (skip-unless (require 'org-ql nil t))
  (require 'cljbang-org-ql)
  (cljbang-org-test--with-temp-fixture file "server.org"
    (should (equal [1]
                   (cljbang-org-test--eval
                    "(->> (cljbang.org.ql/select
                            %S '(and (level 1) (tags \"project\")))
                          (mapv #(cljbang.org/set-property!
                                   %S %% :reviewed \"yes\")))"
                    file file)))
    (should (equal "yes"
                   (cljbang-get (cljbang-get (cljbang-org-test--heading
                                              file "Demo")
                                             :properties)
                                :REVIEWED)))))

(ert-deftest cljbang-org-ql-test-src-blocks-transcluded ()
  "The migration composite: ql match, narrow, expand, collect."
  (skip-unless (and (require 'org-ql nil t)
                    (require 'org-transclusion nil t)))
  (require 'cljbang-org-ql)
  (cljbang-org-test--with-temp-fixture file "transcluding.org"
    (copy-file (cljbang-org-test--fixture "common.org")
               (expand-file-name "common.org" (file-name-directory file)))
    (should (= 2 (length (cljbang-org-test--tangle-targets
                          "(cljbang.org.ql/src-blocks
                             %S '(and (heading \"Quadlets\") (level 1))
                             {:expand-transclusions? true})"
                          file))))))

(provide 'cljbang-org-ql-test)
;;; cljbang-org-ql-test.el ends here
