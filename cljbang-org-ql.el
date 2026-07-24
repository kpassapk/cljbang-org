;;; cljbang-org-ql.el --- org-ql bridge for cljbang -*- lexical-binding: t; -*-

;; Author: Kyle Passarelli
;; URL: https://github.com/kpassapk/cljbang-org

;;; Commentary:

;; The namespace cljbang.org.ql: org-ql queries that return data.
;;
;;   (require '[cljbang.org.ql :as ql])
;;   (ql/select "servers/box.org" '(and (heading "Quadlets") (level 1)))
;;
;; The query sexp goes to org-ql verbatim; the :action is always this
;; library's extractor, so results are the same heading and block maps
;; cljbang.org returns — no imperative lambda at point.

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

;;;###autoload
(defun cljbang-org-ql-src-blocks (file query &optional opts)
  "Src blocks under each heading in FILE matching the org-ql QUERY sexp.
For every match the subtree is narrowed and its blocks collected; one
flat vector of block maps.  OPTS: {:expand-transclusions? true} expands
transclusions inside each subtree before collecting, and removes them
again."
  (let ((expand (cljbang-org--opt opts :expand-transclusions?)))
    (cljbang-org--with-file file
      (apply #'vconcat
             (org-ql-select (current-buffer) query
               :action (lambda ()
                         (save-restriction
                           (org-narrow-to-subtree)
                           (cljbang-org--with-transclusions expand
                             (cljbang-org--collect-blocks)))))))))

(provide 'cljbang-org-ql)
;;; cljbang-org-ql.el ends here
