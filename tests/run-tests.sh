#!/usr/bin/env bash
# tests/run-tests.sh — run all NASe test suites.
# Usage: ./tests/run-tests.sh
# Exit 0 if all tests pass; exit 1 if any fail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OVERALL_FAIL=0

# Scratch state for the whole run (backlog #35). tests/lib.sh points NAS_LOG
# and NASE_STAMP_DIR here by default; clearing it up front keeps one run's
# leftovers from being mistaken for the next run's output. Not cleared
# afterwards on purpose — after a failure it is the first thing worth reading.
NASE_TEST_SCRATCH="${TMPDIR:-/tmp}/nase-tests"
rm -rf "$NASE_TEST_SCRATCH"
mkdir -p "$NASE_TEST_SCRATCH/varlib"
export NASE_TEST_SCRATCH

# Exported here as well as in tests/lib.sh, and not redundantly: not everything
# this runner invokes is a suite that sources lib.sh. tests/validate-config.sh
# sources lib/log.sh directly, so it kept writing "Validating config.yaml" into
# the live log until these were set at the runner level. Anything added to the
# list below is covered from the start, whether it uses the harness or not.
export NAS_LOG="${NASE_TEST_SCRATCH}/nase.log"
export NASE_STAMP_DIR="${NASE_TEST_SCRATCH}/varlib"

# The live paths the suites must not touch. The log's current length is
# recorded so the check at the end only ever looks at lines this run appended —
# historical entries (including the ones that opened #35) must not make it
# fail forever, and a rotation mid-run just makes the check a no-op.
# Overridable so the guard itself can be tested against fakes — pointing these
# at a scratch copy is the only way to prove it still fires without writing the
# very pollution it exists to catch into the real files.
LIVE_LOG="${NASE_LIVE_LOG:-/var/log/nase/nase.log}"
LIVE_STATE="${NASE_LIVE_STATE:-/var/lib/nase}"
LIVE_LOG_LINES=$(wc -l < "$LIVE_LOG" 2>/dev/null || echo 0)

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
run_suite "${REPO_ROOT}/tests/test-calendar.sh"
run_suite "${REPO_ROOT}/tests/test-spindown.sh"
run_suite "${REPO_ROOT}/tests/test-teardown.sh"
run_suite "${REPO_ROOT}/tests/test-prune-mount-units.sh"
run_suite "${REPO_ROOT}/tests/test-config-archive.sh"
run_suite "${REPO_ROOT}/tests/test-sync-guards.sh"
run_suite "${REPO_ROOT}/tests/test-samba.sh"
run_suite "${REPO_ROOT}/tests/test-sync-setup.sh"
run_suite "${REPO_ROOT}/tests/test-sync-group.sh"
run_suite "${REPO_ROOT}/tests/test-status-report.sh"
run_suite "${REPO_ROOT}/tests/test-notify.sh"
run_suite "${REPO_ROOT}/tests/test-integrity.sh"
run_suite "${REPO_ROOT}/tests/integration/test-sync.sh"
run_suite "${REPO_ROOT}/tests/web/run.sh"

# ── Did the run touch live state? (backlog #35) ──────────────────────────────
# Deliberately not "did nase.log grow": nase-spin-sample.timer fires every five
# minutes and nase-config-archive.timer daily, so real NASe activity can append
# to the log or write under /var/lib/nase while the suite runs, and a size or
# line-count check would fail for reasons that have nothing to do with the
# tests. These look for fingerprints only a test could have left.
echo ""
LEAKED=0

# The canary: tests/test-sync-setup.sh provokes this guard deliberately to
# assert it fires. Two of these lines reached a real emailed status report,
# which is what opened #35. Only lines appended during this run are examined.
NEW_LOG_LINES=$(tail -n "+$(( LIVE_LOG_LINES + 1 ))" "$LIVE_LOG" 2>/dev/null || true)
if grep -q "that both map to group" <<< "$NEW_LOG_LINES"; then
    echo "LEAK: test fixture output was appended to ${LIVE_LOG}"
    grep "that both map to group" <<< "$NEW_LOG_LINES" | tail -3 | sed 's/^/      /'
    LEAKED=1
fi

# Anything a suite created under the live state directory names itself after
# its own temp working directory.
if compgen -G "${LIVE_STATE}/**/tmp-nase-test-*" >/dev/null 2>&1 \
   || compgen -G "${LIVE_STATE}/tmp-nase-test-*" >/dev/null 2>&1; then
    echo "LEAK: test artefacts found under ${LIVE_STATE}"
    find "$LIVE_STATE" -name 'tmp-nase-test-*' 2>/dev/null | head -5 | sed 's/^/      /'
    LEAKED=1
fi

if [[ $LEAKED -eq 1 ]]; then
    echo ""
    echo "A suite wrote into live NASe state. It must set NAS_LOG / NASE_STAMP_DIR"
    echo "(tests/lib.sh exports safe defaults — something overrode them, or a"
    echo "module hardcodes a live path the way spin_status.sh used to)."
    OVERALL_FAIL=$(( OVERALL_FAIL + 1 ))
fi

echo ""
if [[ $OVERALL_FAIL -eq 0 ]]; then
    echo "All test suites passed."
else
    echo "${OVERALL_FAIL} test suite(s) failed."
    exit 1
fi
