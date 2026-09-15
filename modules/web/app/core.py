#!/usr/bin/env python3
"""Shared foundation for the NASe dashboard: paths, auth, templates, config.

Everything here is imported by the feature modules as `core`, and always
referenced through that module object — never `from .core import X`. Several of
these names (CONFIG_FILE, STAMP_DIR, _run, ...) are monkeypatched by the tests,
and a `from` import would bind the original value at import time, leaving the
tests green while the code read the real path.
"""
from __future__ import annotations

import os
import secrets
import subprocess
from pathlib import Path

import yaml
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates

# ── Paths ──────────────────────────────────────────────────────────────────────
APP_DIR     = Path(__file__).parent
# parents[2], not .parent.parent: APP_DIR is <repo>/modules/web/app, so two
# levels up is <repo>/modules and CONFIG_FILE becomes <repo>/modules/config.yaml.
# nase-web.service always sets REPO_ROOT, which masked this — it only shows up
# running uvicorn by hand, where every request 500s on a missing config file.
REPO_ROOT   = Path(os.environ.get("REPO_ROOT", APP_DIR.parents[2]))
CONFIG_FILE = REPO_ROOT / "config.yaml"
STAMP_DIR   = Path("/var/lib/nase")
LOG_DIR     = Path("/var/log/nase")
CENTRAL_LOG = LOG_DIR / "nase.log"
EVENTS_LOG  = Path(os.environ.get("NASE_EVENTS_LOG", str(STAMP_DIR / "primary-events.log")))
SPIN_HISTORY_LOG = STAMP_DIR / "spin-history.log"
# Archived status reports, one <generated_at>.json per report, written by
# modules/status-report/write_report.py. Always read from here, never from the
# copy config-archive puts on the drive — serving that would spin both drives
# up on every page view, which is the mistake #29 removed from the report
# generator itself (backlog #37).
REPORTS_DIR = Path(os.environ.get("NASE_REPORTS_DIR", str(STAMP_DIR / "reports")))
BACKLOG_FILE = Path(os.environ.get("NASE_BACKLOG_FILE", str(STAMP_DIR / "backlog.json")))

_CHANGES_PAGE_SIZE = 20
_WINDOW_SECS  = {"hour": 3600, "day": 86400, "week": 604800, "month": 2592000}
_WINDOW_LABEL = {"hour": "1 hour", "day": "24 hours", "week": "7 days", "month": "30 days"}

# ── Auth ───────────────────────────────────────────────────────────────────────
_WEB_USERNAME = os.environ.get("WEB_USERNAME", "nase")
_WEB_PASSWORD = os.environ.get("WEB_PASSWORD", "")
_http_basic   = HTTPBasic(realm="NASe")

# Marks the "server has no password configured" 401 apart from the ordinary
# "wrong password" one, so the error page can tell the two apart: only the
# first is something the user can fix, and it needs different advice.
_AUTH_UNCONFIGURED = "WEB_PASSWORD not set in .env"

def _require_auth(credentials: HTTPBasicCredentials = Depends(_http_basic)):
    if not _WEB_PASSWORD:
        raise HTTPException(status_code=401,
                            detail=_AUTH_UNCONFIGURED,
                            headers={"WWW-Authenticate": 'Basic realm="NASe"'})
    ok = (
        secrets.compare_digest(credentials.username.encode(), _WEB_USERNAME.encode())
        and secrets.compare_digest(credentials.password.encode(), _WEB_PASSWORD.encode())
    )
    if not ok:
        raise HTTPException(status_code=401,
                            headers={"WWW-Authenticate": 'Basic realm="NASe"'})

# ── Templates ──────────────────────────────────────────────────────────────────
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))

# Cache-bust static assets by fingerprinting at startup.
try:
    _css_v = str(int((APP_DIR / "static" / "style.css").stat().st_mtime))
except FileNotFoundError:
    _css_v = "0"
templates.env.globals["css_v"] = _css_v

def protected_router() -> APIRouter:
    """A fresh router whose every route requires authentication.

    A factory rather than one shared instance: each feature module includes its
    own router into the app, and the same APIRouter object cannot be included
    twice."""
    return APIRouter(dependencies=[Depends(_require_auth)])

# ── Config ─────────────────────────────────────────────────────────────────────
def load_config() -> dict:
    with open(CONFIG_FILE) as f:
        return yaml.safe_load(f)

# ── Subprocess ─────────────────────────────────────────────────────────────────
def _run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), capture_output=True, text=True)
