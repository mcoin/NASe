#!/usr/bin/env python3
"""Archived weekly status reports (backlog #37)."""
from __future__ import annotations

import json
from datetime import datetime

from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse

from . import core

router = core.protected_router()

# ── Status reports (backlog #37) ───────────────────────────────────────────────
def load_reports() -> list[dict]:
    """Every archived report, newest first.

    A file that will not parse is skipped rather than allowed to break the
    page: this directory is written by a shell script and copied to the drive
    by another one, so one unreadable entry should cost that entry and nothing
    more."""
    out: list[dict] = []
    try:
        entries = sorted(core.REPORTS_DIR.glob("*.json"))
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
@router.get("/reports", response_class=HTMLResponse)
async def reports_page(request: Request):
    cfg = core.load_config()
    return core.templates.TemplateResponse(request, "reports.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "reports",
        "reports":  [_report_view(r) for r in load_reports()],
        # So the empty state can say when the first one is due rather than
        # leaving the reader wondering whether anything is broken.
        "schedule": cfg.get("status_report", {}).get("schedule", ""),
        "enabled":  cfg.get("status_report", {}).get("enabled", True),
    })


@router.get("/reports/{generated_at}", response_class=HTMLResponse)
async def report_detail(request: Request, generated_at: int):
    cfg = core.load_config()
    match = next((r for r in load_reports() if r["generated_at"] == generated_at), None)
    if match is None:
        raise HTTPException(status_code=404, detail="Report not found")
    return core.templates.TemplateResponse(request, "report_detail.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "reports",
        "report":   _report_view(match),
    })
