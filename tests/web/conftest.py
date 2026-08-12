"""Shared fixtures for web app tests.

Run from repo root:
    modules/web/venv/bin/python -m pytest tests/web/ -v
Or via the shell wrapper:
    bash tests/web/run.sh
"""
import base64
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Ensure repo root is importable so `import modules.web.app.main` resolves.
REPO_ROOT = Path(__file__).parent.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

INTEGRITY_SCHEMA = REPO_ROOT / "modules" / "integrity" / "schema.sql"


def make_integrity_db(db_path: Path, *, rows=(), events=(), meta=None):
    """Build a real .nase/integrity.db (using the actual production schema).
    Used on its own by tests that exercise the manifest DB directly; use
    make_integrity_cache() below for anything the web app itself reads,
    since main.py no longer opens this DB (see modules/integrity/common.sh's
    integrity_write_status_cache)."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.executescript(INTEGRITY_SCHEMA.read_text())
    now = int(time.time())
    for path, size, mtime, checksum, status, last_checked in rows:
        conn.execute(
            "INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (path, size, mtime, checksum, status, now, now, last_checked),
        )
    for path, event_type, detail in events:
        conn.execute(
            "INSERT INTO events (ts, path, event_type, detail) VALUES (?, ?, ?, ?)",
            (now, path, event_type, detail),
        )
    for key, value in (meta or {}).items():
        conn.execute("INSERT INTO meta (key, value) VALUES (?, ?)", (key, value))
    conn.commit()
    conn.close()


def make_integrity_cache(stamp_dir: Path, mountpoint, *, rows=(), events=(), meta=None):
    """Build a real .nase/integrity.db, then run the actual production
    integrity_write_status_cache (modules/integrity/common.sh) against it to
    produce the SD-card status cache — the same code path
    modules/integrity's own scripts use, and the only thing
    drive_integrity_info()/build_integrity() read (see main.py). Exercising
    the real bash/SQL here, rather than a Python reimplementation of it,
    means a change to the cache's shape on either side breaks this test."""
    mountpoint = Path(mountpoint)
    db = mountpoint / ".nase" / "integrity.db"
    make_integrity_db(db, rows=rows, events=events, meta=meta)

    script = (
        'set -euo pipefail\n'
        f'source "{REPO_ROOT}/lib/log.sh"\n'
        f'source "{REPO_ROOT}/modules/integrity/common.sh"\n'
        'integrity_write_status_cache "$1" "$2"\n'
    )
    env = os.environ.copy()
    env["NASE_STAMP_DIR"] = str(stamp_dir)
    env["REPO_ROOT"] = str(REPO_ROOT)
    subprocess.run(
        ["bash", "-c", script, "_", str(mountpoint), str(db)],
        check=True, capture_output=True, text=True, env=env,
    )
    return db

MINIMAL_CONFIG = """\
nas:
  hostname: test-nas
drives:
  - name: primary
    uuid: 00000000-0000-0000-0000-000000000001
    mountpoint: /mnt/primary
    active: false
samba:
  workgroup: WORKGROUP
  shares: []
sync_jobs:
  - name: data
    source: /mnt/primary/data/
    dest: /mnt/backup1/data/
    schedule: '*-*-* 03:00:00'
    rsync_flags: --archive --delete
    on_failure: ignore
    force_sync_days: 7
    trash:
      enabled: false
      path: /mnt/backup1/.trash
      retention_days: 30
services:
  filebrowser:
    enabled: false
  web:
    enabled: true
    port: 8088
tailscale:
  enabled: false
notifications:
  method: none
file_watch: []
"""

TEST_USER = "nase"
TEST_PASS = "testpass"


@pytest.fixture()
def config_file(tmp_path):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(MINIMAL_CONFIG)
    return cfg


@pytest.fixture()
def stamp_dir(tmp_path):
    d = tmp_path / "stamps"
    d.mkdir()
    return d


@pytest.fixture()
def log_dir(tmp_path):
    d = tmp_path / "logs"
    d.mkdir()
    return d


@pytest.fixture()
def backlog_file(tmp_path):
    """Where the app's backlog JSON lives during tests. The client fixture
    points BACKLOG_FILE here, so no test can read or write the real
    /var/lib/nase/backlog.json (which a person may be editing in the UI at
    the same time)."""
    return tmp_path / "backlog.json"


def write_backlog(path, items):
    """Seed backlog_file with items given as (id, title, status, type), or as
    dicts when a test needs more than that (description, notes, ...) — dict
    keys are merged over the same defaults."""
    rows = []
    for item in items:
        row = {"id": None, "title": "", "status": "open", "type": "feature",
               "description": "", "implementation_details": "",
               "created_at": "2026-01-01 00:00:00",
               "links": [], "comments": [], "external_links": []}
        if isinstance(item, dict):
            row.update(item)
        else:
            i, title, status, type_ = item
            row.update(id=i, title=title, status=status, type=type_)
        rows.append(row)
    path.write_text(json.dumps(
        {"items": rows, "next_id": max((r["id"] for r in rows), default=0) + 1}))


@pytest.fixture()
def auth_headers():
    creds = base64.b64encode(f"{TEST_USER}:{TEST_PASS}".encode()).decode()
    return {"Authorization": f"Basic {creds}"}


@pytest.fixture()
def client(config_file, stamp_dir, log_dir, backlog_file, monkeypatch):
    """TestClient with patched paths, auth, and a fake _run (no systemctl calls)."""
    import modules.web.app.main as m
    from fastapi.testclient import TestClient

    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    monkeypatch.setattr(m, "BACKLOG_FILE", backlog_file)
    monkeypatch.setattr(m, "LOG_DIR", log_dir)
    monkeypatch.setattr(m, "CENTRAL_LOG", log_dir / "nase.log")
    monkeypatch.setattr(m, "_WEB_USERNAME", TEST_USER)
    monkeypatch.setattr(m, "_WEB_PASSWORD", TEST_PASS)

    def fake_run(*cmd):
        r = MagicMock()
        r.returncode = 0
        r.stdout = "inactive\n"
        return r

    monkeypatch.setattr(m, "_run", fake_run)
    return TestClient(m.app, raise_server_exceptions=True)


@pytest.fixture()
def integrity_config_file(tmp_path):
    """A config with integrity enabled and one active drive with a real
    (writable, test-owned) mountpoint — MINIMAL_CONFIG's drive is inactive
    and has no real mountpoint, so integrity tests need their own config."""
    drive_mp = tmp_path / "drive1"
    drive_mp.mkdir()
    cfg = tmp_path / "config.yaml"
    cfg.write_text(f"""\
nas:
  hostname: test-nas
drives:
  - name: drive1
    uuid: 00000000-0000-0000-0000-000000000001
    mountpoint: {drive_mp}
    active: true
samba:
  workgroup: WORKGROUP
  shares: []
sync_jobs: []
services:
  filebrowser:
    enabled: false
  web:
    enabled: true
    port: 8088
tailscale:
  enabled: false
notifications:
  method: none
file_watch: []
integrity:
  enabled: true
""")
    return cfg


@pytest.fixture()
def integrity_client(integrity_config_file, stamp_dir, log_dir, monkeypatch):
    """TestClient pointed at integrity_config_file (integrity enabled, one
    active drive with a real mountpoint under tmp_path)."""
    import modules.web.app.main as m
    from fastapi.testclient import TestClient

    monkeypatch.setattr(m, "CONFIG_FILE", integrity_config_file)
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    monkeypatch.setattr(m, "LOG_DIR", log_dir)
    monkeypatch.setattr(m, "CENTRAL_LOG", log_dir / "nase.log")
    monkeypatch.setattr(m, "_WEB_USERNAME", TEST_USER)
    monkeypatch.setattr(m, "_WEB_PASSWORD", TEST_PASS)

    return TestClient(m.app, raise_server_exceptions=True)
