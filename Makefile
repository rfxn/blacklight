# blacklight top-level Makefile
#
# `bl` at repo root is the shipping artifact — curl-fetched by install.sh,
# installed to /usr/local/bin/bl. It is a GENERATED file.
#
# Source of truth: src/bl.d/NN-*.sh (numeric-sort concat order).
# Workflow: edit src/bl.d/NN-*.sh -> make bl -> commit BOTH the part and the
# regenerated bl. See CLAUDE.md "bl source layout" rule and PLAN.md M5.5.
#
# Targets:
#   bl         assemble src/bl.d/*.sh into ./bl (chmod +x)
#   bl-check   fail if committed bl drifts from src/bl.d/ assembly output
#   bl-lint    bash -n + shellcheck on the assembled bl
#   test       delegate to tests/Makefile (debian12 default)
#   test-rocky9, test-all  delegate likewise

BL_PARTS := $(sort $(wildcard src/bl.d/[0-9]*.sh))

.PHONY: bl bl-check bl-lint test test-rocky9 test-all skills-corpus skills-corpus-clean skills-corpus-check

bl: scripts/assemble-bl.sh $(BL_PARTS)
	@test -n "$(BL_PARTS)" || { \
	  echo "bl: no src/bl.d/[0-9]*.sh parts found (pre-M5.5)" >&2; \
	  exit 1; }
	@./scripts/assemble-bl.sh > bl.tmp && mv bl.tmp bl && chmod +x bl
	@echo "bl: assembled from $(words $(BL_PARTS)) parts"

bl-check: skills-corpus-check
	@set -e; \
	test -f bl || { echo "bl-check: bl missing — run 'make bl'" >&2; exit 1; }; \
	if [ -z "$(BL_PARTS)" ]; then \
	  echo "bl-check: src/bl.d/ not populated yet (pre-M5.5) — skipping drift check"; \
	  exit 0; \
	fi; \
	./scripts/assemble-bl.sh | diff -q - bl >/dev/null 2>&1 || { \
	  echo "bl-check: src/bl.d/ parts drifted from bl — run 'make bl' and re-commit" >&2; \
	  exit 1; }; \
	echo "bl-check: in sync"

bl-lint:
	@test -f bl || { echo "bl-lint: bl missing" >&2; exit 1; }
	@bash -n bl
	@command -v shellcheck >/dev/null || { \
	  echo "bl-lint: shellcheck missing — install ShellCheck to lint" >&2; exit 1; }
	@shellcheck bl
	@echo "bl-lint: clean"

skills-corpus:
	@./scripts/build-skills-corpus.sh

skills-corpus-clean:
	@rm -f skills-corpus/*.md
	@echo "skills-corpus-clean: removed skills-corpus/*.md"

skills-corpus-check:
	@set -e; \
	test -d skills-corpus || { echo "skills-corpus-check: skills-corpus/ missing — run 'make skills-corpus'" >&2; exit 1; }; \
	tmp_dir=$$(mktemp -d); \
	CORPUS_DIR=$$tmp_dir ./scripts/build-skills-corpus.sh >/dev/null; \
	for f in $$tmp_dir/*.md; do \
	  diff -q "$$f" "skills-corpus/$$(basename $$f)" >/dev/null 2>&1 || { \
	    echo "skills-corpus-check: drift in $$(basename $$f) — run 'make skills-corpus' and re-commit" >&2; \
	    rm -rf "$$tmp_dir"; \
	    exit 1; }; \
	done; \
	rm -rf "$$tmp_dir"; \
	echo "skills-corpus-check: in sync"

test test-rocky9 test-all:
	@$(MAKE) -C tests $@

.PHONY: live-trace live-trace-grade

live-trace:
	@bash tests/live/trace-runner.sh

live-trace-grade:
	@test -n "$(EVIDENCE)" || { echo 'usage: make live-trace-grade EVIDENCE=path' >&2; exit 64; }
	@bash tests/live/trace-grader.sh $(EVIDENCE)
