#!/usr/bin/env bash
# modules/status-report/report.sh
# Generates and sends a periodic status report.
# Called by nase-status-report.timer; can also be run manually via: sudo nase report
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

log_section "Status report"

enabled=$(config_get '.status_report.enabled // "true"')
if [[ "$enabled" != "true" ]]; then
    log_info "Status report disabled — skipping."
    exit 0
fi

STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
STAMP_FILE="${STAMP_DIR}/status-report.stamp"
LOG_FILE="${NAS_LOG:-/var/log/nase/nase.log}"
HOSTNAME_VAL=$(hostname)

# ── Reporting window ──────────────────────────────────────────────────────────
if [[ -f "$STAMP_FILE" ]]; then
    since_ts=$(stat -c %Y "$STAMP_FILE")
    since_str=$(date -d "@${since_ts}" '+%Y-%m-%d %H:%M:%S')
else
    since_ts=$(( $(date +%s) - 604800 ))
    since_str=$(date -d "@${since_ts}" '+%Y-%m-%d %H:%M:%S')
fi
now_str=$(date '+%Y-%m-%d %H:%M:%S')
since_disp="${since_str:0:16}"
now_disp="${now_str:0:16}"

# ── Drive status ──────────────────────────────────────────────────────────────
anomalies=()
drive_lines=""
n_drives=$(config_len '.drives')
for i in $(seq 0 $((n_drives - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    mp=$(config_idx   '.drives' "$i" '.mountpoint')
    active=$(config_idx '.drives' "$i" '.active')

    if [[ "$active" == "false" ]]; then
        drive_lines+="    ${name}: inactive\n"
        continue
    fi

    if ! findmnt --target "$mp" --noheadings &>/dev/null; then
        drive_lines+="    ${name}: NOT MOUNTED (${mp})\n"
        anomalies+=("Drive '${name}' is not mounted at ${mp}")
        continue
    fi

    opts=$(findmnt --target "$mp" --output OPTIONS --noheadings --first-only 2>/dev/null || echo "")
    mode=$(echo "$opts" | grep -qw ro && echo "ro" || echo "rw")
    usage=$(df -h "$mp" 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}' || echo "—")
    drive_lines+="    ${name}: mounted ${mode}   ${usage}\n"
done

# ── Sync timer status ─────────────────────────────────────────────────────────
all_timers_ok=true
timer_problem_lines=""
n_jobs=$(config_len '.sync_jobs')
for i in $(seq 0 $((n_jobs - 1))); do
    job=$(config_idx '.sync_jobs' "$i" '.name')
    state=$(systemctl is-active "nase-sync-${job}.timer" 2>/dev/null || echo "unknown")
    if [[ "$state" != "active" ]]; then
        all_timers_ok=false
        timer_problem_lines+="    nase-sync-${job}.timer: ${state}\n"
        anomalies+=("Sync timer 'nase-sync-${job}.timer' is ${state}")
    fi
done

# ── Error log lines since last report ────────────────────────────────────────
error_lines=""
error_count=0
if [[ -f "$LOG_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        (( error_count++ )) || true
        if [[ $error_count -le 10 ]]; then
            error_lines+="    ${line}\n"
        fi
    done < <(awk -v since="$since_str" \
        '{ ts = $1 " " $2; if (ts < since) next } /\[ERROR\]/ { print }' \
        "$LOG_FILE" 2>/dev/null || true)
fi
if [[ $error_count -gt 10 ]]; then
    error_lines+="    ... and $((error_count - 10)) more (see ${LOG_FILE})\n"
fi
if [[ $error_count -gt 0 ]]; then
    anomalies+=("${error_count} error(s) in log since last report")
fi

# ── Parse file operations from central log ────────────────────────────────────
# Looks for lines between "Starting sync job 'X'" and "Sync job 'X' completed/failed",
# extracting "  synced:  FILE" and "  trashed: FILE" entries.
# Output: timestamp TAB job TAB op TAB filename, sorted by job then time.
ops_tsv=""
if [[ -f "$LOG_FILE" ]]; then
    ops_tsv=$(awk -v since="$since_str" -v Q="'" '
        BEGIN { job = "" }
        { ts = $1 " " $2; if (ts < since) next }
        index($0, "[INFO ] Starting sync job " Q) {
            n = index($0, "sync job " Q)
            if (n > 0) {
                rest = substr($0, n + 10)
                q = index(rest, Q)
                if (q > 0) job = substr(rest, 1, q - 1)
            }
            next
        }
        /\[OK   \] Sync job /  { job = ""; next }
        /\[ERROR\] Sync job /  { job = ""; next }
        job != "" && index($0, "[INFO ]   synced:  ") {
            n = index($0, "  synced:  ")
            if (n > 0) printf "%s\t%s\tsynced\t%s\n", ts, job, substr($0, n + 11)
        }
        job != "" && index($0, "[INFO ]   trashed: ") {
            n = index($0, "  trashed: ")
            if (n > 0) printf "%s\t%s\ttrashed\t%s\n", ts, job, substr($0, n + 11)
        }
    ' "$LOG_FILE" 2>/dev/null | sort -t$'\t' -k2,2 -k1,1 || true)
fi

total_ops=0
[[ -n "$ops_tsv" ]] && total_ops=$(echo "$ops_tsv" | grep -c . || true)

# Format file operations per job, capped at 30 lines each
ops_section=""
if [[ $total_ops -gt 0 ]]; then
    current_job=""
    declare -i job_total=0 job_shown=0
    while IFS=$'\t' read -r ts job op fname; do
        if [[ "$job" != "$current_job" ]]; then
            if [[ -n "$current_job" && $job_total -gt $job_shown ]]; then
                ops_section+="      ... and $((job_total - job_shown)) more\n"
            fi
            current_job="$job"
            job_total=0
            job_shown=0
            ops_section+="\n  ${job}\n"
        fi
        (( job_total++ )) || true
        if [[ $job_shown -lt 30 ]]; then
            ops_section+="    ${ts:0:16}  ${op}   ${fname}\n"
            (( job_shown++ )) || true
        fi
    done <<< "$ops_tsv"
    if [[ -n "$current_job" && $job_total -gt $job_shown ]]; then
        ops_section+="      ... and $((job_total - job_shown)) more\n"
    fi
fi

# ── Compose report body ───────────────────────────────────────────────────────
n_anomalies=${#anomalies[@]}

body=""
body+="NASe status report — ${HOSTNAME_VAL}\n"
body+="Period: ${since_disp} → ${now_disp}\n"
body+="\n"
body+="\n=== SYSTEM STATUS ===\n"
body+="\n"
if [[ $n_anomalies -eq 0 ]]; then
    body+="  All systems normal.\n"
else
    body+="  ANOMALIES DETECTED:\n"
    for a in "${anomalies[@]}"; do
        body+="    * ${a}\n"
    done
fi
body+="\n"
body+="  Drives:\n${drive_lines}"
body+="\n"
if [[ "$all_timers_ok" == "true" ]]; then
    body+="  Sync timers: all active\n"
else
    body+="  Sync timers:\n${timer_problem_lines}"
fi
body+="\n"
if [[ $error_count -eq 0 ]]; then
    body+="  Errors in period: none\n"
else
    body+="  Errors in period (${error_count}):\n${error_lines}"
fi
body+="\n"
body+="\n=== FILE OPERATIONS ===\n"
body+="\n"
if [[ $total_ops -eq 0 ]]; then
    body+="  No file changes in this period.\n"
else
    body+="  ${total_ops} operation(s) since ${since_disp}.\n"
    body+="${ops_section}\n"
fi
body+="\n"
body+="──────────────────────────────────────────────────────────────────────\n"
body+="Generated by NASe on ${HOSTNAME_VAL} at ${now_str}\n"
body+="Run 'nase status' for live status.\n"

# ── Subject ───────────────────────────────────────────────────────────────────
subject="NASe status report — ${HOSTNAME_VAL} — $(date '+%Y-%m-%d')"
if [[ $n_anomalies -gt 0 ]]; then
    subject+=" [${n_anomalies} ANOMALY]"
    [[ $n_anomalies -gt 1 ]] && subject="${subject%[*}[${n_anomalies} ANOMALIES]"
fi

# ── Send ──────────────────────────────────────────────────────────────────────
log_info "Sending status report (anomalies: ${n_anomalies}, ops: ${total_ops})..."
"${REPO_ROOT}/modules/sync/notify.sh" "$subject" "$(printf '%b' "$body")"

# Update stamp
mkdir -p "$STAMP_DIR"
touch "$STAMP_FILE"
log_ok "Status report sent."
