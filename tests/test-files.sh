#!/usr/bin/env bash
# tests/test-files.sh — lib/files.sh (backlog #24, item 5).
#
# write_if_changed replaced eighteen hand-rolled copies of the same
# "write the unit only if it changed" block across nine files. Two properties
# carry the weight: it must not rewrite a file whose content already matches
# (apply.sh runs on every config change, and churning a unit's mtime would make
# anything tracking it by hash think it had been edited), and its return value
# must tell the caller whether it wrote, because several of them only want to
# daemon-reload or set a CHANGED flag when something actually changed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/files.sh"

echo "=== lib/files.sh ==="
echo ""

WORK=$(mktemp -d /tmp/nase-test-files.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
F="${WORK}/unit.service"

# ── Writing ──────────────────────────────────────────────────────────────────
assert_exit0 "writes a file that does not exist yet" \
    write_if_changed "$F" "hello"
assert_eq "and the content is what was asked for" "hello" "$(cat "$F")"

assert_exit1 "reports no change when the content already matches" \
    write_if_changed "$F" "hello"

assert_exit0 "writes when the content differs" \
    write_if_changed "$F" "goodbye"
assert_eq "and replaces the old content" "goodbye" "$(cat "$F")"

# ── Not touching an unchanged file ───────────────────────────────────────────
# The property apply.sh depends on. Comparing mtime rather than content,
# because "wrote identical bytes" and "did not write" are indistinguishable by
# content alone and only the second one is correct here.
touch -d "2020-01-01 00:00:00" "$F"
before=$(stat -c %Y "$F")
write_if_changed "$F" "goodbye" >/dev/null || true
assert_eq "an unchanged file is not rewritten at all" "$before" "$(stat -c %Y "$F")"

write_if_changed "$F" "something else" >/dev/null || true
assert_exit1 "a changed file is rewritten (mtime moves)" \
    test "$before" = "$(stat -c %Y "$F")"

# ── Content that would confuse echo ──────────────────────────────────────────
# The reason the helper uses printf: `echo "-n"` prints nothing, `echo "-e"`
# prints nothing, and with xpg_echo set backslash escapes in a unit body would
# be interpreted. Unit files are generated text and must survive verbatim.
for tricky in "-n" "-e" "-neE" 'back\slash' 'tab\there' '%s %d percent'; do
    write_if_changed "$F" "$tricky" >/dev/null || true
    assert_eq "content preserved verbatim: ${tricky}" "$tricky" "$(cat "$F")"
done

# Multi-line content, which is what a unit file actually is.
UNIT='[Unit]
Description=NASe test

[Service]
ExecStart=/bin/true'
write_if_changed "$F" "$UNIT" >/dev/null || true
assert_eq "multi-line content round-trips" "$UNIT" "$(cat "$F")"
assert_exit1 "and is then seen as unchanged" write_if_changed "$F" "$UNIT"

# ── Byte-compatibility with the code this replaced ───────────────────────────
# The eighteen call sites used `echo "$content" > "$file"`. If printf disagreed
# by even a trailing newline, the first apply.sh after this change would
# rewrite every unit on the system and daemon-reload for nothing.
OLD="${WORK}/old"; NEW="${WORK}/new"
echo "$UNIT" > "$OLD"
printf '%s\n' "$UNIT" > "$NEW"
assert_exit0 "printf output is byte-identical to the echo it replaced" \
    diff -q "$OLD" "$NEW"

# ── Logging ──────────────────────────────────────────────────────────────────
LOGGED="${WORK}/log"
NAS_LOG="$LOGGED" write_if_changed "${WORK}/logged.service" "x" "    " >/dev/null || true
assert_contains "logs the path it wrote" "logged.service" "$(cat "$LOGGED")"
assert_contains "honours the caller's indent" "    Writing" "$(cat "$LOGGED")"

: > "$LOGGED"
NAS_LOG="$LOGGED" write_if_changed "${WORK}/logged.service" "x" "    " >/dev/null || true
assert_empty "says nothing when it did not write" "$(cat "$LOGGED")"

test_summary
