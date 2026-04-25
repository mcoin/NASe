#!/usr/bin/env bash
# lib/log.sh — logging helpers
# Source this file; do not execute directly.

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

log_info()    { echo -e "${_CLR_CYAN}[INFO]${_CLR_RESET}  $*"; }
log_ok()      { echo -e "${_CLR_GREEN}[OK]${_CLR_RESET}    $*"; }
log_warn()    { echo -e "${_CLR_YELLOW}[WARN]${_CLR_RESET}  $*" >&2; }
log_error()   { echo -e "${_CLR_RED}[ERROR]${_CLR_RESET} $*" >&2; }
log_section() { echo -e "\n${_CLR_BOLD}=== $* ===${_CLR_RESET}"; }

# Print an error and exit with code 1.
die() {
    log_error "$*"
    exit 1
}
