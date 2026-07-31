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

import yaml
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from ruamel.yaml import YAML as RuamelYAML

# ── Paths ──────────────────────────────────────────────────────────────────────
APP_DIR     = Path(__file__).parent
REPO_ROOT   = Path(os.environ.get("REPO_ROOT", APP_DIR.parent.parent))
CONFIG_FILE = REPO_ROOT / "config.yaml"
STAMP_DIR   = Path("/var/lib/nase")
LOG_DIR     = Path("/var/log/nase")
CENTRAL_LOG = LOG_DIR / "nase.log"
EVENTS_LOG  = Path(os.environ.get("NASE_EVENTS_LOG", str(STAMP_DIR / "primary-events.log")))
SPIN_HISTORY_LOG = STAMP_DIR / "spin-history.log"
BACKLOG_FILE = Path(os.environ.get("NASE_BACKLOG_FILE", str(STAMP_DIR / "backlog.json")))

_CHANGES_PAGE_SIZE = 20
_WINDOW_SECS  = {"hour": 3600, "day": 86400, "week": 604800, "month": 2592000}
_WINDOW_LABEL = {"hour": "1 hour", "day": "24 hours", "week": "7 days", "month": "30 days"}

# ── Auth ───────────────────────────────────────────────────────────────────────
_WEB_USERNAME = os.environ.get("WEB_USERNAME", "nase")
_WEB_PASSWORD = os.environ.get("WEB_PASSWORD", "")
_http_basic   = HTTPBasic(realm="NASe")

def _require_auth(credentials: HTTPBasicCredentials = Depends(_http_basic)):
    if not _WEB_PASSWORD:
        raise HTTPException(status_code=401,
                            detail="WEB_PASSWORD not set in .env",
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

# ── Config ─────────────────────────────────────────────────────────────────────
def load_config() -> dict:
    with open(CONFIG_FILE) as f:
        return yaml.safe_load(f)

# ── systemd helpers ────────────────────────────────────────────────────────────
def _run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), capture_output=True, text=True)

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
    r = _run("findmnt", "--target", mp, "--noheadings")
    if r.returncode != 0 or not r.stdout.strip():
        return {"status": "not mounted", "mode": None, "usage": None}
    r_opts = _run("findmnt", "--target", mp,
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

def _read_spin_history() -> dict[str, list[tuple[int, str, str]]]:
    """drive name -> chronological (epoch, state, wake_reason) samples, oldest first.

    wake_reason is "" except on a standby/unknown -> active transition sample,
    where spin_sample.sh records its best guess at what caused the wake.
    """
    try:
        lines = SPIN_HISTORY_LOG.read_text().splitlines() if SPIN_HISTORY_LOG.exists() else []
    except (PermissionError, OSError):
        lines = []
    per_drive: dict[str, list[tuple[int, str, str]]] = {}
    for line in lines:
        parts = line.split("\t")
        # Accept both the current 5-field format and the older 4-field one
        # (no reason column) so pre-upgrade log entries still render.
        if len(parts) == 5:
            ts_str, name, state, _method, reason = parts
        elif len(parts) == 4:
            ts_str, name, state, _method = parts
            reason = "-"
        else:
            continue
        try:
            ts = int(ts_str)
        except ValueError:
            continue
        per_drive.setdefault(name, []).append((ts, state, "" if reason == "-" else reason))
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

    for job in cfg.get("sync_jobs", []):
        name      = job["name"]
        unit      = f"nase-sync-{name}.timer"
        state     = unit_active(unit)
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
_BACKLOG_STATUSES = {"open", "ready", "done", "deleted"}
_BACKLOG_FILTERS  = {"all"} | _BACKLOG_STATUSES

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
        item.setdefault("implementation_details", "")
        item.setdefault("links", [])
    return data

def save_backlog(data: dict) -> None:
    BACKLOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    BACKLOG_FILE.write_text(json.dumps(data, indent=2))

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
    elif item.get("status") != status:
        return False
    if ticket_type != "all" and item.get("type") != ticket_type:
        return False
    return True

def backlog_view(status: str, ticket_type: str = "all") -> dict:
    """Backlog items filtered by status and/or type, for the list/filter bars.

    "all" status deliberately excludes "deleted" — a soft-deleted ticket
    should only reappear when the Deleted filter is picked on purpose, not
    sit in the default view.
    """
    status      = status if status in _BACKLOG_FILTERS else "all"
    ticket_type = ticket_type if ticket_type in _BACKLOG_TYPE_FILTERS else "all"
    items = [i for i in load_backlog()["items"] if _backlog_matches(i, status, ticket_type)]
    return {"items": items, "status": status, "type": ticket_type}

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

def _save_section(section: str, yaml_text: str) -> None:
    """Parse yaml_text with ruamel (preserving CommentedMap/Seq metadata),
    load config.yaml (preserving comments/order in all other sections),
    update one top-level key, and write back."""
    import io
    ry  = _make_ryaml()
    new_value = ry.load(yaml_text)
    with open(CONFIG_FILE) as f:
        doc = ry.load(f)
    # Preserve any block/inline comments attached to this key in the top-level map.
    ca = doc.ca.items.get(section)
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
@_protected.get("/backlog", response_class=HTMLResponse)
async def backlog_page(request: Request, status: str = Query("all"),
                        ticket_type: str = Query("all", alias="type")):
    cfg = load_config()
    return templates.TemplateResponse(request, "backlog.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "backlog",
        "backlog":  backlog_view(status, ticket_type),
    })

@_protected.get("/partials/backlog", response_class=HTMLResponse)
async def partial_backlog(request: Request, status: str = Query("all"),
                           ticket_type: str = Query("all", alias="type")):
    return templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(status, ticket_type),
    })

@_protected.post("/backlog/add", response_class=HTMLResponse)
async def backlog_add(request: Request):
    form  = await request.form()
    title = (form.get("title") or "").strip()
    type_ = form.get("type") or "feature"
    if type_ not in _BACKLOG_TYPES:
        type_ = "feature"
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
    # Always land back on the fully-unfiltered view — a just-added item
    # could otherwise vanish immediately under an active status or type filter.
    return templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view("all", "all"),
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
async def backlog_detail(request: Request, item_id: int):
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
    })

@_protected.post("/backlog/{item_id}/links/add")
async def backlog_link_add(item_id: int, request: Request):
    form      = await request.form()
    rel_type  = form.get("rel_type") or ""
    target_id = form.get("target_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        target = find_backlog_item(data, int(target_id)) if target_id.isdigit() else None
        if item is not None and target is not None and target["id"] != item_id \
           and rel_type in BACKLOG_RELATIONS:
            inverse = BACKLOG_RELATIONS[rel_type]["inverse"]
            if not any(l["type"] == rel_type and l["target_id"] == target["id"]
                       for l in item["links"]):
                item["links"].append({"type": rel_type, "target_id": target["id"]})
            if not any(l["type"] == inverse and l["target_id"] == item_id
                       for l in target["links"]):
                target["links"].append({"type": inverse, "target_id": item_id})
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

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

@_protected.post("/backlog/{item_id}")
async def backlog_update(request: Request, item_id: int):
    form   = await request.form()
    title  = (form.get("title") or "").strip()
    type_  = form.get("type") or "feature"
    if type_ not in _BACKLOG_TYPES:
        type_ = "feature"
    status = form.get("status") or "open"
    if status not in _BACKLOG_STATUSES:
        status = "open"
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if title:
            item["title"] = title
        item["type"] = type_
        item["description"] = form.get("description") or ""
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
                        status: str = Query("all"), ticket_type: str = Query("all", alias="type")):
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
