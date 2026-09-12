#!/usr/bin/env bash
# tests/test-harness.sh — tests for tests/lib.sh itself (backlog #38).
#
# A test harness that miscounts is worse than no harness: it reports success
# while assertions fail underneath it. That is not hypothetical here —
# test-integrity.sh ran 34 assertions and counted 17, because the counters were
# shell variables and a `( ... )` subshell increments its own copy. Seventeen
# assertions could have failed and the suite would still have exited 0.
#
# Each case runs a throwaway suite as a *child process*, so it gets its own
# counter directory, and then asserts on what that child reported and what it
# exited with. Asserting on the exit code is the point: printing FAIL while
# exiting 0 is precisely the bug.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== tests/lib.sh ==="
echo ""

WORK=$(mktemp -d /tmp/nase-test-harness.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# run_child <body> — run a throwaway suite, capture output and exit code.
# Sets CHILD_OUT and CHILD_RC.
run_child() {
    local body="$1" script="${WORK}/child.sh"
    {
        echo "source ${REPO_ROOT}/tests/lib.sh"
        echo "$body"
        echo "test_summary"
    } > "$script"
    CHILD_OUT=$(bash "$script" 2>&1)
    CHILD_RC=$?
}

# ── The regression this file exists for ──────────────────────────────────────
run_child '( assert_eq "fails inside a subshell" "expected" "actual" )'
assert_contains "a failure inside a subshell is counted" \
    "0 passed  1 failed" "$CHILD_OUT"
assert_eq "and fails the suite" "1" "$CHILD_RC"

run_child '( assert_eq "passes inside a subshell" "x" "x" )'
assert_contains "a pass inside a subshell is counted" \
    "1 passed  0 failed" "$CHILD_OUT"
assert_eq "and the suite still succeeds" "0" "$CHILD_RC"

# Nested, because isolating sourced state sometimes means more than one level.
run_child '( ( assert_eq "fails two levels down" "a" "b" ) )'
assert_contains "a failure nested two subshells deep is counted" \
    "0 passed  1 failed" "$CHILD_OUT"
assert_eq "and still fails the suite" "1" "$CHILD_RC"

# A command substitution is also a subshell, and an easy one to write by
# accident — e.g. wrapping a helper that asserts as it goes.
run_child 'out=$( assert_eq "fails in a command substitution" "a" "b" ); :'
assert_contains "a failure in a command substitution is counted" \
    "0 passed  1 failed" "$CHILD_OUT"
assert_eq "and fails the suite too" "1" "$CHILD_RC"

# ── Ordinary counting still works ────────────────────────────────────────────
run_child '
assert_eq "one"   "a" "a"
assert_eq "two"   "b" "b"
assert_eq "three" "c" "d"
skip "four" "not applicable"'
assert_contains "parent-shell results are tallied" \
    "2 passed  1 failed  1 skipped" "$CHILD_OUT"

run_child 'assert_eq "all good" "a" "a"'
assert_contains "a clean suite reports no failures" "1 passed  0 failed" "$CHILD_OUT"
assert_eq "and exits 0" "0" "$CHILD_RC"

# ── Counts must not leak between runs ────────────────────────────────────────
# The counter directory is keyed on the shell's PID and PIDs get reused, so a
# stale directory would otherwise seed a later run's totals with a previous
# one's — including its failures.
run_child 'assert_eq "first run" "a" "a"'
first="$CHILD_OUT"
run_child 'assert_eq "second run" "a" "a"'
assert_contains "a fresh run starts from zero" "1 passed  0 failed" "$CHILD_OUT"
assert_contains "and so did the one before it" "1 passed  0 failed" "$first"

# ── The suites must not reach for the counters directly ──────────────────────
# A raw increment works in the parent shell and is silently lost in a subshell,
# which is exactly how this bug survived. tests_record is the supported route.
# Excluding this file, which necessarily names them to check for them.
direct=$(grep -rln 'TESTS_PASS\|TESTS_FAIL\|TESTS_SKIP' "${REPO_ROOT}/tests" 2>/dev/null \
         | grep -v '/test-harness\.sh$' || true)
assert_empty "no suite manipulates the counters directly" "$direct"

test_summary
