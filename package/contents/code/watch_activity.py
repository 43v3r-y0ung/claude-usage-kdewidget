#!/usr/bin/env python3
"""Waits for Claude Code to do something, for the widget's live updates.

Blocks until a transcript in <config dir>/projects/**/*.jsonl is written (one
line per API response, so once per step of a turn: thinking, a tool call, the
answer), or until the set of busy sessions changes, then prints one JSON
document and exits; the widget runs it again right away. Busy sessions come
from <config dir>/sessions/<pid>.json, which Claude Code keeps for every
running instance with a "status" of "busy" or "idle"; that file is not
documented, so when it is missing or changes shape no sessions are reported.

Uses inotify through ctypes (Linux, standard library only). Always exits 0.
"""

import argparse
import ctypes
import errno
import json
import os
import select
import struct
import sys
import time
from pathlib import Path

IN_MODIFY = 0x2
IN_CLOSE_WRITE = 0x8
IN_MOVED_TO = 0x80
IN_CREATE = 0x100
IN_DELETE = 0x200
IN_Q_OVERFLOW = 0x4000
IN_ISDIR = 0x40000000
IN_ONLYDIR = 0x1000000
EVENT = struct.Struct("iIII")
# How long to keep collecting writes after the first one, so a response written
# as several lines (one per content block) makes one update.
SETTLE = 1.5
# Wakes up this often to notice that the widget (our parent) has gone.
PARENT_CHECK = 30


class Inotify:
    def __init__(self):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1: " + os.strerror(ctypes.get_errno()))
        self.dirs = {}

    def watch(self, path, mask):
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(path), mask | IN_ONLYDIR)
        if wd < 0:
            err = ctypes.get_errno()
            if err == errno.ENOSPC:
                raise OSError(err, "Too many folders to watch (fs.inotify.max_user_watches)")
            return  # gone already, or not a folder
        self.dirs[wd] = Path(path)

    def watch_tree(self, root, mask):
        self.watch(root, mask)
        for parent, subdirs, _ in os.walk(root):
            for name in subdirs:
                self.watch(os.path.join(parent, name), mask)

    def read(self, timeout):
        """[(folder, name, mask)] that arrived within `timeout` seconds."""
        if not select.select([self.fd], [], [], max(0, timeout))[0]:
            return []
        try:
            buf = os.read(self.fd, 1 << 16)
        except BlockingIOError:
            return []
        events, i = [], 0
        while i < len(buf):
            wd, mask, _, length = EVENT.unpack_from(buf, i)
            name = buf[i + EVENT.size:i + EVENT.size + length].rstrip(b"\0").decode(errors="replace")
            events.append((self.dirs.get(wd), name, mask))
            i += EVENT.size + length
        return events


def sessions(sessions_dir):
    """Running Claude Code instances, from the files they keep in <config dir>/sessions."""
    found = []
    try:
        paths = list(sessions_dir.glob("*.json"))
    except OSError:
        return found
    for path in paths:
        try:
            entry = json.loads(path.read_text(encoding="utf-8"))
            pid = int(entry["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not os.path.exists(f"/proc/{pid}"):  # left behind by a crash
            continue
        found.append({"id": str(entry.get("sessionId") or pid), "name": entry.get("name") or "",
                      "cwd": entry.get("cwd") or "", "busy": entry.get("status") == "busy"})
    return sorted(found, key=lambda s: s["id"])


def busy_ids(found):
    return sorted(s["id"] for s in found if s["busy"])


def wait(config_dir, known_busy, timeout):
    projects, sessions_dir = config_dir / "projects", config_dir / "sessions"
    inotify = Inotify()
    tree_mask = IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE
    if projects.is_dir():
        inotify.watch_tree(projects, tree_mask)
    elif config_dir.is_dir():  # Claude Code has not written a transcript yet
        inotify.watch(config_dir, IN_CREATE)
    if sessions_dir.is_dir():
        inotify.watch(sessions_dir, IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE)
    elif config_dir.is_dir():
        inotify.watch(config_dir, IN_CREATE)

    # Watching starts before this, so nothing that happens from here on is missed;
    # a change while the widget was starting us again shows up right away.
    current = sessions(sessions_dir)
    if known_busy is not None and busy_ids(current) != known_busy:
        return "sessions", current

    parent, deadline, settle_until = os.getppid(), time.monotonic() + timeout, None
    while True:
        now = time.monotonic()
        if settle_until is not None and now >= settle_until:
            return "transcripts", sessions(sessions_dir)
        if now >= deadline:
            return "timeout", sessions(sessions_dir)
        if os.getppid() != parent:
            sys.exit(0)  # the widget is gone; nobody would read the answer
        limit = min(deadline, settle_until or deadline, now + PARENT_CHECK) - now
        for folder, name, mask in inotify.read(limit):
            if mask & IN_Q_OVERFLOW:
                return "transcripts", sessions(sessions_dir)
            if folder is None:
                continue
            if folder == config_dir:
                if name in ("projects", "sessions"):
                    return "transcripts", sessions(sessions_dir)  # watch it from the next run
            elif folder == sessions_dir:
                if name.endswith(".json"):
                    found = sessions(sessions_dir)
                    if busy_ids(found) != busy_ids(current):
                        return "sessions", found
                    current = found
            elif mask & IN_ISDIR:
                if mask & (IN_CREATE | IN_MOVED_TO):  # a new project, or a session's subagents
                    inotify.watch_tree(folder / name, tree_mask)
            elif name.endswith(".jsonl") and settle_until is None:
                settle_until = time.monotonic() + SETTLE


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", default="", help="Claude config dir (default $CLAUDE_CONFIG_DIR or ~/.claude)")
    parser.add_argument("--busy", default=None,
                        help="comma-separated ids of the sessions the widget last saw busy; a difference answers at once")
    parser.add_argument("--timeout", type=float, default=600, help="answer after this long even if nothing happened (s)")
    parser.add_argument("--tag", default="", help="echoed back, to match answers to requests")
    args = parser.parse_args()

    config_dir = Path(args.config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser()
    known = sorted(filter(None, args.busy.split(","))) if args.busy is not None else None
    out = {"tag": args.tag, "ok": True, "error": None}
    try:
        reason, found = wait(config_dir, known, args.timeout)
        out.update(reason=reason, sessions=found, busy=busy_ids(found))
    except OSError as e:
        out.update(ok=False, error=str(e.strerror or e))
    json.dump(out, sys.stdout)
    print()


if __name__ == "__main__":
    main()
