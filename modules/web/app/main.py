#!/usr/bin/env python3
"""NASe web dashboard — FastAPI + HTMX."""
from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import subprocess
import threading
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

import yaml
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import (FileResponse, HTMLResponse, JSONResponse,
                               RedirectResponse, StreamingResponse)
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from ruamel.yaml import YAML as RuamelYAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.error import CommentMark
from ruamel.yaml.tokens import CommentToken
from starlette.exceptions import HTTPException as StarletteHTTPException

# ── Paths ──────────────────────────────────────────────────────────────────────
APP_DIR     = Path(__file__).parent
REPO_ROOT   = Path(os.environ.get("REPO_ROOT", APP_DIR.parent.parent))
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

app = FastAPI(title="NASe Dashboard")
app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))

# Cache-bust static assets by fingerprinting at startup.
try:
    _css_v = str(int((APP_DIR / "static" / "style.css").stat().st_mtime))
except FileNotFoundError:
    _css_v = "0"
templates.env.globals["css_v"] = _css_v

# Router whose routes all require authentication (config editing + apply).
_protected = APIRouter(dependencies=[Depends(_require_auth)])

# ── Error pages ────────────────────────────────────────────────────────────────
# By default an HTTPException renders as bare JSON, so cancelling the browser's
# Basic-auth dialog leaves the user staring at {"detail":"Not authenticated"} on
# a blank page. Serve humans a styled page instead, while machine clients — and
# the SSE streams, which must keep speaking event-stream — still get JSON.

def _error_text(status: int, detail: str) -> tuple[str, str, str | None]:
    """(heading, message, hint) for an error response. `hint` is a command or
    action the reader can act on, and is rendered as preformatted text."""
    if status == 401:
        if detail == _AUTH_UNCONFIGURED:
            return ("Dashboard password not configured",
                    "This dashboard has no password set, so it cannot let anyone "
                    "into the protected tabs.",
                    "Set WEB_PASSWORD in /opt/nase/.env, then run:\n"
                    "sudo systemctl restart nase-web")
        return ("Sign-in required",
                "The Config and Backlog tabs are password-protected. The sign-in "
                "was cancelled, or the username or password was wrong.",
                None)
    if status == 403:
        return ("Not allowed", detail or "You do not have access to this page.", None)
    if status == 404:
        return ("Not found", detail or "That page does not exist.", None)
    return (f"Error {status}", detail or "Something went wrong.", None)

def _hostname() -> str:
    """Hostname for the page chrome. Error pages must render even when the
    config file is missing or unparseable — which is itself a likely reason
    for an error — so fall back rather than raise from an error handler."""
    try:
        return load_config().get("nas", {}).get("hostname", "nase")
    except Exception:
        return "nase"

@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    # Registered on Starlette's HTTPException, not FastAPI's subclass, so it
    # also covers the 404s Starlette raises for unmatched routes.
    detail  = str(exc.detail) if exc.detail else ""
    headers = getattr(exc, "headers", None)
    # Keep WWW-Authenticate on 401s: drop it and browsers stop offering the
    # login dialog altogether, so the user could never sign in again.
    heading, message, hint = _error_text(exc.status_code, detail)

    if request.headers.get("hx-request"):
        # A partial swap must not inject a whole document into a card.
        return templates.TemplateResponse(
            request, "partials/error_inline.html",
            {"heading": heading, "message": message},
            status_code=exc.status_code, headers=headers)

    # EventSource sends "text/event-stream" and API clients "application/json";
    # neither accepts HTML, so both fall through to the JSON default below.
    if "text/html" in request.headers.get("accept", ""):
        return templates.TemplateResponse(
            request, "error.html",
            {"hostname": _hostname(), "status": exc.status_code, "heading": heading,
             "message": message, "hint": hint, "retry_path": request.url.path},
            status_code=exc.status_code, headers=headers)

    return JSONResponse({"detail": detail}, status_code=exc.status_code, headers=headers)

# ── Config ─────────────────────────────────────────────────────────────────────
def load_config() -> dict:
    with open(CONFIG_FILE) as f:
        return yaml.safe_load(f)

# ── systemd helpers ────────────────────────────────────────────────────────────
def _run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), capture_output=True, text=True)

# Written by modules/sync/setup.sh into each group timer's Description.
_SYNC_GROUP_DESC = "NASe sync group timer: "

def sync_group_units() -> dict[str, str]:
    """schedule string -> group timer unit name, as systemd actually has them.

    This used to be a schedule_slug() reimplemented here to match the one in
    lib/config.sh, with tests/test-sync-group.sh asserting the two agreed —
    a parity test between two implementations of one function being a fairly
    loud statement that the seam was in the wrong place (backlog #24 item 4).

    The shell names these units, and stamps the schedule verbatim into each
    unit's Description. Reading the mapping back out of systemd means the
    algorithm lives in exactly one place: whatever the shell actually created
    is what is found here, so the two cannot drift.
    """
    out = _run("systemctl", "show", "--property=Id", "--property=Description",
               "nase-sync-group-*.timer")
    mapping: dict[str, str] = {}
    # One block per unit, separated by blank lines; property order is not
    # guaranteed, so collect a block before interpreting it.
    for block in out.stdout.split("\n\n"):
        fields = dict(
            line.split("=", 1) for line in block.splitlines() if "=" in line
        )
        unit, desc = fields.get("Id", "").strip(), fields.get("Description", "").strip()
        if unit and desc.startswith(_SYNC_GROUP_DESC):
            mapping[desc[len(_SYNC_GROUP_DESC):]] = unit
    return mapping

def unit_active(unit: str) -> str:
    return _run("systemctl", "is-active", unit).stdout.strip() or "unknown"

def _relative_duration(seconds: int) -> str:
    """'90' -> '1min', '7300' -> '2h', etc. — shared by past ("X ago") and
    future ("in X") relative-time labels so both use the same thresholds."""
    if   seconds < 60:    return f"{seconds}s"
    elif seconds < 3600:  return f"{seconds // 60}min"
    elif seconds < 86400: return f"{seconds // 3600}h"
    else:                 return f"{seconds // 86400}d"

def unit_next(unit: str) -> tuple[str, str | None]:
    r = _run("systemctl", "show", unit,
             "--property=NextElapseUSecRealtime", "--value")
    val = r.stdout.strip()
    if not val or val in ("0", "n/a"):
        return "—", None
    r2 = _run("date", "-d", val, "+%Y-%m-%d %H:%M:%S %s")
    out = r2.stdout.strip()
    if not out:
        return "—", None
    dt, _, epoch_str = out.rpartition(" ")
    try:
        diff = int(epoch_str) - int(datetime.now().timestamp())
    except ValueError:
        return dt or "—", None
    return dt, f"in {_relative_duration(diff)}" if diff > 0 else None

# ── Drive info ─────────────────────────────────────────────────────────────────
def drive_info(drive: dict) -> dict:
    mp = drive.get("mountpoint", "")
    if drive.get("active") is False:
        return {"status": "inactive", "mode": None, "usage": None}
    # --mountpoint, not --target. --target resolves *up* to the nearest
    # enclosing mount, so with the drive absent it finds the SD card's root
    # mount, succeeds, and the "not mounted" branch below becomes unreachable.
    # The page then showed the drive as mounted rw with the SD card's df
    # figures — roughly 14 GB where 5.5 TB is expected — which is worse than
    # showing nothing, because it states positively that the drive is fine.
    # The shell side of this is is_mounted_at in lib/guards.sh (backlog #33).
    r = _run("findmnt", "--mountpoint", mp, "--noheadings")
    if r.returncode != 0 or not r.stdout.strip():
        return {"status": "not mounted", "mode": None, "usage": None}
    r_opts = _run("findmnt", "--mountpoint", mp,
                  "--output", "OPTIONS", "--noheadings", "--first-only")
    if r_opts.returncode != 0:
        return {"status": "not mounted", "mode": None, "usage": None}
    mode = "ro" if "ro" in r_opts.stdout.split(",") else "rw"
    r_df = _run("df", "-h", mp)
    usage = None
    if r_df.returncode == 0:
        df = r_df.stdout.splitlines()
        if len(df) >= 2:
            parts = df[1].split()
            if len(parts) >= 5:
                usage = f"{parts[2]} / {parts[1]} ({parts[4]})"
    return {"status": "mounted", "mode": mode, "usage": usage}

# ── Spin state ─────────────────────────────────────────────────────────────────
SPIN_STATUS_SCRIPT = REPO_ROOT / "modules" / "drives" / "spin_status.sh"

def drive_spin_info(name: str, active: bool) -> dict:
    if not active:
        return {"spin_state": None, "spin_duration": None, "spin_estimated": False}
    r = _run(str(SPIN_STATUS_SCRIPT), name)
    parts = r.stdout.split()
    if len(parts) != 3 or parts[0] == "unknown":
        return {"spin_state": None, "spin_duration": None, "spin_estimated": False}
    state, since, confidence = parts
    diff = int(datetime.now().timestamp()) - int(since)
    return {
        "spin_state": state,
        "spin_duration": _relative_duration(max(diff, 0)),
        "spin_estimated": confidence == "estimated",
    }

# ── Spin history / monitoring timeline ──────────────────────────────────────────
# Must match modules/drives/spin_sample.sh's timer interval (OnUnitActiveSec).
_SPIN_SAMPLE_INTERVAL_SECS = 300
# How long to trust the most recent sample enough to extend its bar to "now"
# before showing a gap instead — a few missed ticks are just noise, but a
# long silence (sampler disabled, drive removed) shouldn't be drawn over.
_SPIN_STALE_AFTER_SECS = _SPIN_SAMPLE_INTERVAL_SECS * 3

# The prefix of spin-history.log's columns this reader actually needs. The file
# is written by modules/drives/spin_sample.sh, which documents the full field
# list in its header; tests/web/test_app.py asserts the two still agree, so a
# column added or reordered there fails a test instead of silently emptying the
# Monitoring tab.
_SPIN_FIELDS_REQUIRED = ("epoch", "drive", "state", "method")

def _read_spin_history() -> dict[str, list[tuple[int, str, str]]]:
    """drive name -> chronological (epoch, state, wake_reason) samples, oldest first.

    wake_reason is "" except on a standby/unknown -> active transition sample,
    where spin_sample.sh records its best guess at what caused the wake.

    The guess is only a guess, and a demonstrably fallible one — it names the
    last sync job to have started before the wake, which on a night when no
    job touched the drive at all still names a sync job (backlog #4). So when
    the sample carries an I/O delta, it is folded into the reason text: the
    number of block requests that actually accompanied the wake is the thing
    that says whether the named cause is plausible.
    """
    try:
        lines = SPIN_HISTORY_LOG.read_text().splitlines() if SPIN_HISTORY_LOG.exists() else []
    except (PermissionError, OSError):
        lines = []
    per_drive: dict[str, list[tuple[int, str, str]]] = {}
    for line in lines:
        parts = line.split("\t")
        # Positional, with a minimum rather than an exact match on the field
        # count (backlog #24 item 4). The ladder this replaces listed 6, 5 and
        # 4 explicitly, which meant adding a seventh field to spin_sample.sh
        # without editing here would make every line fall through to `continue`
        # and blank the Monitoring tab — a silent, total failure for an
        # additive change. That nearly happened in c3f2d3d, where the I/O
        # column had to be added to both sides in one commit.
        #
        # Fields, in the order spin_sample.sh writes them:
        #   0 epoch  1 drive  2 state  3 method  4 reason  5 io_delta
        # Anything beyond is ignored here rather than rejected, so the writer
        # can grow without this having to know.
        if len(parts) < len(_SPIN_FIELDS_REQUIRED):
            continue
        ts_str, name, state = parts[0], parts[1], parts[2]
        reason   = parts[4] if len(parts) > 4 else "-"
        io_delta = parts[5] if len(parts) > 5 else "-"
        try:
            ts = int(ts_str)
        except ValueError:
            continue
        text = "" if reason == "-" else reason
        if text and io_delta != "-" and io_delta.isdigit():
            n = int(io_delta)
            text = f"{text} — {n} block request{'' if n == 1 else 's'} since last sample"
        per_drive.setdefault(name, []).append((ts, state, text))
    for samples in per_drive.values():
        samples.sort(key=lambda s: s[0])
    return per_drive

# Tick spacing per window — chosen so labels land on round wall-clock
# boundaries (":00", ":10", midnight, ...) instead of an arbitrary offset
# from "now", and so there are few enough of them to stay readable on a
# narrow (phone-width) screen.
_TICK_STEP_SECS = {"hour": 600, "day": 14400, "week": 86400, "month": 432000}

def _aligned_ticks(start: int, secs: int, step: int, fmt: str) -> list[dict]:
    now = start + secs
    # Align to local wall-clock boundaries, not raw UTC epoch multiples —
    # otherwise a 4-hour step would land on odd hours wherever the server's
    # UTC offset isn't itself a multiple of 4.
    local_offset = int(datetime.now().astimezone().utcoffset().total_seconds())
    first = ((start + local_offset) // step) * step - local_offset
    if first < start:
        first += step
    ticks = []
    t = first
    while t <= now:
        ticks.append({
            "pct":   round((t - start) / secs * 100, 3),
            "label": datetime.fromtimestamp(t).strftime(fmt),
        })
        t += step
    return ticks

def build_monitoring(cfg: dict, window: str = "day") -> dict:
    secs  = _WINDOW_SECS.get(window, 86400)
    now   = int(datetime.now().timestamp())
    start = now - secs
    per_drive = _read_spin_history()

    drives = []
    wake_events = []
    for d in cfg.get("drives", []):
        if d.get("active") is False:
            continue
        name    = d["name"]
        samples = per_drive.get(name, [])
        in_window = [s for s in samples if s[0] >= start]
        before    = [s for s in samples if s[0] < start]
        # Carry the last sample before the window in too, so the first bar
        # reflects the state that was already true at window start instead
        # of opening with a gap.
        windowed = ([before[-1]] if before else []) + in_window

        for ts, state, reason in in_window:
            if state == "active" and reason:
                wake_events.append({"ts": ts, "drive": name, "reason": reason})

        segments = []
        if windowed:
            # Collapse consecutive equal-state samples into runs, keeping
            # the reason recorded on the run's first (wake) sample.
            runs = []
            for ts, state, reason in windowed:
                if runs and runs[-1][1] == state:
                    continue
                runs.append((ts, state, reason))
            last_sample_ts = windowed[-1][0]
            for i, (run_start, state, reason) in enumerate(runs):
                if i + 1 < len(runs):
                    run_end = runs[i + 1][0]
                elif now - last_sample_ts <= _SPIN_STALE_AFTER_SECS:
                    run_end = now
                else:
                    run_end = last_sample_ts
                seg_start = max(run_start, start)
                seg_end   = min(run_end, now)
                if seg_end <= seg_start:
                    continue
                time_label = datetime.fromtimestamp(seg_start).strftime(
                    "%H:%M" if secs <= 86400 else "%m-%d %H:%M")
                if state == "active":
                    tooltip = f"Spinning up at {time_label}" + (f" — {reason}" if reason else "")
                else:
                    tooltip = f"{state.capitalize()} since {time_label}"
                segments.append({
                    "state":     state,
                    "left_pct":  round((seg_start - start) / secs * 100, 3),
                    "width_pct": round(max((seg_end - seg_start) / secs * 100, 0.05), 3),
                    "tooltip":   tooltip,
                })

        drives.append({"name": name, "segments": segments, "has_data": bool(windowed)})

    wake_events.sort(key=lambda e: e["ts"], reverse=True)
    wake_events = wake_events[:100]
    wake_fmt = "%H:%M" if secs <= 86400 else "%m-%d %H:%M"
    for e in wake_events:
        e["time"] = datetime.fromtimestamp(e["ts"]).strftime(wake_fmt)

    fmt  = "%H:%M" if secs <= 86400 else "%m-%d"
    step = _TICK_STEP_SECS.get(window, 14400)
    ticks = _aligned_ticks(start, secs, step, fmt)

    return {
        "drives":      drives,
        "window":      window,
        "label":       _WINDOW_LABEL.get(window, "24 hours"),
        "ticks":       ticks,
        "wake_events": wake_events,
    }

# ── Stamp info ─────────────────────────────────────────────────────────────────
def stamp_info(job_name: str, *, stamp_file: Path | None = None) -> tuple[str, str | None]:
    stamp = stamp_file if stamp_file is not None else STAMP_DIR / f"sync-{job_name}.stamp"
    if not stamp.exists():
        return "never", None
    mtime = stamp.stat().st_mtime
    dt    = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
    diff  = int(datetime.now().timestamp() - mtime)
    return dt, f"{_relative_duration(diff)} ago"

# ── Status builder ─────────────────────────────────────────────────────────────
def build_status(cfg: dict) -> dict:
    services = []
    services.append({
        "name":         "nase-monitor",
        "state":        unit_active("nase-monitor.timer"),
        "detail_label": "next",
        "detail":       unit_next("nase-monitor.timer")[0],
    })
    fb = cfg.get("services", {}).get("filebrowser", {})
    if fb.get("enabled"):
        state = unit_active("filebrowser.service")
        port  = fb.get("port", 8080)
        services.append({
            "name":         "filebrowser",
            "state":        state,
            "detail_label": "",
            "detail":       f":{port}" if state == "active" else "",
        })
    if cfg.get("tailscale", {}).get("enabled"):
        r = _run("tailscale", "status")
        services.append({
            "name":         "tailscale",
            "state":        "active" if r.returncode == 0 else "inactive",
            "detail_label": "",
            "detail":       "",
        })

    drives = [
        {**d, **drive_info(d), **drive_spin_info(d["name"], d.get("active") is not False)}
        for d in cfg.get("drives", [])
    ]

    timers = []

    # Config archive timer (shown first, separate from user data sync jobs)
    if cfg.get("config_archive"):
        unit  = "nase-config-archive.timer"
        state = unit_active(unit)
        last, ago = stamp_info("config-archive",
                               stamp_file=STAMP_DIR / "config-archive.stamp")
        next_dt, next_in = unit_next(unit) if state == "active" else ("—", None)
        timers.append({
            "name":    "config-archive",
            "state":   state,
            "next":    next_dt,
            "next_in": next_in,
            "last":    last,
            "ago":     ago,
        })

    # Looked up once for all jobs rather than derived per job — see
    # sync_group_units for why this is discovered rather than computed.
    groups = sync_group_units()
    for job in cfg.get("sync_jobs", []):
        name      = job["name"]
        # Jobs no longer carry their own timer: one group timer per distinct
        # schedule runs them in sequence (backlog #4 phase 2 option C), so the
        # next-trigger shown against a job is its group's.
        unit      = groups.get(job.get("schedule", ""), "")
        # No group timer for this schedule means apply.sh has not run since the
        # job was added. "inactive" is what the old code reported for that, via
        # systemctl on a unit name it had computed but that did not exist.
        state     = unit_active(unit) if unit else "inactive"
        last, ago = stamp_info(name)
        next_dt, next_in = unit_next(unit) if state == "active" else ("—", None)
        timers.append({
            "name":    name,
            "state":   state,
            "next":    next_dt,
            "next_in": next_in,
            "last":    last,
            "ago":     ago,
        })

    return {"services": services, "drives": drives, "timers": timers}

_VALID_JOB_NAME = re.compile(r"^[a-zA-Z0-9_-]+$")

# ── Log helpers ────────────────────────────────────────────────────────────────
def log_path(job: str | None) -> Path:
    if job and not _VALID_JOB_NAME.match(job):
        raise ValueError(f"Invalid job name: {job!r}")
    return Path(f"/var/log/nase-sync-{job}.log") if job else CENTRAL_LOG

def read_log(job: str | None, lines: int = 80) -> list[dict]:
    try:
        path = log_path(job)
    except ValueError:
        return []
    if not path.exists():
        return []
    try:
        with open(path) as f:
            raw = f.readlines()[-lines:]
    except (PermissionError, OSError):
        return []
    result = []
    for line in raw:
        text = line.rstrip("\n")
        if   "[OK   ]" in text: cls = "log-ok"
        elif "[WARN ]" in text: cls = "log-warn"
        elif "[ERROR]" in text: cls = "log-err"
        elif "[-----]" in text: cls = "log-section"
        else:                   cls = "log-info"
        result.append({"text": text, "cls": cls})
    return result

# ── File changes ───────────────────────────────────────────────────────────
# .nase/ (integrity manifest internals) and .trash/ (sync retention) are
# internal bookkeeping, not user activity — never show them here, even for
# entries logged before record.sh started excluding them (retention is 90
# days, so old entries can linger).
_CHANGES_EXCLUDE_RE = re.compile(r"^/mnt/[^/]+/\.(nase|trash)(/|$)")

def build_changes(window: str = "day", page: int = 1, group: bool = False) -> dict:
    secs = _WINDOW_SECS.get(window, 86400)
    since_str = datetime.fromtimestamp(datetime.now().timestamp() - secs).strftime("%Y-%m-%d %H:%M:%S")

    latest_ts: dict[str, str] = {}
    latest_op: dict[str, str] = {}
    counts:    dict[str, int] = {}

    try:
        log_lines_iter = open(EVENTS_LOG).readlines() if EVENTS_LOG.exists() else []
    except (PermissionError, OSError):
        log_lines_iter = []
    for line in log_lines_iter:
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) < 3:
            continue
        ts, op, path = parts
        if ts < since_str:
            continue
        if _CHANGES_EXCLUDE_RE.match(path):
            continue
        counts[path] = counts.get(path, 0) + 1
        if path not in latest_ts or ts > latest_ts[path]:
            latest_ts[path] = ts
            latest_op[path] = op

    items = []
    for path, ts in latest_ts.items():
        parts = path.split("/")
        # path: /mnt/primary/<share>/...  →  parts = ['', 'mnt', 'primary', share, ...]
        if len(parts) > 3 and parts[1] == "mnt":
            share = parts[3] if len(parts) > 3 else "(root)"
            rel   = "/".join(p for p in parts[4:] if p) or parts[-1]
        else:
            share = "(root)"
            rel   = parts[-1] if parts else path
        items.append({"ts": ts, "share": share, "rel": rel,
                      "op": latest_op[path], "count": counts[path]})

    # Sort: (share ASC, ts DESC) when grouped; ts DESC otherwise.
    # Two-pass stable sort achieves (primary ASC, secondary DESC).
    if group:
        items.sort(key=lambda x: x["ts"], reverse=True)
        items.sort(key=lambda x: x["share"])
    else:
        items.sort(key=lambda x: x["ts"], reverse=True)

    total  = len(items)
    pages  = max(1, -(-total // _CHANGES_PAGE_SIZE))
    page   = max(1, min(page, pages))
    sliced = items[(page - 1) * _CHANGES_PAGE_SIZE : page * _CHANGES_PAGE_SIZE]

    rows: list[dict] = []
    if group:
        cur_share: str | None = None
        for item in sliced:
            if item["share"] != cur_share:
                cur_share = item["share"]
                rows.append({"type": "header", "share": cur_share})
            rows.append({"type": "item", **item})
    else:
        rows = [{"type": "item", **item} for item in sliced]

    return {
        "rows":   rows,
        "total":  total,
        "page":   page,
        "pages":  pages,
        "window": window,
        "label":  _WINDOW_LABEL.get(window, "24 hours"),
        "group":  group,
        "since":  since_str,
    }

# ── Integrity manifest (modules/integrity) ────────────────────────────────────
# Status is read from a cache the integrity scripts write to the SD card
# after every write to a drive's manifest (modules/integrity/common.sh's
# integrity_write_status_cache) — never from the manifest DB on the drive
# itself. This page polls every 60s (see partials/integrity.html); querying
# the drive-hosted DB directly on every poll would keep a drive that's
# otherwise idle from ever spinning down for as long as the tab stayed
# open. The trade-off: numbers here lag reality by however long it's been
# since the drive last actually ran an integrity pass — see "updated_at".
def _integrity_cache_path(mountpoint: str) -> Path:
    # STAMP_DIR read at call time, not import time, so tests can monkeypatch it.
    slug = mountpoint.strip("/").replace("/", "-")
    return STAMP_DIR / "integrity-status" / f"{slug}.json"

def drive_integrity_info(name: str, mountpoint: str) -> dict:
    cache = _integrity_cache_path(mountpoint)
    if not mountpoint or not cache.exists():
        return {"name": name, "mountpoint": mountpoint, "has_manifest": False}
    try:
        data = json.loads(cache.read_text())
    except (OSError, ValueError):
        return {"name": name, "mountpoint": mountpoint, "has_manifest": False}

    total_n = data.get("total", 0)
    discovery_complete = bool(data.get("discovery_complete"))
    discovery_pct = None
    if not discovery_complete:
        try:
            discovery_total = int(data.get("discovery_total") or 0)
        except (TypeError, ValueError):
            discovery_total = 0
        if discovery_total > 0:
            discovery_pct = round(min(100, total_n / discovery_total * 100))

    flagged_rows = data.get("flagged_rows") or []
    flagged = [
        {
            "path":       row.get("path", ""),
            "checked":    datetime.fromtimestamp(row["last_checked"]).strftime("%Y-%m-%d %H:%M:%S")
                          if row.get("last_checked") else "—",
            "event_type": row.get("event_type") or "unknown",
            "detail":     row.get("detail") or "",
        }
        for row in flagged_rows
    ]

    updated_at = data.get("updated_at")

    return {
        "name":               name,
        "mountpoint":         mountpoint,
        "has_manifest":       True,
        "total":              total_n,
        "ok":                 data.get("ok", 0),
        "flagged":            data.get("flagged", 0),
        "discovery_complete": discovery_complete,
        "discovery_pct":      discovery_pct,
        "flagged_rows":       flagged,
        "flagged_truncated":  bool(data.get("flagged_truncated")),
        "updated_at":         datetime.fromtimestamp(updated_at).strftime("%Y-%m-%d %H:%M:%S")
                              if updated_at else None,
    }

def build_integrity(cfg: dict) -> dict:
    enabled = bool(cfg.get("integrity", {}).get("enabled"))
    drives = [
        drive_integrity_info(d["name"], d.get("mountpoint", ""))
        for d in cfg.get("drives", [])
        if d.get("active") is not False
    ]
    return {"enabled": enabled, "drives": drives}

# ── Backlog (feature-request list for NASe itself) ─────────────────────────────
# Stored as a small JSON file in STAMP_DIR rather than config.yaml — this is a
# planning list for the app, not a device setting, so it has nothing to do
# with apply.sh. List order is the backlog priority order (top = highest).
# A single in-process lock is enough: nase-web.service runs one uvicorn
# worker, and read-modify-write here is cheap and rare (a person clicking
# buttons, not a hot path).
_backlog_lock = threading.Lock()

_BACKLOG_TYPES    = {"bug", "feature", "improvement"}
# "closed" = decided against, won't be implemented. Unlike "deleted" it stays
# visible in the default view: it's a deliberate outcome worth seeing (and
# worth linking to as a duplicate target), not a mis-click to be hidden away.
_BACKLOG_STATUSES = {"open", "ready", "in_progress", "done", "closed", "deleted"}
# "active" is a pseudo-status: it spans everything still waiting to be worked
# on or being worked on right now. It's only ever a filter, never stored on an
# item. "in_progress" has to be in here: "active" is the default view, so a
# ticket being worked on would otherwise vanish from the one view most likely
# to be open — and it would vanish silently, which is worse than an error.
_BACKLOG_ACTIVE_STATUSES = {"open", "ready", "in_progress"}
_BACKLOG_FILTERS  = {"all", "active"} | _BACKLOG_STATUSES
# Opening the Backlog tab should show the work that's left, not a wall of
# finished and abandoned tickets, so "active" — not "all" — is the default.
_BACKLOG_DEFAULT_FILTER = "active"

# Link relationship types. Each is stored from the perspective of the item
# that owns it ("this item <label> <target>"); adding a link writes the
# chosen type on this item and the paired inverse type on the target, so
# both tickets show the relationship without having to scan the whole
# backlog to find who links to whom.
BACKLOG_RELATIONS: dict[str, dict[str, str]] = {
    "relates_to":    {"label": "Relates to",    "inverse": "relates_to"},
    "causes":        {"label": "Causes",        "inverse": "caused_by"},
    "caused_by":     {"label": "Caused by",     "inverse": "causes"},
    "duplicates":    {"label": "Duplicates",    "inverse": "duplicated_by"},
    "duplicated_by": {"label": "Duplicated by", "inverse": "duplicates"},
    "blocks":        {"label": "Blocks",        "inverse": "blocked_by"},
    "blocked_by":    {"label": "Blocked by",    "inverse": "blocks"},
}

def load_backlog() -> dict:
    if not BACKLOG_FILE.exists():
        return {"items": [], "next_id": 1}
    try:
        data = json.loads(BACKLOG_FILE.read_text())
    except (OSError, ValueError):
        return {"items": [], "next_id": 1}
    data.setdefault("items", [])
    data.setdefault("next_id", 1)
    # Backfill fields added after some items were created — in memory only
    # (not written back here), so a plain read never has a surprising
    # side effect on disk.
    for item in data["items"]:
        item.setdefault("type", "feature")
        item.setdefault("status", "open")
        item.setdefault("description", "")
        # What was decided, distilled from the options weighed in
        # implementation_details — so picking a ticket up does not mean
        # re-reading the comparison to infer its outcome.
        item.setdefault("decision", "")
        item.setdefault("implementation_details", "")
        item.setdefault("links", [])
        item.setdefault("comments", [])
        item.setdefault("external_links", [])
        item.setdefault("attachments", [])
    return data

def _next_sub_id(rows: list[dict]) -> int:
    """Next id for a per-item collection (comments, external links). Ids are
    scoped to the item, so they only need to be unique within that list."""
    return max((r.get("id", 0) for r in rows), default=0) + 1

def _safe_url(url: str) -> str | None:
    """Accept only http(s) URLs. User-supplied strings end up in an href, so
    schemes like javascript: must never survive — Jinja escapes the attribute
    value but would happily emit a javascript: URL."""
    url = (url or "").strip()
    if not url:
        return None
    parsed = urlparse(url)
    if parsed.scheme in ("http", "https") and parsed.netloc:
        return url
    return None

def derive_link_label(url: str) -> str:
    """Short human label for an external URL when the user didn't supply one.
    Recognises the GitHub shapes this is mostly used for (commits, PRs,
    issues) so a pasted commit URL renders as "NASe@7688125" rather than a
    60-character link."""
    parsed = urlparse(url)
    host  = parsed.netloc
    parts = [p for p in parsed.path.split("/") if p]
    if host.endswith("github.com") and len(parts) >= 4:
        owner_repo, kind, ref = parts[1], parts[2], parts[3]
        if kind in ("commit", "commits"):
            return f"{owner_repo}@{ref[:7]}"
        if kind in ("pull", "issues"):
            return f"{owner_repo}#{ref}"
    path = parsed.path.rstrip("/")
    label = f"{host}{path}"
    return label if len(label) <= 48 else label[:45] + "..."

def save_backlog(data: dict) -> None:
    """Write the backlog atomically: a reader must never see a half-written
    file. Writing in place left a window in which the archiver (or a person
    with `cat`) could catch a truncated JSON document — and this file is the
    only copy of the backlog, so a torn read that then gets snapshotted would
    be a bad thing to discover later. Rename within the same directory is
    atomic, so readers see either the old file or the new one."""
    BACKLOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = BACKLOG_FILE.with_suffix(BACKLOG_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, BACKLOG_FILE)

# ── Backlog attachments ────────────────────────────────────────────────────────
# Screenshots live next to the backlog on the SD card, never on /mnt/primary:
# opening a ticket must not spin the main drive up. They are small and few, and
# modules/config-archive copies this directory to the drive along with
# backlog.json, so they inherit the same backup.
ATTACHMENT_DIR = Path(os.environ.get("NASE_ATTACHMENT_DIR",
                                     str(STAMP_DIR / "backlog-attachments")))
MAX_ATTACHMENT_BYTES = 4 * 1024 * 1024
MAX_ATTACHMENTS_PER_ITEM = 10

# ── Reporting a refused write (backlog #28) ───────────────────────────────────
# Every mutating backlog endpoint used to answer 303 whether or not it had done
# anything: a bad rel_type, a target that did not exist, an empty comment, a
# non-http URL — all fell through one `if` and redirected as though they had
# worked. That was found the hard way, by two link requests sent with the field
# named `type` instead of `rel_type` which both returned 303 and created
# nothing. The uploads path already did this properly, so this generalises its
# table and query-parameter round trip rather than inventing a second one.
_FORM_ERRORS = {
    # Attachments.
    "too_big":      f"That image is larger than {MAX_ATTACHMENT_BYTES // (1024 * 1024)} MB — it was not added.",
    "not_an_image": "That file is not a PNG, JPEG, GIF or WebP image — it was not added.",
    "too_many":     f"This ticket already has {MAX_ATTACHMENTS_PER_ITEM} images — remove one first.",
    "none":         "No file was chosen.",
    # Links between tickets.
    "bad_rel_type": "That is not a relationship NASe recognises — no link was created.",
    "bad_target":   "No such ticket — no link was created.",
    "self_link":    "A ticket cannot be linked to itself — no link was created.",
    # External links.
    "bad_url":      "External links must start with http:// or https:// — nothing was added.",
    # Comments.
    "empty_comment": "The comment was empty — nothing was added.",
    # Creating and editing.
    "empty_title":  "A ticket needs a title — nothing was created.",
    "bad_type":     "That is not a ticket type NASe recognises — the ticket was left unchanged.",
    "bad_status":   "That is not a status NASe recognises — the ticket was left unchanged.",
}

def _reject(request: Request, code: str, redirect_to: str):
    """Refuse a form write, and say so.

    Browsers get a 303 back to the page they came from carrying ?err=<code>,
    which renders as a sentence — the same round trip uploads already used.
    Anything that is not asking for HTML gets a 400 with the reason, because
    the whole point is that a script must not record success for a write that
    never happened. The accept-header split mirrors the one in
    http_exception_handler above, which already serves humans a styled page
    while machine clients and SSE streams get JSON."""
    if "text/html" not in request.headers.get("accept", ""):
        return JSONResponse(
            {"detail": _FORM_ERRORS.get(code, "Request rejected."), "error": code},
            status_code=400)
    sep = "&" if "?" in redirect_to else "?"
    return RedirectResponse(url=f"{redirect_to}{sep}err={code}", status_code=303)

# Type is decided by what the bytes actually are, never by the upload's
# Content-Type or the filename's extension — both are attacker-controlled and
# neither survives contact with a phone's photo picker intact anyway.
# SVG is absent on purpose: it can carry script, and there is no version of
# "render it inline" that is safe without sanitising it first.
_IMAGE_SIGNATURES: tuple[tuple[bytes, str, str], ...] = (
    (b"\x89PNG\r\n\x1a\n", "image/png",  "png"),
    (b"\xff\xd8\xff",      "image/jpeg", "jpg"),
    (b"GIF87a",            "image/gif",  "gif"),
    (b"GIF89a",            "image/gif",  "gif"),
)

def sniff_image(head: bytes) -> tuple[str, str] | None:
    """(media_type, extension) for a recognised image, else None."""
    for signature, media_type, ext in _IMAGE_SIGNATURES:
        if head.startswith(signature):
            return media_type, ext
    # WebP is RIFF-framed: "RIFF" <4-byte size> "WEBP".
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None

def attachment_path(item_id: int, stored_name: str) -> Path:
    """Absolute path of a stored attachment. stored_name is generated by this
    module and is checked against the item's own record before use, so a
    traversal attempt cannot reach outside the directory."""
    return ATTACHMENT_DIR / str(item_id) / stored_name

def find_attachment(item: dict, attachment_id: int) -> dict | None:
    return next((a for a in item.get("attachments", []) if a["id"] == attachment_id), None)

def find_backlog_item(data: dict, item_id: int) -> dict | None:
    return next((i for i in data["items"] if i["id"] == item_id), None)

def resolve_backlog_links(data: dict, item: dict) -> list[dict]:
    """item['links'] only stores {type, target_id}; look up each target's
    current title/type/status for display (and to link to it), skipping any
    target that's since vanished entirely rather than erroring out."""
    by_id = {i["id"]: i for i in data["items"]}
    resolved = []
    for link in item.get("links", []):
        target = by_id.get(link.get("target_id"))
        if target is None:
            continue
        resolved.append({
            "type":          link["type"],
            "label":         BACKLOG_RELATIONS.get(link["type"], {}).get("label", link["type"]),
            "target_id":     target["id"],
            "target_title":  target["title"],
            "target_type":   target.get("type", "feature"),
            "target_status": target.get("status", "open"),
        })
    return resolved

_BACKLOG_TYPE_FILTERS = {"all"} | _BACKLOG_TYPES

def _backlog_matches(item: dict, status: str, ticket_type: str) -> bool:
    """Same predicate backlog_view() applies, usable against an in-memory
    list — needed by backlog_move() below to know what's actually *visible*
    under the current filters, without a second disk read."""
    if status == "all":
        if item.get("status") == "deleted":
            return False
    elif status == "active":
        if item.get("status") not in _BACKLOG_ACTIVE_STATUSES:
            return False
    elif item.get("status") != status:
        return False
    if ticket_type != "all" and item.get("type") != ticket_type:
        return False
    return True

def normalize_backlog_filters(status: str, ticket_type: str) -> tuple[str, str]:
    """Coerce user-supplied filter values to known ones. Callers that reason
    about visibility themselves (backlog_move) must normalize the same way
    backlog_view does, or they'd compute "what's visible" from a filter the
    rendered list never used."""
    return (status if status in _BACKLOG_FILTERS else _BACKLOG_DEFAULT_FILTER,
            ticket_type if ticket_type in _BACKLOG_TYPE_FILTERS else "all")

def backlog_view(status: str, ticket_type: str = "all") -> dict:
    """Backlog items filtered by status and/or type, for the list/filter bars.

    "all" status deliberately excludes "deleted" — a soft-deleted ticket
    should only reappear when the Deleted filter is picked on purpose, not
    sit in the default view.

    "total" is the count of items the unfiltered ("all") view would show, so
    the empty state can tell "nothing here yet" apart from "nothing matches
    these filters".
    """
    status, ticket_type = normalize_backlog_filters(status, ticket_type)
    all_items = load_backlog()["items"]
    items = [i for i in all_items if _backlog_matches(i, status, ticket_type)]
    total = sum(1 for i in all_items if _backlog_matches(i, "all", "all"))
    return {"items": items, "status": status, "type": ticket_type, "total": total}

# ── Config sections ────────────────────────────────────────────────────────────
# Order and display labels for the config editor tabs.
CONFIG_SECTIONS: list[tuple[str, str]] = [
    ("nas",            "General"),
    ("drives",         "Drives"),
    ("samba",          "Samba"),
    ("sync_jobs",      "Sync Jobs"),
    ("config_archive", "Config Archive"),
    ("services",       "Services"),
    ("tailscale",      "Tailscale"),
    ("notifications",  "Notifications"),
    ("file_watch",     "File Watch"),
    ("status_report",  "Status Report"),
]
_SECTION_KEYS = {k for k, _ in CONFIG_SECTIONS}

def _make_ryaml() -> RuamelYAML:
    """Return a ruamel.yaml instance configured to match config.yaml's style:
    2-space mapping indent, list dashes at 2 spaces with content at 4."""
    ry = RuamelYAML()
    ry.preserve_quotes = True
    ry.indent(mapping=2, sequence=4, offset=2)
    return ry

def _section_to_yaml(value: object) -> str:
    """Serialise a config section value to a YAML string."""
    import io
    buf = io.StringIO()
    _make_ryaml().dump(value, buf)
    return buf.getvalue()

# ── Rendering hard-wrapped text ────────────────────────────────────────────────
# Older ticket text was written wrapped at ~80 columns, but it renders in a
# ~64-character column, so every stored line wrapped a second time and left a
# short orphan under it. Folding those runs back into paragraphs at render time
# fixes the existing tickets without rewriting a single one: the stored text is
# untouched, and the editor still shows exactly what is stored.
#
# Deliberately conservative — only runs of unindented prose are joined. Headers,
# list items, indented blocks and tables keep their line structure, since
# guessing wrong there would mangle a ticket in a way nobody would notice until
# they needed it.

# A line produced by hard-wrapping is long; one deliberately left short (the end
# of a paragraph, a heading, a one-line note) is not. 55 sits below the narrowest
# wrap width in this backlog and above the short lines that end paragraphs.
_MIN_WRAPPED_LEN = 55

# Openers that start something of their own, so the line before must not swallow
# them: section headers, list items, lettered options, table rows, quotes.
_STRUCTURAL_LINE = re.compile(r"^(==|[-*+]\s|\d+[.)]\s|\(\w+\)|\||>|#)")

def unwrap_prose(text: str) -> str:
    """Join runs of hard-wrapped prose so they reflow to the reader's width."""
    if not text:
        return text
    # Anything typed into the form arrives CRLF-terminated (HTML normalises
    # textarea line breaks that way), and a stray \r left mid-line renders as a
    # line break of its own — so the fold would appear not to have happened.
    out: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        previous = out[-1] if out else ""
        continuable = (
            previous
            and len(previous) >= _MIN_WRAPPED_LEN
            and not previous.startswith((" ", "\t"))
            and not _STRUCTURAL_LINE.match(previous)
        )
        absorbable = (
            line.strip()
            and not line.startswith((" ", "\t"))
            and not _STRUCTURAL_LINE.match(line)
        )
        if continuable and absorbable:
            out[-1] = previous + " " + line.strip()
        else:
            out.append(line)
    return "\n".join(out)

templates.env.filters["unwrap_prose"] = unwrap_prose

def _last_leaf_holder(node) -> tuple | None:
    """The innermost container holding the last leaf of `node`, and its key.

    ruamel attaches a comment to whatever *precedes* it in the file. For a
    block sitting between two sections that is not the section key but the
    deepest, last scalar of the preceding section's subtree — e.g. the
    integrity header was on doc['sync_jobs'][8]['trash']['retention_days'].
    Finding that node is what makes the block rescuable.
    """
    holder = None
    while isinstance(node, (CommentedMap, CommentedSeq)) and len(node) > 0:
        key = list(node.keys())[-1] if isinstance(node, CommentedMap) else len(node) - 1
        holder = (node, key)
        node = node[key]
    return holder

# Slots in a ca.items entry that hold a "comment that follows this node":
# index 2 for a mapping key (post-value), index 0 for a sequence item.
_TRAILING_COMMENT_SLOTS = (2, 0)

def _reanchor_section_comments(doc: CommentedMap) -> None:
    """Move each block comment that introduces a top-level section onto that
    section's key, instead of leaving it buried in the previous section.

    Without this, saving a section replaces its whole subtree and takes any
    such block with it — one save of sync_jobs silently deleted the 23-line
    header documenting `integrity:`. Rewriting the anchor is lossless: the
    dumped file is byte-identical, the comment simply now lives on the key it
    actually documents, where _save_section's existing rescue can protect it.

    Only the part after the first newline moves; the first line is the
    preceding value's own end-of-line comment and stays with it.
    """
    keys = list(doc.keys())
    for prev_key, next_key in zip(keys, keys[1:]):
        holder = _last_leaf_holder(doc.get(prev_key))
        if holder is None:
            continue
        node, key = holder
        entry = node.ca.items.get(key)
        if not entry:
            continue
        for slot in _TRAILING_COMMENT_SLOTS:
            token = entry[slot] if slot < len(entry) else None
            if not isinstance(token, CommentToken):
                continue
            head, sep, tail = (token.value or "").partition("\n")
            if "#" not in tail:
                continue        # just the leaf's own end-of-line comment
            token.value = head + sep
            target = doc.ca.items.setdefault(next_key, [None, None, None, None])
            target[1] = [CommentToken(tail, CommentMark(0), None)] + (target[1] or [])
            break

# ── Preserving comments *inside* a section (backlog #19) ──────────────────────
# Identity keys per list, written down explicitly rather than inferred, and
# matched on nothing else. Positional matching would silently move
# "# this job is the slow one" onto a different job the first time anything is
# reordered or inserted, and #19's guardrail is that losing a comment is
# acceptable while misattributing one is not. A list with no rule here is
# replaced wholesale, which loses its comments and never moves them.
_MERGE_IDENTITY: dict[tuple, tuple] = {
    ("drives",):         ("name", "uuid"),
    ("sync_jobs",):      ("name",),
    ("samba", "shares"): ("name",),
}

def _item_identity(item, keys: tuple):
    """(key, value) of the first identity key this item carries, or None."""
    if not isinstance(item, dict):
        return None
    for k in keys:
        v = item.get(k)
        if v is not None:
            return (k, v)
    return None

def _seq_at(doc, path: tuple):
    node = doc
    for p in path:
        if not isinstance(node, dict):
            return None
        node = node.get(p)
    return node if isinstance(node, CommentedSeq) else None

def _reanchor_item_comments(doc: CommentedMap) -> None:
    """Move each comment that introduces a list item onto that item.

    Exactly the problem _reanchor_section_comments solves one level up, and for
    the same reason: ruamel stores a comment written above item N as a trailing
    comment on the *last leaf of item N-1*, not on item N. So the node that
    survives a targeted merge is the wrong one — the comment would follow the
    item above it, and on a reorder or a delete it would end up introducing
    something it does not describe.

    Rewriting the anchor is lossless: the dumped file is byte-identical, the
    comment simply now lives on the item it actually documents.
    """
    for path, _keys in _MERGE_IDENTITY.items():
        seq = _seq_at(doc, path)
        if seq is None:
            continue
        for idx in range(1, len(seq)):
            holder = _last_leaf_holder(seq[idx - 1])
            if holder is None:
                continue
            node, key = holder
            entry = node.ca.items.get(key)
            if not entry:
                continue
            for slot in _TRAILING_COMMENT_SLOTS:
                token = entry[slot] if slot < len(entry) else None
                if not isinstance(token, CommentToken):
                    continue
                head, sep, tail = (token.value or "").partition("\n")
                if "#" not in tail:
                    continue    # just the leaf's own end-of-line comment
                token.value = head + sep
                # The comment's own leading whitespace becomes its column;
                # ruamel re-indents from there, so passing it through unstripped
                # would double the indent.
                col = len(tail) - len(tail.lstrip(" "))
                target = seq[idx]
                pre = (target.ca.comment[1] if target.ca.comment else None) or []
                target.ca.comment = [
                    None, [CommentToken(tail.lstrip(" "), CommentMark(col), None)] + pre]
                break

def _merge_preserving(old, new, path: tuple = ()):
    """Update `old` in place to hold `new`'s values, reusing old nodes.

    The Form view marshals plain YAML in the browser, so the payload carries no
    comments at all and `doc[section] = new_value` threw away every comment
    anchored inside the section. Reusing the surviving nodes keeps them,
    provided the between-item comments have been re-anchored onto their own
    item first — which is what _reanchor_item_comments is for.
    """
    if isinstance(old, CommentedMap) and isinstance(new, dict):
        for key in [k for k in old if k not in new]:
            del old[key]
        for key, val in new.items():
            old[key] = _merge_preserving(old[key], val, path + (key,)) if key in old else val
        return old

    keys = _MERGE_IDENTITY.get(path)
    if keys and isinstance(old, CommentedSeq) and isinstance(new, list):
        by_id: dict = {}
        for i, item in enumerate(old):
            ident = _item_identity(item, keys)
            if ident is not None and ident not in by_id:
                by_id[ident] = (i, item)
        merged, source_idx = [], []
        for value in new:
            ident = _item_identity(value, keys)
            hit = by_id.pop(ident, None) if ident is not None else None
            if hit is None:
                merged.append(value)            # a new item, or one with no identity
                source_idx.append(None)
            else:
                i, node = hit
                merged.append(_merge_preserving(node, value, path))
                source_idx.append(i)
        # Any index-keyed comments on the sequence itself follow their item to
        # its new position; those whose item is gone are dropped rather than
        # left pointing at whatever now occupies that index.
        ca_before = dict(old.ca.items)
        old[:] = merged
        old.ca.items.clear()
        for new_i, old_i in enumerate(source_idx):
            if old_i is not None and old_i in ca_before:
                old.ca.items[new_i] = ca_before[old_i]
        return old

    return new

def _save_section(section: str, yaml_text: str) -> None:
    """Parse yaml_text with ruamel (preserving CommentedMap/Seq metadata),
    load config.yaml (preserving comments/order in all other sections),
    update one top-level key, and write back."""
    import io
    ry  = _make_ryaml()
    new_value = ry.load(yaml_text)
    with open(CONFIG_FILE) as f:
        doc = ry.load(f)
    # Rehome section-introducing comments before touching anything: a Form-view
    # save sends comment-free YAML, so whatever is still inside the replaced
    # subtree at this point is gone for good.
    _reanchor_section_comments(doc)
    # Same rescue one level down, for comments between items in a list (#19).
    _reanchor_item_comments(doc)
    # Preserve any block/inline comments attached to this key in the top-level map.
    ca = doc.ca.items.get(section)
    if section in doc:
        doc[section] = _merge_preserving(doc[section], new_value, (section,))
    else:
        doc[section] = new_value
    if ca is not None:
        doc.ca.items[section] = ca
    with open(CONFIG_FILE, "w") as f:
        ry.dump(doc, f)

# ── Routes ─────────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    cfg       = load_config()
    job_names = [j["name"] for j in cfg.get("sync_jobs", [])]
    return templates.TemplateResponse(request, "index.html", {
        "hostname":  cfg.get("nas", {}).get("hostname", "nase"),
        "page":      "dashboard",
        "status":    build_status(cfg),
        "job_names": job_names,
        "log_lines": read_log(None),
    })

@app.get("/changes", response_class=HTMLResponse)
async def changes_page(
    request: Request,
    window:  str  = Query("day"),
    page:    int  = Query(1),
    group:   bool = Query(False),
):
    cfg = load_config()
    if window not in _WINDOW_SECS:
        window = "day"
    return templates.TemplateResponse(request, "changes.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "changes",
        "changes":  build_changes(window, page, group),
    })

@app.get("/partials/changes", response_class=HTMLResponse)
async def partial_changes(
    request: Request,
    window:  str  = Query("day"),
    page:    int  = Query(1),
    group:   bool = Query(False),
):
    if window not in _WINDOW_SECS:
        window = "day"
    return templates.TemplateResponse(request, "partials/changes.html", {
        "changes": build_changes(window, page, group),
    })

@app.get("/partials/status", response_class=HTMLResponse)
async def partial_status(request: Request):
    cfg = load_config()
    return templates.TemplateResponse(request, "partials/status.html", {
        "status": build_status(cfg),
    })

@app.get("/integrity", response_class=HTMLResponse)
async def integrity_page(request: Request):
    cfg = load_config()
    return templates.TemplateResponse(request, "integrity.html", {
        "hostname":  cfg.get("nas", {}).get("hostname", "nase"),
        "page":      "integrity",
        "integrity": build_integrity(cfg),
    })

@app.get("/partials/integrity", response_class=HTMLResponse)
async def partial_integrity(request: Request):
    cfg = load_config()
    return templates.TemplateResponse(request, "partials/integrity.html", {
        "integrity": build_integrity(cfg),
    })

@app.get("/monitoring", response_class=HTMLResponse)
async def monitoring_page(request: Request, window: str = Query("day")):
    cfg = load_config()
    if window not in _WINDOW_SECS:
        window = "day"
    return templates.TemplateResponse(request, "monitoring.html", {
        "hostname":   cfg.get("nas", {}).get("hostname", "nase"),
        "page":       "monitoring",
        "monitoring": build_monitoring(cfg, window),
    })

@app.get("/partials/monitoring", response_class=HTMLResponse)
async def partial_monitoring(request: Request, window: str = Query("day")):
    cfg = load_config()
    if window not in _WINDOW_SECS:
        window = "day"
    return templates.TemplateResponse(request, "partials/monitoring.html", {
        "monitoring": build_monitoring(cfg, window),
    })

@app.get("/partials/logs", response_class=HTMLResponse)
async def partial_logs(request: Request, job: str | None = Query(None)):
    return templates.TemplateResponse(request, "partials/logs.html", {
        "log_lines": read_log(job),
    })

@_protected.get("/config", response_class=HTMLResponse)
async def config_page(request: Request, tab: str = Query("nas")):
    cfg        = load_config()
    active_tab = tab if tab in _SECTION_KEYS else "nas"
    section_yaml = {k: _section_to_yaml(cfg.get(k)) for k, _ in CONFIG_SECTIONS}
    return templates.TemplateResponse(request, "config.html", {
        "hostname":     cfg.get("nas", {}).get("hostname", "nase"),
        "page":         "config",
        "sections":     CONFIG_SECTIONS,
        "section_yaml": section_yaml,
        "active_tab":   active_tab,
    })

@_protected.post("/config/{section}", response_class=HTMLResponse)
async def save_config_section(request: Request, section: str):
    def _err(msg: str):
        return templates.TemplateResponse(request, "partials/save_result.html",
                                          {"success": False, "message": msg})

    if section not in _SECTION_KEYS:
        return _err(f"Unknown section '{section}'.")

    form      = await request.form()
    yaml_text = form.get("yaml_text", "")

    # Validate syntax before touching the file.
    try:
        yaml.safe_load(yaml_text)
    except yaml.YAMLError as exc:
        return _err(f"YAML parse error: {exc}")

    try:
        _save_section(section, yaml_text)
    except Exception as exc:
        return _err(f"Write error: {exc}")

    return templates.TemplateResponse(request, "partials/save_result.html",
                                      {"success": True, "message": ""})

# ── Backlog routes ───────────────────────────────────────────────────────────────
# ── Status reports (backlog #37) ───────────────────────────────────────────────
def load_reports() -> list[dict]:
    """Every archived report, newest first.

    A file that will not parse is skipped rather than allowed to break the
    page: this directory is written by a shell script and copied to the drive
    by another one, so one unreadable entry should cost that entry and nothing
    more."""
    out: list[dict] = []
    try:
        entries = sorted(REPORTS_DIR.glob("*.json"))
    except OSError:
        return out
    for f in entries:
        try:
            record = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict) or "generated_at" not in record:
            continue
        try:
            record["generated_at"] = int(record["generated_at"])
        except (TypeError, ValueError):
            continue
        out.append(record)
    out.sort(key=lambda r: r["generated_at"], reverse=True)
    return out


def _report_view(record: dict) -> dict:
    """Add the display-only fields the templates want."""
    fmt = lambda ts: (datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M")
                      if ts else "—")
    return {
        **record,
        "generated_disp": fmt(record.get("generated_at")),
        "period_disp":    f'{fmt(record.get("period_start"))} → {fmt(record.get("period_end"))}',
    }


# Protected, unlike Dashboard/Changes/Integrity/Monitoring. A report carries the
# FILE CHANGES section — real file names from /mnt/primary — plus flagged paths
# and raw ERROR lines. That is Backlog/Config sensitivity, not Dashboard's.
@_protected.get("/reports", response_class=HTMLResponse)
async def reports_page(request: Request):
    cfg = load_config()
    return templates.TemplateResponse(request, "reports.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "reports",
        "reports":  [_report_view(r) for r in load_reports()],
        # So the empty state can say when the first one is due rather than
        # leaving the reader wondering whether anything is broken.
        "schedule": cfg.get("status_report", {}).get("schedule", ""),
        "enabled":  cfg.get("status_report", {}).get("enabled", True),
    })


@_protected.get("/reports/{generated_at}", response_class=HTMLResponse)
async def report_detail(request: Request, generated_at: int):
    cfg = load_config()
    match = next((r for r in load_reports() if r["generated_at"] == generated_at), None)
    if match is None:
        raise HTTPException(status_code=404, detail="Report not found")
    return templates.TemplateResponse(request, "report_detail.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "reports",
        "report":   _report_view(match),
    })


@_protected.get("/backlog", response_class=HTMLResponse)
async def backlog_page(request: Request, status: str = Query(_BACKLOG_DEFAULT_FILTER),
                        ticket_type: str = Query("all", alias="type")):
    cfg = load_config()
    return templates.TemplateResponse(request, "backlog.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "backlog",
        "backlog":  backlog_view(status, ticket_type),
    })

@_protected.get("/partials/backlog", response_class=HTMLResponse)
async def partial_backlog(request: Request, status: str = Query(_BACKLOG_DEFAULT_FILTER),
                           ticket_type: str = Query("all", alias="type")):
    return templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(status, ticket_type),
    })

@_protected.post("/backlog/add", response_class=HTMLResponse)
async def backlog_add(request: Request):
    form  = await request.form()
    title = (form.get("title") or "").strip()
    type_ = form.get("type") or "feature"

    # This one answers with a partial rather than a redirect, so a refusal is
    # rendered straight back into the card instead of round-tripping through
    # ?err= — but a non-browser client still has to be told, since an empty
    # title silently creating nothing is the same defect as the rest of #28.
    err = None
    if not title:
        err = "empty_title"
    elif type_ not in _BACKLOG_TYPES:
        err = "bad_type"
    if err:
        if not request.headers.get("hx-request"):
            return _reject(request, err, "/backlog")
        return templates.TemplateResponse(request, "partials/backlog_list.html", {
            "backlog":    backlog_view(_BACKLOG_DEFAULT_FILTER, "all"),
            "form_error": _FORM_ERRORS[err],
        })

    with _backlog_lock:
        data = load_backlog()
        if title:
            data["items"].append({
                "id":                     data["next_id"],
                "title":                  title,
                "type":                   type_,
                "description":            "",
                "implementation_details": "",
                "status":                 "open",
                "created_at":             datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            })
            data["next_id"] += 1
            save_backlog(data)
    # Always land back on the default view with no type filter — a just-added
    # item could otherwise vanish immediately under a narrower filter. New
    # items are "open", so the default "active" filter always shows them.
    return templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(_BACKLOG_DEFAULT_FILTER, "all"),
    })

# Registered before the /backlog/{item_id} routes below: item_id is typed
# int, and Starlette matches routes by registration order, so "reorder"
# would otherwise be swallowed by that route and fail int parsing instead
# of reaching this one.
@_protected.post("/backlog/reorder")
async def backlog_reorder(request: Request):
    form  = await request.form()
    order = [int(x) for x in (form.get("order") or "").split(",") if x.strip().isdigit()]
    with _backlog_lock:
        data  = load_backlog()
        by_id = {it["id"]: it for it in data["items"]}
        order = [i for i in order if i in by_id]
        # When a status filter is active, `order` only names the ids visible
        # in that filtered view — not the full list. Splice the reordered
        # subsequence back into their original slots rather than treating
        # everything else as "missing" and shoving it to the bottom, which
        # would silently reshuffle items the user couldn't even see.
        if len(order) == len(set(order)):
            order_set = set(order)
            order_iter = iter(order)
            data["items"] = [
                by_id[next(order_iter)] if it["id"] in order_set else it
                for it in data["items"]
            ]
            save_backlog(data)
    return {"ok": True}

@_protected.get("/backlog/{item_id}", response_class=HTMLResponse)
async def backlog_detail(request: Request, item_id: int,
                          err: str = Query("")):
    cfg  = load_config()
    data = load_backlog()
    item = find_backlog_item(data, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Backlog item not found")
    # Candidates for a new link: every other, non-deleted ticket.
    link_options = [i for i in data["items"]
                     if i["id"] != item_id and i.get("status") != "deleted"]
    return templates.TemplateResponse(request, "backlog_detail.html", {
        "hostname":     cfg.get("nas", {}).get("hostname", "nase"),
        "page":         "backlog",
        "item":         item,
        "links":        resolve_backlog_links(data, item),
        "link_options": link_options,
        "relations":    BACKLOG_RELATIONS,
        # Any refused write redirects back here with a reason, so the person
        # who just picked a 12 MB photo — or mistyped a URL, or posted an
        # empty comment — is told why nothing appeared (#28).
        "form_error": _FORM_ERRORS.get(err),
    })

@_protected.post("/backlog/{item_id}/links/add")
async def backlog_link_add(item_id: int, request: Request):
    form      = await request.form()
    rel_type  = form.get("rel_type") or ""
    target_id = form.get("target_id") or ""
    back      = f"/backlog/{item_id}"
    # Checked one at a time so the answer names the actual problem. Posting
    # `type=` instead of `rel_type=` is the mistake that opened #28, and it
    # now says "not a relationship NASe recognises" instead of 303.
    if rel_type not in BACKLOG_RELATIONS:
        return _reject(request, "bad_rel_type", back)
    if not target_id.isdigit():
        return _reject(request, "bad_target", back)
    if int(target_id) == item_id:
        return _reject(request, "self_link", back)
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        target = find_backlog_item(data, int(target_id))
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if target is None:
            return _reject(request, "bad_target", back)
        inverse = BACKLOG_RELATIONS[rel_type]["inverse"]
        if not any(l["type"] == rel_type and l["target_id"] == target["id"]
                   for l in item["links"]):
            item["links"].append({"type": rel_type, "target_id": target["id"]})
        if not any(l["type"] == inverse and l["target_id"] == item_id
                   for l in target["links"]):
            target["links"].append({"type": inverse, "target_id": item_id})
        save_backlog(data)
    return RedirectResponse(url=back, status_code=303)

@_protected.post("/backlog/{item_id}/links/remove")
async def backlog_link_remove(item_id: int, request: Request):
    form      = await request.form()
    rel_type  = form.get("rel_type") or ""
    target_id = form.get("target_id") or ""
    target_id = int(target_id) if target_id.isdigit() else None
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and target_id is not None:
            item["links"] = [l for l in item["links"]
                             if not (l["type"] == rel_type and l["target_id"] == target_id)]
            target = find_backlog_item(data, target_id)
            if target is not None and rel_type in BACKLOG_RELATIONS:
                inverse = BACKLOG_RELATIONS[rel_type]["inverse"]
                target["links"] = [l for l in target["links"]
                                   if not (l["type"] == inverse and l["target_id"] == item_id)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}/comments/add")
async def backlog_comment_add(item_id: int, request: Request):
    form = await request.form()
    text = (form.get("text") or "").strip()
    if not text:
        return _reject(request, "empty_comment", f"/backlog/{item_id}")
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["comments"].append({
                "id":         _next_sub_id(item["comments"]),
                "text":       text,
                "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            })
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}/attachments/add")
async def backlog_attachment_add(item_id: int, request: Request):
    form = await request.form()
    upload = form.get("image")
    if upload is None or not hasattr(upload, "read"):
        return RedirectResponse(url=f"/backlog/{item_id}?err=none", status_code=303)

    # Read one byte past the cap so an oversized file is refused without
    # holding an unbounded amount of it in memory.
    payload = await upload.read(MAX_ATTACHMENT_BYTES + 1)
    if len(payload) > MAX_ATTACHMENT_BYTES:
        return RedirectResponse(url=f"/backlog/{item_id}?err=too_big", status_code=303)

    sniffed = sniff_image(payload[:16])
    if sniffed is None:
        return RedirectResponse(url=f"/backlog/{item_id}?err=not_an_image", status_code=303)
    media_type, ext = sniffed

    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if len(item["attachments"]) >= MAX_ATTACHMENTS_PER_ITEM:
            return RedirectResponse(url=f"/backlog/{item_id}?err=too_many", status_code=303)

        attachment_id = _next_sub_id(item["attachments"])
        stored_name = f"{attachment_id}-{secrets.token_hex(8)}.{ext}"
        target = attachment_path(item_id, stored_name)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Write then rename, so the archiver can never copy a half-written image.
        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_bytes(payload)
        os.replace(tmp, target)

        item["attachments"].append({
            "id":          attachment_id,
            "stored_name": stored_name,
            "filename":    Path(getattr(upload, "filename", "") or "image").name[:120],
            "media_type":  media_type,
            "bytes":       len(payload),
            "created_at":  datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
        save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.get("/backlog/{item_id}/attachments/{attachment_id}")
async def backlog_attachment_get(item_id: int, attachment_id: int):
    """Serve an attachment. Behind auth like the rest of the backlog — the
    /static mount is unauthenticated, which is why these do not live there."""
    item = find_backlog_item(load_backlog(), item_id)
    attachment = find_attachment(item, attachment_id) if item else None
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    path = attachment_path(item_id, attachment["stored_name"])
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Attachment file is missing")
    return FileResponse(
        path,
        media_type=attachment["media_type"],
        headers={
            # The type was sniffed on upload; forbid the browser second-guessing it.
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": f'inline; filename="{attachment["stored_name"]}"',
        },
    )

@_protected.post("/backlog/{item_id}/attachments/remove")
async def backlog_attachment_remove(item_id: int, request: Request):
    form = await request.form()
    raw_id = form.get("attachment_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and raw_id.isdigit():
            attachment = find_attachment(item, int(raw_id))
            if attachment is not None:
                # Unlike a ticket, an attachment is really deleted: it is the
                # file, not a record with history worth keeping.
                attachment_path(item_id, attachment["stored_name"]).unlink(missing_ok=True)
                item["attachments"] = [a for a in item["attachments"]
                                       if a["id"] != attachment["id"]]
                save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}/comments/remove")
async def backlog_comment_remove(item_id: int, request: Request):
    form = await request.form()
    cid  = form.get("comment_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and cid.isdigit():
            item["comments"] = [c for c in item["comments"] if c.get("id") != int(cid)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}/extlinks/add")
async def backlog_extlink_add(item_id: int, request: Request):
    form  = await request.form()
    url   = _safe_url(form.get("url") or "")
    label = (form.get("label") or "").strip()
    # The one rejection an ordinary user can reach today: the URL field is
    # free text, unlike rel_type and status which the UI fills from selects.
    # A typo, or a deliberate smb:// path, used to be dropped without a word.
    if url is None:
        return _reject(request, "bad_url", f"/backlog/{item_id}")
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["external_links"].append({
                "id":    _next_sub_id(item["external_links"]),
                "url":   url,
                "label": label or derive_link_label(url),
            })
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}/extlinks/remove")
async def backlog_extlink_remove(item_id: int, request: Request):
    form = await request.form()
    lid  = form.get("link_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and lid.isdigit():
            item["external_links"] = [l for l in item["external_links"]
                                      if l.get("id") != int(lid)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@_protected.post("/backlog/{item_id}")
async def backlog_update(request: Request, item_id: int):
    form   = await request.form()
    title  = (form.get("title") or "").strip()
    type_  = form.get("type") or "feature"
    status = form.get("status") or "open"
    back   = f"/backlog/{item_id}"
    # Refuse rather than coerce. These used to fall back to "feature" and
    # "open", so a typo did not fail — it quietly rewrote the field, and
    # silently changing a ticket's status is worse than refusing the request
    # (#28). This handler already raised 404 for a missing item, so it was
    # inconsistent with itself about whether errors are worth reporting.
    if type_ not in _BACKLOG_TYPES:
        return _reject(request, "bad_type", back)
    if status not in _BACKLOG_STATUSES:
        return _reject(request, "bad_status", back)
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if title:
            item["title"] = title
        item["type"] = type_
        item["description"] = form.get("description") or ""
        item["decision"] = form.get("decision") or ""
        item["implementation_details"] = form.get("implementation_details") or ""
        item["status"] = status
        save_backlog(data)
    return RedirectResponse(url="/backlog", status_code=303)

@_protected.post("/backlog/{item_id}/delete")
async def backlog_delete(item_id: int):
    # Soft delete: flip the status rather than erase the record, so a
    # mis-click is recoverable (reopen the item, change status back) and
    # matches the "Deleted" status being just another workflow state that
    # happens to be hidden by default (see backlog_view).
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["status"] = "deleted"
            save_backlog(data)
    return RedirectResponse(url="/backlog", status_code=303)

@_protected.post("/backlog/{item_id}/move", response_class=HTMLResponse)
async def backlog_move(request: Request, item_id: int, direction: str = Query("bottom"),
                        status: str = Query(_BACKLOG_DEFAULT_FILTER),
                        ticket_type: str = Query("all", alias="type")):
    status, ticket_type = normalize_backlog_filters(status, ticket_type)
    with _backlog_lock:
        data  = load_backlog()
        items = data["items"]
        idx   = next((i for i, it in enumerate(items) if it["id"] == item_id), None)
        if idx is not None:
            if direction == "top":
                items.insert(0, items.pop(idx))
            elif direction == "bottom":
                items.append(items.pop(idx))
            elif direction in ("up", "down"):
                # "Up"/"down" move by one *visible* slot under the active
                # filters, not one slot in the full list — otherwise, if the
                # adjacent full-list item happens to be filtered out, the
                # button would look like it did nothing.
                visible = [it for it in items if _backlog_matches(it, status, ticket_type)]
                vis_idx = next((i for i, it in enumerate(visible) if it["id"] == item_id), None)
                if vis_idx is not None:
                    neighbor_id = None
                    if direction == "up" and vis_idx > 0:
                        neighbor_id = visible[vis_idx - 1]["id"]
                    elif direction == "down" and vis_idx < len(visible) - 1:
                        neighbor_id = visible[vis_idx + 1]["id"]
                    if neighbor_id is not None:
                        item = items.pop(idx)
                        neighbor_idx = next(i for i, it in enumerate(items) if it["id"] == neighbor_id)
                        items.insert(neighbor_idx if direction == "up" else neighbor_idx + 1, item)
            save_backlog(data)
    return templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(status, ticket_type),
    })

# ── Apply ──────────────────────────────────────────────────────────────────────
_apply_lock = asyncio.Lock()
_SSE_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}

# Maps config section key → nase apply subcommand argument
_SECTION_APPLY_ARG: dict[str, str] = {
    "nas":            "nas",
    "drives":         "drives",
    "samba":          "samba",
    "sync_jobs":      "sync",
    "config_archive": "config-archive",
    "services":       "services",
    "tailscale":      "tailscale",
    "notifications":  "notifications",
    "file_watch":     "watch",
    "status_report":  "status-report",
}

def _stream_cmd(*cmd: str) -> StreamingResponse:
    """Return an SSE StreamingResponse that streams *cmd* stdout under the apply lock."""
    if _apply_lock.locked():
        async def _busy():
            yield "data: [apply already running]\n\n"
            yield "event: done\ndata: 1\n\n"
        return StreamingResponse(_busy(), media_type="text/event-stream", headers=_SSE_HEADERS)

    async def _stream():
        async with _apply_lock:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(REPO_ROOT),
            )
            async for raw in proc.stdout:
                line = raw.decode(errors="replace").rstrip("\n").replace("\n", " ")
                yield f"data: {line}\n\n"
            await proc.wait()
            yield f"event: done\ndata: {proc.returncode}\n\n"

    return StreamingResponse(_stream(), media_type="text/event-stream", headers=_SSE_HEADERS)



@_protected.get("/apply")
async def apply_all():
    """Stream a full `nase apply` (apply.sh) run's output as Server-Sent Events."""
    return _stream_cmd(str(REPO_ROOT / "nase"), "apply")

@_protected.get("/apply/{section}")
async def apply_section(section: str):
    """Stream `nase apply <section>` output as Server-Sent Events."""
    if section not in _SECTION_APPLY_ARG:
        async def _err():
            yield f"data: Unknown section '{section}'\n\n"
            yield "event: done\ndata: 1\n\n"
        return StreamingResponse(_err(), media_type="text/event-stream", headers=_SSE_HEADERS)
    return _stream_cmd(str(REPO_ROOT / "nase"), "apply", _SECTION_APPLY_ARG[section])

app.include_router(_protected)
