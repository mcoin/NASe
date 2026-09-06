#!/usr/bin/env bash
# tests/test-spindown.sh — modules/drives/spindown_common.sh, the helpers
# behind the boot-time spindown service (backlog #32).
#
# The bug these exist to prevent: a USB bridge that isn't ready yet fails one
# hdparm call, nothing retries, and the drive silently spins for hours. So the
# retry behaviour and the -B/-S split are the interesting cases — a bridge
# without APM support must still get its standby timer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

WORK=$(mktemp -d /tmp/nase-test-spindown.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Keep log output out of the central log and off the terminal.
export NAS_LOG="${WORK}/nase.log"
source "${REPO_ROOT}/lib/log.sh"

# hdparm stub: records every invocation, and behaves per-flag according to
# the env — FAIL_UNTIL_ATTEMPT simulates a bridge that isn't ready yet,
# UNSUPPORTED_FLAGS simulates one that will never support a feature.
cat > "${WORK}/hdparm" <<'STUB'
#!/usr/bin/env bash
flag="$1"
echo "$*" >> "$HDPARM_CALLS"
for f in ${UNSUPPORTED_FLAGS:-}; do
    if [[ "$flag" == "$f" ]]; then
        echo " APM_level = not supported"
        exit 1
    fi
done
attempts=$(grep -c -- "^${flag} " "$HDPARM_CALLS")
if [[ -n "${FAIL_UNTIL_ATTEMPT:-}" && "$attempts" -lt "$FAIL_UNTIL_ATTEMPT" ]]; then
    echo "SG_IO: bad/missing sense data"
    exit 1
fi
exit 0
STUB
chmod +x "${WORK}/hdparm"

# spin_status.sh stub: reports whatever SPIN_STATE says, in the real script's
# "<state> <since> <confirmed|estimated>" shape.
cat > "${WORK}/spin_status.sh" <<'STUB'
#!/usr/bin/env bash
echo "${SPIN_STATE:-active} 1788600000 confirmed"
STUB
chmod +x "${WORK}/spin_status.sh"

export NASE_SPIN_STATUS="${WORK}/spin_status.sh"
export NASE_HDPARM="${WORK}/hdparm"
export NASE_SPINDOWN_RETRY_DELAY=0
export NASE_SPINDOWN_RETRIES=6
export NASE_BY_UUID_DIR="${WORK}/by-uuid"
mkdir -p "$NASE_BY_UUID_DIR"

source "${REPO_ROOT}/modules/drives/spindown_common.sh"

reset_calls() {
    export HDPARM_CALLS="${WORK}/calls.txt"
    : > "$HDPARM_CALLS"
    unset FAIL_UNTIL_ATTEMPT UNSUPPORTED_FLAGS
    export SPIN_STATE=active
}
reset_calls

echo "=== spindown_min_to_hdparm ==="
echo ""

assert_eq "0 min disables spindown"          "0"   "$(spindown_min_to_hdparm 0)"
assert_eq "1 min -> 12 (12 x 5 s)"           "12"  "$(spindown_min_to_hdparm 1)"
assert_eq "20 min -> 240, top of the 5 s range" "240" "$(spindown_min_to_hdparm 20)"
assert_eq "30 min -> 241, first of the 30 min range" "241" "$(spindown_min_to_hdparm 30)"
assert_eq "60 min -> 242, the configured value" "242" "$(spindown_min_to_hdparm 60)"
assert_eq "clamped at 251, hdparm's maximum"  "251" "$(spindown_min_to_hdparm 600)"

echo ""
echo "=== spindown_disk_for_uuid ==="
echo ""

assert_empty "absent UUID resolves to nothing" "$(spindown_disk_for_uuid missing-uuid)"

touch "${WORK}/fake-disk"
ln -sf "${WORK}/fake-disk" "${NASE_BY_UUID_DIR}/test-uuid"
assert_eq "present UUID resolves through the symlink" \
    "${WORK}/fake-disk" "$(spindown_disk_for_uuid test-uuid)"

echo ""
echo "=== spindown_hdparm_try ==="
echo ""

reset_calls
assert_exit0 "a working bridge applies first time" \
    spindown_hdparm_try /dev/fake -S 242
assert_eq "and is called exactly once" "1" "$(wc -l < "$HDPARM_CALLS")"

reset_calls
export FAIL_UNTIL_ATTEMPT=3
assert_exit0 "a bridge that isn't ready yet succeeds on retry" \
    spindown_hdparm_try /dev/fake -S 242
assert_eq "after exactly three attempts" "3" "$(wc -l < "$HDPARM_CALLS")"

reset_calls
export FAIL_UNTIL_ATTEMPT=99
assert_exit1 "a bridge that never comes back fails" \
    spindown_hdparm_try /dev/fake -S 242
assert_eq "having used the whole retry budget" "6" "$(wc -l < "$HDPARM_CALLS")"

reset_calls
export UNSUPPORTED_FLAGS="-B"
rc=0; spindown_hdparm_try /dev/fake -B 127 || rc=$?
assert_eq "'not supported' returns 2, not a plain failure" "2" "$rc"
assert_eq "and is not retried" "1" "$(wc -l < "$HDPARM_CALLS")"

echo ""
echo "=== spindown_apm_supported ==="
echo ""

reset_calls
assert_exit0 "a bridge with APM reports supported" spindown_apm_supported /dev/fake
assert_eq "using a read, with no value argument" "-B /dev/fake" "$(cat "$HDPARM_CALLS")"

reset_calls
export UNSUPPORTED_FLAGS="-B"
assert_exit1 "a bridge without APM reports unsupported" spindown_apm_supported /dev/fake

echo ""
echo "=== spindown_apply_drive ==="
echo ""

reset_calls
assert_exit0 "a present drive gets both settings" \
    spindown_apply_drive testdrive test-uuid 242
assert_contains "APM level applied" "-B 127 ${WORK}/fake-disk" "$(cat "$HDPARM_CALLS")"
assert_contains "standby timer applied" "-S 242 ${WORK}/fake-disk" "$(cat "$HDPARM_CALLS")"

# The regression that started backlog #32: primary's bridge has no APM, and a
# single "hdparm -B 127 -S 242" invocation failed as a whole, so the drive
# never got a standby timer either.
reset_calls
export UNSUPPORTED_FLAGS="-B"
assert_exit0 "a bridge without APM still gets its standby timer" \
    spindown_apply_drive testdrive test-uuid 242
assert_contains "standby timer applied anyway" "-S 242 ${WORK}/fake-disk" "$(cat "$HDPARM_CALLS")"
assert_not_contains "and -B is never written to it" "-B 127" "$(cat "$HDPARM_CALLS")"

reset_calls
assert_exit0 "an absent drive is skipped, not an error" \
    spindown_apply_drive testdrive missing-uuid 242
assert_empty "and hdparm is never called for it" "$(cat "$HDPARM_CALLS")"

# Applying the settings spins a sleeping drive back up, and a drive that is
# already parked has working spin-down by definition — so leave it alone.
reset_calls
export SPIN_STATE=standby
assert_exit0 "a parked drive is left alone" \
    spindown_apply_drive testdrive test-uuid 242
assert_empty "and is never touched with hdparm" "$(cat "$HDPARM_CALLS")"

test_summary
