#!/usr/bin/env python3
"""NASe web dashboard — FastAPI + HTMX.

The app itself: error pages, the unauthenticated page routes, the config editor
routes and the apply SSE stream. Everything else lives in a feature module
beside this one, and is reached through the module object (core.CONFIG_FILE,
system.build_status, ...) rather than a `from` import — see core.py for why.
"""
from __future__ import annotations

import asyncio

import yaml
from fastapi import FastAPI, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import backlog, changes, configedit, core, reports, system

app = FastAPI(title="NASe Dashboard")
app.mount("/static", StaticFiles(directory=str(core.APP_DIR / "static")), name="static")

_protected = core.protected_router()

# Registered here rather than in configedit, which defines it: the templates
# live on core and the filter does not, so wiring the two together is the
# composition root's job. Left as an import side effect it would work only for
# as long as something happened to import configedit first.
core.templates.env.filters["unwrap_prose"] = configedit.unwrap_prose

# ── Error pages ────────────────────────────────────────────────────────────────
# By default an HTTPException renders as bare JSON, so cancelling the browser's
# Basic-auth dialog leaves the user staring at {"detail":"Not authenticated"} on
# a blank page. Serve humans a styled page instead, while machine clients — and
# the SSE streams, which must keep speaking event-stream — still get JSON.

def _error_text(status: int, detail: str) -> tuple[str, str, str | None]:
    """(heading, message, hint) for an error response. `hint` is a command or
    action the reader can act on, and is rendered as preformatted text."""
    if status == 401:
        if detail == core._AUTH_UNCONFIGURED:
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
        return core.load_config().get("nas", {}).get("hostname", "nase")
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
        return core.templates.TemplateResponse(
            request, "partials/error_inline.html",
            {"heading": heading, "message": message},
            status_code=exc.status_code, headers=headers)

    # EventSource sends "text/event-stream" and API clients "application/json";
    # neither accepts HTML, so both fall through to the JSON default below.
    if "text/html" in request.headers.get("accept", ""):
        return core.templates.TemplateResponse(
            request, "error.html",
            {"hostname": _hostname(), "status": exc.status_code, "heading": heading,
             "message": message, "hint": hint, "retry_path": request.url.path},
            status_code=exc.status_code, headers=headers)

    return JSONResponse({"detail": detail}, status_code=exc.status_code, headers=headers)

# ── Routes ─────────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    cfg       = core.load_config()
    job_names = [j["name"] for j in cfg.get("sync_jobs", [])]
    return core.templates.TemplateResponse(request, "index.html", {
        "hostname":  cfg.get("nas", {}).get("hostname", "nase"),
        "page":      "dashboard",
        "status":    system.build_status(cfg),
        "job_names": job_names,
        "log_lines": system.read_log(None),
    })

@app.get("/changes", response_class=HTMLResponse)
async def changes_page(
    request: Request,
    window:  str  = Query("day"),
    page:    int  = Query(1),
    group:   bool = Query(False),
):
    cfg = core.load_config()
    if window not in core._WINDOW_SECS:
        window = "day"
    return core.templates.TemplateResponse(request, "changes.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "changes",
        "changes":  changes.build_changes(window, page, group),
    })

@app.get("/partials/changes", response_class=HTMLResponse)
async def partial_changes(
    request: Request,
    window:  str  = Query("day"),
    page:    int  = Query(1),
    group:   bool = Query(False),
):
    if window not in core._WINDOW_SECS:
        window = "day"
    return core.templates.TemplateResponse(request, "partials/changes.html", {
        "changes": changes.build_changes(window, page, group),
    })

@app.get("/partials/status", response_class=HTMLResponse)
async def partial_status(request: Request):
    cfg = core.load_config()
    return core.templates.TemplateResponse(request, "partials/status.html", {
        "status": system.build_status(cfg),
    })

@app.get("/integrity", response_class=HTMLResponse)
async def integrity_page(request: Request):
    cfg = core.load_config()
    return core.templates.TemplateResponse(request, "integrity.html", {
        "hostname":  cfg.get("nas", {}).get("hostname", "nase"),
        "page":      "integrity",
        "integrity": changes.build_integrity(cfg),
    })

@app.get("/partials/integrity", response_class=HTMLResponse)
async def partial_integrity(request: Request):
    cfg = core.load_config()
    return core.templates.TemplateResponse(request, "partials/integrity.html", {
        "integrity": changes.build_integrity(cfg),
    })

@app.get("/monitoring", response_class=HTMLResponse)
async def monitoring_page(request: Request, window: str = Query("day")):
    cfg = core.load_config()
    if window not in core._WINDOW_SECS:
        window = "day"
    return core.templates.TemplateResponse(request, "monitoring.html", {
        "hostname":   cfg.get("nas", {}).get("hostname", "nase"),
        "page":       "monitoring",
        "monitoring": system.build_monitoring(cfg, window),
    })

@app.get("/partials/monitoring", response_class=HTMLResponse)
async def partial_monitoring(request: Request, window: str = Query("day")):
    cfg = core.load_config()
    if window not in core._WINDOW_SECS:
        window = "day"
    return core.templates.TemplateResponse(request, "partials/monitoring.html", {
        "monitoring": system.build_monitoring(cfg, window),
    })

@app.get("/partials/logs", response_class=HTMLResponse)
async def partial_logs(request: Request, job: str | None = Query(None)):
    return core.templates.TemplateResponse(request, "partials/logs.html", {
        "log_lines": system.read_log(job),
    })

@_protected.get("/config", response_class=HTMLResponse)
async def config_page(request: Request, tab: str = Query("nas")):
    cfg        = core.load_config()
    active_tab = tab if tab in configedit._SECTION_KEYS else "nas"
    section_yaml = {k: configedit._section_to_yaml(cfg.get(k)) for k, _ in configedit.CONFIG_SECTIONS}
    return core.templates.TemplateResponse(request, "config.html", {
        "hostname":     cfg.get("nas", {}).get("hostname", "nase"),
        "page":         "config",
        "sections":     configedit.CONFIG_SECTIONS,
        "section_yaml": section_yaml,
        "active_tab":   active_tab,
    })

@_protected.post("/config/{section}", response_class=HTMLResponse)
async def save_config_section(request: Request, section: str):
    def _err(msg: str):
        return core.templates.TemplateResponse(request, "partials/save_result.html",
                                          {"success": False, "message": msg})

    if section not in configedit._SECTION_KEYS:
        return _err(f"Unknown section '{section}'.")

    form      = await request.form()
    yaml_text = form.get("yaml_text", "")

    # Validate syntax before touching the file.
    try:
        yaml.safe_load(yaml_text)
    except yaml.YAMLError as exc:
        return _err(f"YAML parse error: {exc}")

    try:
        configedit._save_section(section, yaml_text)
    except Exception as exc:
        return _err(f"Write error: {exc}")

    return core.templates.TemplateResponse(request, "partials/save_result.html",
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
                cwd=str(core.REPO_ROOT),
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
    return _stream_cmd(str(core.REPO_ROOT / "nase"), "apply")

@_protected.get("/apply/{section}")
async def apply_section(section: str):
    """Stream `nase apply <section>` output as Server-Sent Events."""
    if section not in _SECTION_APPLY_ARG:
        async def _err():
            yield f"data: Unknown section '{section}'\n\n"
            yield "event: done\ndata: 1\n\n"
        return StreamingResponse(_err(), media_type="text/event-stream", headers=_SSE_HEADERS)
    return _stream_cmd(str(core.REPO_ROOT / "nase"), "apply", _SECTION_APPLY_ARG[section])

app.include_router(_protected)
app.include_router(reports.router)
app.include_router(backlog.router)
