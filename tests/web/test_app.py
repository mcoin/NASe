"""Tests for modules/web/app/main.py."""
import base64
import json
import time
from unittest.mock import patch

import pytest
import yaml

from conftest import REPO_ROOT, make_integrity_cache, write_backlog


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
    (1, "an open one",    "open",    "bug"),
    (2, "a ready one",    "ready",   "feature"),
    (3, "a done one",     "done",    "feature"),
    (4, "a closed one",   "closed",  "improvement"),
    (5, "a deleted one",  "deleted", "bug"),
]


def _titles(view):
    return [i["title"] for i in view["items"]]


def test_backlog_view_active_is_open_plus_ready(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("active", "all")) == ["an open one", "a ready one"]


def test_backlog_view_active_combines_with_type_filter(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("active", "bug")) == ["an open one"]


def test_backlog_view_all_still_excludes_deleted_only(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert _titles(m.backlog_view("all", "all")) == [
        "an open one", "a ready one", "a done one", "a closed one"]


def test_backlog_view_unknown_status_falls_back_to_default(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    view = m.backlog_view("bogus", "all")
    assert view["status"] == "active"
    assert _titles(view) == ["an open one", "a ready one"]


def test_backlog_view_total_counts_undeleted_regardless_of_filter(backlog_file, client):
    import modules.web.app.main as m
    write_backlog(backlog_file, SAMPLE_BACKLOG)
    assert m.backlog_view("closed", "all")["total"] == 4


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
                   description="something", implementation_details="something else")
    # "field-empty" also appears in the toggle script, so check the class
    # actually applied to the rendered views rather than the whole page.
    assert "field-text field-empty" not in html


def test_detail_edit_toggle_points_at_both_nodes(client, auth_headers, backlog_file):
    html = _detail(client, auth_headers, backlog_file, description="hello")
    assert 'data-editor="field-description"' in html
    assert 'data-view="view-description"' in html
    assert 'data-editor="field-impl"' in html
    # The toggle shares the label's line rather than taking a row of its own.
    assert html.count("form-label-row") == 2


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
