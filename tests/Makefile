# tests/Makefile — blacklight test harness (wraps batsman)
BATSMAN_PROJECT   := blacklight
BATSMAN_OS_MODERN := debian12 rocky9 ubuntu2404
BATSMAN_OS_LEGACY := centos7 rocky8 ubuntu2004
BATSMAN_OS_EXTRA  := rocky10
BATSMAN_OS_ALL    := $(BATSMAN_OS_MODERN) $(BATSMAN_OS_LEGACY) $(BATSMAN_OS_EXTRA)
BATSMAN_RUN_TESTS := ./run-tests.sh
PARALLEL_JOBS     := 3

include infra/include/Makefile.tests
