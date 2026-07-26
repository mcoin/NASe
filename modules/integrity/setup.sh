#!/usr/bin/env bash
# modules/integrity/setup.sh
# Ensures every active drive has a checksum-manifest database at
# <mountpoint>/.nase/integrity.db, with the schema applied and the
# directory locked down to root:root 0700 (see INTEGRITY_DESIGN.md "Guards"
# — this is the load-bearing protection against .nase/ being reachable
# through Samba or filebrowser, both of which run as the 'nase' OS user).
# Never triggers a bootstrap/discovery run — that happens progressively via
# modules/integrity/discover_and_sample.sh, or on demand via 'nase integrity
# bootstrap'.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    log_info "Checksum integrity manifest disabled (integrity.enabled != true) — skipping."
    exit 0
fi

n=$(config_len '.drives')
log_info "Configuring integrity manifest for ${n} drive(s)..."

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    [[ "$active" != "false" ]] || { log_info "  Drive '${name}': inactive — skipping."; continue; }

    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
    read_only=$(config_idx '.drives' "$i" '.read_only')

    if ! findmnt --target "$mountpoint" --noheadings &>/dev/null; then
        log_info "  Drive '${name}': not mounted — skipping."
        continue
    fi

    nase_dir="${mountpoint%/}/.nase"
    db=$(integrity_db_path "$mountpoint")

    is_ro=$(findmnt --target "$mountpoint" --output OPTIONS --noheadings --first-only \
        | grep -qw ro && echo true || echo false)

    # WAL needs to create a -shm file even for plain reads, which fails on a
    # filesystem mounted read-only. Backup drives spend most of their life
    # read-only at rest (reads must keep working then), so only a drive
    # that's never read-only at rest (config's read_only: false, i.e.
    # primary) gets WAL. This is the one that actually needs it: a bootstrap
    # run holds a writer transaction open for hours while the web
    # dashboard's integrity page polls the same file read-only every 60s
    # (see main.py) — under the default journal mode a reader's SHARED lock
    # can block the writer's COMMIT, which is what produced "cannot commit -
    # no transaction is active" crashes.
    if [[ "$read_only" == "true" ]]; then
        target_journal_mode="delete"
    else
        target_journal_mode="wal"
    fi

    _set_journal_mode() {
        local current
        current=$(sqlite3 "$db" "PRAGMA journal_mode;")
        [[ "$current" == "$target_journal_mode" ]] && return 0
        if [[ "$is_ro" == "true" ]]; then
            mount -o remount,rw "$mountpoint" \
                || { log_error "  Cannot remount ${mountpoint} rw — skipping journal mode migration."; return 0; }
            sqlite3 "$db" "PRAGMA journal_mode=${target_journal_mode};" >/dev/null
            mount -o remount,ro "$mountpoint" \
                || log_warn "  Failed to remount ${mountpoint} ro — drive left writable."
        else
            sqlite3 "$db" "PRAGMA journal_mode=${target_journal_mode};" >/dev/null
        fi
    }

    if [[ -f "$db" ]]; then
        log_info "  Drive '${name}': manifest already exists (${db})."
        # Re-assert permissions in case something (e.g. a manual
        # 'fix-ownership.sh' run predating its .nase exclusion) changed
        # them — but only while rw: chown/chmod fail outright on a
        # read-only mount, and backup drives spend most of their life
        # read-only at rest, so this used to break every 'apply.sh' run
        # that landed while a backup drive was in its normal resting
        # state. Safe to skip while ro: nothing could have changed .nase/'s
        # permissions since the last rw session in the first place.
        if [[ "$is_ro" != "true" ]]; then
            chown root:root "$nase_dir"
            chmod 0700 "$nase_dir"
        fi
        _set_journal_mode
        # apply.sh already has this drive mounted/awake for the checks
        # above, so refreshing the dashboard's SD-card cache here is free —
        # keeps it in sync even if nothing else touches this drive tonight.
        integrity_write_status_cache "$mountpoint" "$db" || true
        continue
    fi

    _create_and_init() {
        mkdir -p "$nase_dir"
        chown root:root "$nase_dir"
        chmod 0700 "$nase_dir"
        sqlite3 "$db" < "$INTEGRITY_SCHEMA"
        sqlite3 "$db" "PRAGMA journal_mode=${target_journal_mode};" >/dev/null
        chown root:root "$db"
        chmod 0600 "$db"
        local uuid
        uuid=$(integrity_live_uuid "$mountpoint")
        integrity_meta_set "$db" "schema_version" "1"
        integrity_meta_set "$db" "drive_uuid" "$uuid"
        integrity_meta_set "$db" "discovery_cursor_n" "0"
        integrity_meta_set "$db" "discovery_complete" "false"
        # So the dashboard has something to show (all zeros, discovery not
        # started) before the first nightly pass ever runs.
        integrity_write_status_cache "$mountpoint" "$db" || true
    }

    if [[ "$is_ro" == "true" ]]; then
        log_info "  Drive '${name}': remounting ${mountpoint} rw to create manifest..."
        mount -o remount,rw "$mountpoint" \
            || { log_error "  Cannot remount ${mountpoint} rw — skipping manifest creation."; continue; }
        _create_and_init
        mount -o remount,ro "$mountpoint" \
            || log_warn "  Failed to remount ${mountpoint} ro — drive left writable."
    else
        _create_and_init
    fi

    log_ok "  Drive '${name}': manifest created at ${db}."
done

log_ok "Integrity manifest configured."
