;;; cljbang-org-ql.el --- org-ql bridge for cljbang -*- lexical-binding: t; -*-

;; Author: Kyle Passarelli
;; URL: https://github.com/kpassapk/cljbang-org
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org-ql "0.7") (cljbang "0.0.9"))
;; Keywords: outlines, languages

;;; Commentary:

;; The namespace cljbang.org.ql: org-ql queries that return data.
;;
;;   (require '[cljbang.org.ql :as ql])
;;   (ql/select "servers/box.org" '(and (heading "Quadlets") (level 1)))
;;
;; The query sexp goes to org-ql verbatim; the :action is always this
;; library's extractor, so results are the same heading, block and
;; table maps cljbang.org returns — no imperative lambda at point.
;;
;; This is the search half of the API, and the only reason cljbang.org
;; itself has no query language: a selector there names one heading you
;; already mean, an org-ql sexp here describes headings you are looking
;; for.  The two meet in the heading map, which `select' returns and
;; cljbang.org's effects accept as a selector.

;;; Code:

(require 'org-ql)
(require 'cljbang-org)

;;;###autoload
(defun cljbang-org-ql-select (file query &optional opts)
  "Headings in FILE matching the org-ql QUERY sexp, as heading maps.
OPTS: {:expand-transclusions? true} to query transcluded content too."
  (cljbang-org--with-file file
    (cljbang-org--with-transclusions
        (cljbang-org--opt opts :expand-transclusions?)
      (apply #'vector
             (org-ql-select (current-buffer) query
               :action #'cljbang-org--heading-at-point)))))

(defun cljbang-org-ql--under (file query opts collect)
  "COLLECT under each heading in FILE matching the org-ql QUERY sexp.
For every match the subtree is narrowed and COLLECT called with no
arguments; the vectors it returns concatenate in file order.  OPTS:
{:expand-transclusions? true} expands transclusions inside each subtree
before collecting, and removes them again.

This is `cljbang-org--scan' with an org-ql query where its :under
selector would be: one heading you already mean becomes every heading
matching a search, and the collector does not know the difference."
  (let ((expand (cljbang-org--opt opts :expand-transclusions?)))
    (cljbang-org--with-file file
      (apply #'vconcat
             (org-ql-select (current-buffer) query
               :action (lambda ()
                         (save-restriction
                           (org-narrow-to-subtree)
                           (cljbang-org--with-transclusions expand
                             (funcall collect)))))))))

;;;###autoload
(defun cljbang-org-ql-src-blocks (file query &optional opts)
  "Src blocks under each heading in FILE matching the org-ql QUERY sexp.
For every match the subtree is narrowed and its blocks collected; one
flat vector of block maps.  OPTS: {:expand-transclusions? true} expands
transclusions inside each subtree before collecting, and removes them
again."
  (cljbang-org-ql--under file query opts #'cljbang-org--collect-blocks))

;;;###autoload
(defun cljbang-org-ql-tables (file query &optional opts)
  "Org tables under each heading in FILE matching the org-ql QUERY sexp.
For every match the subtree is narrowed and its tables collected; one
flat vector of table maps.  OPTS: {:expand-transclusions? true} expands
transclusions inside each subtree before collecting, and removes them
again."
  (cljbang-org-ql--under file query opts #'cljbang-org--collect-tables))

(provide 'cljbang-org-ql)
;;; cljbang-org-ql.el ends here
