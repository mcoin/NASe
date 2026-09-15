#!/usr/bin/env python3
"""The config editor's data layer: which sections exist, how prose is unwrapped
for display, and the comment-preserving write back to config.yaml."""
from __future__ import annotations

import re

from ruamel.yaml import YAML as RuamelYAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.error import CommentMark
from ruamel.yaml.tokens import CommentToken

from . import core

# ── Config sections ────────────────────────────────────────────────────────────
# Order and display labels for the config editor tabs.
CONFIG_SECTIONS: list[tuple[str, str]] = [
    ("nas",            "General"),
    ("drives",         "Drives"),
    ("samba",          "Samba"),
    ("sync_jobs",      "Sync Jobs"),
    ("config_archive", "Config Archive"),
    ("services",       "Services"),
    ("tailscale",      "Tailscale"),
    ("notifications",  "Notifications"),
    ("file_watch",     "File Watch"),
    ("status_report",  "Status Report"),
]
_SECTION_KEYS = {k for k, _ in CONFIG_SECTIONS}

def _make_ryaml() -> RuamelYAML:
    """Return a ruamel.yaml instance configured to match config.yaml's style:
    2-space mapping indent, list dashes at 2 spaces with content at 4."""
    ry = RuamelYAML()
    ry.preserve_quotes = True
    ry.indent(mapping=2, sequence=4, offset=2)
    return ry

def _section_to_yaml(value: object) -> str:
    """Serialise a config section value to a YAML string."""
    import io
    buf = io.StringIO()
    _make_ryaml().dump(value, buf)
    return buf.getvalue()

# ── Rendering hard-wrapped text ────────────────────────────────────────────────
# Older ticket text was written wrapped at ~80 columns, but it renders in a
# ~64-character column, so every stored line wrapped a second time and left a
# short orphan under it. Folding those runs back into paragraphs at render time
# fixes the existing tickets without rewriting a single one: the stored text is
# untouched, and the editor still shows exactly what is stored.
#
# Deliberately conservative — only runs of unindented prose are joined. Headers,
# list items, indented blocks and tables keep their line structure, since
# guessing wrong there would mangle a ticket in a way nobody would notice until
# they needed it.

# A line produced by hard-wrapping is long; one deliberately left short (the end
# of a paragraph, a heading, a one-line note) is not. 55 sits below the narrowest
# wrap width in this backlog and above the short lines that end paragraphs.
_MIN_WRAPPED_LEN = 55

# Openers that start something of their own, so the line before must not swallow
# them: section headers, list items, lettered options, table rows, quotes.
_STRUCTURAL_LINE = re.compile(r"^(==|[-*+]\s|\d+[.)]\s|\(\w+\)|\||>|#)")

def unwrap_prose(text: str) -> str:
    """Join runs of hard-wrapped prose so they reflow to the reader's width."""
    if not text:
        return text
    # Anything typed into the form arrives CRLF-terminated (HTML normalises
    # textarea line breaks that way), and a stray \r left mid-line renders as a
    # line break of its own — so the fold would appear not to have happened.
    out: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        previous = out[-1] if out else ""
        continuable = (
            previous
            and len(previous) >= _MIN_WRAPPED_LEN
            and not previous.startswith((" ", "\t"))
            and not _STRUCTURAL_LINE.match(previous)
        )
        absorbable = (
            line.strip()
            and not line.startswith((" ", "\t"))
            and not _STRUCTURAL_LINE.match(line)
        )
        if continuable and absorbable:
            out[-1] = previous + " " + line.strip()
        else:
            out.append(line)
    return "\n".join(out)

def _last_leaf_holder(node) -> tuple | None:
    """The innermost container holding the last leaf of `node`, and its key.

    ruamel attaches a comment to whatever *precedes* it in the file. For a
    block sitting between two sections that is not the section key but the
    deepest, last scalar of the preceding section's subtree — e.g. the
    integrity header was on doc['sync_jobs'][8]['trash']['retention_days'].
    Finding that node is what makes the block rescuable.
    """
    holder = None
    while isinstance(node, (CommentedMap, CommentedSeq)) and len(node) > 0:
        key = list(node.keys())[-1] if isinstance(node, CommentedMap) else len(node) - 1
        holder = (node, key)
        node = node[key]
    return holder

# Slots in a ca.items entry that hold a "comment that follows this node":
# index 2 for a mapping key (post-value), index 0 for a sequence item.
_TRAILING_COMMENT_SLOTS = (2, 0)

def _reanchor_section_comments(doc: CommentedMap) -> None:
    """Move each block comment that introduces a top-level section onto that
    section's key, instead of leaving it buried in the previous section.

    Without this, saving a section replaces its whole subtree and takes any
    such block with it — one save of sync_jobs silently deleted the 23-line
    header documenting `integrity:`. Rewriting the anchor is lossless: the
    dumped file is byte-identical, the comment simply now lives on the key it
    actually documents, where _save_section's existing rescue can protect it.

    Only the part after the first newline moves; the first line is the
    preceding value's own end-of-line comment and stays with it.
    """
    keys = list(doc.keys())
    for prev_key, next_key in zip(keys, keys[1:]):
        holder = _last_leaf_holder(doc.get(prev_key))
        if holder is None:
            continue
        node, key = holder
        entry = node.ca.items.get(key)
        if not entry:
            continue
        for slot in _TRAILING_COMMENT_SLOTS:
            token = entry[slot] if slot < len(entry) else None
            if not isinstance(token, CommentToken):
                continue
            head, sep, tail = (token.value or "").partition("\n")
            if "#" not in tail:
                continue        # just the leaf's own end-of-line comment
            token.value = head + sep
            target = doc.ca.items.setdefault(next_key, [None, None, None, None])
            target[1] = [CommentToken(tail, CommentMark(0), None)] + (target[1] or [])
            break

# ── Preserving comments *inside* a section (backlog #19) ──────────────────────
# Identity keys per list, written down explicitly rather than inferred, and
# matched on nothing else. Positional matching would silently move
# "# this job is the slow one" onto a different job the first time anything is
# reordered or inserted, and #19's guardrail is that losing a comment is
# acceptable while misattributing one is not. A list with no rule here is
# replaced wholesale, which loses its comments and never moves them.
_MERGE_IDENTITY: dict[tuple, tuple] = {
    ("drives",):         ("name", "uuid"),
    ("sync_jobs",):      ("name",),
    ("samba", "shares"): ("name",),
}

def _item_identity(item, keys: tuple):
    """(key, value) of the first identity key this item carries, or None."""
    if not isinstance(item, dict):
        return None
    for k in keys:
        v = item.get(k)
        if v is not None:
            return (k, v)
    return None

def _seq_at(doc, path: tuple):
    node = doc
    for p in path:
        if not isinstance(node, dict):
            return None
        node = node.get(p)
    return node if isinstance(node, CommentedSeq) else None

def _reanchor_item_comments(doc: CommentedMap) -> None:
    """Move each comment that introduces a list item onto that item.

    Exactly the problem _reanchor_section_comments solves one level up, and for
    the same reason: ruamel stores a comment written above item N as a trailing
    comment on the *last leaf of item N-1*, not on item N. So the node that
    survives a targeted merge is the wrong one — the comment would follow the
    item above it, and on a reorder or a delete it would end up introducing
    something it does not describe.

    Rewriting the anchor is lossless: the dumped file is byte-identical, the
    comment simply now lives on the item it actually documents.
    """
    for path, _keys in _MERGE_IDENTITY.items():
        seq = _seq_at(doc, path)
        if seq is None:
            continue
        for idx in range(1, len(seq)):
            holder = _last_leaf_holder(seq[idx - 1])
            if holder is None:
                continue
            node, key = holder
            entry = node.ca.items.get(key)
            if not entry:
                continue
            for slot in _TRAILING_COMMENT_SLOTS:
                token = entry[slot] if slot < len(entry) else None
                if not isinstance(token, CommentToken):
                    continue
                head, sep, tail = (token.value or "").partition("\n")
                if "#" not in tail:
                    continue    # just the leaf's own end-of-line comment
                token.value = head + sep
                # The comment's own leading whitespace becomes its column;
                # ruamel re-indents from there, so passing it through unstripped
                # would double the indent.
                col = len(tail) - len(tail.lstrip(" "))
                target = seq[idx]
                pre = (target.ca.comment[1] if target.ca.comment else None) or []
                target.ca.comment = [
                    None, [CommentToken(tail.lstrip(" "), CommentMark(col), None)] + pre]
                break

def _merge_preserving(old, new, path: tuple = ()):
    """Update `old` in place to hold `new`'s values, reusing old nodes.

    The Form view marshals plain YAML in the browser, so the payload carries no
    comments at all and `doc[section] = new_value` threw away every comment
    anchored inside the section. Reusing the surviving nodes keeps them,
    provided the between-item comments have been re-anchored onto their own
    item first — which is what _reanchor_item_comments is for.
    """
    if isinstance(old, CommentedMap) and isinstance(new, dict):
        for key in [k for k in old if k not in new]:
            del old[key]
        for key, val in new.items():
            old[key] = _merge_preserving(old[key], val, path + (key,)) if key in old else val
        return old

    keys = _MERGE_IDENTITY.get(path)
    if keys and isinstance(old, CommentedSeq) and isinstance(new, list):
        by_id: dict = {}
        for i, item in enumerate(old):
            ident = _item_identity(item, keys)
            if ident is not None and ident not in by_id:
                by_id[ident] = (i, item)
        merged, source_idx = [], []
        for value in new:
            ident = _item_identity(value, keys)
            hit = by_id.pop(ident, None) if ident is not None else None
            if hit is None:
                merged.append(value)            # a new item, or one with no identity
                source_idx.append(None)
            else:
                i, node = hit
                merged.append(_merge_preserving(node, value, path))
                source_idx.append(i)
        # Any index-keyed comments on the sequence itself follow their item to
        # its new position; those whose item is gone are dropped rather than
        # left pointing at whatever now occupies that index.
        ca_before = dict(old.ca.items)
        old[:] = merged
        old.ca.items.clear()
        for new_i, old_i in enumerate(source_idx):
            if old_i is not None and old_i in ca_before:
                old.ca.items[new_i] = ca_before[old_i]
        return old

    return new

def _save_section(section: str, yaml_text: str) -> None:
    """Parse yaml_text with ruamel (preserving CommentedMap/Seq metadata),
    load config.yaml (preserving comments/order in all other sections),
    update one top-level key, and write back."""
    import io
    ry  = _make_ryaml()
    new_value = ry.load(yaml_text)
    with open(core.CONFIG_FILE) as f:
        doc = ry.load(f)
    # Rehome section-introducing comments before touching anything: a Form-view
    # save sends comment-free YAML, so whatever is still inside the replaced
    # subtree at this point is gone for good.
    _reanchor_section_comments(doc)
    # Same rescue one level down, for comments between items in a list (#19).
    _reanchor_item_comments(doc)
    # Preserve any block/inline comments attached to this key in the top-level map.
    ca = doc.ca.items.get(section)
    if section in doc:
        doc[section] = _merge_preserving(doc[section], new_value, (section,))
    else:
        doc[section] = new_value
    if ca is not None:
        doc.ca.items[section] = ca
    with open(core.CONFIG_FILE, "w") as f:
        ry.dump(doc, f)
