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
                          (mapv #(cljbang.org/cut-subtree! %S %%)))"
                    file file)))
    (should (null (cljbang-org-test--heading file "Demo")))))

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
