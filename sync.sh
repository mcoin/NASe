#!/usr/bin/env bash
# sync.sh — manually run one or all sync jobs defined in config.yaml.
#
# Usage:
#   sudo ./sync.sh                  # interactive menu
#   sudo ./sync.sh --all            # run all jobs in sequence
#   sudo ./sync.sh <job-name>       # run a specific job
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/checks.sh"

check_root

WORKER="${REPO_ROOT}/modules/sync/sync.sh"
n=$(config_len '.sync_jobs')

if [[ "$n" -eq 0 ]]; then
    die "No sync jobs defined in config.yaml."
fi

# Collect job names
job_names=()
for i in $(seq 0 $((n - 1))); do
    job_names+=("$(config_idx '.sync_jobs' "$i" '.name')")
done

run_job() {
    local job="$1"
    log_section "Sync: ${job}"
    bash "$WORKER" "$job"
}

case "${1:-}" in
    --all)
        for job in "${job_names[@]}"; do
            run_job "$job"
        done
        log_ok "All sync jobs complete."
        ;;

    "")
        # Interactive menu
        echo ""
        echo "Available sync jobs:"
        for i in "${!job_names[@]}"; do
            source=$(config_idx '.sync_jobs' "$i" '.source')
            dest=$(config_idx   '.sync_jobs' "$i" '.dest')
            echo "  $((i+1))) ${job_names[$i]}  (${source} → ${dest})"
        done
        echo "  a) All jobs"
        echo "  q) Quit"
        echo ""
        read -r -p "Run which job? " choice

        case "$choice" in
            a|A)
                for job in "${job_names[@]}"; do
                    run_job "$job"
                done
                log_ok "All sync jobs complete."
                ;;
            q|Q)
                exit 0
                ;;
            *)
                # Accept a number or a job name
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
                    run_job "${job_names[$((choice-1))]}"
                else
                    # Try as a job name
                    found=false
                    for job in "${job_names[@]}"; do
                        if [[ "$job" == "$choice" ]]; then
                            run_job "$job"
                            found=true
                            break
                        fi
                    done
                    [[ "$found" == "true" ]] || die "Unknown job: '${choice}'"
                fi
                ;;
        esac
        ;;

    *)
        # Job name passed directly
        found=false
        for job in "${job_names[@]}"; do
            if [[ "$job" == "$1" ]]; then
                run_job "$job"
                found=true
                break
            fi
        done
        [[ "$found" == "true" ]] || die "Unknown sync job '${1}'. Available: ${job_names[*]}"
        ;;
esac
