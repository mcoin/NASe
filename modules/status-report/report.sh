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
now_ts=$(date +%s)
now_str=$(date '+%Y-%m-%d %H:%M:%S')

# ── Reading the integrity status cache ────────────────────────────────────────
# The cache is JSON on the SD card. jq is not a NASe dependency (lib/checks.sh
# requires yq, for YAML), but python3 is already used to read JSON in
# modules/config-archive/archive.sh, so it is the established way to do this
# here. One process per drive per section is nothing against a weekly report.

# cache_summary <file> -> TSV: has total ok flagged complete cursor dtotal updated truncated
cache_summary() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
def s(key, default=""):
    v = d.get(key)
    return default if v is None else str(v)
print("\t".join([
    "true" if d.get("has_manifest") else "false",
    s("total", "0"), s("ok", "0"), s("flagged", "0"),
    "true" if d.get("discovery_complete") else "false",
    s("discovery_cursor_n", "0"), s("discovery_total", "0"),
    s("updated_at"),
    "true" if d.get("flagged_truncated") else "false",
]))
PY
}

# cache_events <file> <since-epoch> -> TSV rows: ts, event_type, path, detail
cache_events() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
since = int(sys.argv[2])
rows = [e for e in (d.get("recent_events") or [])
        if str(e.get("ts", "")).isdigit() and int(e["ts"]) >= since]
for e in sorted(rows, key=lambda r: int(r["ts"])):
    print("\t".join(str(e.get(k) or "") for k in ("ts", "event_type", "path", "detail")))
PY
}

# cache_flagged_paths <file> -> up to 50 flagged paths, sorted
cache_flagged_paths() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for r in sorted(d.get("flagged_rows") or [], key=lambda r: r.get("path") or "")[:50]:
    if r.get("path"):
        print(r["path"])
PY
}
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

    # --mountpoint, not --target: --target resolves *up* to the nearest
    # enclosing mount, so an unmounted /mnt/primary answers with the SD card's
    # root mount and the report cheerfully calls the drive mounted rw. That is
    # the trap lib/guards.sh exists to catch, and a status report is the last
    # place that should get it wrong.
    if ! findmnt --mountpoint "$mp" --noheadings &>/dev/null; then
        drive_lines+="    ${name}: NOT MOUNTED (${mp})\n"
        anomalies+=("Drive '${name}' is not mounted at ${mp}")
        continue
    fi

    opts=$(findmnt --mountpoint "$mp" --output OPTIONS --noheadings --first-only 2>/dev/null || echo "")
    mode=$(echo "$opts" | grep -qw ro && echo "ro" || echo "rw")
    usage=$(df -h "$mp" 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}' || echo "—")
    drive_lines+="    ${name}: mounted ${mode}   ${usage}\n"
done

# ── Sync timer status ─────────────────────────────────────────────────────────
# One group timer per distinct schedule, not one per job: #4 phase 2 replaced
# the per-job timers with nase-sync-group-<slug>.timer and modules/sync/setup.sh
# actively deletes the old ones. Checking the per-job names therefore reported
# all nine as dead every week — the false alarm that opened #29. Derive the
# group names the same way setup.sh and run-group.sh do, via schedule_slug, so
# this cannot drift from them again.
all_timers_ok=true
timer_problem_lines=""
declare -A _seen_slug=()
n_jobs=$(config_len '.sync_jobs')
for i in $(seq 0 $((n_jobs - 1))); do
    schedule=$(config_idx '.sync_jobs' "$i" '.schedule')
    [[ -n "$schedule" ]] || continue
    slug=$(schedule_slug "$schedule")
    [[ -z "${_seen_slug[$slug]+x}" ]] || continue
    _seen_slug["$slug"]=1

    unit="nase-sync-group-${slug}.timer"
    # `systemctl is-active` prints the state and exits non-zero for anything
    # that is not active, so the old `|| echo unknown` appended a second line
    # to a perfectly good answer — which is why the report read "inactive"
    # and "unknown" on consecutive lines.
    state=$(systemctl is-active "$unit" 2>/dev/null) || true
    [[ -n "$state" ]] || state="unknown"
    if [[ "$state" != "active" ]]; then
        all_timers_ok=false
        timer_problem_lines+="    ${unit}: ${state}\n"
        anomalies+=("Sync timer '${unit}' is ${state}")
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

# ── Parse file changes from primary events log ────────────────────────────────
# Reads /var/lib/nase/primary-events.log (written by nase-primary-watch.service).
# Deduplicates by path: each file appears once, with the most recent operation
# and a (×N) annotation when it was touched more than once in the period.
# Output: timestamp TAB share TAB op TAB rel-path TAB count,
#         sorted by share then most-recent-first.
ops_tsv=""
EVENTS_LOG="${STAMP_DIR}/primary-events.log"
# NASe's own config archive writes a fresh snapshot under this path on every
# flush. It is NASe reporting its own bookkeeping back to the reader as though
# it were user activity, and it was the single most frequent entry in the
# report (#29). Anything under the configured archive destination is excluded.
archive_dest=$(config_get '.config_archive.dest // ""')
archive_dest="${archive_dest%/}"
if [[ -f "$EVENTS_LOG" ]]; then
    ops_tsv=$(awk -v since="$since_str" -v archive="$archive_dest" '
        BEGIN { FS = "\t" }
        $1 >= since {
            ts = $1; op = $2; path = $3
            # Bookkeeping the watcher writes about itself, not file activity:
            # __heartbeat__ proves the watcher is alive and __gap__ marks a
            # restart. Both carry "-" as their path, so the path-based filters
            # below never caught them and they surfaced in the report as
            # changes to a share called "(root)".
            if (op == "__heartbeat__" || op == "__gap__") next
            if (archive != "" && (path == archive || index(path, archive "/") == 1)) next
            # .nase/ (the integrity manifest) and .trash/ are internal
            # churn, not user activity — record.sh and reconcile-primary.sh
            # already exclude them at the source, but old log entries can
            # predate that fix (or the watch service predates a restart),
            # so filter here too rather than ever surface them in a report.
            if (path ~ /\/\.(nase|trash)(\/|$)/) next
            cnt[path]++
            if (!(path in lts) || ts > lts[path]) {
                lts[path] = ts
                lop[path] = op
            }
        }
        END {
            for (path in lts) {
                n = split(path, parts, "/")
                share = (n >= 4) ? parts[4] : "(root)"
                rel = ""
                for (i = 5; i <= n; i++) {
                    if (parts[i] != "") rel = rel (rel != "" ? "/" : "") parts[i]
                }
                if (rel == "") rel = parts[n]
                printf "%s\t%s\t%s\t%s\t%d\n", \
                    lts[path], share, lop[path], rel, cnt[path]
            }
        }
    ' "$EVENTS_LOG" 2>/dev/null | sort -t$'\t' -k2,2 -k1,1r || true)
fi

total_ops=0
[[ -n "$ops_tsv" ]] && total_ops=$(echo "$ops_tsv" | grep -c . || true)

# Format file changes per share.
ops_section=""
if [[ $total_ops -gt 0 ]]; then
    current_share=""
    while IFS=$'\t' read -r ts share op fname count; do
        if [[ "$share" != "$current_share" ]]; then
            current_share="$share"
            ops_section+="\n  ${share}\n"
        fi
        count_str=""
        [[ "$count" -gt 1 ]] && count_str=" (×${count})"
        ops_section+="    ${ts:0:16}  ${op}${count_str}   ${fname}\n"
    done <<< "$ops_tsv"
fi

# ── Integrity manifest status ─────────────────────────────────────────────────
# Per-drive checksum manifest summary: discovery progress and any
# mismatch/missing events recorded since the last report, plus the current
# list of flagged files. This is what actually matters about the .nase
# manifest for a human reading the report — its own internal file churn
# (covered by the .nase exclude above) is not.
integrity_section=""
if config_bool '.integrity.enabled' 2>/dev/null; then
    source "${REPO_ROOT}/modules/integrity/common.sh"
    n_drives_i=$(config_len '.drives')
    for i in $(seq 0 $((n_drives_i - 1))); do
        iname=$(config_idx '.drives' "$i" '.name')
        imp=$(config_idx   '.drives' "$i" '.mountpoint')
        iactive=$(config_idx '.drives' "$i" '.active')
        [[ "$iactive" != "false" ]] || continue
        # Read the SD-card cache, never the manifest on the drive. The DB is
        # at <mountpoint>/.nase/integrity.db, and counting ~4M rows in it is a
        # full table scan: doing that here woke both drives from standby every
        # single run and held them up for the spindown timer afterwards —
        # ~330k block requests on 2026-09-12, which is what sent #29 looking
        # (see #4). integrity_write_status_cache writes everything below at
        # the end of each integrity run, when the drive was awake anyway, and
        # the web dashboard has always read it for exactly this reason.
        icache=$(integrity_status_cache_path "$imp")
        if [[ ! -f "$icache" ]]; then
            integrity_section+="\n  ${iname} (${imp}): no manifest status recorded yet\n"
            continue
        fi
        isummary=$(cache_summary "$icache") || isummary=""
        if [[ -z "$isummary" ]]; then
            integrity_section+="\n  ${iname} (${imp}): manifest status unreadable (${icache})\n"
            anomalies+=("Integrity status cache for drive '${iname}' could not be read")
            continue
        fi
        IFS=$'\t' read -r ihas itotal iok iflagged icomplete icursor idtotal \
                          iupdated itruncated <<< "$isummary"
        if [[ "$ihas" != "true" ]]; then
            integrity_section+="\n  ${iname} (${imp}): no manifest yet\n"
            continue
        fi

        integrity_section+="\n  ${iname} (${imp})\n"
        # The figures are as fresh as the last integrity run, which only
        # happens after a real rsync — so they can be days old. Say so rather
        # than presenting a stale number as the current one.
        if [[ -n "$iupdated" ]]; then
            iage_d=$(( (now_ts - iupdated) / 86400 ))
            iage_str=$(date -d "@${iupdated}" '+%Y-%m-%d %H:%M')
            if [[ "$iage_d" -ge 1 ]]; then
                integrity_section+="    as of ${iage_str} (${iage_d}d ago — updated when integrity last ran)\n"
            else
                integrity_section+="    as of ${iage_str}\n"
            fi
        fi
        integrity_section+="    files: ${itotal}   ok: ${iok}   flagged: ${iflagged}\n"
        if [[ "$icomplete" == "true" ]]; then
            integrity_section+="    discovery: complete\n"
        else
            integrity_section+="    discovery: in progress (${icursor}/${idtotal})\n"
        fi

        ievents=$(cache_events "$icache" "$since_ts")
        if [[ -n "$ievents" ]]; then
            integrity_section+="    checks since last report:\n"
            while IFS=$'\t' read -r ets etype epath edetail; do
                [[ -n "$ets" ]] || continue
                edt=$(date -d "@${ets}" '+%Y-%m-%d %H:%M')
                integrity_section+="      ${edt}  ${etype}   ${epath}${edetail:+ (${edetail})}\n"
            done <<< "$ievents"
        else
            integrity_section+="    checks since last report: no mismatches or missing files\n"
        fi

        if [[ "$iflagged" -gt 0 ]]; then
            anomalies+=("${iflagged} flagged file(s) on drive '${iname}' — see integrity status below")
            integrity_section+="    flagged files (ack with: sudo nase integrity ack ${iname} <path>):\n"
            while IFS= read -r ifp; do
                [[ -n "$ifp" ]] || continue
                integrity_section+="      ${ifp}\n"
            done < <(cache_flagged_paths "$icache")
            # flagged_rows is capped when writing the cache; say so rather
            # than silently showing a short list as if it were the whole set.
            if [[ "$itruncated" == "true" ]]; then
                integrity_section+="      ... list truncated; run 'sudo nase integrity status ${iname}' for all\n"
            fi
        fi
    done
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
body+="\n=== FILE CHANGES (primary drive) ===\n"
body+="\n"
if [[ $total_ops -eq 0 ]]; then
    body+="  No file changes in this period.\n"
else
    body+="  ${total_ops} file(s) changed since ${since_disp}.\n"
    body+="${ops_section}\n"
fi
body+="\n"
body+="\n=== INTEGRITY STATUS ===\n"
body+="\n"
if ! config_bool '.integrity.enabled' 2>/dev/null; then
    body+="  Integrity manifest disabled (integrity.enabled: false in config.yaml).\n"
elif [[ -z "$integrity_section" ]]; then
    body+="  No active drives configured.\n"
else
    body+="${integrity_section}"
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

# ── Archive, then send ────────────────────────────────────────────────────────
# Written before the notifier runs, not after. The report is most worth keeping
# when delivery failed, and notify.sh gives up with a warning on several paths
# (SMTP_HOST unset, WEBHOOK_URL unset, unknown method) — in each of those the
# report used to evaporate. Archiving first also means an SMTP hard failure,
# which aborts this script under `set -euo pipefail` before the stamp is
# touched, still leaves the report readable. With notifications.method: none it
# turns a report that was composed and discarded into a local-only one.
#
# python3, not hand-rolled JSON: escaping a multi-line body in bash is a bug
# waiting to happen, and python3 is already how NASe shell handles JSON (see
# modules/config-archive/archive.sh). Written to a temp file in the same
# directory and os.replace'd, the same atomic pattern as save_backlog in
# main.py — a half-written report read by the web page is the one failure mode
# that would look like corruption, and archive.sh copies this whole directory
# to the drive at whatever instant it happens to run. See backlog #37.
REPORTS_DIR="${STAMP_DIR}/reports"
mkdir -p "$REPORTS_DIR"
if ! NASE_REPORTS_DIR="$REPORTS_DIR" \
     R_TS="$now_ts" R_TRIGGER="${NASE_REPORT_TRIGGER:-scheduled}" \
     R_SUBJECT="$subject" R_SINCE="$since_ts" \
     R_ANOMALIES="$n_anomalies" R_CHANGES="$total_ops" \
     R_BODY="$(printf '%b' "$body")" \
     python3 "${REPO_ROOT}/modules/status-report/write_report.py"; then
    # A report that cannot be archived is still worth sending.
    log_warn "Could not archive the report to ${REPORTS_DIR} — sending it anyway."
fi

log_info "Sending status report (anomalies: ${n_anomalies}, changes: ${total_ops})..."
printf '%b' "$body" | "${REPO_ROOT}/modules/sync/notify.sh" "$subject"

# Update stamp
mkdir -p "$STAMP_DIR"
touch "$STAMP_FILE"
log_ok "Status report sent."
