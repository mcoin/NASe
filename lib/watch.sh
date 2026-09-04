#!/usr/bin/env bash
# lib/watch.sh
# Reading the primary-watch event log as a change-detection source.
#
# Sync change detection used to run `find "$source" -newer "$STAMP_FILE"`,
# which walks the source tree and therefore wakes the primary drive every
# night even when every job then decides it has nothing to do (backlog #4).
# modules/primary-watch/record.sh already maintains an event log on the SD
# card; this reads it instead, so a quiet night costs no drive access at all.
#
# The whole design rests on one rule: SILENCE IS ONLY EVIDENCE IF THE WATCHER
# CAN VOUCH FOR IT. An empty answer from a dead watcher is indistinguishable
# from an empty answer from a quiet drive, and treating the former as "nothing
# changed" would silently stop backing up for ever. So every uncertainty here
# resolves toward "cannot vouch", and the caller falls back to the find.

# Timestamps in the event log are 'YYYY-MM-DD HH:MM:SS' local time. That format
# is fixed-width and zero-padded, so lexical comparison is chronological — which
# lets awk filter without parsing a date per line.
WATCH_EVENTS_LOG="${NASE_EVENTS_LOG:-${NASE_STAMP_DIR:-/var/lib/nase}/primary-events.log}"

# How stale the newest line may be before we stop believing the watcher is
# alive. record.sh beats every NASE_WATCH_HEARTBEAT_SECS (default 300); allow
# several missed beats so ordinary scheduling jitter is not read as death.
WATCH_MAX_SILENCE_SECS="${NASE_WATCH_MAX_SILENCE_SECS:-1200}"

# watch_vouch_failure <since-epoch>
# Print the reason the log cannot vouch for everything since <since-epoch>, or
# nothing at all if it can. Exit status is 0 when it CAN vouch.
watch_vouch_failure() {
    local since_epoch="$1" since_str now_epoch newest_str newest_epoch
    since_str=$(date -d "@${since_epoch}" '+%Y-%m-%d %H:%M:%S')
    now_epoch=$(date +%s)

    if [[ ! -r "$WATCH_EVENTS_LOG" ]]; then
        echo "event log '${WATCH_EVENTS_LOG}' is not readable"
        return 1
    fi

    # 1. Is the watcher alive now? The newest line of any kind answers this,
    #    because a running watcher emits heartbeats even when nothing changes.
    newest_str=$(tail -n 1 "$WATCH_EVENTS_LOG" 2>/dev/null | cut -f1)
    if [[ -z "$newest_str" ]]; then
        echo "event log is empty"
        return 1
    fi
    newest_epoch=$(date -d "$newest_str" +%s 2>/dev/null) || {
        echo "event log's last line has an unparseable timestamp"
        return 1
    }
    if (( now_epoch - newest_epoch > WATCH_MAX_SILENCE_SECS )); then
        echo "watcher last spoke $(( (now_epoch - newest_epoch) / 60 ))m ago (max $(( WATCH_MAX_SILENCE_SECS / 60 ))m) — may be dead"
        return 1
    fi

    # 2. Does the log reach back far enough to cover the window? If its oldest
    #    line is newer than the stamp, the earlier part of the window was never
    #    observed.
    local oldest_str
    oldest_str=$(head -n 1 "$WATCH_EVENTS_LOG" 2>/dev/null | cut -f1)
    if [[ -z "$oldest_str" || "$oldest_str" > "$since_str" ]]; then
        echo "event log starts at '${oldest_str:-?}', after the stamp '${since_str}' — window not covered"
        return 1
    fi

    # 3. Was there a hole in the window? record.sh writes a __gap__ line on
    #    every start and after pruning, so any gap at or after the stamp means
    #    events may have been missed.
    local gap
    gap=$(awk -F'\t' -v s="$since_str" '$2=="__gap__" && $1>=s {print $1": "$3; exit}' \
          "$WATCH_EVENTS_LOG" 2>/dev/null)
    if [[ -n "$gap" ]]; then
        echo "watcher recorded a gap in the window (${gap})"
        return 1
    fi

    return 0
}

# watch_first_event_since <since-epoch> <path-prefix>
# Print the first real file event under <path-prefix> at or after the given
# time, as "<timestamp>\t<op>\t<path>". Prints nothing when there are none.
#
# Uses >= rather than > on the timestamp: the log has one-second resolution, so
# an event in the same second as the stamp would otherwise be dropped. Erring
# toward syncing is the only safe direction.
watch_first_event_since() {
    local since_epoch="$1" prefix="$2" since_str
    since_str=$(date -d "@${since_epoch}" '+%Y-%m-%d %H:%M:%S')
    # Normalise to exactly one trailing slash so '/mnt/primary/movies' cannot
    # also match '/mnt/primary/movies-old/...'.
    prefix="${prefix%/}/"
    awk -F'\t' -v s="$since_str" -v p="$prefix" \
        '$1>=s && $2!="__gap__" && $2!="__heartbeat__" && index($3, p)==1 {print; exit}' \
        "$WATCH_EVENTS_LOG" 2>/dev/null
}
