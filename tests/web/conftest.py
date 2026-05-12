"""Shared fixtures for web app tests.

Run from repo root:
    modules/web/venv/bin/python -m pytest tests/web/ -v
Or via the shell wrapper:
    bash tests/web/run.sh
"""
import base64
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Ensure repo root is importable so `import modules.web.app.main` resolves.
REPO_ROOT = Path(__file__).parent.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

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
def auth_headers():
    creds = base64.b64encode(f"{TEST_USER}:{TEST_PASS}".encode()).decode()
    return {"Authorization": f"Basic {creds}"}


@pytest.fixture()
def client(config_file, stamp_dir, log_dir, monkeypatch):
    """TestClient with patched paths, auth, and a fake _run (no systemctl calls)."""
    import modules.web.app.main as m
    from fastapi.testclient import TestClient

    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
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
