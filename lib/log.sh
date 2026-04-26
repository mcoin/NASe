#!/usr/bin/env bash
# lib/log.sh — logging helpers
# Source this file; do not execute directly.

# Central log file — all NASe actions are appended here with timestamps.
NAS_LOG="${NAS_LOG:-/var/log/nase/nase.log}"

# Colours (disabled when not a terminal)
if [[ -t 1 ]]; then
    _CLR_RESET='\033[0m'
    _CLR_RED='\033[0;31m'
    _CLR_YELLOW='\033[0;33m'
    _CLR_GREEN='\033[0;32m'
    _CLR_CYAN='\033[0;36m'
    _CLR_BOLD='\033[1m'
else
    _CLR_RESET='' _CLR_RED='' _CLR_YELLOW='' _CLR_GREEN='' _CLR_CYAN='' _CLR_BOLD=''
fi

# Append a timestamped line to the log file.
# Creates the directory if it doesn't exist yet; silently skips if not writable.
_log_to_file() {
    local level="$1"; shift
    local dir
    dir=$(dirname "$NAS_LOG")
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" >> "$NAS_LOG" 2>/dev/null || true
}

log_info()    { echo -e "${_CLR_CYAN}[INFO]${_CLR_RESET}  $*";  _log_to_file "INFO " "$*"; }
log_ok()      { echo -e "${_CLR_GREEN}[OK]${_CLR_RESET}    $*"; _log_to_file "OK   " "$*"; }
log_warn()    { echo -e "${_CLR_YELLOW}[WARN]${_CLR_RESET}  $*" >&2; _log_to_file "WARN " "$*"; }
log_error()   { echo -e "${_CLR_RED}[ERROR]${_CLR_RESET} $*" >&2; _log_to_file "ERROR" "$*"; }
log_section() { echo -e "\n${_CLR_BOLD}=== $* ===${_CLR_RESET}"; _log_to_file "-----" "=== $* ==="; }

# Print an error and exit with code 1.
die() {
    log_error "$*"
    exit 1
}
