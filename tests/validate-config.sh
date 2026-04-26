#!/usr/bin/env bash
# tests/validate-config.sh
# Validates config.yaml for required fields and sane values.
# Exit 0 = valid, exit 1 = errors found.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

errors=0
fail() { log_error "  $*"; (( errors++ )) || true; }

command -v yq &>/dev/null || { log_info "yq not found — skipping config validation."; exit 0; }

log_info "Validating ${CONFIG_FILE}..."

# ── Verify yq can parse the file ──────────────────────────────────────────────
yq eval '.' "$CONFIG_FILE" > /dev/null 2>&1 \
    || { fail "config.yaml is not valid YAML."; exit 1; }

# ── nas section ───────────────────────────────────────────────────────────────
hostname=$(config_get '.nas.hostname')
[[ -n "$hostname" ]] || fail ".nas.hostname is required."

# ── drives section ────────────────────────────────────────────────────────────
n_drives=$(config_len '.drives')
[[ "$n_drives" -gt 0 ]] || fail ".drives must contain at least one drive."

UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
declare -A seen_uuids seen_mountpoints

for i in $(seq 0 $((n_drives - 1))); do
    prefix=".drives[$i]"
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    uuid=$(config_idx '.drives' "$i" '.uuid')
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
    filesystem=$(config_idx '.drives' "$i" '.filesystem')
    role=$(config_idx '.drives' "$i" '.role')

    [[ -n "$name" ]] || fail "${prefix}.name is required."

    if [[ -n "$active" && "$active" != "true" && "$active" != "false" ]]; then
        fail "${prefix}.active must be 'true' or 'false' (drive: ${name})."
    fi

    # Skip detailed validation for inactive drives — they may have placeholder values.
    if [[ "$active" == "false" ]]; then
        log_info "  Drive '${name}': inactive — skipping detailed validation."
        continue
    fi

    [[ -n "$uuid"        ]] || fail "${prefix}.uuid is required (drive: ${name})."
    [[ -n "$mountpoint"  ]] || fail "${prefix}.mountpoint is required (drive: ${name})."
    [[ -n "$filesystem"  ]] || fail "${prefix}.filesystem is required (drive: ${name})."

    if [[ -n "$uuid" ]] && ! [[ "$uuid" =~ $UUID_REGEX ]]; then
        fail "${prefix}.uuid '${uuid}' does not look like a valid UUID (drive: ${name})."
    fi

    if [[ -n "${seen_uuids[$uuid]+x}" ]]; then
        fail "Duplicate UUID '${uuid}' found in drives section."
    fi
    seen_uuids["$uuid"]=1

    if [[ -n "${seen_mountpoints[$mountpoint]+x}" ]]; then
        fail "Duplicate mountpoint '${mountpoint}' found in drives section."
    fi
    seen_mountpoints["$mountpoint"]=1

    if [[ "$role" != "main" && "$role" != "backup" ]]; then
        fail "${prefix}.role must be 'main' or 'backup' (got: '${role}')."
    fi
done

# ── samba section ─────────────────────────────────────────────────────────────
workgroup=$(config_get '.samba.workgroup')
[[ -n "$workgroup" ]] || fail ".samba.workgroup is required."

n_shares=$(config_len '.samba.shares')
for i in $(seq 0 $((n_shares - 1))); do
    share_name=$(config_idx '.samba.shares' "$i" '.name')
    share_path=$(config_idx '.samba.shares' "$i" '.path')
    [[ -n "$share_name" ]] || fail ".samba.shares[$i].name is required."
    [[ -n "$share_path" ]] || fail ".samba.shares[$i].path is required (share: ${share_name})."
done

# ── sync_jobs section ─────────────────────────────────────────────────────────
n_jobs=$(config_len '.sync_jobs')
declare -A seen_job_names

for i in $(seq 0 $((n_jobs - 1))); do
    job_name=$(config_idx '.sync_jobs' "$i" '.name')
    source=$(config_idx   '.sync_jobs' "$i" '.source')
    dest=$(config_idx     '.sync_jobs' "$i" '.dest')
    schedule=$(config_idx '.sync_jobs' "$i" '.schedule')
    on_failure=$(config_idx '.sync_jobs' "$i" '.on_failure')

    [[ -n "$job_name"  ]] || fail ".sync_jobs[$i].name is required."
    [[ -n "$source"    ]] || fail ".sync_jobs[$i].source is required (job: ${job_name})."
    [[ -n "$dest"      ]] || fail ".sync_jobs[$i].dest is required (job: ${job_name})."
    [[ -n "$schedule"  ]] || fail ".sync_jobs[$i].schedule is required (job: ${job_name})."

    # Trailing slashes on source and dest are required for correct rsync behaviour:
    # without a trailing slash on the source rsync copies the directory itself
    # rather than its contents, producing an unintended extra nesting level.
    [[ "$source" == */ ]] || fail ".sync_jobs[$i].source must end with '/' (job: ${job_name}). Got: '${source}'"
    [[ "$dest"   == */ ]] || fail ".sync_jobs[$i].dest must end with '/' (job: ${job_name}). Got: '${dest}'"

    if [[ -n "${seen_job_names[$job_name]+x}" ]]; then
        fail "Duplicate sync job name '${job_name}'."
    fi
    seen_job_names["$job_name"]=1

    if [[ "$on_failure" != "notify" && "$on_failure" != "ignore" ]]; then
        fail ".sync_jobs[$i].on_failure must be 'notify' or 'ignore' (job: ${job_name})."
    fi

    # Validate OnCalendar expression if systemd-analyze is available
    if command -v systemd-analyze &>/dev/null; then
        if ! systemd-analyze calendar "$schedule" &>/dev/null; then
            fail ".sync_jobs[$i].schedule '${schedule}' is not a valid systemd OnCalendar expression."
        fi
    fi
done

# ── services.web section ──────────────────────────────────────────────────────
if config_bool '.services.web.enabled' 2>/dev/null; then
    web_port=$(config_get '.services.web.port')
    [[ -n "$web_port" ]] || fail ".services.web.port is required when web is enabled."
fi

# ── notifications section ─────────────────────────────────────────────────────
method=$(config_get '.notifications.method')
if [[ "$method" == "email" ]]; then
    email=$(config_get '.notifications.email')
    [[ -n "$email" ]] || fail ".notifications.email is required when method=email."
fi
if [[ "$method" != "email" && "$method" != "webhook" && "$method" != "none" && -n "$method" ]]; then
    fail ".notifications.method must be 'email', 'webhook', or 'none' (got: '${method}')."
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ "$errors" -gt 0 ]]; then
    die "config.yaml validation failed with ${errors} error(s)."
fi

log_ok "config.yaml is valid."
