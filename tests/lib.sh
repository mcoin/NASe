#!/usr/bin/env bash
# tests/lib.sh — shared test harness.
# Source this file from test scripts; do not execute directly.

TESTS_PASS=0
TESTS_FAIL=0
TESTS_SKIP=0

# assert_eq DESCRIPTION EXPECTED ACTUAL
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $desc"
        (( TESTS_PASS++ )) || true
    else
        echo "  FAIL  $desc"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        got:      $(printf '%q' "$actual")"
        (( TESTS_FAIL++ )) || true
    fi
}

# assert_empty DESCRIPTION ACTUAL
assert_empty() {
    local desc="$1" actual="$2"
    assert_eq "$desc" "" "$actual"
}

# assert_exit0 DESCRIPTION [COMMAND...]
# Run COMMAND; assert exit code is 0.
assert_exit0() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        echo "  PASS  $desc"
        (( TESTS_PASS++ )) || true
    else
        echo "  FAIL  $desc (expected exit 0, got $?)"
        (( TESTS_FAIL++ )) || true
    fi
}

# assert_exit1 DESCRIPTION [COMMAND...]
# Run COMMAND; assert exit code is non-zero.
assert_exit1() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        echo "  PASS  $desc"
        (( TESTS_PASS++ )) || true
    else
        echo "  FAIL  $desc (expected non-zero exit, got 0)"
        (( TESTS_FAIL++ )) || true
    fi
}

# skip DESCRIPTION REASON
skip() {
    echo "  SKIP  $1 ($2)"
    (( TESTS_SKIP++ )) || true
}

# test_summary
# Print totals and exit 1 if any failures.
test_summary() {
    echo ""
    echo "  ${TESTS_PASS} passed  ${TESTS_FAIL} failed  ${TESTS_SKIP} skipped"
    [[ $TESTS_FAIL -eq 0 ]] || exit 1
}
