#!/usr/bin/env python3
"""Readings taken from the running system: systemd units, drives, spin state,
the monitoring timeline, and the log tail."""
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

from . import core

# ── systemd helpers ────────────────────────────────────────────────────────────
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
    out = core._run("systemctl", "show", "--property=Id", "--property=Description",
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
    return core._run("systemctl", "is-active", unit).stdout.strip() or "unknown"

def _relative_duration(seconds: int) -> str:
    """'90' -> '1min', '7300' -> '2h', etc. — shared by past ("X ago") and
    future ("in X") relative-time labels so both use the same thresholds."""
    if   seconds < 60:    return f"{seconds}s"
    elif seconds < 3600:  return f"{seconds // 60}min"
    elif seconds < 86400: return f"{seconds // 3600}h"
    else:                 return f"{seconds // 86400}d"

def unit_next(unit: str) -> tuple[str, str | None]:
    r = core._run("systemctl", "show", unit,
             "--property=NextElapseUSecRealtime", "--value")
    val = r.stdout.strip()
    if not val or val in ("0", "n/a"):
        return "—", None
    r2 = core._run("date", "-d", val, "+%Y-%m-%d %H:%M:%S %s")
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
    r = core._run("findmnt", "--mountpoint", mp, "--noheadings")
    if r.returncode != 0 or not r.stdout.strip():
        return {"status": "not mounted", "mode": None, "usage": None}
    r_opts = core._run("findmnt", "--mountpoint", mp,
                  "--output", "OPTIONS", "--noheadings", "--first-only")
    if r_opts.returncode != 0:
        return {"status": "not mounted", "mode": None, "usage": None}
    mode = "ro" if "ro" in r_opts.stdout.split(",") else "rw"
    r_df = core._run("df", "-h", mp)
    usage = None
    if r_df.returncode == 0:
        df = r_df.stdout.splitlines()
        if len(df) >= 2:
            parts = df[1].split()
            if len(parts) >= 5:
                usage = f"{parts[2]} / {parts[1]} ({parts[4]})"
    return {"status": "mounted", "mode": mode, "usage": usage}

# ── Spin state ─────────────────────────────────────────────────────────────────
SPIN_STATUS_SCRIPT = core.REPO_ROOT / "modules" / "drives" / "spin_status.sh"

def drive_spin_info(name: str, active: bool) -> dict:
    if not active:
        return {"spin_state": None, "spin_duration": None, "spin_estimated": False}
    r = core._run(str(SPIN_STATUS_SCRIPT), name)
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
        lines = core.SPIN_HISTORY_LOG.read_text().splitlines() if core.SPIN_HISTORY_LOG.exists() else []
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
    secs  = core._WINDOW_SECS.get(window, 86400)
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
        "label":       core._WINDOW_LABEL.get(window, "24 hours"),
        "ticks":       ticks,
        "wake_events": wake_events,
    }

# ── Stamp info ─────────────────────────────────────────────────────────────────
def stamp_info(job_name: str, *, stamp_file: Path | None = None) -> tuple[str, str | None]:
    stamp = stamp_file if stamp_file is not None else core.STAMP_DIR / f"sync-{job_name}.stamp"
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
        r = core._run("tailscale", "status")
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
                               stamp_file=core.STAMP_DIR / "config-archive.stamp")
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
    return Path(f"/var/log/nase-sync-{job}.log") if job else core.CENTRAL_LOG

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
