#!/usr/bin/env python3
"""Archive one status report to the SD card (backlog #37).

Called by modules/status-report/report.sh, which passes everything through the
environment rather than argv because the body is multi-line and would otherwise
need quoting twice.

A separate file rather than an inline heredoc in report.sh: the script already
carries three of those for reading the integrity cache, and this one has to be
nested inside an `if !` block, where a second `<<'PY'` becomes easy to get
wrong and impossible to lint.

Writes <generated_at>.json holding both the metadata the list view needs and
the rendered body, to a temp file in the same directory and then os.replace, so
a reader — the web page, or config-archive copying the whole directory to the
drive — can only ever see a complete file. Nothing prunes: reports are ~2 KB
and weekly, so keeping every one costs a few hundred KB a year, and a retention
cap would be the only thing capable of losing one.
"""
import json
import os
import sys
import tempfile


def main() -> int:
    env = os.environ
    try:
        reports_dir = env["NASE_REPORTS_DIR"]
        record = {
            "generated_at": int(env["R_TS"]),
            "trigger":      env.get("R_TRIGGER") or "scheduled",
            "subject":      env.get("R_SUBJECT") or "",
            "period_start": int(env["R_SINCE"]),
            "period_end":   int(env["R_TS"]),
            "anomalies":    int(env.get("R_ANOMALIES") or 0),
            "changes":      int(env.get("R_CHANGES") or 0),
            "body":         env.get("R_BODY") or "",
        }
    except (KeyError, ValueError) as exc:
        print(f"write_report: bad input: {exc}", file=sys.stderr)
        return 1

    os.makedirs(reports_dir, exist_ok=True)
    path = os.path.join(reports_dir, f"{record['generated_at']}.json")
    fd, tmp = tempfile.mkstemp(dir=reports_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(record, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
