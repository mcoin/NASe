#!/usr/bin/env bash
# lib/config.sh — reading config.yaml.
# Source this file; do not execute directly.
#
# Requires: REPO_ROOT and CONFIG_FILE to be set by the caller,
#           and yq (mikefarah/yq v4) to be on PATH.
#
# The whole file is parsed once, with a single yq invocation, into a flat
# associative array; the accessors below are then pure string lookups.
#
# It used to be one yq process per field. That is 248 call sites in production
# code (config_idx alone accounts for 139), and most of them sit inside a loop
# over drives or sync jobs, so the real number of forks was a multiple of that:
# modules/drives/spin_sample.sh re-read every sync job's name, source and dest
# from yq on every drive, every five minutes. See backlog #24.
#
# Loaded eagerly, at the bottom of this file, and that is deliberate rather
# than lazy. Almost every call site is `x=$(config_get ...)`, which runs in a
# subshell — a cache populated there dies with it, so a lazily built one would
# be rebuilt on every single call and be slower than what it replaced. Built in
# the parent at source time, every subshell inherits it already populated.

CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/config.yaml}"

declare -gA _CONFIG_CACHE=()
_CONFIG_CACHE_KEY=""

# _config_cache_key — file identity, so a config edited mid-run is noticed.
_config_cache_key() {
    printf '%s:%s' "$CONFIG_FILE" "$(stat -c '%Y:%s' "$CONFIG_FILE" 2>/dev/null || echo 0)"
}

# _config_load — parse CONFIG_FILE into _CONFIG_CACHE unless already current.
#
# `yq -o=props` flattens everything to "a.b.0.c = value" lines, which is the
# same shape the accessors want after normalising their expressions, so no
# structure has to be rebuilt in bash.
_config_load() {
    local want
    want=$(_config_cache_key)
    [[ "$want" == "$_CONFIG_CACHE_KEY" ]] && return 0
    _CONFIG_CACHE=()
    _CONFIG_CACHE_KEY="$want"
    [[ -r "$CONFIG_FILE" ]] || return 0
    local line key val
    while IFS= read -r line; do
        # props output carries the document's comments through as-is.
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%% = *}"
        [[ "$key" != "$line" ]] || continue          # no separator on this line
        val="${line#* = }"                            # first " = " only; keys have no spaces
        _CONFIG_CACHE["$key"]="$val"
    done < <(yq -o=props '.' "$CONFIG_FILE" 2>/dev/null)
    return 0
}

# _config_path <yq-path-expression>
# ".drives[0].name" -> "drives.0.name", matching the props key form.
_config_path() {
    local p="${1#.}"
    p="${p//\[/.}"
    p="${p//\]/}"
    printf '%s' "$p"
}

# config_get <yq-expression>
# Print the scalar value at the given path.
# Returns the empty string (and exit 0) if the key is absent or null.
#
# Supports the two forms the codebase actually uses: a dotted path, optionally
# with [N] indices, and an optional `// default` suffix. Anything more
# elaborate would need yq and is not used anywhere.
config_get() {
    local expr="$1" default="" has_default=false path val
    if [[ "$expr" == *" // "* ]]; then
        has_default=true
        default="${expr#* // }"
        expr="${expr%% // *}"
        [[ "$default" == '"'*'"' ]] && { default="${default#\"}"; default="${default%\"}"; }
    fi

    _config_load
    path=$(_config_path "$expr")

    if [[ -z "${_CONFIG_CACHE[$path]+x}" ]]; then
        $has_default && { printf '%s\n' "$default"; return 0; }
        echo ""
        return 0
    fi
    val="${_CONFIG_CACHE[$path]}"

    # yq's props writer escapes newlines, so a block scalar would come back as
    # a literal \n rather than a real one. Nothing in config.yaml is multi-line
    # today; ask yq directly rather than hand back something subtly wrong if
    # that ever changes.
    if [[ "$val" == *'\n'* ]]; then
        val=$(yq eval "$expr" "$CONFIG_FILE" 2>/dev/null)
    fi

    if [[ "$val" == "null" ]]; then
        $has_default && { printf '%s\n' "$default"; return 0; }
        echo ""
        return 0
    fi
    # `a // b` in yq yields b when a is null *or false*, not merely absent.
    # Reproduced rather than corrected: this is a behaviour-preserving change,
    # and the one place it bites (a boolean with a `// "true"` default) is
    # tracked separately.
    if $has_default && [[ "$val" == "false" ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    printf '%s\n' "$val"
}

# config_len <yq-expression>
# Print the length of the array at the given path (0 if absent).
#
# Counted from the flattened keys: a sequence appears as "<path>.<n>....", so
# the length is the highest index seen plus one. Every call site in the tree
# asks about a sequence (.drives, .sync_jobs, .samba.shares, .samba.users,
# .file_watch); `length` on a map would mean something different and is not
# used.
config_len() {
    _config_load
    local path n=0 k rest idx
    path=$(_config_path "$1")
    for k in "${!_CONFIG_CACHE[@]}"; do
        [[ "$k" == "$path".* ]] || continue
        rest="${k#"$path".}"
        idx="${rest%%.*}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        (( idx + 1 > n )) && n=$(( idx + 1 ))
    done
    printf '%s\n' "$n"
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
# Lowercase, non-alphanumerics collapsed to single dashes, trimmed.
schedule_slug() {
    local s="${1,,}"
    # Collapse every run of non-alphanumerics to a single dash, then trim.
    s=$(printf '%s' "$s" | tr -cs '[:alnum:]' '-')
    s="${s#-}"
    s="${s%-}"
    printf '%s' "$s"
}

# Populate now, in the caller's shell, so the subshells that every
# `$(config_get ...)` creates inherit a warm cache instead of rebuilding it.
_config_load
