#!/bin/bash
#
# tests/run-tests.sh — blacklight smoke test runner (batsman wrapper)
# Usage: ./tests/run-tests.sh [--os OS] [--parallel [N]] [bats args...]
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BATSMAN_PROJECT="blacklight"
BATSMAN_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BATSMAN_TESTS_DIR="$SCRIPT_DIR"
BATSMAN_INFRA_DIR="$SCRIPT_DIR/infra"
BATSMAN_DOCKER_FLAGS=""                  # blacklight is unprivileged — no --privileged
BATSMAN_DEFAULT_OS="debian12"
BATSMAN_CONTAINER_TEST_PATH="/opt/tests"
BATSMAN_SUPPORTED_OS="debian12 rocky9 ubuntu2404 centos7 rocky8 ubuntu2004 rocky10 centos6"
BATSMAN_TEST_TIMEOUT="${BATSMAN_TEST_TIMEOUT:-120}"

source "$BATSMAN_INFRA_DIR/lib/run-tests-core.sh"
batsman_run "$@"
