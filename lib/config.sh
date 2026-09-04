#!/usr/bin/env bash
# lib/config.sh — thin wrappers around yq for reading config.yaml.
# Source this file; do not execute directly.
#
# Requires: REPO_ROOT and CONFIG_FILE to be set by the caller,
#           and yq (mikefarah/yq v4) to be on PATH.

CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/config.yaml}"

# config_get <yq-expression>
# Print the scalar value at the given path.
# Returns the empty string (and exit 0) if the key is absent or null.
config_get() {
    local val
    val=$(yq eval "$1" "$CONFIG_FILE")
    # yq prints "null" for missing keys; normalise to empty string
    if [[ "$val" == "null" ]]; then
        echo ""
    else
        echo "$val"
    fi
}

# config_len <yq-expression>
# Print the length of the array at the given path (0 if absent).
config_len() {
    local val
    val=$(yq eval "${1} | length" "$CONFIG_FILE")
    echo "${val:-0}"
}

# config_bool <yq-expression>
# Exit 0 if the boolean is true, exit 1 otherwise.
config_bool() {
    local val
    val=$(config_get "$1")
    [[ "$val" == "true" ]]
}

# config_idx <array-yq-path> <index> <field-yq-path>
# E.g.: config_idx '.drives' 0 '.name'
config_idx() {
    config_get "${1}[${2}]${3}"
}

# schedule_slug <systemd-calendar-expression>
# Derive a stable, readable unit-name fragment from a schedule string.
# E.g. '*-*-* 03:00:00' -> '03-00-00', 'Mon *-*-* 04:00' -> 'mon-04-00'.
#
# Sync jobs sharing a schedule are driven by one group timer (backlog #4,
# phase 2 option C), and the group's unit is named after the schedule. Both
# modules/sync/setup.sh (which writes the unit) and modules/sync/run-group.sh
# (which the unit invokes, and which re-reads config to find its jobs) derive
# the slug from the same schedule string, so this must live in one place —
# if the two ever disagreed the timer would fire a runner that finds no jobs.
schedule_slug() {
    local s="${1,,}"
    # Collapse every run of non-alphanumerics to a single dash, then trim.
    s=$(printf '%s' "$s" | tr -cs '[:alnum:]' '-')
    s="${s#-}"
    s="${s%-}"
    printf '%s' "$s"
}
