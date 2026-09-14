"""Tests for modules/web/app/main.py."""
import base64
import json
import re
import time
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from conftest import REPO_ROOT, make_integrity_cache, write_backlog

# The live backlog, used read-only as a corpus for the fold's safety property.
REPO_ROOT_BACKLOG = Path("/var/lib/nase/backlog.json")


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


# ── Backlog filters ─────────────────────────────────────────────────────────────

SAMPLE_BACKLOG = [
    (1, "an open one",        "open",        "bug"),
    (2, "a ready one",        "ready",       "feature"),
    (3, "an in-progress one", "in_progress", "feature"),
    (4, "a done one",         "done",        "feature"),
    (5, "a closed one",       "closed",      "improvement"),
    (6, "a deleted one",      "deleted",     "bug"),
]


def _titles(view):
    return [i["title"] for i in view["items"]]


def test_backlog_view_active_spans_open_ready_and_in_progress(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("active", "all")) == [
        "an open one", "a ready one", "an in-progress one"]


def test_backlog_view_in_progress_is_visible_in_default_view(backlog_file, client):
    # The regression this guards is silent rather than loud: leaving
    # "in_progress" out of _BACKLOG_ACTIVE_STATUSES doesn't raise, it just
    # hides every ticket someone is actually working on from the default view.
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert m.backlog_view(m._BACKLOG_DEFAULT_FILTER, "all")["status"] == "active"
    assert "an in-progress one" in _titles(m.backlog_view("active", "all"))
    assert _titles(m.backlog_view("in_progress", "all")) == ["an in-progress one"]


def test_backlog_view_active_combines_with_type_filter(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("active", "bug")) == ["an open one"]


def test_backlog_view_all_still_excludes_deleted_only(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("all", "all")) == [
        "an open one", "a ready one", "an in-progress one", "a done one",
        "a closed one"]


def test_backlog_view_unknown_status_falls_back_to_default(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    view = m.backlog_view("bogus", "all")
    assert view["status"] == "active"
    assert _titles(view) == ["an open one", "a ready one", "an in-progress one"]


def test_backlog_view_total_counts_undeleted_regardless_of_filter(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert m.backlog_view("closed", "all")["total"] == 5


def test_backlog_page_defaults_to_active(client, auth_headers, backlog_file):
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    r = client.get("/backlog", headers=auth_headers)
    assert r.status_code == 200
    assert "an open one" in r.text
    assert "a ready one" in r.text
    assert "a done one" not in r.text
    assert "a closed one" not in r.text


def test_backlog_page_explicit_status_overrides_default(client, auth_headers, backlog_file):
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    r = client.get("/backlog?status=done", headers=auth_headers)
    assert "a done one" in r.text
    assert "an open one" not in r.text


def test_partial_backlog_defaults_to_active(client, auth_headers, backlog_file):
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    r = client.get("/partials/backlog", headers=auth_headers)
    assert "a ready one" in r.text
    assert "a done one" not in r.text


def test_backlog_add_lands_on_view_showing_new_item(client, auth_headers, backlog_file):
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    r = client.post("/backlog/add", headers=auth_headers,
                    data={"title": "brand new", "type": "bug"})
    assert r.status_code == 200
    # New items are "open", so the default (active) view must show it.
    assert "brand new" in r.text


def test_backlog_move_up_uses_visible_order_under_active_filter(client, auth_headers, backlog_file):
    # Full-list order: open(1), done(3), ready(2). Under "active", 2 is
    # directly below 1, so moving it up must put it above 1 in the stored
    # list — not merely swap it with the invisible done item.
    write_backlog(backlog_file, [
        (1, "an open one", "open",  "bug"),
        (3, "a done one",  "done",  "feature"),
        (2, "a ready one", "ready", "feature"),
    ])
    r = client.post("/backlog/2/move?direction=up&status=active&type=all",
                    headers=auth_headers)
    assert r.status_code == 200
    stored = json.loads(backlog_file.read_text())["items"]
    assert [i["id"] for i in stored] == [2, 1, 3]


def test_backlog_empty_state_distinguishes_no_items_from_no_matches(client, auth_headers, backlog_file):
    write_backlog(backlog_file, [])
    assert "No backlog items yet" in client.get("/backlog", headers=auth_headers).text

    write_backlog(backlog_file, [(1, "a done one", "done", "bug")])
    r = client.get("/backlog", headers=auth_headers)
    assert "No matching backlog items" in r.text


# ── Error pages ─────────────────────────────────────────────────────────────────

HTML_ACCEPT = {"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}


def test_unauthenticated_browser_gets_styled_page_not_json(client):
    """The bug: cancelling the Basic-auth dialog left a bare
    {"detail":"Not authenticated"} on an otherwise empty page."""
    r = client.get("/config", headers=HTML_ACCEPT)
    assert r.status_code == 401
    assert "text/html" in r.headers["content-type"]
    assert "Sign-in required" in r.text
    assert "Back to Dashboard" in r.text
    assert '{"detail"' not in r.text


def test_unauthenticated_page_keeps_www_authenticate_header(client):
    """Without this header browsers stop offering the login dialog, so the
    friendlier page would lock the user out of signing in at all."""
    r = client.get("/config", headers=HTML_ACCEPT)
    assert r.headers["www-authenticate"] == 'Basic realm="NASe"'


def test_unauthenticated_page_offers_retry_to_the_same_path(client):
    r = client.get("/backlog", headers=HTML_ACCEPT)
    assert 'href="/backlog"' in r.text


def test_unauthenticated_json_client_still_gets_json(client):
    r = client.get("/config", headers={"Accept": "application/json"})
    assert r.status_code == 401
    assert r.json() == {"detail": "Not authenticated"}
    assert r.headers["www-authenticate"] == 'Basic realm="NASe"'


def test_unauthenticated_sse_client_still_gets_json(client):
    """EventSource must not be handed an HTML document."""
    r = client.get("/apply", headers={"Accept": "text/event-stream"})
    assert r.status_code == 401
    assert "application/json" in r.headers["content-type"]


def test_unauthenticated_htmx_request_gets_fragment_not_document(client):
    r = client.get("/partials/backlog", headers={**HTML_ACCEPT, "HX-Request": "true"})
    assert r.status_code == 401
    assert "Sign-in required" in r.text
    assert "<!DOCTYPE" not in r.text
    assert "<nav" not in r.text


def test_missing_web_password_gets_its_own_message(client, monkeypatch, auth_headers):
    """A server with no WEB_PASSWORD is misconfigured, not a wrong password —
    telling the user to try again would be a dead end."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_WEB_PASSWORD", "")
    r = client.get("/config", headers={**HTML_ACCEPT, **auth_headers})
    assert r.status_code == 401
    assert "not configured" in r.text
    assert "WEB_PASSWORD" in r.text
    assert "Sign-in required" not in r.text


def test_error_page_renders_without_a_readable_config(client, monkeypatch):
    """The page chrome needs a hostname from config.yaml; an unreadable config
    is itself a plausible cause of an error, so it must not blow up here."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", "/nonexistent/config.yaml")
    r = client.get("/config", headers=HTML_ACCEPT)
    assert r.status_code == 401
    assert "Sign-in required" in r.text


def test_missing_backlog_item_gets_styled_404(client, auth_headers, backlog_file):
    write_backlog(backlog_file, [(1, "the only one", "open", "bug")])
    r = client.get("/backlog/99", headers={**HTML_ACCEPT, **auth_headers})
    assert r.status_code == 404
    assert "Not found" in r.text
    assert "Backlog item not found" in r.text


def test_unknown_url_gets_styled_404(client, auth_headers):
    """Starlette raises its own HTTPException for unmatched routes — the
    handler is registered on that base class so these are covered too."""
    r = client.get("/no/such/page", headers={**HTML_ACCEPT, **auth_headers})
    assert r.status_code == 404
    assert "Back to Dashboard" in r.text


# ── Backlog detail: read-first fields ───────────────────────────────────────────

LONG_NOTES = "== Section ==\n" + "\n".join(f"line {i}" for i in range(120))


def _detail(client, auth_headers, backlog_file, **fields):
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket", **fields}])
    return client.get("/backlog/1", headers=auth_headers).text


def test_detail_renders_description_as_text_not_only_in_a_textarea(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file, description="hello world")
    # The rendered view is what makes the page readable on a phone; the
    # textarea stays in the DOM so Save still posts the field untouched.
    assert 'id="view-description"' in html
    assert html.count("hello world") == 2


def test_detail_renders_full_notes_without_truncating(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file, implementation_details=LONG_NOTES)
    assert 'id="view-impl"' in html
    assert "line 119" in html


def test_detail_empty_fields_show_a_muted_placeholder(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file)
    assert "No description yet." in html
    assert "No notes yet." in html
    assert "field-empty" in html


def test_detail_non_empty_field_has_no_empty_placeholder_class(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file,
                   description="something", decision="something decided",
                   implementation_details="something else")
    # "field-empty" also appears in the toggle script, so check the class
    # actually applied to the rendered views rather than the whole page.
    assert "field-text field-empty" not in html


def test_detail_edit_toggle_points_at_both_nodes(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file, description="hello")
    assert 'data-editor="field-description"' in html
    assert 'data-view="view-description"' in html
    assert 'data-editor="field-impl"' in html
    assert 'data-editor="field-decision"' in html
    # One per read-first field (description, decision, notes); the toggle shares
    # the label's line rather than taking a row of its own.
    assert html.count("form-label-row") == 3


def test_saving_untouched_fields_keeps_their_value(client, auth_headers, backlog_file):
    """The read-first swap is client-side only: an unopened field posts the
    textarea's original value, so a Save from the rendered view must not
    blank the description or the notes."""
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket",
                                  "description": "keep me",
                                  "implementation_details": LONG_NOTES}])
    r = client.post("/backlog/1", headers=auth_headers, follow_redirects=False,
                    data={"title": "a ticket", "type": "feature", "status": "ready",
                          "description": "keep me",
                          "implementation_details": LONG_NOTES})
    assert r.status_code == 303
    item = json.loads(backlog_file.read_text())["items"][0]
    assert item["description"] == "keep me"
    assert item["implementation_details"] == LONG_NOTES
    assert item["status"] == "ready"


def test_backlog_update_persists_in_progress(client, auth_headers, backlog_file):
    """Saving In progress must store it, not silently reset to Open.

    backlog_update falls back to "open" for any status outside
    _BACKLOG_STATUSES, so a value wired into the dropdown but missing from
    that set would look like the Save simply didn't take."""
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket"}])
    r = client.post("/backlog/1", headers=auth_headers, follow_redirects=False,
                    data={"title": "a ticket", "type": "feature",
                          "status": "in_progress", "description": "",
                          "implementation_details": ""})
    assert r.status_code == 303
    assert json.loads(backlog_file.read_text())["items"][0]["status"] == "in_progress"


# ── Config editor: comment preservation (#10) ───────────────────────────────────

CONFIG_WITH_SECTION_HEADER = """\
nas:
  hostname: test-nas

sync_jobs:
  # Header comment inside the section
  - name: data
    source: /mnt/primary/data/
    trash:
      enabled: false
      retention_days: 30   # keep a month

# --------------------------------------------------------------------------
# Checksum integrity manifest (see INTEGRITY_DESIGN.md)
# --------------------------------------------------------------------------
integrity:
  enabled: true

services:
  web:
    enabled: true
"""


def test_save_section_keeps_the_header_of_the_following_section(config_file, monkeypatch):
    """The bug: one Form-view save of sync_jobs deleted the whole comment block
    documenting `integrity:`, because ruamel had anchored it to the deepest last
    scalar of the sync_jobs subtree, which the save replaced wholesale."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_SECTION_HEADER)

    # Form view marshals plain, comment-free YAML — nothing to restore from.
    m._save_section("sync_jobs", "- name: data\n  source: /mnt/primary/data/\n")

    text = config_file.read_text()
    assert "Checksum integrity manifest" in text
    assert "INTEGRITY_DESIGN.md" in text
    # ...and it still introduces integrity: rather than floating elsewhere.
    header_at = text.index("Checksum integrity manifest")
    assert 0 < header_at < text.index("integrity:")


def test_save_section_keeps_the_end_of_line_comment_on_the_last_leaf(config_file, monkeypatch):
    """Only the block after the first newline is re-anchored; the leaf's own
    trailing comment belongs to the value and must stay with it."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_SECTION_HEADER)

    m._save_section("nas", "hostname: renamed\n")

    text = config_file.read_text()
    assert "retention_days: 30   # keep a month" in text
    assert "hostname: renamed" in text


def test_save_section_leaves_other_sections_comments_alone(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_SECTION_HEADER)

    m._save_section("services", "web:\n  enabled: false\n")

    text = config_file.read_text()
    assert "Checksum integrity manifest" in text
    assert "Header comment inside the section" in text
    assert yaml.safe_load(text)["services"]["web"]["enabled"] is False


def test_reanchor_is_byte_stable_on_the_real_config():
    """Re-anchoring only changes which node a comment hangs off, never the
    file: loading the repo's own config.yaml, re-anchoring and dumping must
    reproduce it exactly."""
    import io
    import modules.web.app.main as m

    src = (REPO_ROOT / "config.yaml").read_text()
    ry = m._make_ryaml()
    doc = ry.load(src)
    m._reanchor_section_comments(doc)
    buf = io.StringIO()
    ry.dump(doc, buf)
    assert buf.getvalue() == src


def test_reanchor_survives_empty_and_scalar_sections():
    """Sections with nothing to descend into must not break the walk."""
    import modules.web.app.main as m
    ry = m._make_ryaml()
    doc = ry.load("a: 1\nb: {}\nc: []\n\n# block\nd:\n  x: 1\n")
    m._reanchor_section_comments(doc)   # must not raise
    assert list(doc.keys()) == ["a", "b", "c", "d"]


# ── Backlog detail: Decision field ──────────────────────────────────────────────

def test_detail_renders_decision_read_first(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file, decision="Go with option (b).")
    assert 'id="view-decision"' in html
    assert 'data-editor="field-decision"' in html
    assert html.count("Go with option (b).") == 2   # rendered view + textarea


def test_detail_empty_decision_shows_placeholder(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file)
    assert "Not decided yet." in html


def test_decision_sits_above_the_notes(client, auth_headers, backlog_file):
    """The point of the field: the conclusion is visible before the analysis."""
    html = _detail(client, auth_headers, backlog_file,
                   decision="Go with (b).", implementation_details=LONG_NOTES)
    assert html.index('id="view-decision"') < html.index('id="view-impl"')


def test_saving_a_decision_persists_it(client, auth_headers, backlog_file):
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket"}])
    r = client.post("/backlog/1", headers=auth_headers, follow_redirects=False,
                    data={"title": "a ticket", "type": "feature", "status": "ready",
                          "description": "", "decision": "Do the cheap one first.",
                          "implementation_details": ""})
    assert r.status_code == 303
    assert json.loads(backlog_file.read_text())["items"][0]["decision"] == "Do the cheap one first."


def test_decision_survives_an_ordinary_save(client, auth_headers, backlog_file):
    """Same trap as #19/#3: the update rewrites the item from the submitted
    fields, so a field the form forgets to send is silently blanked."""
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket",
                                  "decision": "keep me", "description": "d"}])
    html = client.get("/backlog/1", headers=auth_headers).text
    assert 'name="decision"' in html          # the form does submit it
    client.post("/backlog/1", headers=auth_headers, follow_redirects=False,
                data={"title": "a ticket", "type": "feature", "status": "open",
                      "description": "d", "decision": "keep me",
                      "implementation_details": ""})
    assert json.loads(backlog_file.read_text())["items"][0]["decision"] == "keep me"


def test_existing_items_without_a_decision_still_load(client, auth_headers, backlog_file):
    """Items written before the field existed have no 'decision' key at all."""
    backlog_file.write_text(json.dumps({"items": [{"id": 1, "title": "old", "status": "open"}],
                                        "next_id": 2}))
    r = client.get("/backlog/1", headers=auth_headers)
    assert r.status_code == 200
    assert "Not decided yet." in r.text


# ── unwrap_prose: rendering hard-wrapped text (#22) ─────────────────────────────

def _unwrap(text):
    import modules.web.app.main as m
    return m.unwrap_prose(text)


def test_unwrap_joins_a_hard_wrapped_paragraph():
    text = ("A sync_job with source /var/lib/nase/ cannot work: is_safe_mount_path\n"
            "refuses any source that resolves to the root device, on purpose — it is\n"
            "what stops an unmounted drive turning an rsync --delete into a wipe.")
    assert "\n" not in _unwrap(text)


def test_unwrap_keeps_paragraph_breaks():
    text = "First paragraph that is long enough to have been wrapped by hand here.\n\nSecond."
    assert _unwrap(text).count("\n\n") == 1


def test_unwrap_leaves_section_headers_alone():
    text = ("== Why not simply add a sync job ==\n"
            "A line of prose that is easily long enough to look like a wrapped one.\n"
            "== Recommended ==")
    out = _unwrap(text)
    assert out.startswith("== Why not simply add a sync job ==\n")
    assert out.endswith("\n== Recommended ==")


def test_unwrap_leaves_list_items_and_their_indents_alone():
    text = ("  - it compares a hash cached on the SD card and exits before touching\n"
            "    the destination when nothing changed;\n"
            "  - it writes a latest copy plus a timestamped snapshot.")
    assert _unwrap(text) == text


def test_unwrap_leaves_lettered_options_alone():
    text = ("(a) Stop hard-wrapping notes when writing them; let the browser wrap it.\n"
            "(b) Reflow at render time, joining consecutive prose lines together.")
    assert _unwrap(text) == text


def test_unwrap_leaves_tables_alone():
    text = "| viewport | result |\n| 390x844  | two rows |\n| 1200x900 | one row  |"
    assert _unwrap(text) == text


def test_unwrap_does_not_join_onto_a_short_line():
    """A short line ended its paragraph deliberately; the next line starts a new
    one even without a blank line between them."""
    text = "Short line.\nA following line that happens to be quite a lot longer than that."
    assert _unwrap(text) == text


def test_unwrap_changes_only_whitespace():
    """The one guarantee: folding may never add, drop or reorder content."""
    import re
    for item in json.loads(REPO_ROOT_BACKLOG.read_text())["items"] if REPO_ROOT_BACKLOG.exists() else []:
        for field in ("description", "decision", "implementation_details"):
            before = item.get(field) or ""
            after = _unwrap(before)
            assert re.sub(r"\s+", " ", before).strip() == re.sub(r"\s+", " ", after).strip()


def test_unwrap_is_idempotent():
    text = ("A hard-wrapped paragraph that runs past the threshold and therefore\n"
            "continues onto a second line, and then a third one here.\n"
            "\n"
            "== Header ==\n"
            "  - a list item\n")
    once = _unwrap(text)
    assert _unwrap(once) == once


def test_detail_view_folds_but_the_textarea_keeps_the_stored_text(client, auth_headers, backlog_file):
    """No migration: what is stored must survive a Save untouched, so the fold
    applies to the rendered view only."""
    wrapped = ("A hard-wrapped paragraph that runs past the fold threshold and so\n"
               "continues onto a second line here.")
    html = _detail(client, auth_headers, backlog_file, implementation_details=wrapped)
    folded = wrapped.replace("\n", " ")
    assert folded in html          # the rendered view
    assert wrapped in html         # the textarea, still verbatim


def test_unwrap_handles_crlf_from_the_form():
    """Everything typed into the web form arrives CRLF-terminated. A \\r left
    mid-line renders as a line break, so the fold would look like it had not
    happened at all — which is exactly how this was found."""
    text = ("A sync_job with source /var/lib/nase/ cannot work: is_safe_mount_path\r\n"
            "refuses any source that resolves to the root device, on purpose.\r\n")
    out = _unwrap(text)
    assert "\r" not in out
    assert out.strip() == ("A sync_job with source /var/lib/nase/ cannot work: is_safe_mount_path "
                           "refuses any source that resolves to the root device, on purpose.")


def test_unwrap_keeps_crlf_paragraph_breaks():
    text = "A first paragraph long enough to have been wrapped by hand right here.\r\n\r\nSecond."
    assert _unwrap(text).count("\n\n") == 1


# ── Backlog attachments (#20) ───────────────────────────────────────────────────

PNG_1PX = (b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + b"IHDR" + b"\x00" * 40)
JPEG_HEAD = b"\xff\xd8\xff\xe0" + b"\x00" * 60
GIF_HEAD = b"GIF89a" + b"\x00" * 60
WEBP_HEAD = b"RIFF" + b"\x00\x00\x00\x00" + b"WEBP" + b"\x00" * 40


@pytest.fixture()
def attach_client(client, tmp_path, monkeypatch):
    """The client fixture with attachments redirected into tmp_path, so no test
    can write next to the real backlog."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "ATTACHMENT_DIR", tmp_path / "backlog-attachments")
    return client


def _upload(client, auth_headers, payload, filename="shot.png", content_type="image/png"):
    return client.post("/backlog/1/attachments/add", headers=auth_headers,
                       files={"image": (filename, payload, content_type)},
                       follow_redirects=False)


def _one_item(backlog_file):
    write_backlog(backlog_file, [{"id": 1, "title": "a ticket"}])


def test_attachment_upload_round_trip(attach_client, auth_headers, backlog_file):
    _one_item(backlog_file)
    assert _upload(attach_client, auth_headers, PNG_1PX).status_code == 303

    item = json.loads(backlog_file.read_text())["items"][0]
    assert len(item["attachments"]) == 1
    a = item["attachments"][0]
    assert a["media_type"] == "image/png"
    assert a["bytes"] == len(PNG_1PX)

    r = attach_client.get(f"/backlog/1/attachments/{a['id']}", headers=auth_headers)
    assert r.status_code == 200
    assert r.content == PNG_1PX
    assert r.headers["content-type"].startswith("image/png")
    assert r.headers["x-content-type-options"] == "nosniff"


@pytest.mark.parametrize("payload,expected", [
    (PNG_1PX, "image/png"), (JPEG_HEAD, "image/jpeg"),
    (GIF_HEAD, "image/gif"), (WEBP_HEAD, "image/webp"),
])
def test_attachment_accepts_the_four_image_types(attach_client, auth_headers, backlog_file,
                                                 payload, expected):
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, payload)
    assert json.loads(backlog_file.read_text())["items"][0]["attachments"][0]["media_type"] == expected


def test_attachment_rejects_a_non_image_claiming_to_be_one(attach_client, auth_headers, backlog_file):
    """The upload's Content-Type and filename are both attacker-controlled, so
    the decision is made on the bytes."""
    _one_item(backlog_file)
    r = _upload(attach_client, auth_headers, b"#!/bin/sh\nrm -rf /\n",
                filename="totally.png", content_type="image/png")
    assert r.status_code == 303
    assert "err=not_an_image" in r.headers["location"]
    # .get(): a rejected upload writes nothing at all, so the stored item never
    # even gains the key — load_backlog() backfills it in memory only.
    assert json.loads(backlog_file.read_text())["items"][0].get("attachments", []) == []


def test_attachment_rejects_svg(attach_client, auth_headers, backlog_file):
    """SVG can carry script and there is no safe way to serve it inline."""
    _one_item(backlog_file)
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    r = _upload(attach_client, auth_headers, svg, filename="x.svg", content_type="image/svg+xml")
    assert "err=not_an_image" in r.headers["location"]


def test_attachment_enforces_the_size_cap(attach_client, auth_headers, backlog_file):
    import modules.web.app.main as m
    _one_item(backlog_file)
    too_big = PNG_1PX + b"\x00" * (m.MAX_ATTACHMENT_BYTES + 1)
    r = _upload(attach_client, auth_headers, too_big)
    assert "err=too_big" in r.headers["location"]
    assert json.loads(backlog_file.read_text())["items"][0].get("attachments", []) == []


def test_attachment_enforces_the_count_cap(attach_client, auth_headers, backlog_file):
    import modules.web.app.main as m
    _one_item(backlog_file)
    for _ in range(m.MAX_ATTACHMENTS_PER_ITEM):
        _upload(attach_client, auth_headers, PNG_1PX)
    r = _upload(attach_client, auth_headers, PNG_1PX)
    assert "err=too_many" in r.headers["location"]
    assert len(json.loads(backlog_file.read_text())["items"][0]["attachments"]) == \
        m.MAX_ATTACHMENTS_PER_ITEM


def test_attachment_serving_requires_auth(attach_client, auth_headers, backlog_file):
    """These do not live under the unauthenticated /static mount for this reason."""
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX)
    aid = json.loads(backlog_file.read_text())["items"][0]["attachments"][0]["id"]
    assert attach_client.get(f"/backlog/1/attachments/{aid}").status_code == 401


def test_attachment_stored_name_is_generated_not_the_upload_name(attach_client, auth_headers,
                                                                 backlog_file):
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX, filename="../../etc/passwd.png")
    a = json.loads(backlog_file.read_text())["items"][0]["attachments"][0]
    assert "/" not in a["stored_name"]
    assert ".." not in a["stored_name"]
    assert a["stored_name"].endswith(".png")


def test_attachment_delete_removes_the_file(attach_client, auth_headers, backlog_file, tmp_path):
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX)
    a = json.loads(backlog_file.read_text())["items"][0]["attachments"][0]
    path = tmp_path / "backlog-attachments" / "1" / a["stored_name"]
    assert path.is_file()

    attach_client.post("/backlog/1/attachments/remove", headers=auth_headers,
                       data={"attachment_id": str(a["id"])}, follow_redirects=False)
    assert not path.exists()
    assert json.loads(backlog_file.read_text())["items"][0]["attachments"] == []


def test_attachments_survive_an_ordinary_save(attach_client, auth_headers, backlog_file):
    """The trap from #19, #3 and #23: the update rewrites the item from the
    submitted fields, and the edit form knows nothing about attachments."""
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX)
    attach_client.post("/backlog/1", headers=auth_headers, follow_redirects=False,
                       data={"title": "a ticket", "type": "feature", "status": "ready",
                             "description": "d", "decision": "", "implementation_details": ""})
    assert len(json.loads(backlog_file.read_text())["items"][0]["attachments"]) == 1


def test_detail_page_shows_the_thumbnail_and_the_upload_form(attach_client, auth_headers,
                                                             backlog_file):
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX)
    html = attach_client.get("/backlog/1", headers=auth_headers).text
    assert 'enctype="multipart/form-data"' in html
    assert 'accept="image/*"' in html          # phones offer the camera for this
    assert "/backlog/1/attachments/1" in html


def test_detail_page_reports_a_rejected_upload(attach_client, auth_headers, backlog_file):
    _one_item(backlog_file)
    html = attach_client.get("/backlog/1?err=too_big", headers=auth_headers).text
    assert "larger than 4 MB" in html


def test_missing_attachment_file_is_a_404_not_a_crash(attach_client, auth_headers, backlog_file,
                                                      tmp_path):
    _one_item(backlog_file)
    _upload(attach_client, auth_headers, PNG_1PX)
    a = json.loads(backlog_file.read_text())["items"][0]["attachments"][0]
    (tmp_path / "backlog-attachments" / "1" / a["stored_name"]).unlink()
    r = attach_client.get(f"/backlog/1/attachments/{a['id']}", headers=auth_headers)
    assert r.status_code == 404


# ── Spin history parsing (#4) ───────────────────────────────────────────────────

def _spin_history(tmp_path, monkeypatch, text):
    import modules.web.app.main as m
    log = tmp_path / "spin-history.log"
    log.write_text(text)
    monkeypatch.setattr(m, "SPIN_HISTORY_LOG", log)
    return m._read_spin_history()


def test_spin_history_reads_io_delta_into_the_reason(tmp_path, monkeypatch):
    """The I/O magnitude is the corrective signal for a wake reason that is
    known to misattribute (backlog #4), so it has to reach the reader."""
    out = _spin_history(tmp_path, monkeypatch,
                        "100\tprimary\tactive\testimated\tsync job: video-backup-daily\t3\n")
    assert out["primary"] == [(100, "active", "sync job: video-backup-daily"
                                              " — 3 block requests since last sample")]


def test_spin_history_io_delta_singular_is_not_pluralised(tmp_path, monkeypatch):
    out = _spin_history(tmp_path, monkeypatch, "100\tprimary\tactive\testimated\twoke\t1\n")
    assert out["primary"][0][2] == "woke — 1 block request since last sample"


def test_spin_history_unknown_io_delta_leaves_reason_alone(tmp_path, monkeypatch):
    out = _spin_history(tmp_path, monkeypatch, "100\tprimary\tactive\testimated\twoke\t-\n")
    assert out["primary"][0][2] == "woke"


def test_spin_history_io_delta_without_a_reason_stays_blank(tmp_path, monkeypatch):
    # Non-wake samples carry "-" as the reason; a delta must not invent one.
    out = _spin_history(tmp_path, monkeypatch, "100\tprimary\tstandby\testimated\t-\t0\n")
    assert out["primary"][0][2] == ""


def test_spin_history_still_reads_the_older_formats(tmp_path, monkeypatch):
    """Pre-upgrade lines have to keep rendering — the log is not rewritten on
    upgrade, so the 30-day window spans both formats after any deploy."""
    out = _spin_history(tmp_path, monkeypatch,
                        "100\tprimary\tactive\testimated\twoke\n"       # 5-field
                        "200\tprimary\tstandby\testimated\n"            # 4-field
                        "300\tprimary\tactive\testimated\twoke\t7\n")   # 6-field
    assert out["primary"] == [
        (100, "active", "woke"),
        (200, "standby", ""),
        (300, "active", "woke — 7 block requests since last sample"),
    ]


def test_spin_history_skips_malformed_lines(tmp_path, monkeypatch):
    out = _spin_history(tmp_path, monkeypatch,
                        "not-a-timestamp\tprimary\tactive\testimated\t-\t0\n"
                        "100\tprimary\n"
                        "300\tprimary\tactive\testimated\t-\t0\n")
    assert [s[0] for s in out["primary"]] == [300]


# ── Refused writes are reported, not swallowed (#28) ───────────────────────────
# Every mutating endpoint used to answer 303 whether or not it had done
# anything. The failure mode was invisible: nothing in the log, nothing on the
# page, and a success status code — so a script recorded success for writes
# that never happened. Each case below asserts both halves: the item is
# unchanged, and the caller was told.

HTML_FORM = {"Accept": "text/html,application/xhtml+xml"}


def _two_items(backlog_file):
    write_backlog(backlog_file, [(1, "first", "open", "bug"),
                                 (2, "second", "open", "feature")])


def _item(backlog_file, n=0):
    return json.loads(backlog_file.read_text())["items"][n]


def test_link_add_with_the_wrong_field_name_is_refused(client, auth_headers, backlog_file):
    """The exact bug that opened #28: two requests sent `type=` instead of
    `rel_type=`, both answered 303, and neither created a link."""
    _two_items(backlog_file)
    r = client.post("/backlog/1/links/add", headers={**auth_headers, **HTML_FORM},
                    data={"type": "relates_to", "target_id": "2"}, follow_redirects=False)
    assert r.status_code == 303
    assert "err=bad_rel_type" in r.headers["location"]
    assert _item(backlog_file)["links"] == []


def test_link_add_reports_each_rejection_distinctly(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    cases = [
        ({"rel_type": "invented", "target_id": "2"}, "bad_rel_type"),
        ({"rel_type": "relates_to", "target_id": "99"}, "bad_target"),
        ({"rel_type": "relates_to", "target_id": "not-a-number"}, "bad_target"),
        ({"rel_type": "relates_to", "target_id": "1"}, "self_link"),
    ]
    for data, code in cases:
        r = client.post("/backlog/1/links/add", headers={**auth_headers, **HTML_FORM},
                        data=data, follow_redirects=False)
        assert f"err={code}" in r.headers["location"], data
    assert _item(backlog_file)["links"] == []


def test_a_valid_link_still_works(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    r = client.post("/backlog/1/links/add", headers={**auth_headers, **HTML_FORM},
                    data={"rel_type": "relates_to", "target_id": "2"}, follow_redirects=False)
    assert r.status_code == 303
    assert "err=" not in r.headers["location"]
    assert _item(backlog_file)["links"] == [{"type": "relates_to", "target_id": 2}]


def test_a_script_gets_400_not_a_redirect(client, auth_headers, backlog_file):
    """The reason this matters: a client that is not a browser must not be able
    to record success for a write that did not happen."""
    _two_items(backlog_file)
    r = client.post("/backlog/1/links/add", headers=auth_headers,
                    data={"type": "relates_to", "target_id": "2"}, follow_redirects=False)
    assert r.status_code == 400
    assert r.json()["error"] == "bad_rel_type"
    assert _item(backlog_file)["links"] == []


def test_external_link_with_a_non_http_url_is_refused(client, auth_headers, backlog_file):
    """The one an ordinary user can reach: the URL field is free text."""
    _two_items(backlog_file)
    r = client.post("/backlog/1/extlinks/add", headers={**auth_headers, **HTML_FORM},
                    data={"url": "smb://nas/share", "label": "share"},
                    follow_redirects=False)
    assert "err=bad_url" in r.headers["location"]
    assert _item(backlog_file)["external_links"] == []


def test_empty_comment_is_refused(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    r = client.post("/backlog/1/comments/add", headers={**auth_headers, **HTML_FORM},
                    data={"text": "   "}, follow_redirects=False)
    assert "err=empty_comment" in r.headers["location"]
    assert _item(backlog_file)["comments"] == []


def test_update_refuses_a_bad_status_instead_of_coercing_it(client, auth_headers, backlog_file):
    """The worst of the set: an unrecognised status used to become "open", so a
    typo did not fail — it quietly changed the ticket."""
    _two_items(backlog_file)
    r = client.post("/backlog/1", headers={**auth_headers, **HTML_FORM},
                    data={"title": "first", "type": "bug", "status": "dnoe",
                          "description": "", "implementation_details": ""},
                    follow_redirects=False)
    assert "err=bad_status" in r.headers["location"]
    item = _item(backlog_file)
    assert item["status"] == "open"     # unchanged, not coerced from "dnoe"
    assert item["title"] == "first"


def test_update_refuses_a_bad_type_instead_of_coercing_it(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    r = client.post("/backlog/1", headers={**auth_headers, **HTML_FORM},
                    data={"title": "first", "type": "buug", "status": "open",
                          "description": "", "implementation_details": ""},
                    follow_redirects=False)
    assert "err=bad_type" in r.headers["location"]
    assert _item(backlog_file)["type"] == "bug"   # not rewritten to "feature"


def test_update_does_not_discard_edits_it_refuses(client, auth_headers, backlog_file):
    """A refused Save must leave everything alone, not apply the good fields."""
    _two_items(backlog_file)
    client.post("/backlog/1", headers={**auth_headers, **HTML_FORM},
                data={"title": "a new title", "type": "bug", "status": "nonsense",
                      "description": "new text", "implementation_details": ""},
                follow_redirects=False)
    item = _item(backlog_file)
    assert item["title"] == "first"
    assert item["description"] == ""


def test_add_with_an_empty_title_says_so_in_the_partial(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    r = client.post("/backlog/add", headers={**auth_headers, "HX-Request": "true"},
                    data={"title": "   ", "type": "bug"})
    assert r.status_code == 200
    assert "A ticket needs a title" in r.text
    assert len(json.loads(backlog_file.read_text())["items"]) == 2


def test_the_detail_page_renders_the_reason(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    html = client.get("/backlog/1?err=bad_rel_type", headers=auth_headers).text
    assert "not a relationship NASe recognises" in html


def test_an_unknown_error_code_renders_nothing(client, auth_headers, backlog_file):
    _two_items(backlog_file)
    html = client.get("/backlog/1?err=made-up", headers=auth_headers).text
    assert "form-error-banner" not in html


# ── Config editor: comments between items inside a section (#19) ────────────────
# #10 rescued the comment block documenting the *next* section. This is the same
# loss one level down: a note written above the third sync job. The Form view
# marshals comment-free YAML in the browser, so a save used to replace the whole
# subtree and take any such comment with it.

CONFIG_WITH_ITEM_COMMENTS = """\
nas:
  hostname: test-nas

sync_jobs:
  - name: alpha
    source: /mnt/primary/alpha/
  # beta only exists because of the odd camera export
  - name: beta
    source: /mnt/primary/beta/
  # gamma is the slow one — runs last on purpose
  - name: gamma
    source: /mnt/primary/gamma/

services:
  web:
    enabled: true
"""

BETA_NOTE  = "beta only exists because of the odd camera export"
GAMMA_NOTE = "gamma is the slow one"


def _save_jobs(m, config_file, *jobs):
    """Marshal jobs the way the Form view does: plain YAML, no comments."""
    body = "".join(f"- name: {n}\n  source: /mnt/primary/{n}/\n" for n in jobs)
    m._save_section("sync_jobs", body)
    return config_file.read_text()


def _comment_precedes(text, note, name):
    """The note appears, and introduces the item called `name`."""
    if note not in text or f"name: {name}" not in text:
        return False
    return text.index(note) < text.index(f"name: {name}")


def test_item_comment_survives_an_in_place_save(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_ITEM_COMMENTS)
    text = _save_jobs(m, config_file, "alpha", "beta", "gamma")
    assert _comment_precedes(text, BETA_NOTE, "beta")
    assert _comment_precedes(text, GAMMA_NOTE, "gamma")


def test_item_comment_follows_its_item_when_jobs_are_reordered(config_file, monkeypatch):
    """The reason identity matching is non-negotiable. Positionally, the note
    about beta lives after alpha — so a positional merge would leave it
    introducing whatever ends up second, which is the one outcome #19's
    guardrail rules out."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_ITEM_COMMENTS)
    text = _save_jobs(m, config_file, "gamma", "beta", "alpha")
    assert _comment_precedes(text, GAMMA_NOTE, "gamma")
    assert _comment_precedes(text, BETA_NOTE, "beta")
    # And specifically not reattached to the job that now sits where beta was.
    assert text.index(GAMMA_NOTE) < text.index("name: gamma") < text.index(BETA_NOTE)


def test_item_comment_survives_an_insertion_above_it(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_ITEM_COMMENTS)
    text = _save_jobs(m, config_file, "alpha", "inserted", "beta", "gamma")
    assert "name: inserted" in text
    assert _comment_precedes(text, BETA_NOTE, "beta")
    # The new job must not inherit the note that belongs to beta.
    assert text.index("name: inserted") < text.index(BETA_NOTE)


def test_removing_a_job_takes_its_comment_and_leaves_the_others(config_file, monkeypatch):
    """Losing the comment of a deleted item is correct — it documented that
    item. What must not happen is it surviving to introduce another one."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_ITEM_COMMENTS)
    text = _save_jobs(m, config_file, "alpha", "gamma")
    assert "name: beta" not in text
    assert BETA_NOTE not in text
    assert _comment_precedes(text, GAMMA_NOTE, "gamma")


def test_editing_a_field_does_not_disturb_the_comments(config_file, monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_ITEM_COMMENTS)
    m._save_section("sync_jobs",
                    "- name: alpha\n  source: /mnt/primary/alpha/\n"
                    "- name: beta\n  source: /mnt/primary/CHANGED/\n"
                    "- name: gamma\n  source: /mnt/primary/gamma/\n")
    text = config_file.read_text()
    assert "/mnt/primary/CHANGED/" in text
    assert _comment_precedes(text, BETA_NOTE, "beta")
    assert _comment_precedes(text, GAMMA_NOTE, "gamma")


def test_section_header_rescue_from_10_still_works(config_file, monkeypatch):
    """The two passes run back to back; neither may undo the other."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    config_file.write_text(CONFIG_WITH_SECTION_HEADER)
    m._save_section("sync_jobs", "- name: data\n  source: /mnt/primary/data/\n")
    text = config_file.read_text()
    assert "Checksum integrity manifest" in text
    assert 0 < text.index("Checksum integrity manifest") < text.index("integrity:")


def test_the_repos_own_config_round_trips_byte_identically(monkeypatch, tmp_path):
    """The guardrail carried over from #10: the re-anchor passes must not
    quietly reformat the real file. Byte-for-byte, or the pass is not safe to
    run on every save."""
    import io
    import modules.web.app.main as m
    src = (REPO_ROOT / "config.yaml").read_text()
    ry  = m._make_ryaml()
    doc = ry.load(io.StringIO(src))
    m._reanchor_section_comments(doc)
    m._reanchor_item_comments(doc)
    buf = io.StringIO(); ry.dump(doc, buf)
    assert buf.getvalue() == src


# ── A missing drive must not read as mounted (#33) ─────────────────────────────

def _findmnt_fake(mounted_at):
    """Stand in for _run, with the real findmnt's distinction: --target
    resolves up to an enclosing mount, --mountpoint matches only exactly."""
    import subprocess
    def fake(*args):
        argv = list(args)
        if argv[0] == "df":
            # df on an unmounted path reports the filesystem above it — the
            # SD card — which is how the wrong capacity reached the page.
            return subprocess.CompletedProcess(argv, 0, "Filesystem Size Used Avail Use%\n"
                                                        "/dev/root 14G 3G 11G 25%\n", "")
        if argv[0] != "findmnt":
            return subprocess.CompletedProcess(argv, 0, "", "")
        path = argv[argv.index("--mountpoint") + 1] if "--mountpoint" in argv else \
               argv[argv.index("--target") + 1]
        exact = path in mounted_at
        if exact:
            out = "rw,noatime" if "OPTIONS" in argv else path
            return subprocess.CompletedProcess(argv, 0, out, "")
        if "--target" in argv:          # resolves up to the root mount
            out = "rw,relatime" if "OPTIONS" in argv else "/"
            return subprocess.CompletedProcess(argv, 0, out, "")
        return subprocess.CompletedProcess(argv, 1, "", "")
    return fake


def test_absent_drive_reports_not_mounted(monkeypatch):
    """The bug: drive_info asked `findmnt --target`, which succeeds against the
    SD card's root mount, so the "not mounted" branch was unreachable and the
    page showed a missing 5.5 TB drive as mounted rw with ~14 GB of capacity."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", _findmnt_fake({"/mnt/backup_daily"}))
    info = m.drive_info({"mountpoint": "/mnt/primary", "active": True})
    assert info["status"] == "not mounted"
    assert info["usage"] is None
    assert info["mode"] is None


def test_present_drive_still_reports_mounted(monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", _findmnt_fake({"/mnt/primary"}))
    info = m.drive_info({"mountpoint": "/mnt/primary", "active": True})
    assert info["status"] == "mounted"
    assert info["mode"] == "rw"
    assert info["usage"] == "3G / 14G (25%)"


def test_inactive_drive_is_unchanged(monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", _findmnt_fake(set()))
    assert m.drive_info({"mountpoint": "/mnt/x", "active": False})["status"] == "inactive"


def test_drive_info_never_asks_findmnt_target(monkeypatch):
    """Belt and braces: --target cannot answer "is this mounted", so it must
    not be how the dashboard asks. Pins the fix against a later edit."""
    import subprocess
    import modules.web.app.main as m
    seen = []
    def spy(*args):
        seen.append(list(args))
        return subprocess.CompletedProcess(list(args), 1, "", "")
    monkeypatch.setattr(m, "_run", spy)
    m.drive_info({"mountpoint": "/mnt/primary", "active": True})
    findmnt_calls = [a for a in seen if a and a[0] == "findmnt"]
    assert findmnt_calls, "drive_info should consult findmnt"
    assert not any("--target" in a for a in findmnt_calls)


# ── Nav overflow menu (#18) ────────────────────────────────────────────────────

def test_nav_still_lists_every_page(client):
    """The bar #17 set, which #18 must not drop below: every page reachable.
    The tabs are all in the markup; the script only moves them between the row
    and the menu, so if one is missing here it is missing everywhere."""
    html = client.get("/").text
    for href in ("/changes", "/integrity", "/monitoring", "/backlog", "/config"):
        assert f'href="{href}"' in html


def test_nav_has_an_overflow_control(client):
    html = client.get("/").text
    assert 'id="nav-more-btn"' in html
    assert 'aria-expanded="false"' in html      # closed until the user opens it
    assert 'aria-haspopup="true"' in html
    assert 'aria-label="More pages"' in html    # the … glyph alone names nothing


def test_nav_degrades_without_javascript(client):
    """The row may only stop wrapping once the script is running. The
    stylesheet must never set nowrap on its own, or a browser with the script
    blocked gets a bar that overflows the document sideways — the bug #17
    existed to fix."""
    css = (REPO_ROOT / "modules/web/app/static/style.css").read_text()
    nav_block = css[css.index("/* ── Site nav"):css.index("/* ── Nav overflow menu")]
    assert "flex-wrap: wrap" in nav_block
    assert "nowrap" not in nav_block            # only .nav-js, set by the script
    assert ".site-nav.nav-js" in css and "flex-wrap: nowrap" in css


def test_nav_more_container_is_really_hidden_when_empty(client):
    """An author `display: flex` beats the UA stylesheet's [hidden] rule, so
    without an explicit override the … control keeps its ~44px of width while
    reporting itself hidden — which overflowed the document by exactly that
    much before it was caught."""
    css = (REPO_ROOT / "modules/web/app/static/style.css").read_text()
    assert ".nav-more[hidden] { display: none; }" in css


def test_nav_tabs_do_not_shrink(client):
    """Flex items default to flex-shrink: 1, so in a nowrap row the tabs are
    squeezed and getBoundingClientRect reports the squeezed width — the script
    then adds those up, concludes everything fits, and moves nothing while the
    bar still overflows."""
    css = (REPO_ROOT / "modules/web/app/static/style.css").read_text()
    assert ".site-nav.nav-js > a," in css
    assert "flex: 0 0 auto" in css


def test_nav_more_control_meets_the_touch_target_minimum(client):
    css = (REPO_ROOT / "modules/web/app/static/style.css").read_text()
    block = css[css.index(".nav-more-btn {"):]
    assert "min-height: 44px" in block[:400]


def test_nav_menu_closes_on_escape(client):
    html = client.get("/").text
    assert "Escape" in html and "closeMenu" in html


# ── Status reports page (#37) ──────────────────────────────────────────────────

@pytest.fixture
def reports_dir(tmp_path, monkeypatch):
    import modules.web.app.main as m
    d = tmp_path / "reports"
    d.mkdir()
    monkeypatch.setattr(m, "REPORTS_DIR", d)
    return d


def _write_report(d, ts, **over):
    record = {
        "generated_at": ts, "trigger": "scheduled",
        "subject": f"NASe status report — nase — {ts}",
        "period_start": ts - 604800, "period_end": ts,
        "anomalies": 0, "changes": 0,
        "body": "NASe status report\n\n=== SYSTEM STATUS ===\n\n  All systems normal.\n",
    }
    record.update(over)
    (d / f"{ts}.json").write_text(json.dumps(record))
    return record


def test_reports_require_login(client, reports_dir):
    """Stated requirement, not inherited: a report carries file names from
    /mnt/primary, flagged paths and raw ERROR lines, so unlike Dashboard,
    Changes, Integrity and Monitoring this page is not public."""
    _write_report(reports_dir, 1700000000)
    assert client.get("/reports").status_code == 401
    assert client.get("/reports/1700000000").status_code == 401


def test_reports_listed_newest_first(client, auth_headers, reports_dir):
    for ts in (1700000000, 1700600000, 1700300000):
        _write_report(reports_dir, ts)
    html = client.get("/reports", headers=auth_headers).text
    order = [int(t) for t in re.findall(r'href="/reports/(\d+)"', html)]
    assert order == [1700600000, 1700300000, 1700000000]


def test_reports_show_the_anomaly_count(client, auth_headers, reports_dir):
    _write_report(reports_dir, 1700000000, anomalies=3)
    html = client.get("/reports", headers=auth_headers).text
    assert ">3<" in html
    assert "badge-err" in html


def test_a_clean_report_is_visibly_clean(client, auth_headers, reports_dir):
    _write_report(reports_dir, 1700000000, anomalies=0)
    html = client.get("/reports", headers=auth_headers).text
    assert "badge-ok" in html


def test_reports_empty_state_is_explicit(client, auth_headers, reports_dir):
    """Genuinely empty on day one — reports were never kept before this page
    existed, so there is no history to backfill and the reader needs telling
    that nothing is broken."""
    html = client.get("/reports", headers=auth_headers).text
    assert "No reports kept yet" in html


def test_reports_empty_state_names_the_schedule(client, auth_headers, reports_dir, monkeypatch):
    """When a schedule is configured the empty state says when the first report
    is due, so "nothing here" reads as "not yet" rather than "broken"."""
    import modules.web.app.main as m
    base = m.load_config()
    monkeypatch.setattr(m, "load_config",
                        lambda: {**base, "status_report": {"enabled": True,
                                                           "schedule": "Sat *-*-* 03:00:00"}})
    html = client.get("/reports", headers=auth_headers).text
    assert "Sat *-*-* 03:00:00" in html


def test_reports_empty_state_when_disabled(client, auth_headers, reports_dir, monkeypatch):
    import modules.web.app.main as m
    base = m.load_config()
    monkeypatch.setattr(m, "load_config",
                        lambda: {**base, "status_report": {"enabled": False, "schedule": "x"}})
    html = client.get("/reports", headers=auth_headers).text
    assert "disabled" in html


def test_report_detail_renders_the_body(client, auth_headers, reports_dir):
    _write_report(reports_dir, 1700000000)
    html = client.get("/reports/1700000000", headers=auth_headers).text
    assert "=== SYSTEM STATUS ===" in html
    assert "report-body" in html


def test_report_body_is_escaped_not_interpreted(client, auth_headers, reports_dir):
    """The body is text straight off the drive — file names included — and is
    rendered in a <pre>. It must never reach the page as markup."""
    _write_report(reports_dir, 1700000000,
                  body="a file called <script>alert(1)</script> changed")
    html = client.get("/reports/1700000000", headers=auth_headers).text
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;" in html


def test_unknown_report_is_a_404(client, auth_headers, reports_dir):
    assert client.get("/reports/12345", headers=auth_headers).status_code == 404


def test_a_malformed_report_is_skipped_not_fatal(client, auth_headers, reports_dir):
    """Written by one shell script and copied to the drive by another, so one
    unreadable entry should cost that entry and nothing more."""
    _write_report(reports_dir, 1700000000)
    (reports_dir / "1700400000.json").write_text("{ this is not json")
    (reports_dir / "1700500000.json").write_text('{"no_generated_at": true}')
    html = client.get("/reports", headers=auth_headers).text
    assert re.findall(r'href="/reports/(\d+)"', html) == ["1700000000"]


def test_reports_appear_in_the_nav(client):
    assert 'href="/reports"' in client.get("/").text


# ── Sync group timers are discovered, not recomputed (#24 item 4) ──────────────

def _systemctl_show(units):
    """Stand in for _run, returning systemctl show output for the given
    {unit: description} mapping — blocks separated by blank lines."""
    import subprocess
    blocks = "\n\n".join(f"Id={u}\nDescription={d}" for u, d in units.items())
    def fake(*args):
        return subprocess.CompletedProcess(list(args), 0, blocks, "")
    return fake


def test_sync_groups_read_the_schedule_from_systemd(monkeypatch):
    """The schedule is stamped into each timer's Description by the shell that
    names the unit, so reading it back cannot drift from the naming."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", _systemctl_show({
        "nase-sync-group-03-00-00.timer": "NASe sync group timer: *-*-* 03:00:00",
        "nase-sync-group-05-30-00.timer": "NASe sync group timer: *-*-* 05:30:00",
    }))
    assert m.sync_group_units() == {
        "*-*-* 03:00:00": "nase-sync-group-03-00-00.timer",
        "*-*-* 05:30:00": "nase-sync-group-05-30-00.timer",
    }


def test_sync_groups_ignore_unrelated_units(monkeypatch):
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", _systemctl_show({
        "nase-monitor.timer": "NASe SMART health check",
        "nase-sync-group-03-00-00.timer": "NASe sync group timer: *-*-* 03:00:00",
    }))
    assert m.sync_group_units() == {"*-*-* 03:00:00": "nase-sync-group-03-00-00.timer"}


def test_sync_groups_tolerate_reversed_property_order(monkeypatch):
    """systemctl show does not promise an order for the properties asked for."""
    import subprocess
    import modules.web.app.main as m
    blocks = ("Description=NASe sync group timer: *-*-* 03:00:00\n"
              "Id=nase-sync-group-03-00-00.timer")
    monkeypatch.setattr(m, "_run",
                        lambda *a: subprocess.CompletedProcess(list(a), 0, blocks, ""))
    assert m.sync_group_units() == {"*-*-* 03:00:00": "nase-sync-group-03-00-00.timer"}


def test_sync_groups_empty_when_nothing_installed(monkeypatch):
    import subprocess
    import modules.web.app.main as m
    monkeypatch.setattr(m, "_run", lambda *a: subprocess.CompletedProcess(list(a), 1, "", ""))
    assert m.sync_group_units() == {}


def test_a_job_with_no_group_timer_reads_as_inactive(monkeypatch, config_file):
    """What apply.sh-not-yet-run looks like. The old code computed a unit name
    that did not exist and systemctl answered "inactive"; this must not become
    a crash or a blank now that the name is looked up instead."""
    import modules.web.app.main as m
    monkeypatch.setattr(m, "CONFIG_FILE", config_file)
    monkeypatch.setattr(m, "sync_group_units", lambda: {})
    timers = m.build_status(m.load_config())["timers"]
    jobs = [t for t in timers if t["name"] != "config-archive"]
    assert jobs, "expected the test config to define sync jobs"
    assert all(t["state"] == "inactive" for t in jobs)
    assert all(t["next"] == "—" for t in jobs)


# ── spin-history.log: writer and reader must agree (#24 item 4) ────────────────

def test_spin_history_reader_tolerates_a_new_column():
    """The drift that used to be fatal. The old parser matched the field count
    exactly, so adding a column to spin_sample.sh without editing main.py made
    every line fall through and blanked the Monitoring tab — a silent, total
    failure for a purely additive change."""
    import modules.web.app.main as m
    from pathlib import Path
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        log = Path(d) / "spin-history.log"
        log.write_text("100\tprimary\tactive\testimated\twoke\t7\tsomething-new\n")
        orig, m.SPIN_HISTORY_LOG = m.SPIN_HISTORY_LOG, log
        try:
            out = m._read_spin_history()
        finally:
            m.SPIN_HISTORY_LOG = orig
    assert out["primary"][0][1] == "active"
    assert "7 block requests" in out["primary"][0][2]


def test_spin_history_writer_and_reader_agree_on_the_columns():
    """One definition, checked across the language boundary.

    modules/drives/spin_sample.sh writes the file and documents its columns;
    main.py reads it positionally. Nothing at runtime couples them, so this
    asserts the writer still emits at least the prefix the reader indexes into,
    in the order the reader assumes."""
    sampler = (REPO_ROOT / "modules/drives/spin_sample.sh").read_text()

    # The single printf that writes a sample line.
    fmt = re.search(r"printf '((?:%s\\t)+%s\\n)'", sampler)
    assert fmt, "could not find the sample-writing printf in spin_sample.sh"
    written = fmt.group(1).count("%s")

    import modules.web.app.main as m
    assert written >= len(m._SPIN_FIELDS_REQUIRED), (
        f"spin_sample.sh writes {written} fields but the reader indexes "
        f"{len(m._SPIN_FIELDS_REQUIRED)}")

    # And the documented order in the sampler's header is the order the reader
    # relies on, so a reordering there is caught here rather than by a wrong
    # timeline on the dashboard.
    header = sampler[:sampler.index("set -euo pipefail")]
    documented = re.search(r'"(<epoch>[^"]*)"', header)
    assert documented, "spin_sample.sh no longer documents its line format"
    names = documented.group(1).split(r"\t")
    assert [n.strip("<>") for n in names[:3]] == ["epoch", "drive", "state"], names
