#!/usr/bin/env python3
"""Read the state of bmad-loop runs for the Claude Code status line.

Prints ONE line, fields separated by \x1f (never a TAB: an empty field separated
by tabs disappears, and everything after it slides one place to the left):

    status \x1f story \x1f phase \x1f elapsed_s \x1f reason \x1f graceful \x1f deferred

or the word NONE when there is nothing worth showing.

WATCH OUT for bmad-loop's TWO state vocabularies, which do not agree
(documents.py:352 for list, :277 for status):

    list --json    running | paused | finished | stopped | crashed | interrupted | unknown
    status --json  in-progress | paused | crashed | stopped | finished

`list` is liveness-aware (it checks whether the process really exists) and has
`interrupted` on top, which means: the state file says alive, but nobody is
running it any more. Both vocabularies are accepted here, because the two
commands answer differently about the same run.

What is shown and what is not: `finished` and `stopped` runs stay in the listing
forever, so showing them would occupy the line forever. Only live runs are shown,
plus the ones that died badly in the last 24 hours.
"""

import datetime
import json
import subprocess
import sys

LIVE = {"running", "paused", "in-progress"}
BAD = {"crashed", "interrupted", "unknown"}
SEP = "\x1f"
TIMEOUT_S = 8


def age_seconds(started, now):
    """Seconds elapsed since an ISO timestamp, or None if it cannot be read.

    A NAIVE `started_at` IS LOCAL TIME, NOT UTC. bmad-loop writes it as plain
    wall-clock with no offset, and stamping it UTC shifted every run by the
    machine's offset. Measured 2026-09-04 in CEST (UTC+2): a run 42 minutes old
    computed as MINUS 78 minutes, the negative was clamped to zero on the way
    out, and the line read "0m" for the first two hours of every run. No error
    anywhere - just a number that stayed still while the run went on.

    `astimezone()` on a naive value is exactly this rule: read it as local,
    attach the local offset. It follows the machine, daylight saving included.
    """
    if not started:
        return None
    try:
        stamp = datetime.datetime.fromisoformat(started.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            stamp = stamp.astimezone()
        return (now - stamp).total_seconds()
    except Exception:
        return None


def run_json(args):
    """Run bmad-loop and return the document, or None if anything goes wrong.

    It never raises: a status line that fails is worse than one without the block.
    """
    try:
        done = subprocess.run(
            ["bmad-loop", *args], capture_output=True, text=True, timeout=TIMEOUT_S
        )
        return json.loads(done.stdout)
    except Exception:
        return None


def pick_run(runs, now):
    """The run to show: the last live one, otherwise the last recently dead one."""
    live = [r for r in runs if r.get("status") in LIVE]
    if live:
        return live[-1]
    recent_bad = [
        r
        for r in runs
        if r.get("status") in BAD
        and (age_seconds(r.get("started_at"), now) or float("inf")) < 86400
    ]
    return recent_bad[-1] if recent_bad else None


def detail(run_id, project):
    """Phase, pause reason, story and deferred findings: they cost a second process.

    Only paid for on a live run - while a run is going, one process every half a
    minute is nothing next to what the run itself is doing.
    """
    story = phase = reason = ""
    graceful = "0"
    deferred = 0
    doc = run_json(["status", "--json", run_id, "--project", project])
    if not doc:
        return story, phase, reason, graceful, deferred
    if doc.get("graceful_stop_pending"):
        graceful = "1"
    reason = doc.get("paused_reason") or ""
    story = doc.get("paused_story_key") or ""
    tasks = doc.get("tasks") or []
    # The last story not yet concluded is the one the run is working on; if they
    # are all concluded we still show the last, rather than going silent.
    current = None
    for task in tasks:
        if task.get("phase") not in ("done", "", None):
            current = task
    if current is None and tasks:
        current = tasks[-1]
    if current:
        story = story or current.get("story_key") or ""
        phase = current.get("phase") or ""
    for task in tasks:
        found = task.get("deferred")
        if isinstance(found, list):
            deferred += len(found)
    return story, phase, reason, graceful, deferred


def main():
    project = sys.argv[1] if len(sys.argv) > 1 else "."
    now = datetime.datetime.now(datetime.timezone.utc)

    listing = run_json(["list", "--json", "--project", project])
    if not listing:
        print("NONE")
        return
    run = pick_run(listing.get("runs") or [], now)
    if run is None:
        print("NONE")
        return

    status = run.get("status") or ""
    # A run that started in the future has no age, and printing 0 there is worse
    # than printing nothing: zero is a plausible number, so it reads as a
    # measurement and nobody goes looking - which is exactly how the timezone
    # defect above survived. An empty field makes the duration disappear instead.
    _age = age_seconds(run.get("started_at"), now)
    elapsed = "" if _age is None or _age < 0 else str(int(_age))
    story = phase = reason = ""
    graceful = "0"
    deferred = 0
    if status in LIVE:
        story, phase, reason, graceful, deferred = detail(run.get("run_id") or "", project)
    # With no story we fall back to the run's short ref: always present, so the
    # block never appears without saying WHO it is talking about.
    story = story or run.get("ref") or ""
    print(SEP.join([status, story, phase, elapsed, reason, graceful, str(deferred)]))


if __name__ == "__main__":
    main()
