#!/usr/bin/env python3
"""The backlog: its JSON data layer, attachments, and every /backlog route."""
from __future__ import annotations

import json
import os
import secrets
import threading
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from fastapi import HTTPException, Query, Request
from fastapi.responses import (FileResponse, HTMLResponse, JSONResponse,
                               RedirectResponse)

from . import core

router = core.protected_router()

# ── Backlog (feature-request list for NASe itself) ─────────────────────────────
# Stored as a small JSON file in STAMP_DIR rather than config.yaml — this is a
# planning list for the app, not a device setting, so it has nothing to do
# with apply.sh. List order is the backlog priority order (top = highest).
# A single in-process lock is enough: nase-web.service runs one uvicorn
# worker, and read-modify-write here is cheap and rare (a person clicking
# buttons, not a hot path).
_backlog_lock = threading.Lock()

_BACKLOG_TYPES    = {"bug", "feature", "improvement"}
# "closed" = decided against, won't be implemented. Unlike "deleted" it stays
# visible in the default view: it's a deliberate outcome worth seeing (and
# worth linking to as a duplicate target), not a mis-click to be hidden away.
_BACKLOG_STATUSES = {"open", "ready", "in_progress", "done", "closed", "deleted"}
# "active" is a pseudo-status: it spans everything still waiting to be worked
# on or being worked on right now. It's only ever a filter, never stored on an
# item. "in_progress" has to be in here: "active" is the default view, so a
# ticket being worked on would otherwise vanish from the one view most likely
# to be open — and it would vanish silently, which is worse than an error.
_BACKLOG_ACTIVE_STATUSES = {"open", "ready", "in_progress"}
_BACKLOG_FILTERS  = {"all", "active"} | _BACKLOG_STATUSES
# Opening the Backlog tab should show the work that's left, not a wall of
# finished and abandoned tickets, so "active" — not "all" — is the default.
_BACKLOG_DEFAULT_FILTER = "active"

# Link relationship types. Each is stored from the perspective of the item
# that owns it ("this item <label> <target>"); adding a link writes the
# chosen type on this item and the paired inverse type on the target, so
# both tickets show the relationship without having to scan the whole
# backlog to find who links to whom.
BACKLOG_RELATIONS: dict[str, dict[str, str]] = {
    "relates_to":    {"label": "Relates to",    "inverse": "relates_to"},
    "causes":        {"label": "Causes",        "inverse": "caused_by"},
    "caused_by":     {"label": "Caused by",     "inverse": "causes"},
    "duplicates":    {"label": "Duplicates",    "inverse": "duplicated_by"},
    "duplicated_by": {"label": "Duplicated by", "inverse": "duplicates"},
    "blocks":        {"label": "Blocks",        "inverse": "blocked_by"},
    "blocked_by":    {"label": "Blocked by",    "inverse": "blocks"},
}

def load_backlog() -> dict:
    if not core.BACKLOG_FILE.exists():
        return {"items": [], "next_id": 1}
    try:
        data = json.loads(core.BACKLOG_FILE.read_text())
    except (OSError, ValueError):
        return {"items": [], "next_id": 1}
    data.setdefault("items", [])
    data.setdefault("next_id", 1)
    # Backfill fields added after some items were created — in memory only
    # (not written back here), so a plain read never has a surprising
    # side effect on disk.
    for item in data["items"]:
        item.setdefault("type", "feature")
        item.setdefault("status", "open")
        item.setdefault("description", "")
        # What was decided, distilled from the options weighed in
        # implementation_details — so picking a ticket up does not mean
        # re-reading the comparison to infer its outcome.
        item.setdefault("decision", "")
        item.setdefault("implementation_details", "")
        item.setdefault("links", [])
        item.setdefault("comments", [])
        item.setdefault("external_links", [])
        item.setdefault("attachments", [])
    return data

def _next_sub_id(rows: list[dict]) -> int:
    """Next id for a per-item collection (comments, external links). Ids are
    scoped to the item, so they only need to be unique within that list."""
    return max((r.get("id", 0) for r in rows), default=0) + 1

def _safe_url(url: str) -> str | None:
    """Accept only http(s) URLs. User-supplied strings end up in an href, so
    schemes like javascript: must never survive — Jinja escapes the attribute
    value but would happily emit a javascript: URL."""
    url = (url or "").strip()
    if not url:
        return None
    parsed = urlparse(url)
    if parsed.scheme in ("http", "https") and parsed.netloc:
        return url
    return None

def derive_link_label(url: str) -> str:
    """Short human label for an external URL when the user didn't supply one.
    Recognises the GitHub shapes this is mostly used for (commits, PRs,
    issues) so a pasted commit URL renders as "NASe@7688125" rather than a
    60-character link."""
    parsed = urlparse(url)
    host  = parsed.netloc
    parts = [p for p in parsed.path.split("/") if p]
    if host.endswith("github.com") and len(parts) >= 4:
        owner_repo, kind, ref = parts[1], parts[2], parts[3]
        if kind in ("commit", "commits"):
            return f"{owner_repo}@{ref[:7]}"
        if kind in ("pull", "issues"):
            return f"{owner_repo}#{ref}"
    path = parsed.path.rstrip("/")
    label = f"{host}{path}"
    return label if len(label) <= 48 else label[:45] + "..."

def save_backlog(data: dict) -> None:
    """Write the backlog atomically: a reader must never see a half-written
    file. Writing in place left a window in which the archiver (or a person
    with `cat`) could catch a truncated JSON document — and this file is the
    only copy of the backlog, so a torn read that then gets snapshotted would
    be a bad thing to discover later. Rename within the same directory is
    atomic, so readers see either the old file or the new one."""
    core.BACKLOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = core.BACKLOG_FILE.with_suffix(core.BACKLOG_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, core.BACKLOG_FILE)

# ── Backlog attachments ────────────────────────────────────────────────────────
# Screenshots live next to the backlog on the SD card, never on /mnt/primary:
# opening a ticket must not spin the main drive up. They are small and few, and
# modules/config-archive copies this directory to the drive along with
# backlog.json, so they inherit the same backup.
ATTACHMENT_DIR = Path(os.environ.get("NASE_ATTACHMENT_DIR",
                                     str(core.STAMP_DIR / "backlog-attachments")))
MAX_ATTACHMENT_BYTES = 4 * 1024 * 1024
MAX_ATTACHMENTS_PER_ITEM = 10

# ── Reporting a refused write (backlog #28) ───────────────────────────────────
# Every mutating backlog endpoint used to answer 303 whether or not it had done
# anything: a bad rel_type, a target that did not exist, an empty comment, a
# non-http URL — all fell through one `if` and redirected as though they had
# worked. That was found the hard way, by two link requests sent with the field
# named `type` instead of `rel_type` which both returned 303 and created
# nothing. The uploads path already did this properly, so this generalises its
# table and query-parameter round trip rather than inventing a second one.
_FORM_ERRORS = {
    # Attachments.
    "too_big":      f"That image is larger than {MAX_ATTACHMENT_BYTES // (1024 * 1024)} MB — it was not added.",
    "not_an_image": "That file is not a PNG, JPEG, GIF or WebP image — it was not added.",
    "too_many":     f"This ticket already has {MAX_ATTACHMENTS_PER_ITEM} images — remove one first.",
    "none":         "No file was chosen.",
    # Links between tickets.
    "bad_rel_type": "That is not a relationship NASe recognises — no link was created.",
    "bad_target":   "No such ticket — no link was created.",
    "self_link":    "A ticket cannot be linked to itself — no link was created.",
    # External links.
    "bad_url":      "External links must start with http:// or https:// — nothing was added.",
    # Comments.
    "empty_comment": "The comment was empty — nothing was added.",
    # Creating and editing.
    "empty_title":  "A ticket needs a title — nothing was created.",
    "bad_type":     "That is not a ticket type NASe recognises — the ticket was left unchanged.",
    "bad_status":   "That is not a status NASe recognises — the ticket was left unchanged.",
}

def _reject(request: Request, code: str, redirect_to: str):
    """Refuse a form write, and say so.

    Browsers get a 303 back to the page they came from carrying ?err=<code>,
    which renders as a sentence — the same round trip uploads already used.
    Anything that is not asking for HTML gets a 400 with the reason, because
    the whole point is that a script must not record success for a write that
    never happened. The accept-header split mirrors the one in
    http_exception_handler above, which already serves humans a styled page
    while machine clients and SSE streams get JSON."""
    if "text/html" not in request.headers.get("accept", ""):
        return JSONResponse(
            {"detail": _FORM_ERRORS.get(code, "Request rejected."), "error": code},
            status_code=400)
    sep = "&" if "?" in redirect_to else "?"
    return RedirectResponse(url=f"{redirect_to}{sep}err={code}", status_code=303)

# Type is decided by what the bytes actually are, never by the upload's
# Content-Type or the filename's extension — both are attacker-controlled and
# neither survives contact with a phone's photo picker intact anyway.
# SVG is absent on purpose: it can carry script, and there is no version of
# "render it inline" that is safe without sanitising it first.
_IMAGE_SIGNATURES: tuple[tuple[bytes, str, str], ...] = (
    (b"\x89PNG\r\n\x1a\n", "image/png",  "png"),
    (b"\xff\xd8\xff",      "image/jpeg", "jpg"),
    (b"GIF87a",            "image/gif",  "gif"),
    (b"GIF89a",            "image/gif",  "gif"),
)

def sniff_image(head: bytes) -> tuple[str, str] | None:
    """(media_type, extension) for a recognised image, else None."""
    for signature, media_type, ext in _IMAGE_SIGNATURES:
        if head.startswith(signature):
            return media_type, ext
    # WebP is RIFF-framed: "RIFF" <4-byte size> "WEBP".
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None

def attachment_path(item_id: int, stored_name: str) -> Path:
    """Absolute path of a stored attachment. stored_name is generated by this
    module and is checked against the item's own record before use, so a
    traversal attempt cannot reach outside the directory."""
    return ATTACHMENT_DIR / str(item_id) / stored_name

def find_attachment(item: dict, attachment_id: int) -> dict | None:
    return next((a for a in item.get("attachments", []) if a["id"] == attachment_id), None)

def find_backlog_item(data: dict, item_id: int) -> dict | None:
    return next((i for i in data["items"] if i["id"] == item_id), None)

def resolve_backlog_links(data: dict, item: dict) -> list[dict]:
    """item['links'] only stores {type, target_id}; look up each target's
    current title/type/status for display (and to link to it), skipping any
    target that's since vanished entirely rather than erroring out."""
    by_id = {i["id"]: i for i in data["items"]}
    resolved = []
    for link in item.get("links", []):
        target = by_id.get(link.get("target_id"))
        if target is None:
            continue
        resolved.append({
            "type":          link["type"],
            "label":         BACKLOG_RELATIONS.get(link["type"], {}).get("label", link["type"]),
            "target_id":     target["id"],
            "target_title":  target["title"],
            "target_type":   target.get("type", "feature"),
            "target_status": target.get("status", "open"),
        })
    return resolved

_BACKLOG_TYPE_FILTERS = {"all"} | _BACKLOG_TYPES

def _backlog_matches(item: dict, status: str, ticket_type: str) -> bool:
    """Same predicate backlog_view() applies, usable against an in-memory
    list — needed by backlog_move() below to know what's actually *visible*
    under the current filters, without a second disk read."""
    if status == "all":
        if item.get("status") == "deleted":
            return False
    elif status == "active":
        if item.get("status") not in _BACKLOG_ACTIVE_STATUSES:
            return False
    elif item.get("status") != status:
        return False
    if ticket_type != "all" and item.get("type") != ticket_type:
        return False
    return True

def normalize_backlog_filters(status: str, ticket_type: str) -> tuple[str, str]:
    """Coerce user-supplied filter values to known ones. Callers that reason
    about visibility themselves (backlog_move) must normalize the same way
    backlog_view does, or they'd compute "what's visible" from a filter the
    rendered list never used."""
    return (status if status in _BACKLOG_FILTERS else _BACKLOG_DEFAULT_FILTER,
            ticket_type if ticket_type in _BACKLOG_TYPE_FILTERS else "all")

def backlog_view(status: str, ticket_type: str = "all") -> dict:
    """Backlog items filtered by status and/or type, for the list/filter bars.

    "all" status deliberately excludes "deleted" — a soft-deleted ticket
    should only reappear when the Deleted filter is picked on purpose, not
    sit in the default view.

    "total" is the count of items the unfiltered ("all") view would show, so
    the empty state can tell "nothing here yet" apart from "nothing matches
    these filters".
    """
    status, ticket_type = normalize_backlog_filters(status, ticket_type)
    all_items = load_backlog()["items"]
    items = [i for i in all_items if _backlog_matches(i, status, ticket_type)]
    total = sum(1 for i in all_items if _backlog_matches(i, "all", "all"))
    return {"items": items, "status": status, "type": ticket_type, "total": total}

# ── Backlog routes ───────────────────────────────────────────────────────────────
@router.get("/backlog", response_class=HTMLResponse)
async def backlog_page(request: Request, status: str = Query(_BACKLOG_DEFAULT_FILTER),
                        ticket_type: str = Query("all", alias="type")):
    cfg = core.load_config()
    return core.templates.TemplateResponse(request, "backlog.html", {
        "hostname": cfg.get("nas", {}).get("hostname", "nase"),
        "page":     "backlog",
        "backlog":  backlog_view(status, ticket_type),
    })

@router.get("/partials/backlog", response_class=HTMLResponse)
async def partial_backlog(request: Request, status: str = Query(_BACKLOG_DEFAULT_FILTER),
                           ticket_type: str = Query("all", alias="type")):
    return core.templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(status, ticket_type),
    })

@router.post("/backlog/add", response_class=HTMLResponse)
async def backlog_add(request: Request):
    form  = await request.form()
    title = (form.get("title") or "").strip()
    type_ = form.get("type") or "feature"

    # This one answers with a partial rather than a redirect, so a refusal is
    # rendered straight back into the card instead of round-tripping through
    # ?err= — but a non-browser client still has to be told, since an empty
    # title silently creating nothing is the same defect as the rest of #28.
    err = None
    if not title:
        err = "empty_title"
    elif type_ not in _BACKLOG_TYPES:
        err = "bad_type"
    if err:
        if not request.headers.get("hx-request"):
            return _reject(request, err, "/backlog")
        return core.templates.TemplateResponse(request, "partials/backlog_list.html", {
            "backlog":    backlog_view(_BACKLOG_DEFAULT_FILTER, "all"),
            "form_error": _FORM_ERRORS[err],
        })

    with _backlog_lock:
        data = load_backlog()
        if title:
            data["items"].append({
                "id":                     data["next_id"],
                "title":                  title,
                "type":                   type_,
                "description":            "",
                "implementation_details": "",
                "status":                 "open",
                "created_at":             datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            })
            data["next_id"] += 1
            save_backlog(data)
    # Always land back on the default view with no type filter — a just-added
    # item could otherwise vanish immediately under a narrower filter. New
    # items are "open", so the default "active" filter always shows them.
    return core.templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(_BACKLOG_DEFAULT_FILTER, "all"),
    })

# Registered before the /backlog/{item_id} routes below: item_id is typed
# int, and Starlette matches routes by registration order, so "reorder"
# would otherwise be swallowed by that route and fail int parsing instead
# of reaching this one.
@router.post("/backlog/reorder")
async def backlog_reorder(request: Request):
    form  = await request.form()
    order = [int(x) for x in (form.get("order") or "").split(",") if x.strip().isdigit()]
    with _backlog_lock:
        data  = load_backlog()
        by_id = {it["id"]: it for it in data["items"]}
        order = [i for i in order if i in by_id]
        # When a status filter is active, `order` only names the ids visible
        # in that filtered view — not the full list. Splice the reordered
        # subsequence back into their original slots rather than treating
        # everything else as "missing" and shoving it to the bottom, which
        # would silently reshuffle items the user couldn't even see.
        if len(order) == len(set(order)):
            order_set = set(order)
            order_iter = iter(order)
            data["items"] = [
                by_id[next(order_iter)] if it["id"] in order_set else it
                for it in data["items"]
            ]
            save_backlog(data)
    return {"ok": True}

@router.get("/backlog/{item_id}", response_class=HTMLResponse)
async def backlog_detail(request: Request, item_id: int,
                          err: str = Query("")):
    cfg  = core.load_config()
    data = load_backlog()
    item = find_backlog_item(data, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Backlog item not found")
    # Candidates for a new link: every other, non-deleted ticket.
    link_options = [i for i in data["items"]
                     if i["id"] != item_id and i.get("status") != "deleted"]
    return core.templates.TemplateResponse(request, "backlog_detail.html", {
        "hostname":     cfg.get("nas", {}).get("hostname", "nase"),
        "page":         "backlog",
        "item":         item,
        "links":        resolve_backlog_links(data, item),
        "link_options": link_options,
        "relations":    BACKLOG_RELATIONS,
        # Any refused write redirects back here with a reason, so the person
        # who just picked a 12 MB photo — or mistyped a URL, or posted an
        # empty comment — is told why nothing appeared (#28).
        "form_error": _FORM_ERRORS.get(err),
    })

@router.post("/backlog/{item_id}/links/add")
async def backlog_link_add(item_id: int, request: Request):
    form      = await request.form()
    rel_type  = form.get("rel_type") or ""
    target_id = form.get("target_id") or ""
    back      = f"/backlog/{item_id}"
    # Checked one at a time so the answer names the actual problem. Posting
    # `type=` instead of `rel_type=` is the mistake that opened #28, and it
    # now says "not a relationship NASe recognises" instead of 303.
    if rel_type not in BACKLOG_RELATIONS:
        return _reject(request, "bad_rel_type", back)
    if not target_id.isdigit():
        return _reject(request, "bad_target", back)
    if int(target_id) == item_id:
        return _reject(request, "self_link", back)
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        target = find_backlog_item(data, int(target_id))
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if target is None:
            return _reject(request, "bad_target", back)
        inverse = BACKLOG_RELATIONS[rel_type]["inverse"]
        if not any(l["type"] == rel_type and l["target_id"] == target["id"]
                   for l in item["links"]):
            item["links"].append({"type": rel_type, "target_id": target["id"]})
        if not any(l["type"] == inverse and l["target_id"] == item_id
                   for l in target["links"]):
            target["links"].append({"type": inverse, "target_id": item_id})
        save_backlog(data)
    return RedirectResponse(url=back, status_code=303)

@router.post("/backlog/{item_id}/links/remove")
async def backlog_link_remove(item_id: int, request: Request):
    form      = await request.form()
    rel_type  = form.get("rel_type") or ""
    target_id = form.get("target_id") or ""
    target_id = int(target_id) if target_id.isdigit() else None
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and target_id is not None:
            item["links"] = [l for l in item["links"]
                             if not (l["type"] == rel_type and l["target_id"] == target_id)]
            target = find_backlog_item(data, target_id)
            if target is not None and rel_type in BACKLOG_RELATIONS:
                inverse = BACKLOG_RELATIONS[rel_type]["inverse"]
                target["links"] = [l for l in target["links"]
                                   if not (l["type"] == inverse and l["target_id"] == item_id)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}/comments/add")
async def backlog_comment_add(item_id: int, request: Request):
    form = await request.form()
    text = (form.get("text") or "").strip()
    if not text:
        return _reject(request, "empty_comment", f"/backlog/{item_id}")
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["comments"].append({
                "id":         _next_sub_id(item["comments"]),
                "text":       text,
                "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            })
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}/attachments/add")
async def backlog_attachment_add(item_id: int, request: Request):
    form = await request.form()
    upload = form.get("image")
    if upload is None or not hasattr(upload, "read"):
        return RedirectResponse(url=f"/backlog/{item_id}?err=none", status_code=303)

    # Read one byte past the cap so an oversized file is refused without
    # holding an unbounded amount of it in memory.
    payload = await upload.read(MAX_ATTACHMENT_BYTES + 1)
    if len(payload) > MAX_ATTACHMENT_BYTES:
        return RedirectResponse(url=f"/backlog/{item_id}?err=too_big", status_code=303)

    sniffed = sniff_image(payload[:16])
    if sniffed is None:
        return RedirectResponse(url=f"/backlog/{item_id}?err=not_an_image", status_code=303)
    media_type, ext = sniffed

    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if len(item["attachments"]) >= MAX_ATTACHMENTS_PER_ITEM:
            return RedirectResponse(url=f"/backlog/{item_id}?err=too_many", status_code=303)

        attachment_id = _next_sub_id(item["attachments"])
        stored_name = f"{attachment_id}-{secrets.token_hex(8)}.{ext}"
        target = attachment_path(item_id, stored_name)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Write then rename, so the archiver can never copy a half-written image.
        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_bytes(payload)
        os.replace(tmp, target)

        item["attachments"].append({
            "id":          attachment_id,
            "stored_name": stored_name,
            "filename":    Path(getattr(upload, "filename", "") or "image").name[:120],
            "media_type":  media_type,
            "bytes":       len(payload),
            "created_at":  datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
        save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.get("/backlog/{item_id}/attachments/{attachment_id}")
async def backlog_attachment_get(item_id: int, attachment_id: int):
    """Serve an attachment. Behind auth like the rest of the backlog — the
    /static mount is unauthenticated, which is why these do not live there."""
    item = find_backlog_item(load_backlog(), item_id)
    attachment = find_attachment(item, attachment_id) if item else None
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    path = attachment_path(item_id, attachment["stored_name"])
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Attachment file is missing")
    return FileResponse(
        path,
        media_type=attachment["media_type"],
        headers={
            # The type was sniffed on upload; forbid the browser second-guessing it.
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": f'inline; filename="{attachment["stored_name"]}"',
        },
    )

@router.post("/backlog/{item_id}/attachments/remove")
async def backlog_attachment_remove(item_id: int, request: Request):
    form = await request.form()
    raw_id = form.get("attachment_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and raw_id.isdigit():
            attachment = find_attachment(item, int(raw_id))
            if attachment is not None:
                # Unlike a ticket, an attachment is really deleted: it is the
                # file, not a record with history worth keeping.
                attachment_path(item_id, attachment["stored_name"]).unlink(missing_ok=True)
                item["attachments"] = [a for a in item["attachments"]
                                       if a["id"] != attachment["id"]]
                save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}/comments/remove")
async def backlog_comment_remove(item_id: int, request: Request):
    form = await request.form()
    cid  = form.get("comment_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and cid.isdigit():
            item["comments"] = [c for c in item["comments"] if c.get("id") != int(cid)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}/extlinks/add")
async def backlog_extlink_add(item_id: int, request: Request):
    form  = await request.form()
    url   = _safe_url(form.get("url") or "")
    label = (form.get("label") or "").strip()
    # The one rejection an ordinary user can reach today: the URL field is
    # free text, unlike rel_type and status which the UI fills from selects.
    # A typo, or a deliberate smb:// path, used to be dropped without a word.
    if url is None:
        return _reject(request, "bad_url", f"/backlog/{item_id}")
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["external_links"].append({
                "id":    _next_sub_id(item["external_links"]),
                "url":   url,
                "label": label or derive_link_label(url),
            })
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}/extlinks/remove")
async def backlog_extlink_remove(item_id: int, request: Request):
    form = await request.form()
    lid  = form.get("link_id") or ""
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None and lid.isdigit():
            item["external_links"] = [l for l in item["external_links"]
                                      if l.get("id") != int(lid)]
            save_backlog(data)
    return RedirectResponse(url=f"/backlog/{item_id}", status_code=303)

@router.post("/backlog/{item_id}")
async def backlog_update(request: Request, item_id: int):
    form   = await request.form()
    title  = (form.get("title") or "").strip()
    type_  = form.get("type") or "feature"
    status = form.get("status") or "open"
    back   = f"/backlog/{item_id}"
    # Refuse rather than coerce. These used to fall back to "feature" and
    # "open", so a typo did not fail — it quietly rewrote the field, and
    # silently changing a ticket's status is worse than refusing the request
    # (#28). This handler already raised 404 for a missing item, so it was
    # inconsistent with itself about whether errors are worth reporting.
    if type_ not in _BACKLOG_TYPES:
        return _reject(request, "bad_type", back)
    if status not in _BACKLOG_STATUSES:
        return _reject(request, "bad_status", back)
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="Backlog item not found")
        if title:
            item["title"] = title
        item["type"] = type_
        item["description"] = form.get("description") or ""
        item["decision"] = form.get("decision") or ""
        item["implementation_details"] = form.get("implementation_details") or ""
        item["status"] = status
        save_backlog(data)
    return RedirectResponse(url="/backlog", status_code=303)

@router.post("/backlog/{item_id}/delete")
async def backlog_delete(item_id: int):
    # Soft delete: flip the status rather than erase the record, so a
    # mis-click is recoverable (reopen the item, change status back) and
    # matches the "Deleted" status being just another workflow state that
    # happens to be hidden by default (see backlog_view).
    with _backlog_lock:
        data = load_backlog()
        item = find_backlog_item(data, item_id)
        if item is not None:
            item["status"] = "deleted"
            save_backlog(data)
    return RedirectResponse(url="/backlog", status_code=303)

@router.post("/backlog/{item_id}/move", response_class=HTMLResponse)
async def backlog_move(request: Request, item_id: int, direction: str = Query("bottom"),
                        status: str = Query(_BACKLOG_DEFAULT_FILTER),
                        ticket_type: str = Query("all", alias="type")):
    status, ticket_type = normalize_backlog_filters(status, ticket_type)
    with _backlog_lock:
        data  = load_backlog()
        items = data["items"]
        idx   = next((i for i, it in enumerate(items) if it["id"] == item_id), None)
        if idx is not None:
            if direction == "top":
                items.insert(0, items.pop(idx))
            elif direction == "bottom":
                items.append(items.pop(idx))
            elif direction in ("up", "down"):
                # "Up"/"down" move by one *visible* slot under the active
                # filters, not one slot in the full list — otherwise, if the
                # adjacent full-list item happens to be filtered out, the
                # button would look like it did nothing.
                visible = [it for it in items if _backlog_matches(it, status, ticket_type)]
                vis_idx = next((i for i, it in enumerate(visible) if it["id"] == item_id), None)
                if vis_idx is not None:
                    neighbor_id = None
                    if direction == "up" and vis_idx > 0:
                        neighbor_id = visible[vis_idx - 1]["id"]
                    elif direction == "down" and vis_idx < len(visible) - 1:
                        neighbor_id = visible[vis_idx + 1]["id"]
                    if neighbor_id is not None:
                        item = items.pop(idx)
                        neighbor_idx = next(i for i, it in enumerate(items) if it["id"] == neighbor_id)
                        items.insert(neighbor_idx if direction == "up" else neighbor_idx + 1, item)
            save_backlog(data)
    return core.templates.TemplateResponse(request, "partials/backlog_list.html", {
        "backlog": backlog_view(status, ticket_type),
    })
