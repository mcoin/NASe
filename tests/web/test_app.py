"""Tests for modules/web/app/main.py."""
import base64
import time
from unittest.mock import patch

import pytest
import yaml

from conftest import make_integrity_cache


# ── read_log ───────────────────────────────────────────────────────────────────

def test_read_log_missing_returns_empty(tmp_path, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CENTRAL_LOG", tmp_path / "nonexistent.log")
    assert m.read_log(None) == []


def test_read_log_line_classification(tmp_path, monkeypatch):
    import modules.web.app.main as m
    log = tmp_path / "nase.log"
    log.write_text(
        "[OK   ] success\n"
        "[WARN ] warning\n"
        "[ERROR] error\n"
        "[-----] section\n"
        "plain info\n"
    )
    monkeypatch.setattr(m, "CENTRAL_LOG", log)
    lines = m.read_log(None)
    assert [ln["cls"] for ln in lines] == [
        "log-ok", "log-warn", "log-err", "log-section", "log-info"
    ]


def test_read_log_tail_limits_lines(tmp_path, monkeypatch):
    import modules.web.app.main as m
    log = tmp_path / "nase.log"
    log.write_text("\n".join(f"line {i}" for i in range(100)) + "\n")
    monkeypatch.setattr(m, "CENTRAL_LOG", log)
    lines = m.read_log(None, lines=10)
    assert len(lines) == 10
    assert lines[-1]["text"] == "line 99"


def test_read_log_strips_trailing_newline(tmp_path, monkeypatch):
    import modules.web.app.main as m
    log = tmp_path / "nase.log"
    log.write_text("hello world\n")
    monkeypatch.setattr(m, "CENTRAL_LOG", log)
    assert m.read_log(None)[0]["text"] == "hello world"


def test_read_log_missing_job_returns_empty():
    import modules.web.app.main as m
    # /var/log/nase-sync-no-such-job.log won't exist in test environment
    assert m.read_log("no-such-job-xyz") == []


# ── stamp_info ─────────────────────────────────────────────────────────────────

def test_stamp_info_missing_returns_never(tmp_path, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", tmp_path)
    dt, ago = m.stamp_info("nojob")
    assert dt == "never"
    assert ago is None


def test_stamp_info_existing_stamp(tmp_path, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", tmp_path)
    (tmp_path / "sync-myjob.stamp").touch()
    dt, ago = m.stamp_info("myjob")
    assert dt != "never"
    assert ago is not None
    assert "ago" in ago


# ── _section_to_yaml / _save_section ──────────────────────────────────────────

def test_section_to_yaml_produces_valid_yaml():
    import modules.web.app.main as m
    value = {"hostname": "test-nas", "port": 8088}
    text = m._section_to_yaml(value)
    assert yaml.safe_load(text) == value


def test_save_section_updates_target_key(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    m._save_section("nas", "hostname: updated-nas\n")
    result = yaml.safe_load(config_file.read_text())
    assert result["nas"]["hostname"] == "updated-nas"


def test_save_section_preserves_other_sections(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    original = yaml.safe_load(config_file.read_text())
    m._save_section("nas", "hostname: new-name\n")
    result = yaml.safe_load(config_file.read_text())
    assert result["drives"] == original["drives"]
    assert result["sync_jobs"] == original["sync_jobs"]
    assert result["tailscale"] == original["tailscale"]


# ── Route: GET / ───────────────────────────────────────────────────────────────

def test_index_returns_200_html(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_index_shows_hostname(client):
    r = client.get("/")
    assert "test-nas" in r.text


# ── Route: GET /partials/status ────────────────────────────────────────────────

def test_partial_status_returns_200(client):
    r = client.get("/partials/status")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_partial_status_shows_drive_name(client):
    r = client.get("/partials/status")
    assert "primary" in r.text


def test_partial_status_shows_sync_job(client):
    r = client.get("/partials/status")
    assert "data" in r.text


# ── Route: GET /partials/logs ──────────────────────────────────────────────────

def test_partial_logs_no_job_returns_200(client):
    r = client.get("/partials/logs")
    assert r.status_code == 200


def test_partial_logs_renders_log_content(client, log_dir):
    (log_dir / "nase.log").write_text("[OK   ] all good\n")
    r = client.get("/partials/logs")
    assert r.status_code == 200
    assert "all good" in r.text


def test_partial_logs_job_param_returns_200(client):
    # Job log at /var/log/nase-sync-data.log won't exist; returns empty log view.
    r = client.get("/partials/logs?job=data")
    assert r.status_code == 200


# ── Route: GET /config ─────────────────────────────────────────────────────────

def test_config_requires_auth(client):
    r = client.get("/config")
    assert r.status_code == 401


def test_config_rejects_wrong_password(client):
    bad = base64.b64encode(b"nase:wrongpass").decode()
    r = client.get("/config", headers={"Authorization": f"Basic {bad}"})
    assert r.status_code == 401


def test_config_ok_with_correct_auth(client, auth_headers):
    r = client.get("/config", headers=auth_headers)
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_config_default_tab_is_nas(client, auth_headers):
    r = client.get("/config", headers=auth_headers)
    assert "General" in r.text  # label for the "nas" tab in CONFIG_SECTIONS


def test_config_unknown_tab_falls_back_to_nas(client, auth_headers):
    r = client.get("/config?tab=bogus", headers=auth_headers)
    assert r.status_code == 200
    assert "General" in r.text


def test_config_known_tab_accepted(client, auth_headers):
    r = client.get("/config?tab=drives", headers=auth_headers)
    assert r.status_code == 200


# ── Route: POST /config/{section} ─────────────────────────────────────────────

def test_save_section_requires_auth(client):
    r = client.post("/config/nas", data={"yaml_text": "hostname: x\n"})
    assert r.status_code == 401


def test_save_section_valid_yaml_shows_saved(client, auth_headers):
    r = client.post(
        "/config/nas",
        headers=auth_headers,
        data={"yaml_text": "hostname: new-name\n"},
    )
    assert r.status_code == 200
    assert "Saved" in r.text


def test_save_section_invalid_yaml_shows_error(client, auth_headers):
    r = client.post(
        "/config/nas",
        headers=auth_headers,
        data={"yaml_text": "{\n  unclosed bracket\n"},
    )
    assert r.status_code == 200
    assert "YAML parse error" in r.text


def test_save_section_unknown_section_shows_error(client, auth_headers):
    r = client.post(
        "/config/bogus",
        headers=auth_headers,
        data={"yaml_text": "key: value\n"},
    )
    assert r.status_code == 200
    assert "Unknown section" in r.text


def test_save_section_persists_to_config_file(client, auth_headers, config_file):
    client.post(
        "/config/nas",
        headers=auth_headers,
        data={"yaml_text": "hostname: persisted-name\n"},
    )
    assert yaml.safe_load(config_file.read_text())["nas"]["hostname"] == "persisted-name"


# ── Route: GET /apply ──────────────────────────────────────────────────────────

def test_apply_all_requires_auth(client):
    r = client.get("/apply")
    assert r.status_code == 401


def test_apply_section_requires_auth(client):
    r = client.get("/apply/nas")
    assert r.status_code == 401


def test_apply_unknown_section_returns_sse_error(client, auth_headers):
    r = client.get("/apply/bogus", headers=auth_headers)
    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert "Unknown section" in r.text
    assert "event: done" in r.text


def test_apply_section_streams_sse(client, auth_headers):
    class FakeProcess:
        returncode = 0

        def __init__(self):
            async def _gen():
                yield b"applying...\n"
            self.stdout = _gen()

        async def wait(self):
            pass

    async def fake_create(*args, **kwargs):
        return FakeProcess()

    with patch("asyncio.create_subprocess_exec", new=fake_create):
        r = client.get("/apply/nas", headers=auth_headers)

    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert "data: applying..." in r.text
    assert "event: done" in r.text


def test_apply_all_streams_sse(client, auth_headers):
    class FakeProcess:
        returncode = 0

        def __init__(self):
            async def _gen():
                yield b"all done\n"
            self.stdout = _gen()

        async def wait(self):
            pass

    async def fake_create(*args, **kwargs):
        return FakeProcess()

    with patch("asyncio.create_subprocess_exec", new=fake_create):
        r = client.get("/apply", headers=auth_headers)

    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert "event: done" in r.text


# ── drive_integrity_info / build_integrity ──────────────────────────────────────

def test_drive_integrity_info_no_manifest(tmp_path):
    import modules.web.app.main as m
    info = m.drive_integrity_info("drive1", str(tmp_path / "nope"))
    assert info == {"name": "drive1", "mountpoint": str(tmp_path / "nope"), "has_manifest": False}


def test_drive_integrity_info_empty_mountpoint():
    import modules.web.app.main as m
    info = m.drive_integrity_info("drive1", "")
    assert info["has_manifest"] is False


def test_drive_integrity_info_counts_and_discovery(tmp_path, stamp_dir, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    mountpoint = tmp_path / "drive1"
    now = int(time.time())
    make_integrity_cache(
        stamp_dir, mountpoint,
        rows=[
            ("a.txt", 10, now, "aaa", "ok", now),
            ("b.txt", 10, now, "bbb", "ok", now),
            ("c.txt", 10, now, "ccc", "flagged", now),
        ],
        meta={"discovery_complete": "false", "discovery_total": "6", "drive_uuid": "x"},
    )
    info = m.drive_integrity_info("drive1", str(mountpoint))
    assert info["has_manifest"] is True
    assert info["total"] == 3
    assert info["ok"] == 2
    assert info["flagged"] == 1
    assert info["discovery_complete"] is False
    # 3 known files out of a 6-file discovery_total → 50%
    assert info["discovery_pct"] == 50


def test_drive_integrity_info_discovery_complete_has_no_pct(tmp_path, stamp_dir, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    mountpoint = tmp_path / "drive1"
    make_integrity_cache(stamp_dir, mountpoint, meta={"discovery_complete": "true"})
    info = m.drive_integrity_info("drive1", str(mountpoint))
    assert info["discovery_complete"] is True
    assert info["discovery_pct"] is None


def test_drive_integrity_info_flagged_rows_include_event_detail(tmp_path, stamp_dir, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    mountpoint = tmp_path / "drive1"
    now = int(time.time())
    make_integrity_cache(
        stamp_dir, mountpoint,
        rows=[("bad.txt", 10, now, "aaa", "flagged", now)],
        events=[("bad.txt", "mismatch", "expected aaa got zzz")],
        meta={"discovery_complete": "true"},
    )
    info = m.drive_integrity_info("drive1", str(mountpoint))
    assert len(info["flagged_rows"]) == 1
    row = info["flagged_rows"][0]
    assert row["path"] == "bad.txt"
    assert row["event_type"] == "mismatch"
    assert "expected aaa got zzz" in row["detail"]


def test_drive_integrity_info_flagged_rows_only_ok_excluded(tmp_path, stamp_dir, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "STAMP_DIR", stamp_dir)
    mountpoint = tmp_path / "drive1"
    now = int(time.time())
    make_integrity_cache(
        stamp_dir, mountpoint,
        rows=[("good.txt", 10, now, "aaa", "ok", now)],
        meta={"discovery_complete": "true"},
    )
    info = m.drive_integrity_info("drive1", str(mountpoint))
    assert info["flagged_rows"] == []


def test_build_integrity_disabled_by_default():
    import modules.web.app.main as m
    assert m.build_integrity({}) == {"enabled": False, "drives": []}


def test_build_integrity_excludes_inactive_drives(tmp_path):
    import modules.web.app.main as m
    cfg = {
        "integrity": {"enabled": True},
        "drives": [
            {"name": "a", "mountpoint": str(tmp_path / "a"), "active": True},
            {"name": "b", "mountpoint": str(tmp_path / "b"), "active": False},
        ],
    }
    result = m.build_integrity(cfg)
    assert result["enabled"] is True
    assert [d["name"] for d in result["drives"]] == ["a"]


# ── Route: GET /integrity ───────────────────────────────────────────────────────

def test_integrity_page_returns_200(integrity_client):
    r = integrity_client.get("/integrity")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_integrity_page_no_auth_required(integrity_client):
    # Unlike /config, integrity status is read-only and unauthenticated,
    # matching / and /changes.
    r = integrity_client.get("/integrity")
    assert r.status_code == 200


def test_integrity_page_shows_drive_name(integrity_client):
    r = integrity_client.get("/integrity")
    assert "drive1" in r.text


def test_integrity_page_no_manifest_shows_hint(integrity_client):
    r = integrity_client.get("/integrity")
    assert "no manifest" in r.text.lower()
    assert "nase apply integrity" in r.text


def test_integrity_page_disabled_shows_hint(client):
    # The shared `client` fixture's MINIMAL_CONFIG has no integrity section.
    r = client.get("/integrity")
    assert r.status_code == 200
    assert "integrity.enabled" in r.text


def test_integrity_page_shows_flagged_file(integrity_client, integrity_config_file, stamp_dir):
    cfg = yaml.safe_load(integrity_config_file.read_text())
    mountpoint = cfg["drives"][0]["mountpoint"]
    now = int(time.time())
    make_integrity_cache(
        stamp_dir, mountpoint,
        rows=[("movies/bad.mp4", 10, now, "aaa", "flagged", now)],
        events=[("movies/bad.mp4", "mismatch", "expected aaa got zzz")],
        meta={"discovery_complete": "true"},
    )
    r = integrity_client.get("/integrity")
    assert "movies/bad.mp4" in r.text
    assert "mismatch" in r.text


def test_integrity_page_no_flagged_files_shows_all_clear(integrity_client, integrity_config_file, stamp_dir):
    cfg = yaml.safe_load(integrity_config_file.read_text())
    mountpoint = cfg["drives"][0]["mountpoint"]
    now = int(time.time())
    make_integrity_cache(
        stamp_dir, mountpoint,
        rows=[("ok.txt", 10, now, "aaa", "ok", now)],
        meta={"discovery_complete": "true"},
    )
    r = integrity_client.get("/integrity")
    assert "all checks passing" in r.text.lower()


# ── Route: GET /partials/integrity ──────────────────────────────────────────────

def test_partial_integrity_returns_200(integrity_client):
    r = integrity_client.get("/partials/integrity")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]


def test_partial_integrity_matches_full_page_content(integrity_client):
    full    = integrity_client.get("/integrity").text
    partial = integrity_client.get("/partials/integrity").text
    assert "drive1" in full
    assert "drive1" in partial
