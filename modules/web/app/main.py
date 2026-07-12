#!/usr/bin/env python3
"""NASe web dashboard — FastAPI + HTMX."""
from __future__ import annotations

import asyncio
import os
import re
import secrets
import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path

import yaml
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, StreamingResponse
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

def unit_next(unit: str) -> str:
    r = _run("systemctl", "show", unit,
             "--property=NextElapseUSecRealtime", "--value")
    val = r.stdout.strip()
    if not val or val in ("0", "n/a"):
        return "—"
    r2 = _run("date", "-d", val, "+%Y-%m-%d %H:%M:%S")
    return r2.stdout.strip() or "—"

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

# ── Stamp info ─────────────────────────────────────────────────────────────────
def stamp_info(job_name: str, *, stamp_file: Path | None = None) -> tuple[str, str | None]:
    stamp = stamp_file if stamp_file is not None else STAMP_DIR / f"sync-{job_name}.stamp"
    if not stamp.exists():
        return "never", None
    mtime = stamp.stat().st_mtime
    dt    = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
    diff  = int(datetime.now().timestamp() - mtime)
    if   diff < 60:    ago = f"{diff}s ago"
    elif diff < 3600:  ago = f"{diff // 60}min ago"
    elif diff < 86400: ago = f"{diff // 3600}h ago"
    else:              ago = f"{diff // 86400}d ago"
    return dt, ago

# ── Status builder ─────────────────────────────────────────────────────────────
def build_status(cfg: dict) -> dict:
    services = []
    services.append({
        "name":         "nase-monitor",
        "state":        unit_active("nase-monitor.timer"),
        "detail_label": "next",
        "detail":       unit_next("nase-monitor.timer"),
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

    drives = [{**d, **drive_info(d)} for d in cfg.get("drives", [])]

    timers = []

    # Config archive timer (shown first, separate from user data sync jobs)
    if cfg.get("config_archive"):
        unit  = "nase-config-archive.timer"
        state = unit_active(unit)
        last, ago = stamp_info("config-archive",
                               stamp_file=STAMP_DIR / "config-archive.stamp")
        timers.append({
            "name":  "config-archive",
            "state": state,
            "next":  unit_next(unit) if state == "active" else "—",
            "last":  last,
            "ago":   ago,
        })

    for job in cfg.get("sync_jobs", []):
        name      = job["name"]
        unit      = f"nase-sync-{name}.timer"
        state     = unit_active(unit)
        last, ago = stamp_info(name)
        timers.append({
            "name":  name,
            "state": state,
            "next":  unit_next(unit) if state == "active" else "—",
            "last":  last,
            "ago":   ago,
        })

    return {"services": services, "drives": drives, "timers": timers}

_VALID_JOB_NAME = re.compile(r"^[a-zA-Z0-9_-]+$")

# ── Log helpers ────────────────────────────────────────────────────────────────
def log_path(job: str | None) -> Path:
    if job is not None and not _VALID_JOB_NAME.match(job):
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
_INTEGRITY_FLAGGED_LIMIT = 200

def _integrity_db_path(mountpoint: str) -> Path:
    return Path(mountpoint) / ".nase" / "integrity.db"

def _integrity_query(db: Path, sql: str, params: tuple = ()) -> list[tuple]:
    """Read-only query against a drive's manifest. Never opens for writing —
    this dashboard must not be able to corrupt or lock a DB that
    modules/integrity's own scripts are concurrently updating."""
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5) as conn:
            return conn.execute(sql, params).fetchall()
    except sqlite3.Error:
        return []

def _integrity_meta(db: Path, key: str) -> str | None:
    rows = _integrity_query(db, "SELECT value FROM meta WHERE key = ?", (key,))
    return rows[0][0] if rows else None

def drive_integrity_info(name: str, mountpoint: str) -> dict:
    db = _integrity_db_path(mountpoint)
    if not mountpoint or not db.exists():
        return {"name": name, "mountpoint": mountpoint, "has_manifest": False}

    total_n   = (_integrity_query(db, "SELECT COUNT(*) FROM files") or [(0,)])[0][0]
    ok_n      = (_integrity_query(db, "SELECT COUNT(*) FROM files WHERE status='ok'") or [(0,)])[0][0]
    flagged_n = (_integrity_query(db, "SELECT COUNT(*) FROM files WHERE status='flagged'") or [(0,)])[0][0]

    discovery_complete = _integrity_meta(db, "discovery_complete") == "true"
    discovery_pct = None
    if not discovery_complete:
        discovery_total_raw = _integrity_meta(db, "discovery_total")
        try:
            discovery_total = int(discovery_total_raw) if discovery_total_raw else 0
        except ValueError:
            discovery_total = 0
        if discovery_total > 0:
            discovery_pct = round(min(100, total_n / discovery_total * 100))

    flagged_rows = _integrity_query(db, f"""
        SELECT f.path, f.last_checked, e.event_type, e.detail
        FROM files f
        LEFT JOIN events e ON e.id = (
            SELECT id FROM events e2
            WHERE e2.path = f.path AND e2.event_type IN ('mismatch', 'missing')
            ORDER BY e2.ts DESC LIMIT 1
        )
        WHERE f.status = 'flagged'
        ORDER BY f.last_checked DESC
        LIMIT {_INTEGRITY_FLAGGED_LIMIT}
    """)
    flagged = [
        {
            "path":       path,
            "checked":    datetime.fromtimestamp(last_checked).strftime("%Y-%m-%d %H:%M:%S")
                          if last_checked else "—",
            "event_type": event_type or "unknown",
            "detail":     detail or "",
        }
        for path, last_checked, event_type, detail in flagged_rows
    ]

    return {
        "name":               name,
        "mountpoint":         mountpoint,
        "has_manifest":       True,
        "total":              total_n,
        "ok":                 ok_n,
        "flagged":            flagged_n,
        "discovery_complete": discovery_complete,
        "discovery_pct":      discovery_pct,
        "flagged_rows":       flagged,
        "flagged_truncated":  flagged_n > len(flagged),
    }

def build_integrity(cfg: dict) -> dict:
    enabled = bool(cfg.get("integrity", {}).get("enabled"))
    drives = [
        drive_integrity_info(d["name"], d.get("mountpoint", ""))
        for d in cfg.get("drives", [])
        if d.get("active") is not False
    ]
    return {"enabled": enabled, "drives": drives}

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
