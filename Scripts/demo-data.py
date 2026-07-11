#!/usr/bin/env python3
"""Seed a fake session store so Temple can be demoed or screenshotted without
exposing real projects.

    ./Scripts/demo-data.py          # writes /tmp/temple-demo/{claude,codex}-store
    make demo                       # seeds + launches Temple against it

The app reads its index from TEMPLE_CLAUDE_ROOT / TEMPLE_CODEX_ROOT when set,
so the real ~/.claude and ~/.codex stores are never touched.
"""
import json
import os
import shutil
import uuid
from datetime import datetime, timedelta, timezone

DEMO = "/private/tmp/temple-demo"
CLAUDE_STORE = f"{DEMO}/claude-store"
CODEX_STORE = f"{DEMO}/codex-store"
PROJECTS = f"{DEMO}/projects"

CLAUDE_SESSIONS = {
    "acme-api": [
        ("the /orders endpoint returns 500 when the cart is empty, can you trace it?", 4),
        ("add pagination to the customers list, cursor based", 40),
        ("write integration tests for the webhook retry logic", 190),
        ("why is the staging deploy 4x slower than prod?", 1500),
        ("bump the sdk and fix whatever breaks", 2600),
        ("can you review the rate limiter before I open the PR", 4300),
    ],
    "storefront": [
        ("checkout button does nothing on mobile safari", 12),
        ("migrate the product grid to the new design tokens", 300),
        ("lighthouse score dropped to 61, find the regression", 900),
        ("add optimistic updates to the cart", 3100),
    ],
    "pipeline": [
        ("the nightly job silently drops rows, help me find where", 55),
        ("parallelize the backfill, it takes 6 hours", 800),
        ("set up alerting for the ingestion lag", 2000),
    ],
    "notes-app": [
        ("offline sync conflicts are duplicating notes", 26),
        ("swiftui list scroll jank on large documents", 700),
        ("add full text search over the local db", 6000),
    ],
    "dotfiles": [
        ("clean up my zsh startup, it takes 400ms", 130),
        ("script to sync my brew packages across machines", 5000),
    ],
}

CODEX_SESSIONS = [
    ("acme-api", "audit the auth middleware for timing leaks", 70),
    ("storefront", "convert the legacy sass to css modules", 1200),
]

now = datetime.now(timezone.utc)


def write(path, lines, when):
    with open(path, "w") as fh:
        for line in lines:
            fh.write(json.dumps(line) + "\n")
    os.utime(path, (when.timestamp(), when.timestamp()))


def main():
    shutil.rmtree(CLAUDE_STORE, ignore_errors=True)
    shutil.rmtree(CODEX_STORE, ignore_errors=True)

    for name, sessions in CLAUDE_SESSIONS.items():
        cwd = f"{PROJECTS}/{name}"
        os.makedirs(cwd, exist_ok=True)          # cwd must exist or it reads as noise
        store_dir = os.path.join(CLAUDE_STORE, cwd.replace("/", "-"))
        os.makedirs(store_dir, exist_ok=True)
        for title, minutes_ago in sessions:
            sid = str(uuid.uuid4())
            when = now - timedelta(minutes=minutes_ago)
            stamp = when.isoformat().replace("+00:00", "Z")
            write(os.path.join(store_dir, f"{sid}.jsonl"), [
                {"type": "user", "message": {"role": "user", "content": title},
                 "cwd": cwd, "timestamp": stamp, "gitBranch": "main", "sessionId": sid},
                {"type": "assistant", "sessionId": sid, "cwd": cwd, "timestamp": stamp,
                 "message": {"role": "assistant", "model": "claude-opus-4-8",
                             "content": "On it."}},
            ], when)

    day = f"{CODEX_STORE}/sessions/{now:%Y/%m/%d}"
    os.makedirs(day, exist_ok=True)
    history = []
    for name, title, minutes_ago in CODEX_SESSIONS:
        cwd = f"{PROJECTS}/{name}"
        sid = str(uuid.uuid4())
        when = now - timedelta(minutes=minutes_ago)
        write(f"{day}/rollout-{when:%Y-%m-%dT%H-%M-%S}-{sid}.jsonl", [
            {"type": "session_meta", "payload": {
                "session_id": sid, "cwd": cwd, "originator": "codex-tui",
                "timestamp": when.isoformat().replace("+00:00", "Z")}},
        ], when)
        history.append({"session_id": sid, "ts": int(when.timestamp()), "text": title})
    with open(f"{CODEX_STORE}/history.jsonl", "w") as fh:
        for entry in history:
            fh.write(json.dumps(entry) + "\n")

    total = sum(len(v) for v in CLAUDE_SESSIONS.values()) + len(CODEX_SESSIONS)
    print(f"seeded {total} sessions across {len(CLAUDE_SESSIONS)} projects in {DEMO}")


if __name__ == "__main__":
    main()
