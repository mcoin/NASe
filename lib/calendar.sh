#!/usr/bin/env bash
# lib/calendar.sh — helpers for systemd OnCalendar expressions.
# Source this file; do not execute directly.
#
# Used to pin forced syncs to a chosen day ("every Thursday", "the first
# Thursday of the month") instead of an elapsed-days counter, so the forced
# runs of many jobs land on the same day and cost one drive spin-up between
# them rather than one each. See modules/sync/sync.sh.

# calendar_spec_valid <spec>
# True when systemd can parse <spec>. False when systemd-analyze is missing,
# so callers must treat "cannot tell" as "do not rely on this spec".
calendar_spec_valid() {
    command -v systemd-analyze &>/dev/null || return 1
    systemd-analyze calendar "$1" &>/dev/null
}

# calendar_matches_day <spec> [YYYY-MM-DD]
# True when <spec> fires at some point during that day (default: today).
#
# systemd-analyze reports the next elapse *strictly after* --base-time, so the
# base has to be the last second of the previous day: with --base-time set to
# midnight itself, "Thu" asked on a Thursday answers with next Thursday.
calendar_matches_day() {
    local spec="$1" day="${2:-$(date +%F)}"
    local base_epoch base next

    [[ -n "$spec" ]] || return 1
    base_epoch=$(date -d "${day} 00:00:00" +%s 2>/dev/null) || return 1
    base=$(date -d "@$(( base_epoch - 1 ))" '+%Y-%m-%d %H:%M:%S')

    next=$(systemd-analyze calendar --base-time="$base" --iterations=1 "$spec" 2>/dev/null \
           | sed -n 's/.*Next elapse: *//p' \
           | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
           | head -1)
    [[ -n "$next" && "$next" == "$day" ]]
}
