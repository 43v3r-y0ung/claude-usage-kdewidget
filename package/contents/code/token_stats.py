#!/usr/bin/env python3
"""Token usage per model, kept in SQLite, for the Plasma widget.

Claude Code writes every API response, with its model and token counts, to the
transcripts in <config dir>/projects/**/*.jsonl, and deletes transcripts after
`cleanupPeriodDays` (30 by default). `ingest` copies the token counts into a
database the widget owns, reading each transcript only from where it stopped
last time, so the history outlives the transcripts. It also keeps the
rejections Claude Code logs when a limit is hit, which date the 5-hour
sessions. `query` ingests, then prints the totals of one period as JSON.

What the tokens cost is worked out at Claude API list prices, as Claude Code's
/cost does. It is an estimate: a subscription is not billed per token, and
transcripts leave out some background requests Claude Code makes.
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
VERSION = 3
# Claude Code's names for the windows of a rejection, as the usage API names them.
HIT_KINDS = {"five_hour": "session", "seven_day": "weekly_all"}

# Claude API list prices in USD per million tokens: input, output, and cache
# reads as a share of input. Cache writes cost 1.25x input when they last 5
# minutes, 2x when they last an hour.
# https://platform.claude.com/docs/en/about-claude/pricing (October 2026)
PRICES = {
    "claude-fable-5-1": (10, 50, 0.025), "claude-mythos-5-1": (10, 50, 0.025),
    "claude-fable-5": (10, 50, 0.1), "claude-mythos-5": (10, 50, 0.1),
    "claude-opus-5-5": (4, 20, 0.05), "claude-opus-5": (5, 25, 0.1),
    "claude-opus-4-8": (5, 25, 0.1), "claude-opus-4-7": (5, 25, 0.1),
    "claude-opus-4-6": (5, 25, 0.1), "claude-opus-4-5": (5, 25, 0.1),
    "claude-opus-4-1": (15, 75, 0.1), "claude-opus-4": (15, 75, 0.1),
    "claude-sonnet-5-5": (2, 10, 0.05), "claude-sonnet-5": (2, 10, 0.1),
    "claude-sonnet-4-6": (3, 15, 0.1), "claude-sonnet-4-5": (3, 15, 0.1), "claude-sonnet-4": (3, 15, 0.1),
    "claude-haiku-5-5": (0.1, 0.5, 0.1), "claude-haiku-4-5": (1, 5, 0.1), "claude-3-5-haiku": (0.8, 4, 0.1),
}
# Fast mode replaces the input and output prices; the cache multipliers still apply.
FAST_PRICES = {"claude-opus-5-5": (8, 40), "claude-opus-5": (10, 50), "claude-opus-4-8": (10, 50)}
# Claude Haiku 5.5 costs 5x for a request whose prompt (input and cache) is over 100K tokens.
LONG_PROMPT = {"claude-haiku-5-5": (100_000, 5)}
US_ONLY = 1.1  # inference_geo "us" (Claude 4.6 and later)
WEB_SEARCH = 0.01
# The cost of a row of `messages`, through the SQL function cost() that connect() adds.
COST = "cost(model, input, output, cache_write, cache_write_1h, cache_read, web_search, fast, us_only)"

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
    -- The part of cache_write kept for an hour; NULL in rows from before it was kept.
    cache_write_1h INTEGER,
    web_search INTEGER NOT NULL DEFAULT 0,
    fast INTEGER NOT NULL DEFAULT 0,
    us_only INTEGER NOT NULL DEFAULT 0,
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
    db.create_function("cost", 9, cost, deterministic=True)
    columns = {row[1] for row in db.execute("PRAGMA table_info(messages)")}
    for column, kind in (("cache_write_1h", "INTEGER"), ("web_search", "INTEGER NOT NULL DEFAULT 0"),
                         ("fast", "INTEGER NOT NULL DEFAULT 0"), ("us_only", "INTEGER NOT NULL DEFAULT 0")):
        if column not in columns:
            db.execute(f"ALTER TABLE messages ADD COLUMN {column} {kind}")
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

    def part(key, inner):
        value = usage.get(key)
        value = value.get(inner) if isinstance(value, dict) else None
        return int(value) if isinstance(value, (int, float)) else 0

    # One response is written once per content block, each with the same id
    # and usage; the primary key keeps one row per response.
    return "message", (message.get("id") or entry.get("uuid") or "", entry.get("requestId") or "", ts,
                       entry.get("sessionId"), model, count("input_tokens"), count("output_tokens"),
                       count("cache_creation_input_tokens"), count("cache_read_input_tokens"),
                       part("cache_creation", "ephemeral_1h_input_tokens"),
                       part("server_tool_use", "web_search_requests"),
                       int(usage.get("speed") == "fast"), int(usage.get("inference_geo") == "us"))


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
            db.executemany("INSERT OR REPLACE INTO messages (msg_id, request_id, ts, session_id, model, input, output, "
                           "cache_write, cache_read, cache_write_1h, web_search, fast, us_only) "
                           "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           [row for what, row in parsed if what == "message"])
            db.executemany("INSERT OR REPLACE INTO limit_hits VALUES (?,?,?)",
                           [row for what, row in parsed if what == "hit"])
            db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?)", (str(path), offset + end, offset + end))


def cost(model, inp, out, cache_write, cache_write_1h, cache_read, web_search, fast, us_only):
    """USD at list prices for one response, or None for a model without a known price."""
    key = re.sub(r"-\d{8}$", "", model)
    if key not in PRICES:
        return None
    base_in, base_out, read = PRICES[key]
    if fast and key in FAST_PRICES:
        base_in, base_out = FAST_PRICES[key]
    threshold, factor = LONG_PROMPT.get(key, (None, 1))
    scale = (factor if threshold and inp + cache_write + cache_read > threshold else 1) * (US_ONLY if us_only else 1)
    hour = cache_write_1h or 0  # rows from before the split was kept are priced as 5-minute writes
    tokens = (inp + (cache_write - hour) * 1.25 + hour * 2 + cache_read * read) * base_in + out * base_out
    return tokens * scale / 1e6 + web_search * WEB_SEARCH


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
    """Tokens and their cost between two times."""
    tokens, usd = db.execute(f"SELECT SUM(input + output + cache_write + cache_read), SUM({COST}) "
                             "FROM messages WHERE ts >= ? AND ts < ?", (start, end)).fetchone()
    return tokens or 0, usd or 0


def current_session(db, session_end, now):
    """Tokens and cost of the 5-hour session running now, or None between sessions."""
    if session_end and session_end > now:
        end = (session_end + 30) // 60 * 60
        start = end - SESSION
    else:
        windows = session_windows(db, session_end, now)
        if not windows or windows[0][1] <= now:
            return None
        start, end = windows[0][:2]
    total, usd = window_total(db, start, end)
    return {"start": start, "end": end, "total": total, "cost": usd}


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
    return db.execute(f"""
        SELECT model, (ts / ?) * ?, SUM(input), SUM(output), SUM(cache_write), SUM(cache_read), COUNT(*), SUM({COST})
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
        extra["strip"] = []
        for i in reversed(page):
            total, usd = window_total(db, *windows[i][:2])
            extra["strip"].append({"offset": i, "start": windows[i][0], "end": windows[i][1], "total": total,
                                   "cost": usd, "hit": session_info(db, *windows[i][:2], now)["hit_at"] is not None})
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

    models, buckets = {}, [{"start": s, "total": 0, "cost": 0, "models": {}} for s in starts[:-1]]
    for model, slice_start, inp, out, cw, cr, n, usd in totals(db, start, end, MINUTE if period == "session" else QUARTER):
        # A model without a known price keeps a cost of None.
        m = models.setdefault(model, {"id": model, "name": model_name(model), "slot": ranking.index(model),
                                      "input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "requests": 0,
                                      "cost": None if usd is None else 0})
        m["input"] += inp
        m["output"] += out
        m["cache_write"] += cw
        m["cache_read"] += cr
        m["requests"] += n
        if usd is not None:
            m["cost"] += usd
        bucket = buckets[max(0, bisect.bisect_right(starts, slice_start) - 1)]
        bucket["total"] += inp + out + cw + cr
        bucket["cost"] += usd or 0
        bucket["models"][model] = bucket["models"].get(model, 0) + inp + out + cw + cr
    for m in models.values():
        m["total"] = m["input"] + m["output"] + m["cache_write"] + m["cache_read"]

    # A period still running is compared with the same stretch of the one before.
    partial = now < end
    prev_end = min(prev_full_end, prev_start + (now - start)) if partial else prev_full_end
    prev_total, prev_cost = window_total(db, prev_start, prev_end)

    ordered = sorted(models.values(), key=lambda m: -m["total"])
    return {
        "period": period, "offset": offset, "start": start, "end": end,
        "total": sum(m["total"] for m in ordered),
        "prev_total": prev_total,
        "cost": sum(m["cost"] or 0 for m in ordered),
        "prev_cost": prev_cost,
        # False when a model has no known price, so the cost leaves its tokens out.
        "cost_complete": all(m["cost"] is not None for m in ordered),
        "partial": partial,
        "input": sum(m["input"] for m in ordered),
        "output": sum(m["output"] for m in ordered),
        "cache_write": sum(m["cache_write"] for m in ordered),
        "cache_read": sum(m["cache_read"] for m in ordered),
        "requests": sum(m["requests"] for m in ordered),
        "models": ordered,
        "buckets": buckets,
        "has_older": has_older,
        # Shown under the session limit, whatever period is picked.
        "current_session": current_session(db, session_end, now),
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
