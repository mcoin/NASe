#!/usr/bin/env bash
# fix-future-mtimes.sh
# Finds files and directories whose mtime lies in the future and resets them to
# a truthful timestamp.
#
# Why this matters (backlog #4): sync change detection asks
# `find "$source" -newer "$STAMP_FILE"`. A future-dated entry is never overtaken
# by the stamp file, so detection fires on every run for as long as the
# timestamp stands — both drives wake, rsync walks the tree and transfers
# nothing. One such directory under /mnt/primary/movies was waking this machine
# nightly.
#
# The replacement timestamp is the entry's ctime (inode change time), which is
# when the entry actually last changed on *this* filesystem and cannot itself be
# set into the future by touch. Where ctime is unusable, 'now' is the fallback.
#
# Refuses to run against a drive in standby: waking a disk is the exact cost
# this script exists to remove. Run it in a window where the drive is already
# awake — e.g. right after the nightly sync.
#
# Usage: sudo ./fix-future-mtimes.sh [--dry-run] [--force] [PATH ...]
#   --dry-run   report what would change, touch nothing
#   --force     proceed even if the drive is in standby, or the number of
#               offenders exceeds the sanity cap
#   PATH ...    what to sweep (default: every active drive's mountpoint)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/checks.sh"
source "${REPO_ROOT}/lib/guards.sh"

# A handful of stray timestamps is the bug this script is for. Hundreds means
# something systematic — a clock that ran wrong during an import, a bad restore
# — and rewriting them all unattended would destroy the evidence needed to work
# out what happened. Stop and let a human look instead.
SANITY_CAP=50

DRY_RUN=false
FORCE=false
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true;   shift ;;
        -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*)        die "Unknown option: $1" ;;
        *)         TARGETS+=("$1"); shift ;;
    esac
done

check_root

# ── Default targets: the main drive(s) only ──────────────────────────────────
# Backup drives are deliberately excluded from the default. A future mtime only
# causes the nightly false positive on the *source* side, where change detection
# reads it; correcting one on a backup would instead make the copy differ from
# its source and get re-transferred on the next run. Name a backup mountpoint
# explicitly if you really want to sweep it.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    n=$(config_len '.drives')
    for i in $(seq 0 $((n - 1))); do
        active=$(config_idx '.drives' "$i" '.active')
        role=$(config_idx '.drives' "$i" '.role')
        mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
        [[ "$active" != "false" ]] || continue
        [[ "$role" == "main" ]] || continue
        [[ -d "$mountpoint" ]] || continue
        TARGETS+=("$mountpoint")
    done
fi

[[ ${#TARGETS[@]} -gt 0 ]] || die "No paths to sweep."

# ── Refuse to touch anything that is not on a mounted drive ──────────────────
# If a drive is unmounted, its mountpoint directory still exists on the SD card
# and `findmnt --target` resolves *up* to the root device — so an unguarded
# sweep of /mnt/<drive> would happily rewrite timestamps on the SD card while
# reporting the drive's name. This is the same trap lib/guards.sh was written
# for on the rsync path; reuse it rather than re-deriving it.
root_dev=$(get_mount_device /)
safe_targets=()
for target in "${TARGETS[@]}"; do
    if is_safe_mount_path "Sweep target" "$target" "$root_dev"; then
        safe_targets+=("$target")
    fi
done
[[ ${#safe_targets[@]} -gt 0 ]] || die "None of the given paths are on a mounted drive — nothing to sweep."
TARGETS=("${safe_targets[@]}")

# ── Refuse to wake a sleeping drive ──────────────────────────────────────────
# Asks modules/drives/spin_status.sh rather than hdparm directly. This box's
# primary drive sits behind a USB-SATA bridge that never implements ATA CHECK
# POWER MODE and always answers "unknown", so a raw `hdparm -C` probe cannot
# tell asleep from awake on the one drive this script most needs to protect —
# and treating "unknown" as "go ahead" silently defeats the whole guard.
# spin_status.sh already handles that case by inferring state from
# /sys/block/<disk>/stat, and reports "estimated" when it does.
awake_targets=()
for target in "${TARGETS[@]}"; do
    # Map the mountpoint back to a configured drive name; only those have a
    # spin state to ask about. An ad-hoc path (a scratch dir, a bind mount)
    # has no drive to protect and is swept without a power check.
    drive_name=""
    n=$(config_len '.drives')
    for i in $(seq 0 $((n - 1))); do
        if [[ "$(config_idx '.drives' "$i" '.mountpoint')" == "$target" ]]; then
            drive_name=$(config_idx '.drives' "$i" '.name')
            break
        fi
    done
    if [[ -z "$drive_name" ]]; then
        awake_targets+=("$target")
        continue
    fi

    read -r state _since method < <("${REPO_ROOT}/modules/drives/spin_status.sh" "$drive_name" 2>/dev/null || echo "unknown - none")

    # "unknown" here means spin_status could not tell either — fail toward not
    # touching the drive, since the cost of a wrong guess in that direction is
    # a skipped sweep, and in the other direction it is the spin-up this whole
    # ticket is about.
    if [[ "$state" != "active" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            # Skip rather than abort: the intended invocation sweeps in the
            # window after a nightly sync, and one target having spun back down
            # is a normal state of affairs, not a reason to do nothing at all.
            log_warn "Drive '${drive_name}' (${target}) is ${state} (${method}) — skipping. Sweeping it would spin the drive up, which is the cost this script exists to avoid. Re-run while it is awake (e.g. just after the nightly sync), or pass --force."
            continue
        fi
        log_warn "Drive '${drive_name}' (${target}) is ${state} (${method}) — sweeping anyway because --force was given."
    fi
    awake_targets+=("$target")
done
[[ ${#awake_targets[@]} -gt 0 ]] || die "Every target drive is spun down — nothing swept. Re-run in a window where the drive is already awake, or pass --force."
TARGETS=("${awake_targets[@]}")

# ── Find offenders ───────────────────────────────────────────────────────────
NOW=$(date +%s)
log_info "Sweeping for entries dated after $(date -d "@${NOW}" '+%Y-%m-%d %H:%M:%S'): ${TARGETS[*]}"

offenders=()
while IFS= read -r -d '' entry; do
    offenders+=("$entry")
done < <(
    # Pinned to one instant so a long sweep cannot pick up entries written while
    # it runs. The +1s is a grace second: mtimes carry sub-second precision, so
    # anything written during the current whole second reads as "after NOW" and
    # would otherwise be reported as future-dated. .nase/ is the integrity
    # manifest (root:root 0700, see INTEGRITY_DESIGN.md), not sync source data.
    find "${TARGETS[@]}" -name .nase -prune -o \
         -newermt "@$((NOW + 1))" -print0 2>/dev/null
)

if [[ ${#offenders[@]} -eq 0 ]]; then
    log_ok "No future-dated entries found — nothing to do."
    exit 0
fi

log_warn "Found ${#offenders[@]} future-dated entr$( [[ ${#offenders[@]} -eq 1 ]] && echo y || echo ies ):"
for entry in "${offenders[@]}"; do
    log_warn "  $(stat -c '%y' "$entry" 2>/dev/null || echo '?')  ${entry}"
done

if [[ ${#offenders[@]} -gt $SANITY_CAP && "$FORCE" != "true" ]]; then
    die "${#offenders[@]} offenders exceeds the sanity cap of ${SANITY_CAP}. That pattern suggests a systematic clock problem rather than a few stray timestamps — investigate before rewriting them. Pass --force to override."
fi

# ── Rewrite ──────────────────────────────────────────────────────────────────
changed=0
failed=0
for entry in "${offenders[@]}"; do
    # ctime cannot be set into the future by touch, so it is a truthful record
    # of when this entry last changed on this filesystem.
    ctime=$(stat -c '%Z' "$entry" 2>/dev/null || echo "")
    if [[ -z "$ctime" || "$ctime" -gt "$NOW" ]]; then
        new_epoch="$NOW"
        source_note="now (ctime unusable)"
    else
        new_epoch="$ctime"
        source_note="ctime"
    fi
    old_h=$(stat -c '%y' "$entry" 2>/dev/null || echo '?')
    new_h=$(date -d "@${new_epoch}" '+%Y-%m-%d %H:%M:%S')

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "would set '${entry}': ${old_h} → ${new_h} (${source_note})"
        continue
    fi

    # -h: act on a symlink itself rather than following it to a target that may
    # sit outside the swept tree. -m: mtime only; atime is not what find -newer
    # compares and is not ours to rewrite.
    if touch -h -m -d "@${new_epoch}" "$entry" 2>/dev/null; then
        log_ok "'${entry}': ${old_h} → ${new_h} (${source_note})"
        changed=$((changed + 1))
    else
        log_warn "'${entry}': could not set mtime — skipped."
        failed=$((failed + 1))
    fi
done

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run — nothing was modified."
    exit 0
fi

summary="Corrected ${changed} entr$( [[ $changed -eq 1 ]] && echo y || echo ies )"
[[ $failed -gt 0 ]] && summary="${summary}, ${failed} failed"
log_ok "${summary}."
log_info "The next sync run for the affected job should log 'no changes since last sync — skipping'."
