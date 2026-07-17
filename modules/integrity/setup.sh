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

    if [[ -f "$db" ]]; then
        log_info "  Drive '${name}': manifest already exists (${db})."
        # Re-assert permissions every run in case something (e.g. a manual
        # 'fix-ownership.sh' run predating its .nase exclusion) changed them.
        chown root:root "$nase_dir"
        chmod 0700 "$nase_dir"
        # Retroactively migrate DBs created before WAL became the default
        # (schema.sql's PRAGMA only applies at creation time) — a no-op once
        # already on WAL. Needs a rw remount on backup drives, which are
        # read-only at rest.
        if [[ "$is_ro" == "true" ]]; then
            mount -o remount,rw "$mountpoint" \
                || { log_error "  Cannot remount ${mountpoint} rw — skipping WAL migration."; continue; }
            sqlite3 "$db" "PRAGMA journal_mode=WAL;" >/dev/null
            mount -o remount,ro "$mountpoint" \
                || log_warn "  Failed to remount ${mountpoint} ro — drive left writable."
        else
            sqlite3 "$db" "PRAGMA journal_mode=WAL;" >/dev/null
        fi
        continue
    fi

    _create_and_init() {
        mkdir -p "$nase_dir"
        chown root:root "$nase_dir"
        chmod 0700 "$nase_dir"
        sqlite3 "$db" < "$INTEGRITY_SCHEMA"
        chown root:root "$db"
        chmod 0600 "$db"
        local uuid
        uuid=$(integrity_live_uuid "$mountpoint")
        integrity_meta_set "$db" "schema_version" "1"
        integrity_meta_set "$db" "drive_uuid" "$uuid"
        integrity_meta_set "$db" "discovery_cursor_n" "0"
        integrity_meta_set "$db" "discovery_complete" "false"
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
