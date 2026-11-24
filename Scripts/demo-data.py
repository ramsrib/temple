#!/usr/bin/env python3
"""Seed a fake session store so Temple can be demoed or screenshotted without
exposing real projects.

    ./Scripts/demo-data.py          # writes /tmp/temple-demo/{claude,codex,antigravity}-store
    ./Scripts/demo-data.py --prune  # deletes the sessions recorded in pruned.txt
    make demo                       # seeds, imports, prunes, launches Temple

`--prune` plays Claude Code's retention cleanup: the PRUNED sessions are
imported first (so they are Temple's), then their transcripts deleted, and
Temple archives them on launch (ADR-030). A copy of each is kept beside it
(`<file>.kept`), so copying one back shows that only Restore brings it back.

The app reads its index from TEMPLE_CLAUDE_ROOT / TEMPLE_CODEX_ROOT /
TEMPLE_ANTIGRAVITY_ROOT, and keeps
its own state (index cache, SQLite) in TEMPLE_STATE_DIR, so a demo run neither
reads nor clobbers real data.

The seeded sessions are fixtures: they list and search, but they cannot resume
(no agent ever ran them). To screenshot a live terminal, start a new session in
a demo project from the app, then `make demo-clean` afterwards -- the agent
writes that one to the real ~/.claude store, and demo-clean removes it.
"""
import json
import os
import shutil
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone

DEMO = "/private/tmp/temple-demo"
CLAUDE_STORE = f"{DEMO}/claude-store"
CODEX_STORE = f"{DEMO}/codex-store"
ANTIGRAVITY_STORE = f"{DEMO}/antigravity-store"
PROJECTS = f"{DEMO}/projects"

CLAUDE_SESSIONS = {
    "acme-api": [
        ("the /orders endpoint returns 500 when the cart is empty, can you trace it?", 4),
        ("add pagination to the customers list, cursor based", 40),
        ("write integration tests for the webhook retry logic", 190),
        ("why is the staging deploy 4x slower than prod?", 1500),
        ("bump the sdk and fix whatever breaks", 2600),
        ("can you review the rate limiter before I open the PR", 4300),
        # Past the sidebar's collapse limit, so the demo shows "Show more".
        ("split the monolith config into per-env files", 5200),
        ("the idempotency key check is racy under load", 6100),
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

# Sessions whose transcripts `--prune` deletes, as the CLI's cleanup would:
# all older than the week a session must sit idle before Temple archives it.
PRUNED_PROJECT = "legacy-tools"
PRUNED_SESSIONS = [
    ("port the release script from bash to python", 9),
    ("why does the nightly build only fail on tuesdays", 20),
    ("document the old deploy runbook before we retire it", 45),
]
PRUNED_LIST = f"{DEMO}/pruned.txt"

CODEX_SESSIONS = [
    ("acme-api", "audit the auth middleware for timing leaks", 70),
    ("storefront", "convert the legacy sass to css modules", 1200),
]

# Antigravity CLI conversations (ADR-043): SQLite, shaped like `agy`'s own
# (SESSION-FORMATS.md) — a summaries table and a database per conversation.
ANTIGRAVITY_SESSIONS = [
    ("pipeline", "Backfill Parallelization", "split the backfill by partition and run them in parallel", 150),
    ("notes-app", "", "profile the sync engine on a 10k note account", 2400),
]


def _varint(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _field(number, payload):
    """A length-delimited protobuf field."""
    return _varint(number << 3 | 2) + _varint(len(payload)) + payload


def _varint_field(number, value):
    return _varint(number << 3) + _varint(value)


def user_step_payload(text, when):
    """A user-input step: field 5.1 its time, field 19.2 its text."""
    stamp = _varint_field(1, int(when.timestamp())) + _varint_field(2, when.microsecond * 1000)
    return _varint_field(1, 14) + _field(5, _field(1, stamp)) + _field(19, _field(2, text.encode()))


def write_antigravity_store():
    conversations = f"{ANTIGRAVITY_STORE}/conversations"
    os.makedirs(conversations, exist_ok=True)
    summaries = sqlite3.connect(f"{ANTIGRAVITY_STORE}/conversation_summaries.db")
    summaries.execute("""CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY,
        title text NOT NULL DEFAULT '', preview text NOT NULL DEFAULT '', step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL, workspace_uris text NOT NULL,
        parent_conversation_id text NOT NULL DEFAULT '')""")
    for name, title, prompt, minutes_ago in ANTIGRAVITY_SESSIONS:
        cid = str(uuid.uuid4())
        when = now - timedelta(minutes=minutes_ago)
        path = f"{conversations}/{cid}.db"
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text)")
        db.execute("CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL, step_payload blob)")
        db.execute("INSERT INTO trajectory_meta VALUES (?, ?)", (str(uuid.uuid4()), cid))
        db.execute("INSERT INTO steps VALUES (0, 14, ?)", (user_step_payload(prompt, when),))
        db.commit(); db.close()
        os.utime(path, (when.timestamp(), when.timestamp()))
        summaries.execute("INSERT INTO conversation_summaries VALUES (?, ?, ?, 2, ?, ?, '')",
                          (cid, title, title, when.strftime("%Y-%m-%d %H:%M:%S.%f+00:00"),
                           json.dumps([f"file://{PROJECTS}/{name}"])))
    summaries.commit(); summaries.close()


# The sidebar footer's Codex meter reads the newest rollout's last
# `rate_limits` record (CodexUsageReader); without one the demo shows no meter.
# Shaped like Codex's own token_count event: a 5-hour and a weekly window.
# (The Claude meter reads the Keychain, which a demo must not fake.)
CODEX_RATE_LIMITS = {
    "primary": {"used_percent": 23.0, "window_minutes": 300, "resets_in_minutes": 170},
    "secondary": {"used_percent": 41.0, "window_minutes": 10080, "resets_in_minutes": 3 * 24 * 60},
}


def rate_limits_record(when):
    """One token_count event carrying CODEX_RATE_LIMITS, as of `when`."""
    limits = {slot: {"used_percent": w["used_percent"], "window_minutes": w["window_minutes"],
                     "resets_at": int((when + timedelta(minutes=w["resets_in_minutes"])).timestamp())}
              for slot, w in CODEX_RATE_LIMITS.items()}
    limits["plan_type"] = "pro"
    return {"timestamp": when.isoformat().replace("+00:00", "Z"), "type": "event_msg",
            "payload": {"type": "token_count", "info": None, "rate_limits": limits}}

now = datetime.now(timezone.utc)


def write(path, lines, when):
    with open(path, "w") as fh:
        for line in lines:
            fh.write(json.dumps(line) + "\n")
    os.utime(path, (when.timestamp(), when.timestamp()))


def main():
    shutil.rmtree(CLAUDE_STORE, ignore_errors=True)
    shutil.rmtree(CODEX_STORE, ignore_errors=True)
    shutil.rmtree(ANTIGRAVITY_STORE, ignore_errors=True)

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

    cwd = f"{PROJECTS}/{PRUNED_PROJECT}"
    os.makedirs(cwd, exist_ok=True)
    store_dir = os.path.join(CLAUDE_STORE, cwd.replace("/", "-"))
    os.makedirs(store_dir, exist_ok=True)
    pruned = []
    for title, days_ago in PRUNED_SESSIONS:
        sid = str(uuid.uuid4())
        when = now - timedelta(days=days_ago)
        stamp = when.isoformat().replace("+00:00", "Z")
        path = os.path.join(store_dir, f"{sid}.jsonl")
        write(path, [
            {"type": "user", "message": {"role": "user", "content": title},
             "cwd": cwd, "timestamp": stamp, "gitBranch": "main", "sessionId": sid},
        ], when)
        pruned.append(path)
    with open(PRUNED_LIST, "w") as fh:
        fh.write("".join(f"{path}\n" for path in pruned))

    day = f"{CODEX_STORE}/sessions/{now:%Y/%m/%d}"
    os.makedirs(day, exist_ok=True)
    history = []
    newest = min(minutes for _, _, minutes in CODEX_SESSIONS)
    for name, title, minutes_ago in CODEX_SESSIONS:
        cwd = f"{PROJECTS}/{name}"
        sid = str(uuid.uuid4())
        when = now - timedelta(minutes=minutes_ago)
        lines = [
            {"type": "session_meta", "payload": {
                "session_id": sid, "cwd": cwd, "originator": "codex-tui",
                "timestamp": when.isoformat().replace("+00:00", "Z")}},
        ]
        if minutes_ago == newest:
            lines.append(rate_limits_record(when))
        write(f"{day}/rollout-{when:%Y-%m-%dT%H-%M-%S}-{sid}.jsonl", lines, when)
        history.append({"session_id": sid, "ts": int(when.timestamp()), "text": title})
    with open(f"{CODEX_STORE}/history.jsonl", "w") as fh:
        for entry in history:
            fh.write(json.dumps(entry) + "\n")

    write_antigravity_store()

    total = (sum(len(v) for v in CLAUDE_SESSIONS.values()) + len(PRUNED_SESSIONS) + len(CODEX_SESSIONS)
             + len(ANTIGRAVITY_SESSIONS))
    print(f"seeded {total} sessions across {len(CLAUDE_SESSIONS) + 1} projects in {DEMO}")


def prune():
    """Delete the transcripts `main` recorded, keeping a copy of each."""
    try:
        with open(PRUNED_LIST) as fh:
            paths = [line.strip() for line in fh if line.strip()]
    except FileNotFoundError:
        sys.exit(f"nothing to prune: {PRUNED_LIST} is missing (seed first)")
    for path in paths:
        if os.path.exists(path):
            shutil.copy2(path, path + ".kept")
            os.remove(path)
    print(f"pruned {len(paths)} transcripts (copies kept as <file>.kept)")


if __name__ == "__main__":
    prune() if sys.argv[1:] == ["--prune"] else main()
