#!/usr/bin/env bash
# lib/files.sh — writing generated files idempotently.
# Source this file; do not execute directly.
# Requires: lib/log.sh already sourced.

# write_if_changed PATH CONTENT [LOG_PREFIX]
#
# Write CONTENT to PATH only if it differs from what is already there, logging
# when it does. Returns 0 if the file was written, 1 if it was already correct.
#
# The return value is the useful half: several callers only want to run
# `systemctl daemon-reload`, re-enable a unit, or set a CHANGED flag when
# something actually changed, and the alternative is re-reading the file to
# find out what was just done to it.
#
# Every setup.sh generates units this way, and before this helper each carried
# its own copy of
#
#     if [[ ! -f "$f" ]] || ! diff -q <(echo "$c") "$f" &>/dev/null; then
#         log_info "Writing ${f}"; echo "$c" > "$f"; fi
#
# — eighteen of them across nine files (backlog #24). Being idempotent matters
# more here than it looks: apply.sh runs on every config change, and rewriting
# an unchanged unit file would churn its mtime and, for anything watched with a
# hash stamp, make it look modified.
#
# printf rather than echo: echo mangles content beginning with -n or -e, and
# with xpg_echo set it would also interpret backslash escapes in the body of a
# unit file. For the content NASe generates the two are equivalent today; this
# just removes the question.
write_if_changed() {
    local path="$1" content="$2" prefix="${3-  }"
    if [[ -f "$path" ]] && printf '%s\n' "$content" | diff -q - "$path" &>/dev/null; then
        return 1
    fi
    log_info "${prefix}Writing ${path}"
    printf '%s\n' "$content" > "$path"
    return 0
}
