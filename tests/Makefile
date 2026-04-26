# tests/Makefile — blacklight test harness (wraps batsman)
BATSMAN_PROJECT   := blacklight
BATSMAN_OS_MODERN := debian12 rocky9 ubuntu2404
BATSMAN_OS_LEGACY := centos7 rocky8 ubuntu2004
BATSMAN_OS_EXTRA  := rocky10
BATSMAN_OS_DEEP   := centos6
BATSMAN_OS_ALL    := $(BATSMAN_OS_MODERN) $(BATSMAN_OS_LEGACY) $(BATSMAN_OS_EXTRA) $(BATSMAN_OS_DEEP)
BATSMAN_RUN_TESTS := ./run-tests.sh
PARALLEL_JOBS     := 3

include infra/include/Makefile.tests

# M5.5: drift-guard prerequisite. `make bl-check` (root Makefile) fails if
# src/bl.d/*.sh parts drifted from committed bl. Runs BEFORE batsman's
# container build so drift is caught fast. Post-include so this augments
# (not replaces) the include's test / test-rocky9 / test-all targets.
test test-rocky9 test-all test-quick: _bl-drift-check

.PHONY: _bl-drift-check
_bl-drift-check:
	@$(MAKE) --no-print-directory -C .. bl-check

# Rapid-iteration target — smoke + CLI surface only (19 tests, single container).
# Inner loop for src/bl.d edits while CLAUDE.md "Development mode" banner is set.
# Promote to `make test` (debian12) + `make test-rocky9` before commit when the
# dev-mode banner is removed.
test-quick:
	$(BATSMAN_RUN_TESTS) -- /opt/tests/00-smoke.bats /opt/tests/01-cli-surface.bats /opt/tests/skill-routing/smoke.bats

# M13 P4: standalone target — run routing-Skill structural tests only.
# Use during inner-loop iteration on routing-skills/ content.
test-skill-routing-smoke:
	$(BATSMAN_RUN_TESTS) -- /opt/tests/skill-routing/smoke.bats

# M13 P11: live promotion eval gate — opt-in only (BL_EVAL_LIVE=1 required).
# NOT wired into test / test-quick / test-rocky9 / test-all — operator-triggered.
# Usage: BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=... make -C tests test-skill-routing-eval
test-skill-routing-eval:
	$(BATSMAN_RUN_TESTS) -- /opt/tests/skill-routing/eval-runner.bats
