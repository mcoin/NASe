-- modules/integrity/schema.sql
-- Per-drive checksum manifest. Applied identically to every drive's
-- .nase/integrity.db (see modules/integrity/setup.sh).
-- See INTEGRITY_DESIGN.md for the full design.

-- WAL instead of the default rollback journal: a bootstrap run holds a
-- writer transaction open for hours, while the web dashboard's integrity
-- page polls this same file read-only every 60s (see main.py). Under the
-- default journal mode a reader's SHARED lock can block the writer's COMMIT
-- (needs to briefly escalate to EXCLUSIVE), which is exactly the kind of
-- contention that produced "cannot commit - no transaction is active"
-- crashes. WAL lets readers and the one writer proceed fully concurrently.
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS files (
  id            INTEGER PRIMARY KEY,
  path          TEXT NOT NULL UNIQUE,      -- relative to the drive's mountpoint
  size          INTEGER NOT NULL,
  mtime         INTEGER NOT NULL,          -- unix epoch, from stat
  checksum      TEXT NOT NULL,             -- sha256, lowercase hex (64 chars)
  status        TEXT NOT NULL DEFAULT 'ok' CHECK(status IN ('ok','flagged')),
  first_seen    INTEGER NOT NULL,
  last_updated  INTEGER NOT NULL,          -- checksum last legitimately (re)computed
  last_checked  INTEGER NOT NULL           -- last time verified, changed or not
);

-- Supports "pick the oldest-checked, still-ok rows" as an index-only scan.
CREATE INDEX IF NOT EXISTS idx_files_sample ON files(status, last_checked);

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,
  path        TEXT NOT NULL,
  event_type  TEXT NOT NULL CHECK(event_type IN ('mismatch','missing','ack')),
  detail      TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);

-- Key/value store. Keys in use:
--   schema_version           integer, currently "1"
--   drive_uuid                the drive's UUID at DB creation time (guards.sh cross-check)
--   discovery_cursor_n         count of find-order entries already scanned by discovery (0 = not started)
--   discovery_total            total files seen by the most recent discovery walk (progress display only)
--   discovery_complete        "true" once the walk has reached the end of the tree
--   primary_events_cursor     byte offset already processed in primary-events.log (primary only)
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
