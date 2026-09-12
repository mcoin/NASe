#!/usr/bin/env bash
# tests/lib.sh — shared test harness.
# Source this file from test scripts; do not execute directly.

# ── Keep the tests out of live NASe state (backlog #35) ──────────────────────
# Running the suite used to write into /var/log/nase/nase.log and
# /var/lib/nase/, and the damage was not cosmetic: ERROR lines provoked
# deliberately by tests/test-sync-setup.sh ended up in a real emailed status
# report, and modules/drives/spin_status.sh deleting a live state file made the
# next sample record a drive wake that never happened, in the history backlog
# #4 is judged on.
#
# These are exported, which matters for two different leak modes. A suite that
# runs the code under test as a child process needs the variable inherited; a
# suite that *sources* a NASe library into its own shell — tests/test-integrity.sh
# does this with modules/integrity/common.sh — resolves these from its own
# environment, where an env-prefix on some later `bash ...` call never reaches.
# Exporting here covers both, for every suite, since all of them source this
# file before doing anything else.
#
# A suite that wants its own paths still just sets them: an `export` in the
# suite or an env-prefix at the point of invocation both take precedence.
#
# Deliberately a fixed path rather than `mktemp -d` with an EXIT trap. Bash
# traps are not additive — the suites register `trap 'rm -rf "$WORK"' EXIT`
# after sourcing this file, which would silently replace a trap set here and
# leak a directory into /tmp on every run. tests/run-tests.sh clears this at
# the start of a run instead, which also leaves it behind for inspection when
# a suite fails.
NASE_TEST_SCRATCH="${TMPDIR:-/tmp}/nase-tests"
export NASE_TEST_SCRATCH
export NAS_LOG="${NAS_LOG:-${NASE_TEST_SCRATCH}/nase.log}"
export NASE_STAMP_DIR="${NASE_STAMP_DIR:-${NASE_TEST_SCRATCH}/varlib}"
mkdir -p "$(dirname "$NAS_LOG")" "$NASE_STAMP_DIR" 2>/dev/null || true

# ── Counters (backlog #38) ───────────────────────────────────────────────────
# File-backed, not shell variables. A `( ... )` subshell gets its own copy of a
# variable, so an assertion inside one used to print FAIL and then be forgotten
# — test-integrity.sh ran 34 assertions, counted 17, and exited 0 no matter
# what the other 17 did. Subshells are used deliberately there to isolate
# sourced state, so the harness is the right place to fix this rather than
# banning the pattern.
#
# $$ is the invoking shell's PID and stays constant inside a subshell, so every
# subshell of a suite appends to the same files. Cleared on source because PIDs
# are reused, and a stale directory would otherwise seed the next run's totals.
_TESTS_COUNT_DIR="${NASE_TEST_SCRATCH}/counters.$$"
rm -rf "$_TESTS_COUNT_DIR"
mkdir -p "$_TESTS_COUNT_DIR"
export _TESTS_COUNT_DIR

# tests_record pass|fail|skip
# Record one result. Use this instead of touching a counter directly: a
# variable increment is invisible to the parent shell from inside a subshell.
tests_record() {
    printf 'x\n' >> "${_TESTS_COUNT_DIR}/$1"
}

_tests_total() {
    local f="${_TESTS_COUNT_DIR}/$1"
    if [[ -f "$f" ]]; then wc -l < "$f"; else echo 0; fi
}

# assert_eq DESCRIPTION EXPECTED ACTUAL
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        got:      $(printf '%q' "$actual")"
        tests_record fail
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
        tests_record pass
    else
        echo "  FAIL  $desc (expected exit 0, got $?)"
        tests_record fail
    fi
}

# assert_exit1 DESCRIPTION [COMMAND...]
# Run COMMAND; assert exit code is non-zero.
assert_exit1() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc (expected non-zero exit, got 0)"
        tests_record fail
    fi
}

# assert_file_exists DESCRIPTION PATH
assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc — file not found: $path"
        tests_record fail
    fi
}

# assert_file_absent DESCRIPTION PATH
assert_file_absent() {
    local desc="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc — unexpected file: $path"
        tests_record fail
    fi
}

# assert_dir_absent DESCRIPTION PATH
assert_dir_absent() {
    local desc="$1" path="$2"
    if [[ ! -d "$path" ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc — unexpected directory: $path"
        tests_record fail
    fi
}

# assert_contains DESCRIPTION NEEDLE HAYSTACK
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc"
        echo "        expected to contain: $(printf '%q' "$needle")"
        echo "        got: $(printf '%q' "$haystack")"
        tests_record fail
    fi
}

# assert_not_contains DESCRIPTION NEEDLE HAYSTACK
assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS  $desc"
        tests_record pass
    else
        echo "  FAIL  $desc"
        echo "        expected NOT to contain: $(printf '%q' "$needle")"
        tests_record fail
    fi
}

# skip DESCRIPTION REASON
skip() {
    echo "  SKIP  $1 ($2)"
    tests_record skip
}

# test_summary
# Print totals and exit 1 if any failures.
test_summary() {
    local p f s
    p=$(_tests_total pass); f=$(_tests_total fail); s=$(_tests_total skip)
    echo ""
    echo "  ${p} passed  ${f} failed  ${s} skipped"
    [[ "$f" -eq 0 ]] || exit 1
}
