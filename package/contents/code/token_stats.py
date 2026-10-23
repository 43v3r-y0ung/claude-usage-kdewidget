#!/usr/bin/env python3
"""Token usage per model, kept in SQLite, for the Plasma widget.

Claude Code writes every API response, with its model and token counts, to the
transcripts in <config dir>/projects/**/*.jsonl, and deletes transcripts after
`cleanupPeriodDays` (30 by default). `ingest` copies the token counts into a
database the widget owns, reading each transcript only from where it stopped
last time, so the history outlives the transcripts. It also keeps the
rejections Claude Code logs when a limit is hit, which date the 5-hour
sessions. `query` ingests, then prints the totals of one period as JSON.
"""

import argparse
import bisect
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

DATA_DIR = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "claude-usage-widget"
DB_FILE = DATA_DIR / "history.sqlite"
# Calendar bucket boundaries are multiples of 15 minutes in any time zone, so the
# database is summed per quarter hour first and the buckets are built from that.
# A session starts whenever its limit last reset, so it is summed per minute.
QUARTER = 900
MINUTE = 60
SESSION = 5 * 3600
# Bumped when ingest starts keeping something new, so every transcript is read again.
VERSION = 2
# Claude Code's names for the windows of a rejection, as the usage API names them.
HIT_KINDS = {"five_hour": "session", "seven_day": "weekly_all"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY,
    offset INTEGER NOT NULL,
    size INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    msg_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    session_id TEXT,
    model TEXT NOT NULL,
    input INTEGER NOT NULL,
    output INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    cache_read INTEGER NOT NULL,
    PRIMARY KEY (msg_id, request_id)
);
CREATE INDEX IF NOT EXISTS messages_ts ON messages (ts);
-- A request refused because a limit was used up, and when that limit resets.
CREATE TABLE IF NOT EXISTS limit_hits (
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    resets_at INTEGER NOT NULL,
    PRIMARY KEY (ts, kind)
);
-- The usage API's answer at each refresh; written by fetch_usage.py.
CREATE TABLE IF NOT EXISTS limit_snapshots (
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    percent REAL NOT NULL,
    resets_at INTEGER,
    PRIMARY KEY (ts, kind)
);
"""


def connect():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    os.umask(0o077)  # the database and its -wal/-shm files are private
    db = sqlite3.connect(DB_FILE, timeout=30)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    if db.execute("PRAGMA user_version").fetchone()[0] < VERSION:
        with db:
            db.execute("DELETE FROM files")
            db.execute(f"PRAGMA user_version = {VERSION}")
    return db


def parse_line(line):
    """("message", token counts) or ("hit", a limit rejection) for one transcript line, or None."""
    # Most lines are prompts and tool output; skip them before parsing JSON.
    rejection = b'"quotaLimits"' in line
    if not rejection and (b'"usage"' not in line or b'"assistant"' not in line):
        return None
    try:
        entry = json.loads(line)
        ts = int(datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).timestamp())
    except (ValueError, KeyError, AttributeError, TypeError):
        return None
    quota = entry.get("quotaLimits")
    if isinstance(quota, dict) and quota.get("status") == "rejected" and isinstance(quota.get("resetsAt"), (int, float)):
        kind = quota.get("rateLimitType") or "unknown"
        return "hit", (ts, HIT_KINDS.get(kind, kind), int(quota["resetsAt"]))
    message = entry.get("message")
    if entry.get("type") != "assistant" or not isinstance(message, dict):
        return None
    usage, model = message.get("usage"), message.get("model")
    if not isinstance(usage, dict) or not model or model == "<synthetic>":
        return None

    def count(key):
        value = usage.get(key)
        return int(value) if isinstance(value, (int, float)) else 0

    # One response is written once per content block, each with the same id
    # and usage; the primary key keeps one row per response.
    return "message", (message.get("id") or entry.get("uuid") or "", entry.get("requestId") or "", ts,
                       entry.get("sessionId"), model, count("input_tokens"), count("output_tokens"),
                       count("cache_creation_input_tokens"), count("cache_read_input_tokens"))


def ingest(db, config_dir):
    known = {path: (offset, size) for path, offset, size in db.execute("SELECT path, offset, size FROM files")}
    for path in (config_dir / "projects").glob("**/*.jsonl"):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        offset, seen = known.get(str(path), (0, -1))
        if size == seen:
            continue
        if size < offset:  # rewritten; the primary key drops what is already stored
            offset = 0
        try:
            with open(path, "rb") as f:
                f.seek(offset)
                chunk = f.read()
        except OSError:
            continue
        end = chunk.rfind(b"\n") + 1  # a line still being written waits for the next run
        parsed = [p for p in map(parse_line, chunk[:end].splitlines()) if p]
        with db:
            db.executemany("INSERT OR REPLACE INTO messages VALUES (?,?,?,?,?,?,?,?,?)",
                           [row for what, row in parsed if what == "message"])
            db.executemany("INSERT OR REPLACE INTO limit_hits VALUES (?,?,?)",
                           [row for what, row in parsed if what == "hit"])
            db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?)", (str(path), offset + end, offset + end))


def model_name(model):
    """claude-opus-4-5-20251101 -> Opus 4.5, claude-3-5-sonnet-20241022 -> Sonnet 3.5"""
    parts = re.sub(r"-\d{8}$", "", model.removeprefix("claude-")).split("-")
    words = [p for p in parts if not p.isdigit()]
    digits = [p for p in parts if p.isdigit()]
    if not words:
        return model
    return " ".join(w.capitalize() for w in words) + (" " + ".".join(digits) if digits else "")


def local(ts):
    return datetime.fromtimestamp(ts).astimezone()


def epoch(dt):
    return int(dt.timestamp())


def month_start(year, month):
    year, month = year + (month - 1) // 12, (month - 1) % 12 + 1
    return datetime(year, month, 1).astimezone()


def session_windows(db, current_end, now):
    """Every 5-hour session that has started, newest first, as (start, end, confirmed).

    A session is confirmed when its reset time is known: from a rejection, from a
    usage API snapshot, or `current_end`. Otherwise it is estimated the way the
    limit behaves: a session opens with the first request after the previous one
    closed, rounded down to 10 minutes. Requests from elsewhere (claude.ai, other
    computers) open sessions this cannot see, so an estimate can be off.
    """
    anchors = {(r + 30) // 60 * 60 for (r,) in db.execute(
        "SELECT resets_at FROM limit_hits WHERE kind = 'session' UNION "
        "SELECT resets_at FROM limit_snapshots WHERE kind = 'session' AND resets_at IS NOT NULL")}
    if current_end:
        anchors.add((current_end + 30) // 60 * 60)
    anchors = sorted(anchors)
    windows, end = [], 0
    for (t,) in db.execute("SELECT ts FROM messages ORDER BY ts"):
        if t < end:
            continue
        i = bisect.bisect_right(anchors, t)
        if i < len(anchors) and anchors[i] - SESSION <= t:
            start, end, confirmed = anchors[i] - SESSION, anchors[i], True
        elif i < len(anchors) and anchors[i] - 2 * SESSION < t:
            # The next known session opens within 5 hours, so this one closed
            # when that one opened: sessions follow each other back to back.
            end, confirmed = anchors[i] - SESSION, False
            start = max(end - SESSION, windows[-1][1] if windows else 0)
        else:
            start, confirmed = t - t % 600, False
            end = start + SESSION
        windows.append((start, end, confirmed))
    for r in anchors:  # sessions with no requests from this computer
        if not any(s < r and r - SESSION < e for s, e, _ in windows):
            windows.append((r - SESSION, r, True))
    return sorted((w for w in windows if w[0] <= now), reverse=True)


def session_info(db, start, end, now):
    """Whether a session hit its limit, and when."""
    hit_at = db.execute("SELECT MIN(ts) FROM limit_hits WHERE kind = 'session' AND ts >= ? AND ts < ?",
                        (start, end)).fetchone()[0]
    peak = db.execute("SELECT MAX(percent) FROM limit_snapshots WHERE kind = 'session' AND resets_at BETWEEN ? AND ?",
                      (end - 120, end + 120)).fetchone()[0]
    if hit_at is None and peak is not None and peak >= 100:
        hit_at = db.execute("SELECT MIN(ts) FROM limit_snapshots WHERE kind = 'session' AND percent >= 100 "
                            "AND resets_at BETWEEN ? AND ?", (end - 120, end + 120)).fetchone()[0]
    first, last = db.execute("SELECT MIN(ts), MAX(ts) FROM messages WHERE ts >= ? AND ts < ?", (start, end)).fetchone()
    return {"active": now < end, "hit_at": hit_at, "peak_percent": peak, "first_activity": first, "last_activity": last}


def window_total(db, start, end):
    return db.execute("SELECT SUM(input + output + cache_write + cache_read) FROM messages WHERE ts >= ? AND ts < ?",
                      (start, end)).fetchone()[0] or 0


def bucket_starts(period, offset, now):
    """Start of each bucket of a calendar period, plus its end, as epoch seconds."""
    today = local(now).replace(hour=0, minute=0, second=0, microsecond=0, tzinfo=None)
    if period == "day":
        day = today - timedelta(days=offset)
        # Built from wall-clock hours so DST days get 23 or 25 buckets.
        return sorted({epoch((day + timedelta(hours=h)).astimezone()) for h in range(25)}
                      | {epoch((day + timedelta(days=1)).astimezone())})
    if period == "week":
        monday = today - timedelta(days=today.weekday() + 7 * offset)
        return [epoch((monday + timedelta(days=d)).astimezone()) for d in range(8)]
    if period == "month":
        first = month_start(today.year, today.month - offset)
        last = month_start(first.year, first.month + 1)
        days = (last.replace(tzinfo=None) - first.replace(tzinfo=None)).days
        return [epoch((first.replace(tzinfo=None) + timedelta(days=d)).astimezone()) for d in range(days + 1)]
    if period == "year":
        year = today.year - offset
        return [epoch(month_start(year, m)) for m in range(1, 14)]
    raise ValueError(period)


def totals(db, start, end, step):
    return db.execute("""
        SELECT model, (ts / ?) * ?, SUM(input), SUM(output), SUM(cache_write), SUM(cache_read), COUNT(*)
        FROM messages WHERE ts >= ? AND ts < ? GROUP BY model, ts / ?""",
                      (step, step, start, end, step)).fetchall()


def query(db, period, offset, now, session_end):
    extra = {}
    if period == "session":
        windows = session_windows(db, session_end, now)
        if not windows:
            windows = [(now - SESSION, now, False)]
        offset = min(offset, len(windows) - 1)
        start, end, confirmed = windows[offset]
        starts = [start + i * QUARTER for i in range(SESSION // QUARTER + 1)]
        prev_start, prev_full_end = windows[offset + 1][:2] if offset + 1 < len(windows) else (start, start)
        has_older = offset + 1 < len(windows)
        # The page of up to 12 sessions around this one, oldest first, for the strip.
        page = range(offset // 12 * 12, min(len(windows), offset // 12 * 12 + 12))
        extra["session"] = {**session_info(db, start, end, now), "confirmed": confirmed, "count": len(windows)}
        extra["strip"] = [{"offset": i, "start": windows[i][0], "end": windows[i][1],
                           "total": window_total(db, *windows[i][:2]),
                           "hit": session_info(db, *windows[i][:2], now)["hit_at"] is not None}
                          for i in reversed(page)]
    else:
        starts = bucket_starts(period, offset, now)
        start, end = starts[0], starts[-1]
        prev_start = (start - (end - start) if period in ("day", "week")
                      else bucket_starts(period, offset + 1, now)[0])
        prev_full_end = start
        oldest = db.execute("SELECT MIN(ts) FROM messages").fetchone()[0]
        has_older = oldest is not None and oldest < start
        extra["oldest"] = oldest
    # Colors follow the model, not its rank in this period: slots go by all-time use.
    ranking = [m for (m,) in db.execute(
        "SELECT model FROM messages GROUP BY model ORDER BY SUM(input + output + cache_write + cache_read) DESC")]

    models, buckets = {}, [{"start": s, "total": 0, "models": {}} for s in starts[:-1]]
    for model, slice_start, inp, out, cw, cr, n in totals(db, start, end, MINUTE if period == "session" else QUARTER):
        m = models.setdefault(model, {"id": model, "name": model_name(model), "slot": ranking.index(model),
                                      "input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "requests": 0})
        m["input"] += inp
        m["output"] += out
        m["cache_write"] += cw
        m["cache_read"] += cr
        m["requests"] += n
        bucket = buckets[max(0, bisect.bisect_right(starts, slice_start) - 1)]
        bucket["total"] += inp + out + cw + cr
        bucket["models"][model] = bucket["models"].get(model, 0) + inp + out + cw + cr
    for m in models.values():
        m["total"] = m["input"] + m["output"] + m["cache_write"] + m["cache_read"]

    # A period still running is compared with the same stretch of the one before.
    partial = now < end
    prev_end = min(prev_full_end, prev_start + (now - start)) if partial else prev_full_end
    prev_total = window_total(db, prev_start, prev_end)

    ordered = sorted(models.values(), key=lambda m: -m["total"])
    return {
        "period": period, "offset": offset, "start": start, "end": end,
        "total": sum(m["total"] for m in ordered),
        "prev_total": prev_total,
        "partial": partial,
        "input": sum(m["input"] for m in ordered),
        "output": sum(m["output"] for m in ordered),
        "cache_write": sum(m["cache_write"] for m in ordered),
        "cache_read": sum(m["cache_read"] for m in ordered),
        "requests": sum(m["requests"] for m in ordered),
        "models": ordered,
        "buckets": buckets,
        "has_older": has_older,
        **extra,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["ingest", "query"])
    parser.add_argument("--config-dir", default="", help="Claude config dir (default $CLAUDE_CONFIG_DIR or ~/.claude)")
    parser.add_argument("--period", default="day", choices=["session", "day", "week", "month", "year"])
    parser.add_argument("--offset", type=int, default=0, help="periods back from the current one")
    parser.add_argument("--session-end", default="", help="reset time of the current 5-hour session (ISO)")
    parser.add_argument("--tag", default="", help="echoed back, to match answers to requests")
    args = parser.parse_args()

    config_dir = Path(args.config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser()
    out = {"tag": args.tag, "ok": True, "error": None}
    try:
        db = connect()
        ingest(db, config_dir)
        if args.command == "query":
            session_end = None
            if args.session_end:
                session_end = int(datetime.fromisoformat(args.session_end.replace("Z", "+00:00")).timestamp())
            out.update(query(db, args.period, max(0, args.offset), int(time.time()), session_end))
    except (sqlite3.Error, OSError, ValueError) as e:
        out.update(ok=False, error=f"{type(e).__name__}: {e}")
    json.dump(out, sys.stdout)
    print()


if __name__ == "__main__":
    main()
