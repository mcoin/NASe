#!/usr/bin/env bash
# tests/web/run.sh — run Python tests for the web dashboard.
# Usage: bash tests/web/run.sh [pytest args...]
#
# One-time setup (requires root):
#   sudo /opt/nase/modules/web/venv/bin/pip install pytest httpx
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${REPO_ROOT}/modules/web/venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo "SKIP: web venv not found (run sudo ./apply.sh first)"
    exit 0
fi

if ! "$PYTHON" -m pytest --version &>/dev/null 2>&1; then
    echo "SKIP: pytest not installed in web venv"
    echo "      Run: sudo ${PYTHON} -m pip install pytest httpx"
    exit 0
fi

cd "$REPO_ROOT"
"$PYTHON" -m pytest tests/web/ -v "$@"
