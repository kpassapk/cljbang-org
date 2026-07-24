CLJBANG_DIR ?= ../cljbang.el
ELPA ?= $(HOME)/dotfiles/emacs/tikal2601/elpa
EMACS ?= emacs

# org-ql and org-transclusion come from ELPA when present; their tests
# skip-unless otherwise.
test:
	$(EMACS) -Q --batch \
	  --eval "(when (file-directory-p \"$(ELPA)\") (setq package-user-dir \"$(ELPA)\") (package-initialize))" \
	  -L . -L $(CLJBANG_DIR) -L test \
	  -l test/cljbang-org-test.el -l test/cljbang-org-ql-test.el \
	  -f ert-run-tests-batch-and-exit

.PHONY: test
