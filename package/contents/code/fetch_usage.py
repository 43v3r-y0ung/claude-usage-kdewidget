#!/usr/bin/env python3
"""Fetch Claude subscription usage limits for the Plasma widget.

Reads the OAuth login Claude Code keeps in <config dir>/.credentials.json and asks
the (undocumented) endpoint Claude Code's /usage command uses. Prints one JSON
document on stdout and always exits 0, so the widget only has to parse stdout.

The last good answer is cached, so several widget instances share one request
per interval, and errors (expired token, offline, 429) still show the last data.
"""

import argparse
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # Claude Code's public OAuth client
# Anthropic's edge answers 403 to User-Agents that are not Claude Code's.
USER_AGENT = "claude-code/2.1.309"
TIMEOUT = 15

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "claude-usage-widget"
CACHE_FILE = CACHE_DIR / "usage.json"
# Shared with token_stats.py, which reads the snapshots to tell when sessions hit their limit.
HISTORY_FILE = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "claude-usage-widget" / "history.sqlite"

LABELS = {"session": "Session (5h)", "weekly_all": "Weekly · all models"}
# Older responses had flat windows instead of a "limits" list.
FLAT = {"five_hour": "session", "seven_day": "weekly_all", "seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet"}


class UsageError(Exception):
    def __init__(self, code, message, retry_after=None):
        super().__init__(message)
        self.code = code
        self.retry_after = retry_after


def now():
    return time.time()


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json_atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def request_json(url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json", **headers}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read(1 << 20))
    except urllib.error.HTTPError as e:
        retry = e.headers.get("Retry-After") if e.headers else None
        try:
            retry = float(retry) if retry else None
        except ValueError:
            retry = None
        raise UsageError(f"http_{e.code}", f"HTTP {e.code} from {url.split('/')[2]}", retry) from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise UsageError("network", f"Network error: {getattr(e, 'reason', e)}") from None
    except ValueError:
        raise UsageError("bad_response", "The server did not answer with JSON") from None


def load_login(creds_path):
    creds = read_json(creds_path)
    if not isinstance(creds, dict) or not isinstance(creds.get("claudeAiOauth"), dict):
        raise UsageError("no_login", f"No Claude Code login in {creds_path}; run `claude` and /login")
    return creds


def refresh_login(creds_path, creds):
    """Renew the access token and write the rotated refresh token back for Claude Code."""
    used = creds["claudeAiOauth"].get("refreshToken")
    if not used:
        raise UsageError("expired", "Token expired; open Claude Code to renew it")
    result = request_json(TOKEN_URL, {}, {"grant_type": "refresh_token", "refresh_token": used, "client_id": CLIENT_ID})
    if not isinstance(result, dict) or not result.get("access_token"):
        raise UsageError("expired", "Token renewal failed; open Claude Code to renew it")
    # Claude Code may have renewed it while we were asking; its file wins then.
    latest = load_login(creds_path)
    if latest["claudeAiOauth"].get("refreshToken") != used:
        return latest
    login = latest["claudeAiOauth"]
    login["accessToken"] = result["access_token"]
    if result.get("refresh_token"):
        login["refreshToken"] = result["refresh_token"]
    if result.get("expires_in"):
        login["expiresAt"] = int((now() + float(result["expires_in"])) * 1000)
    write_json_atomic(creds_path, latest)
    return latest


def scoped_label(entry):
    scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
    model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
    name = model.get("display_name") or model.get("id")
    return f"Weekly · {name}" if name else "Weekly · scoped"


def normalize(usage):
    limits = []
    if isinstance(usage.get("limits"), list):
        for entry in usage["limits"]:
            if not isinstance(entry, dict) or not isinstance(entry.get("percent"), (int, float)):
                continue
            kind = entry.get("kind") or "unknown"
            label = scoped_label(entry) if kind == "weekly_scoped" else LABELS.get(kind, kind.replace("_", " ").title())
            limits.append({"kind": kind, "label": label, "percent": float(entry["percent"]),
                           "resets_at": entry.get("resets_at"), "active": bool(entry.get("is_active"))})
    if not limits:
        for key, kind in FLAT.items():
            window = usage.get(key)
            if not isinstance(window, dict) or not isinstance(window.get("utilization"), (int, float)):
                continue
            label = LABELS.get(kind) or f"Weekly · {kind}"
            limits.append({"kind": kind if kind in LABELS else "weekly_scoped", "label": label,
                           "percent": float(window["utilization"]), "resets_at": window.get("resets_at"),
                           "active": False})
    extra = usage.get("extra_usage")
    extra = extra if isinstance(extra, dict) and extra.get("is_enabled") else None
    return limits, extra


def record_snapshot(limits):
    """Adds the limits just fetched to the history database."""
    rows = []
    for limit in limits:
        try:
            resets = int(datetime.fromisoformat(limit["resets_at"].replace("Z", "+00:00")).timestamp())
        except (AttributeError, TypeError, ValueError):
            resets = None
        # Several weekly limits can be scoped to different models.
        kind = limit["kind"] if limit["kind"] != "weekly_scoped" else "weekly_scoped:" + limit["label"]
        rows.append((int(now()), kind, limit["percent"], resets))
    os.umask(0o077)
    HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(HISTORY_FILE, timeout=30)
    try:
        with db:
            db.execute("CREATE TABLE IF NOT EXISTS limit_snapshots (ts INTEGER NOT NULL, kind TEXT NOT NULL, "
                       "percent REAL NOT NULL, resets_at INTEGER, PRIMARY KEY (ts, kind))")
            db.executemany("INSERT OR REPLACE INTO limit_snapshots VALUES (?,?,?,?)", rows)
    finally:
        db.close()


def fetch(creds_path, allow_refresh):
    creds = load_login(creds_path)
    login = creds["claudeAiOauth"]
    expires = (login.get("expiresAt") or 0) / 1000
    if expires and expires < now() + 60:
        if not allow_refresh:
            raise UsageError("expired", "Token expired; open Claude Code to renew it")
        creds = refresh_login(creds_path, creds)
        login = creds["claudeAiOauth"]

    def ask(token):
        return request_json(USAGE_URL, {"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"})

    try:
        usage = ask(login["accessToken"])
    except UsageError as e:
        if e.code != "http_401":
            raise
        if not allow_refresh:
            raise UsageError("expired", "Token rejected; open Claude Code to renew it") from None
        usage = ask(refresh_login(creds_path, creds)["claudeAiOauth"]["accessToken"])
    if not isinstance(usage, dict):
        raise UsageError("bad_response", "Unexpected usage response")
    limits, extra = normalize(usage)
    return {"plan": login.get("subscriptionType"), "limits": limits, "extra_usage": extra}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", default="", help="Claude config dir (default $CLAUDE_CONFIG_DIR or ~/.claude)")
    parser.add_argument("--max-age", type=int, default=240, help="reuse a cached answer younger than this (s)")
    parser.add_argument("--force", action="store_true", help="ignore the cache age (still honors 429 backoff)")
    parser.add_argument("--allow-refresh", action="store_true", help="renew an expired token and save it back")
    args = parser.parse_args()

    config_dir = Path(args.config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser()
    creds_path = config_dir / ".credentials.json"
    cache = read_json(CACHE_FILE) or {}
    if cache.get("config_dir") != str(config_dir):
        cache = {}

    fresh = cache.get("data") and now() - cache.get("fetched", 0) < args.max_age
    backing_off = now() < cache.get("backoff_until", 0)
    if (fresh and not args.force) or backing_off:
        out = {"ok": True, "stale": False, "error": None, "error_code": None}
        if backing_off:
            out.update(ok=False, stale=bool(cache.get("data")), error="Rate limited; waiting before asking again",
                       error_code="http_429")
    else:
        try:
            cache = {"config_dir": str(config_dir), "fetched": now(), "data": fetch(creds_path, args.allow_refresh)}
            out = {"ok": True, "stale": False, "error": None, "error_code": None}
            try:
                record_snapshot(cache["data"]["limits"])
            except (sqlite3.Error, OSError):
                pass  # the history is a bonus; the widget still shows the limits
        except UsageError as e:
            out = {"ok": False, "stale": bool(cache.get("data")), "error": str(e), "error_code": e.code}
            cache["config_dir"] = str(config_dir)
            if e.code == "http_429":
                cache["backoff_until"] = now() + max(e.retry_after or 0, 300)
        try:
            write_json_atomic(CACHE_FILE, cache)
        except OSError:
            pass

    data = cache.get("data") or {}
    out.update(fetched_at=iso(cache["fetched"]) if cache.get("fetched") else None,
               plan=data.get("plan"), limits=data.get("limits", []), extra_usage=data.get("extra_usage"))
    json.dump(out, sys.stdout)
    print()


if __name__ == "__main__":
    main()
