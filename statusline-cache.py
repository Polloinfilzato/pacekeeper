#!/usr/bin/env python3
"""Say when this session's prompt cache goes cold.

Prints a single line:

    <expiry_epoch> <ttl_seconds>

or nothing, when the transcript does not say enough to answer.

Two things here are not obvious, and both were checked against Anthropic's own
documentation (bundled-skills/<version>/*/claude-api/shared/prompt-caching.md,
lines 148 and 208) rather than recalled:

1. THE TTL IS NOT GUESSED, IT IS WRITTEN IN THE DATA. Every turn that writes to
   the cache carries `usage.cache_creation.ephemeral_1h_input_tokens` next to
   `ephemeral_5m_input_tokens`: whichever is non-zero names the TTL in force.
   This matters because the TTL is NOT a constant - 5 minutes by default, an hour
   when Claude Code asks for one, and back to 5 minutes if the account goes into
   overage. A turn that only READS from the cache writes nothing and has both
   fields at zero, which is why we walk backwards to the last real write.

2. THE CLOCK STARTS AT THE BEGINNING OF THE REQUEST, NOT AT THE END. The time the
   model spends answering is time already eaten. So the instant that counts is the
   timestamp of the last USER message (the request that went out), not of the
   answer: counting from the end would produce a countdown that is too generous,
   and the error would go the worst possible way - "take your time" while it cools.

Every successful read refreshes the timer, for free. So while you are working the
indicator stays green on its own: it is there to decide whether to pick the work
back up NOW or after a break, not to hurry you along while you think.
"""

import datetime
import json
import os
import sys

TAIL_BYTES = 512 * 1024      # plenty for the last few turns, without reading it all
TTL_DEFAULT = 300            # no recognisable write -> assume the shortest, which means
                             # erring on the cautious side: cold sooner than the truth.


def tail_lines(path):
    """The last complete lines of the file, without loading all of it into memory."""
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if size > TAIL_BYTES:
            fh.seek(size - TAIL_BYTES)
            fh.readline()          # the first line read is cut in half: throw it away
        data = fh.read()
    return data.decode("utf-8", "replace").splitlines()


def parse_stamp(value):
    """ISO 8601 (with or without the Z) -> epoch, or None."""
    if not value:
        return None
    try:
        stamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=datetime.timezone.utc)
        return int(stamp.timestamp())
    except Exception:
        return None


def main():
    if len(sys.argv) < 2:
        return
    path = sys.argv[1]
    try:
        lines = tail_lines(path)
    except Exception:
        return

    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except Exception:
            continue

    ttl = None
    started = None

    for entry in reversed(entries):
        message = entry.get("message")
        if not isinstance(message, dict):
            continue

        if ttl is None:
            written = (message.get("usage") or {}).get("cache_creation") or {}
            if written.get("ephemeral_1h_input_tokens"):
                ttl = 3600
            elif written.get("ephemeral_5m_input_tokens"):
                ttl = 300

        if started is None and message.get("role") == "user":
            started = parse_stamp(entry.get("timestamp"))

        if ttl is not None and started is not None:
            break

    if started is None:
        return
    print(started + (ttl or TTL_DEFAULT), ttl or TTL_DEFAULT)


if __name__ == "__main__":
    main()
