#!/usr/bin/env python3
"""What changed on the drives: the file-activity feed built from the watcher's
event log, and the integrity manifest summary."""
from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

from . import core

# ── File changes ───────────────────────────────────────────────────────────
# .nase/ (integrity manifest internals) and .trash/ (sync retention) are
# internal bookkeeping, not user activity — never show them here, even for
# entries logged before record.sh started excluding them (retention is 90
# days, so old entries can linger).
_CHANGES_EXCLUDE_RE = re.compile(r"^/mnt/[^/]+/\.(nase|trash)(/|$)")

# Bookkeeping the watcher writes about itself, not file activity: __heartbeat__
# proves nase-primary-watch is still alive (lib/watch.sh reads it to decide
# whether the event log can vouch for a window) and __gap__ marks a restart.
#
# Both carry "-" as their path, so the path-based exclude above cannot see
# them — which is how 288 heartbeats came to be listed as a single changed file
# called "-" in a share called "(root)", and counted as "1 file" (backlog #39).
# The status report had the identical bug and was fixed under #29; this reader
# was missed at the time, so the filter goes in by operation on both sides now.
_CHANGES_EXCLUDE_OPS = frozenset({"__heartbeat__", "__gap__"})

def build_changes(window: str = "day", page: int = 1, group: bool = False) -> dict:
    secs = core._WINDOW_SECS.get(window, 86400)
    since_str = datetime.fromtimestamp(datetime.now().timestamp() - secs).strftime("%Y-%m-%d %H:%M:%S")

    latest_ts: dict[str, str] = {}
    latest_op: dict[str, str] = {}
    counts:    dict[str, int] = {}

    try:
        log_lines_iter = open(core.EVENTS_LOG).readlines() if core.EVENTS_LOG.exists() else []
    except (PermissionError, OSError):
        log_lines_iter = []
    for line in log_lines_iter:
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) < 3:
            continue
        ts, op, path = parts
        if ts < since_str:
            continue
        if op in _CHANGES_EXCLUDE_OPS:
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
    pages  = max(1, -(-total // core._CHANGES_PAGE_SIZE))
    page   = max(1, min(page, pages))
    sliced = items[(page - 1) * core._CHANGES_PAGE_SIZE : page * core._CHANGES_PAGE_SIZE]

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
        "label":  core._WINDOW_LABEL.get(window, "24 hours"),
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
    return core.STAMP_DIR / "integrity-status" / f"{slug}.json"

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
