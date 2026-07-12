#!/usr/bin/env bash
# tests/test-integrity.sh — unit tests for modules/integrity/*.
# No root needed; no real drives needed. Scripts that resolve mountpoints via
# findmnt (reconcile-backup.sh, reconcile-primary.sh) are exercised with
# NASE_SKIP_MOUNT_GUARDS=1 plus a mocked findmnt, following the same
# convention as tests/test-sync-guards.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

command -v sqlite3 &>/dev/null || { skip "all integrity tests" "sqlite3 not found"; test_summary; exit 0; }

echo "=== modules/integrity ==="
echo ""

WORK=$(mktemp -d /tmp/nase-test-integrity.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ── common.sh: pure-logic helpers ───────────────────────────────────────────────
echo "--- common.sh ---"

(
    REPO_ROOT="$REPO_ROOT"
    source "${REPO_ROOT}/lib/log.sh"
    source "${REPO_ROOT}/modules/integrity/common.sh"

    assert_eq "db path" "/mnt/primary/.nase/integrity.db" "$(integrity_db_path /mnt/primary)"
    assert_eq "db path: trailing slash on mountpoint" "/mnt/primary/.nase/integrity.db" "$(integrity_db_path /mnt/primary/)"

    assert_eq "relpath" "movies/a.mp4" "$(integrity_relpath /mnt/primary /mnt/primary/movies/a.mp4)"
    assert_eq "abspath" "/mnt/primary/movies/a.mp4" "$(integrity_abspath /mnt/primary movies/a.mp4)"

    assert_eq "escape: no quotes" "plain" "$(_integrity_escape "plain")"
    assert_eq "escape: single quote doubled" "it''s" "$(_integrity_escape "it's")"

    DB="${WORK}/common.db"
    sqlite3 "$DB" < "${REPO_ROOT}/modules/integrity/schema.sql"

    integrity_meta_set "$DB" "test_key" "hello"
    assert_eq "meta set/get round-trip" "hello" "$(integrity_meta_get "$DB" "test_key")"

    integrity_meta_set "$DB" "test_key" "it's got a quote"
    assert_eq "meta set/get: value with a single quote" "it's got a quote" "$(integrity_meta_get "$DB" "test_key")"

    assert_eq "meta get: absent key is empty" "" "$(integrity_meta_get "$DB" "nope")"

    now=$(date +%s)
    sqlite3 "$DB" "INSERT INTO files (path,size,mtime,checksum,status,first_seen,last_updated,last_checked) VALUES
        ('a',1,1,'x','ok',${now},${now},${now}),
        ('b',1,1,'x','ok',${now},${now},${now}),
        ('c',1,1,'x','flagged',${now},${now},${now});"
    assert_eq "row_count: all" "3" "$(integrity_row_count "$DB")"
    assert_eq "row_count: ok" "2" "$(integrity_row_count "$DB" "ok")"
    assert_eq "row_count: flagged" "1" "$(integrity_row_count "$DB" "flagged")"

    # budget = count(ok) / cycle_days, clamped to [min, max]
    assert_eq "budget: floor applies (2/60 < min)" "50" "$(integrity_budget "$DB" 60 50 5000)"
    assert_eq "budget: ceiling applies" "1" "$(integrity_budget "$DB" 1 1 1)"

    # integrity_check_uuid, mocked findmnt
    integrity_meta_set "$DB" "drive_uuid" "abc-123"
    findmnt() { echo "abc-123"; }
    assert_exit0 "check_uuid: live matches recorded" integrity_check_uuid /mnt/whatever "$DB"
    findmnt() { echo "different-uuid"; }
    assert_exit1 "check_uuid: mismatch is rejected" integrity_check_uuid /mnt/whatever "$DB"
    findmnt() { echo ""; }
    assert_exit1 "check_uuid: empty live uuid is rejected" integrity_check_uuid /mnt/whatever "$DB"
)

# ── discover_and_sample.sh ──────────────────────────────────────────────────────
echo ""
echo "--- discover_and_sample.sh ---"

setup_drive() {
    local drive="$1"
    rm -rf "$drive"
    mkdir -p "$drive/.nase"
    sqlite3 "$drive/.nase/integrity.db" < "${REPO_ROOT}/modules/integrity/schema.sql"
    sqlite3 "$drive/.nase/integrity.db" \
        "INSERT INTO meta(key,value) VALUES ('schema_version','1'),('drive_uuid','test'),('discovery_cursor_n','0'),('discovery_complete','false');"
}

run_discover() {
    local drive="$1" min="$2" max="$3"
    local cfg="${WORK}/discover-config.yaml"
    cat > "$cfg" <<YAML
integrity:
  enabled: true
  cycle_days: 60
  min_sample: ${min}
  max_sample: ${max}
  skip_recent_seconds: 0
YAML
    REPO_ROOT="$REPO_ROOT" CONFIG_FILE="$cfg" NASE_STAMP_DIR="${WORK}/varlib" NASE_SKIP_MOUNT_GUARDS=1 \
        bash "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$drive" &>/dev/null
    rm -f "${WORK}/varlib"/integrity-*.date   # simulate the next call being a new day
}

DRIVE="${WORK}/drive1"
setup_drive "$DRIVE"
mkdir -p "$DRIVE/sub"
for i in 1 2 3 4 5 6 7; do echo "content $i" > "$DRIVE/sub/f${i}.txt"; done

# Small budget forces multiple runs to fully discover a 7-file tree — this is
# the exact scenario that used to prematurely mark discovery complete after
# only indexing `budget` files out of a larger scanned window.
for _ in 1 2 3 4 5 6 7 8; do run_discover "$DRIVE" 2 2; done
assert_eq "discovery: converges to all files despite small per-run budget" \
    "7" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT COUNT(*) FROM files;")"
assert_not_contains "discovery: .nase/ itself is never indexed" \
    ".nase" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT path FROM files;")"

# Corrupt a file's content while preserving size+mtime (simulated bit-rot),
# reset last_checked so it's picked first, then confirm it gets flagged and
# the *original* checksum is retained on record (not silently overwritten).
orig_checksum=$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT checksum FROM files WHERE path='sub/f1.txt';")
orig_mtime=$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT mtime FROM files WHERE path='sub/f1.txt';")
printf 'XXXXXXXXXX' > "$DRIVE/sub/f1.txt"
touch -d "@${orig_mtime}" "$DRIVE/sub/f1.txt"
rm -f "$DRIVE/sub/f2.txt"   # will be sampled as "missing"
sqlite3 "$DRIVE/.nase/integrity.db" "UPDATE files SET last_checked=0 WHERE path IN ('sub/f1.txt','sub/f2.txt');"
run_discover "$DRIVE" 5 5

assert_eq "mismatch: file is flagged" \
    "flagged" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT status FROM files WHERE path='sub/f1.txt';")"
assert_eq "mismatch: original checksum is retained, not overwritten" \
    "$orig_checksum" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT checksum FROM files WHERE path='sub/f1.txt';")"
assert_eq "missing: deleted file is flagged" \
    "flagged" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT status FROM files WHERE path='sub/f2.txt';")"

# Flagged rows must never be silently re-verified back to 'ok' by a later run.
sqlite3 "$DRIVE/.nase/integrity.db" "UPDATE files SET last_checked=0 WHERE path='sub/f1.txt';"
run_discover "$DRIVE" 5 5
assert_eq "flagged rows stay excluded from resampling" \
    "flagged" "$(sqlite3 "$DRIVE/.nase/integrity.db" "SELECT status FROM files WHERE path='sub/f1.txt';")"

# ── reconcile-backup.sh (mocked findmnt) ────────────────────────────────────────
echo ""
echo "--- reconcile-backup.sh ---"

SRC_DRIVE="${WORK}/srcdrive"
DST_DRIVE="${WORK}/dstdrive"
export SRC_DRIVE DST_DRIVE   # read inside the mocked findmnt() closures below
setup_drive "$SRC_DRIVE"
setup_drive "$DST_DRIVE"
mkdir -p "$SRC_DRIVE/movies" "$DST_DRIVE/movies"
echo "AAAA" > "$SRC_DRIVE/movies/a.mp4"
cp "$SRC_DRIVE/movies/a.mp4" "$DST_DRIVE/movies/a.mp4"

RECONCILE_CFG="${WORK}/reconcile-config.yaml"
cat > "$RECONCILE_CFG" <<YAML
integrity:
  enabled: true
YAML

printf 'a.mp4\n' > "${WORK}/transferred.txt"
cat > "${WORK}/rsync.log" <<'EOF'
2026/01/01 00:00:00 [1] building file list
2026/01/01 00:00:00 [1] >f+++++++++ a.mp4
EOF

(
    findmnt() {
        case "$*" in
            *"$SRC_DRIVE"*) echo "$SRC_DRIVE" ;;
            *"$DST_DRIVE"*) echo "$DST_DRIVE" ;;
        esac
    }
    export -f findmnt
    REPO_ROOT="$REPO_ROOT" CONFIG_FILE="$RECONCILE_CFG" NASE_SKIP_MOUNT_GUARDS=1 \
        bash "${REPO_ROOT}/modules/integrity/reconcile-backup.sh" \
        "${SRC_DRIVE}/movies/" "${DST_DRIVE}/movies/" "${WORK}/transferred.txt" "${WORK}/rsync.log" &>/dev/null
)

assert_eq "reconcile-backup: source side indexed" \
    "movies/a.mp4" "$(sqlite3 "$SRC_DRIVE/.nase/integrity.db" "SELECT path FROM files;")"
assert_eq "reconcile-backup: dest side indexed" \
    "movies/a.mp4" "$(sqlite3 "$DST_DRIVE/.nase/integrity.db" "SELECT path FROM files;")"

# A flagged file that gets legitimately re-synced should heal back to 'ok'.
sqlite3 "$DST_DRIVE/.nase/integrity.db" "UPDATE files SET status='flagged' WHERE path='movies/a.mp4';"
(
    findmnt() {
        case "$*" in
            *"$SRC_DRIVE"*) echo "$SRC_DRIVE" ;;
            *"$DST_DRIVE"*) echo "$DST_DRIVE" ;;
        esac
    }
    export -f findmnt
    REPO_ROOT="$REPO_ROOT" CONFIG_FILE="$RECONCILE_CFG" NASE_SKIP_MOUNT_GUARDS=1 \
        bash "${REPO_ROOT}/modules/integrity/reconcile-backup.sh" \
        "${SRC_DRIVE}/movies/" "${DST_DRIVE}/movies/" "${WORK}/transferred.txt" "${WORK}/rsync.log" &>/dev/null
)
assert_eq "reconcile-backup: resync heals a flagged row back to ok" \
    "ok" "$(sqlite3 "$DST_DRIVE/.nase/integrity.db" "SELECT status FROM files WHERE path='movies/a.mp4';")"

# Deletion via rsync --delete removes the dest row only.
cat > "${WORK}/rsync-del.log" <<'EOF'
2026/01/01 00:01:00 [2] building file list
2026/01/01 00:01:00 [2] *deleting   a.mp4
EOF
: > "${WORK}/empty-transferred.txt"
(
    findmnt() {
        case "$*" in
            *"$SRC_DRIVE"*) echo "$SRC_DRIVE" ;;
            *"$DST_DRIVE"*) echo "$DST_DRIVE" ;;
        esac
    }
    export -f findmnt
    REPO_ROOT="$REPO_ROOT" CONFIG_FILE="$RECONCILE_CFG" NASE_SKIP_MOUNT_GUARDS=1 \
        bash "${REPO_ROOT}/modules/integrity/reconcile-backup.sh" \
        "${SRC_DRIVE}/movies/" "${DST_DRIVE}/movies/" "${WORK}/empty-transferred.txt" "${WORK}/rsync-del.log" &>/dev/null
)
assert_eq "reconcile-backup: delete removes dest row" \
    "0" "$(sqlite3 "$DST_DRIVE/.nase/integrity.db" "SELECT COUNT(*) FROM files WHERE path='movies/a.mp4';")"
assert_eq "reconcile-backup: delete does not touch source row" \
    "1" "$(sqlite3 "$SRC_DRIVE/.nase/integrity.db" "SELECT COUNT(*) FROM files WHERE path='movies/a.mp4';")"

test_summary
