# cljbang-org
#
# `make test` runs the suite against dependencies it can fetch itself:
# cljbang.el at the tag Package-Requires names, and org-ql and
# org-transclusion from ELPA, all under .deps/.  Point CLJBANG_DIR or
# ELPA at checkouts already on the machine to use those instead, on the
# command line or in local.mk, which is yours and untracked.
#
#   make test
#   make test CLJBANG_DIR=../cljbang.el
#   make deps        # fetch without running anything
#   make clean-deps  # throw the fetched copies away

EMACS ?= emacs
CLJBANG_REF ?= v0.0.9
CLJBANG_REPO ?= https://github.com/borkdude/cljbang.el.git

-include local.mk

DEPS := $(CURDIR)/.deps
VENDORED_CLJBANG := $(DEPS)/cljbang.el
VENDORED_ELPA := $(DEPS)/elpa
ELPA_STAMP := $(DEPS)/elpa.stamp

CLJBANG_DIR ?= $(VENDORED_CLJBANG)
ELPA ?= $(VENDORED_ELPA)

# Fetch only what this file owns.  A CLJBANG_DIR or ELPA pointing
# somewhere else is the caller's to provide, so make says it is missing
# rather than cloning into it.
FETCH :=
ifeq ($(CLJBANG_DIR),$(VENDORED_CLJBANG))
FETCH += $(VENDORED_CLJBANG)
endif
ifeq ($(ELPA),$(VENDORED_ELPA))
FETCH += $(ELPA_STAMP)
endif

.PHONY: test deps clean-deps

# org-ql and org-transclusion come from ELPA when present; their tests
# skip-unless otherwise.
test: deps
	@[ -d "$(CLJBANG_DIR)" ] || { \
	  echo "no cljbang at $(CLJBANG_DIR): point CLJBANG_DIR at a checkout," >&2; \
	  echo "or leave it unset and make will fetch $(CLJBANG_REF) into .deps/" >&2; \
	  exit 1; }
	$(EMACS) -Q --batch \
	  --eval "(when (file-directory-p \"$(ELPA)\") (setq package-user-dir \"$(ELPA)\") (package-initialize))" \
	  -L . -L $(CLJBANG_DIR) -L test \
	  -l test/cljbang-org-test.el -l test/cljbang-org-ql-test.el \
	  -f ert-run-tests-batch-and-exit

deps: $(FETCH)

$(VENDORED_CLJBANG):
	git clone --depth 1 --branch $(CLJBANG_REF) $(CLJBANG_REPO) $@

# A stamp rather than the directory itself: package.el creates
# package-user-dir before it installs anything, so a half-finished
# install would otherwise look done.
$(ELPA_STAMP):
	mkdir -p $(DEPS)
	$(EMACS) -Q --batch \
	  --eval "(progn \
	            (require 'package) \
	            (setq package-user-dir \"$(VENDORED_ELPA)\") \
	            (add-to-list 'package-archives \
	                         '(\"melpa\" . \"https://melpa.org/packages/\") t) \
	            (package-initialize) \
	            (package-refresh-contents) \
	            (dolist (p '(org-ql org-transclusion)) \
	              (unless (package-installed-p p) (package-install p))))"
	touch $@

clean-deps:
	rm -rf $(DEPS)
