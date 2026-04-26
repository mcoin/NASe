#!/usr/bin/env bash
# tests/run-tests.sh — run all NASe test suites.
# Usage: ./tests/run-tests.sh
# Exit 0 if all tests pass; exit 1 if any fail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OVERALL_FAIL=0

run_suite() {
    local script="$1"
    echo ""
    if bash "$script"; then
        true
    else
        OVERALL_FAIL=$(( OVERALL_FAIL + 1 ))
    fi
}

run_suite "${REPO_ROOT}/tests/validate-config.sh"
run_suite "${REPO_ROOT}/tests/test-config.sh"
run_suite "${REPO_ROOT}/tests/test-sync-guards.sh"

echo ""
if [[ $OVERALL_FAIL -eq 0 ]]; then
    echo "All test suites passed."
else
    echo "${OVERALL_FAIL} test suite(s) failed."
    exit 1
fi
