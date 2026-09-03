#!/usr/bin/env bash
# EXAMPLE — a spend guard built on pacekeeper-quota.
#
# READ THIS BEFORE COPYING IT.
#
# The numbers below are ONE PERSON'S POLICY, not a fact about Claude Code. They come
# from one particular subscription and one particular way of working. Copy the shape,
# change the thresholds. A policy shipped as if it were a truth is how somebody ends
# up making a decision that was never theirs.
#
# What it is for: an unattended job — a nightly agent, a batch of tasks, a runner that
# decides whether to start one more piece of work — has no way of reading the quota.
# Claude Code hands those numbers to the status line and nowhere else. The status line
# writes them down, this reads them back, and your job asks this before it starts.
#
#   ./spend-guard.sh && start_one_more_job
#
# Exit status: 0 go ahead, 1 stop, 2 no trustworthy reading (treat as stop).
set -u

READER="${PACEKEEPER_QUOTA:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/pacekeeper-quota}"

# --- the policy, and the only part you should be editing --------------------
#
# On any day but the last, keep going until today's balance has gone 7 points into
# debt — a little borrowing is fine, it gets repaid by the days that follow.
NORMAL_FLOOR="-7.0"
#
# On the LAST day of the window the rule inverts: quota not spent by the reset is
# quota thrown away, so keep going almost to the end and stop just short of zero.
LAST_DAY_FLOOR="0.3"
# ---------------------------------------------------------------------------

command -v "$READER" >/dev/null 2>&1 || [ -x "$READER" ] || {
    echo "STOP  pacekeeper-quota not found at $READER"
    exit 2
}

reading=$("$READER" --json) || { echo "STOP  $reading"; exit 2; }

# Pulled out with a plain shell parse so this example needs nothing but bash.
get() { printf '%s' "$reading" | sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p"; }
day=$(get day)
days=$(get days)
balance=$(get balance)
used=$(get used_pct)

# THE LAST DAY IS `days`, NOT 7. This is the whole reason the reader reports `days`:
# when the weekly counter restarts mid-window, the last day arrives early. A guard
# that waits for day 7 in a two-day window never applies its last-day rule at all,
# and keeps spending on the one day when the rule mattered most.
if [ "$day" -ge "$days" ]; then
    floor="$LAST_DAY_FLOOR"
    label="last day ($day/$days), floor at ${floor}%"
else
    floor="$NORMAL_FLOOR"
    label="day $day/$days, floor at ${floor}%"
fi

# LC_ALL=C so awk prints and compares decimals with a dot, whatever the locale is.
# Without it, on an Italian machine, "0,3" and "0.3" stop comparing as numbers and the
# guard answers at random. This is not hypothetical; it was measured.
go=$(LC_ALL=C awk -v b="$balance" -v f="$floor" 'BEGIN{ print (b > f) ? 1 : 0 }')

if [ "$go" = "1" ]; then
    echo "GO    $label · balance ${balance}% · ${used}% of the week used"
    exit 0
fi
echo "STOP  $label · balance ${balance}% has reached the floor · ${used}% of the week used"
exit 1
