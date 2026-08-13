#!/usr/bin/env bash
# tests/test-calendar.sh — unit tests for lib/calendar.sh.
#
# The helper answers "does this systemd calendar expression fire on this day?",
# which is what pins a job's forced sync to a chosen day (backlog #3). Every
# case is asserted against a fixed date, so the results do not depend on when
# the suite runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/calendar.sh"

echo "=== lib/calendar.sh ==="
echo ""

if ! command -v systemd-analyze &>/dev/null; then
    skip "all calendar tests" "systemd-analyze not found"
    test_summary
    exit 0
fi

# assert_matches SPEC DAY  — the spec must fire on that day
assert_matches() {
    local spec="$1" day="$2"
    if calendar_matches_day "$spec" "$day"; then
        echo "  PASS  '$spec' fires on $day"
        (( TESTS_PASS++ )) || true
    else
        echo "  FAIL  '$spec' should fire on $day but did not"
        (( TESTS_FAIL++ )) || true
    fi
}

# assert_no_match SPEC DAY — the spec must not fire on that day
assert_no_match() {
    local spec="$1" day="$2"
    if calendar_matches_day "$spec" "$day"; then
        echo "  FAIL  '$spec' should not fire on $day but did"
        (( TESTS_FAIL++ )) || true
    else
        echo "  PASS  '$spec' does not fire on $day"
        (( TESTS_PASS++ )) || true
    fi
}

# Reference dates (verified with `date -d <day> +%A`):
#   2026-08-13 Thursday      2026-08-14 Friday
#   2026-08-06 Thursday (1st Thursday of August 2026)
#   2026-08-20 Thursday (3rd Thursday)
#   2026-09-01 Tuesday  (1st of the month)

# ── Weekly pin ────────────────────────────────────────────────────────────────
assert_matches  "Thu" 2026-08-13
assert_no_match "Thu" 2026-08-14
assert_matches  "Sun" 2026-08-16
assert_no_match "Sun" 2026-08-13

# ── Monthly pin (first Thursday) ──────────────────────────────────────────────
assert_matches  "Thu *-*-1..7" 2026-08-06
assert_no_match "Thu *-*-1..7" 2026-08-13
assert_no_match "Thu *-*-1..7" 2026-08-20

# ── Day-of-month pin ──────────────────────────────────────────────────────────
assert_matches  "*-*-01" 2026-09-01
assert_no_match "*-*-01" 2026-09-02

# ── A spec carrying a time of day still matches on its day ────────────────────
# The job's own timer decides the hour; the pin only answers "which day".
assert_matches  "Thu *-*-* 03:00:00" 2026-08-13
assert_no_match "Thu *-*-* 03:00:00" 2026-08-14

# ── Boundary: the day the spec fires at midnight ──────────────────────────────
# Regression guard for the base-time off-by-one — with --base-time at midnight
# rather than one second before it, systemd answers with the *next* occurrence
# and a weekly pin would never match its own day.
assert_matches "Thu *-*-* 00:00:00" 2026-08-13

# ── Daily spec fires every day ────────────────────────────────────────────────
assert_matches "daily" 2026-08-13
assert_matches "daily" 2026-08-14

# ── Invalid and empty input ───────────────────────────────────────────────────
assert_no_match "Nonesuch" 2026-08-13
assert_no_match ""         2026-08-13

if calendar_spec_valid "Thu"; then
    echo "  PASS  calendar_spec_valid accepts 'Thu'"
    (( TESTS_PASS++ )) || true
else
    echo "  FAIL  calendar_spec_valid rejected 'Thu'"
    (( TESTS_FAIL++ )) || true
fi

if calendar_spec_valid "Thu *-*-1..7 03:00:00"; then
    echo "  PASS  calendar_spec_valid accepts a monthly spec"
    (( TESTS_PASS++ )) || true
else
    echo "  FAIL  calendar_spec_valid rejected a monthly spec"
    (( TESTS_FAIL++ )) || true
fi

if calendar_spec_valid "Thurs-day"; then
    echo "  FAIL  calendar_spec_valid accepted a typo'd spec"
    (( TESTS_FAIL++ )) || true
else
    echo "  PASS  calendar_spec_valid rejects a typo'd spec"
    (( TESTS_PASS++ )) || true
fi

test_summary
