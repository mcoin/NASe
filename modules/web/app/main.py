#!/usr/bin/env python3
"""NASe web dashboard — FastAPI + HTMX."""
from __future__ import annotations

import os
import subprocess
from datetime import datetime
from pathlib import Path

import yaml
from fastapi import FastAPI, Query, Request
from fastapi.responses import HTMLResponse
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

app = FastAPI(title="NASe Dashboard")
app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))

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
    opts = _run("findmnt", "--target", mp,
                "--output", "OPTIONS", "--noheadings", "--first-only").stdout
    mode = "ro" if "ro" in opts.split(",") else "rw"
    df = _run("df", "-h", mp).stdout.splitlines()
    usage = None
    if len(df) >= 2:
        parts = df[1].split()
        if len(parts) >= 5:
            usage = f"{parts[2]} / {parts[1]} ({parts[4]})"
    return {"status": "mounted", "mode": mode, "usage": usage}

# ── Stamp info ─────────────────────────────────────────────────────────────────
def stamp_info(job_name: str) -> tuple[str, str | None]:
    stamp = STAMP_DIR / f"sync-{job_name}.stamp"
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

# ── Log helpers ────────────────────────────────────────────────────────────────
def log_path(job: str | None) -> Path:
    return Path(f"/var/log/nase-sync-{job}.log") if job else CENTRAL_LOG

def read_log(job: str | None, lines: int = 80) -> list[dict]:
    path = log_path(job)
    if not path.exists():
        return []
    with open(path) as f:
        raw = f.readlines()[-lines:]
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

# ── Config sections ────────────────────────────────────────────────────────────
# Order and display labels for the config editor tabs.
CONFIG_SECTIONS: list[tuple[str, str]] = [
    ("nas",           "General"),
    ("drives",        "Drives"),
    ("samba",         "Samba"),
    ("sync_jobs",     "Sync Jobs"),
    ("services",      "Services"),
    ("tailscale",     "Tailscale"),
    ("notifications", "Notifications"),
]
_SECTION_KEYS = {k for k, _ in CONFIG_SECTIONS}

def _section_to_yaml(value: object) -> str:
    """Serialise a config section value to a YAML string."""
    import io
    ry = RuamelYAML()
    ry.default_flow_style = False
    buf = io.StringIO()
    ry.dump(value, buf)
    return buf.getvalue()

def _save_section(section: str, new_value: object) -> None:
    """Load config.yaml with ruamel (preserving comments/order in other
    sections), update one top-level key, and write back."""
    ry = RuamelYAML()
    ry.preserve_quotes = True
    with open(CONFIG_FILE) as f:
        doc = ry.load(f)
    doc[section] = new_value
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

@app.get("/partials/status", response_class=HTMLResponse)
async def partial_status(request: Request):
    cfg = load_config()
    return templates.TemplateResponse(request, "partials/status.html", {
        "status": build_status(cfg),
    })

@app.get("/partials/logs", response_class=HTMLResponse)
async def partial_logs(request: Request, job: str | None = Query(None)):
    return templates.TemplateResponse(request, "partials/logs.html", {
        "log_lines": read_log(job),
    })

@app.get("/config", response_class=HTMLResponse)
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

@app.post("/config/{section}", response_class=HTMLResponse)
async def save_config_section(request: Request, section: str):
    def _err(msg: str):
        return templates.TemplateResponse(request, "partials/save_result.html",
                                          {"success": False, "message": msg})

    if section not in _SECTION_KEYS:
        return _err(f"Unknown section '{section}'.")

    form      = await request.form()
    yaml_text = form.get("yaml_text", "")

    try:
        new_value = yaml.safe_load(yaml_text)
    except yaml.YAMLError as exc:
        return _err(f"YAML parse error: {exc}")

    try:
        _save_section(section, new_value)
    except Exception as exc:
        return _err(f"Write error: {exc}")

    return templates.TemplateResponse(request, "partials/save_result.html",
                                      {"success": True, "message": ""})
