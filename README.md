# ——pacekeeper-->

**A status line for Claude Code that tells you whether you are ahead of or behind your pace.**

Every status line shows you how much quota you have burned. `42% used` is a fact, and it is
useless on its own — it does not tell you whether 42% on a Tuesday is comfortable or reckless.
`——pacekeeper-->` answers the question you are actually asking:

```
7d g3/7 left 58% · resets in 4d 6h (today still 8.1%)
```

Read it as: *you are on day 3 of a 7-day window, you have 58% left, and after today's share you
can still spend 8.1% before you start eating into the days that come after.* When that number
goes red, you are borrowing from tomorrow.

```
 pacekeeper   main*  ██████░░░░ 62%  cache ⬤  47m  ⛭ 2/3 · 4/9  [Opus 5] [high]
  5h left 78% · resets in 1h 12m   │   7d g3/7 left 58% · resets in 4d 6h (today still 8.1%)   │   plan Max 5x · billed in 12d   │   bmad 7-4 ⏵ 47m (dev)
```

---

## Why another status line

There are good ones already, and most of them are prettier. This one exists because it survives
the four situations where a plain percentage quietly lies to you.

### 1. It reports your pace, not your total

The daily balance (`today still 8.1%` / `today over by 3.2%`) divides what is left by the days
that are actually left, and compares it to what you have already spent. It answers *"have I been
working too much or too little so far?"* — not *"how hard could I still push?"*

**It is a heuristic, and it is worth being honest about what kind.** It applies one policy — spend
the window evenly across the days it has left — to one number. Anthropic does not publish a daily
allowance, so this is not a measurement of what you are permitted to spend; it is a pace you have
chosen to hold yourself to, made visible. It knows nothing about the five-hour cap running
alongside it, about how much a given piece of work is worth doing, or about anything happening
server-side. Read it as a speedometer, never as a permit.

### 2. It survives a counter reset in the middle of a window

The weekly counter sometimes drops to zero without the weekly deadline moving. A naive display
then shows `0% used` and lets you spend as if you had seven days, when you may have two.

*These are observations, not documented behaviour.* Measured on one account on 2026-09-01 and
2026-09-03, on Claude Code 2.1.259: once when a new model shipped, once at a billing renewal that
coincided with a plan change. Anthropic documents none of this, the two causes were not separated,
and it may not generalise. The code treats a drop of ten points or more as a restart, which is a
guess about a cause from an effect — and a deliberately conservative one, since believing in a
restart that did not happen shortens the window rather than lengthening it.

`——pacekeeper-->` notices the restart, remembers when it happened, and says so:

```
7d g1/2 left 100% · resets in 1d 14h (today still 50.0%)
     ↑
     the denominator turns orange: your 100% has to last
     2 days, not 7. Today's share is 50%, not 14%.
```

The colour is the emphasis; the number is the information. Pipe the line into a file, or read it
without seeing colour, and `/2` still tells you everything you need.

This is measured behaviour, not a theory. It fired twice in one week.

### 3. It arbitrates between your open sessions

Claude Code hands the usage numbers to the status line process of *each* session, on stdin. Ten
open windows means ten processes writing the same shared file — and a window that has been idle
for two days keeps rewriting its stale snapshot over the live one, with a fresh timestamp on it.

The failure is silent and it errs the permissive way: the brake reads a low number and lets you
through. `——pacekeeper-->` ranks snapshots by the fields an idle writer cannot fake — the five-hour
deadline and the weekly one — and declines to write when it cannot show it is the fresher one. In
practice that is what stops a window left open since yesterday from speaking for today.

**What it does NOT do, stated plainly, because the difference matters.** The payload carries no
observation timestamp, so two snapshots sharing a five-hour deadline cannot be ordered at all;
inside that window the rule assumes consumption only rises, which is true except in the minutes
after a mid-window counter reset.

The concurrent race is fixed — the comparison is locked — but **the ordering ambiguity is not, and
a lock cannot fix it**: serialising two writers does not tell you which of their snapshots was
observed first. This is a mitigation, not a guarantee, and it cannot become one without a field the
input does not carry. It is why the published file carries `ts`, and why `pacekeeper-quota` refuses a reading
older than five minutes rather than trusting the arbitration to have been right.

### 4. It reads the cache TTL instead of assuming it

The prompt cache TTL is not a constant: 5 minutes by default, 1 hour when Claude Code asks for
it, back to 5 minutes if your account goes into overage. Every turn that writes to the cache
declares which one it used, in `usage.cache_creation`. `——pacekeeper-->` reads that field, so the
countdown is right on your account rather than right on someone else's.

It also counts from the **start** of the request, not the end — generation time is time already
spent — so the countdown never promises minutes you do not have.

---

## What can appear on the line

Nothing here is mandatory. **Every block disappears on its own when it has nothing to say**, so
what you see depends on what you actually use. Blocks that need a tool you do not have installed
never render at all.

### Line 1 — this window

| Block | Looks like | When it appears |
|---|---|---|
| **Folder** | `pacekeeper` | always |
| **Git** | ` main*+ ↑2 ↓1` | inside a git repository |
| **Context** | `██████░░░░ 62%` | once the conversation has a measurable size |
| **Cache** | `cache ⬤  47m` / `cache ◌` | when the transcript is readable |
| **Plan register** | `⛭ 2/3 · 4/9` | when a long-running plan file exists |
| **Model** | `[Opus 5]` | always |
| **Effort** | `[high]` | when a reasoning effort level is set |
| **Session cost** | `≈$0.42` | **API users only** — hidden on subscriptions, where it would be a fiction |

**Git.** `*` means tracked changes, `+` means untracked files, `↑N` commits you have not pushed,
`↓N` commits you have not pulled. The branch is green when the tree is clean and orange when it
is not. Uses Nerd Font glyphs, so without one of those fonts you will see two placeholder boxes
where the icons are. Cached for a few seconds, because `git status` on a large repository is not
free — which means it can be a few seconds behind reality.

**Context.** A ten-block bar plus the percentage. This is the one number people mistake for
progress: it is how full *this conversation* is, and it has nothing to do with how much
subscription you have left.

**Cache.** `⬤` with a countdown means the prompt cache for this session is still warm: picking
the conversation back up costs a fraction. `◌` means it has gone cold and the next turn re-buys
the whole context at full price. It turns orange in the last quarter of an hour. While you are
working it stays green on its own — every read refreshes the timer for free — so it is a
*resume-or-wait* signal, not a stopwatch on your thinking.

**Plan register.** For long jobs whose real memory is a `PLAN.md` (or `PIANO.md`) file rather
than the conversation. `2/3 · 4/9` reads: **4 of 9 tasks done across the whole plan**, and you are
in piece 3, where 2 of its tasks are done. The total comes first because it is the number people
say out loud. It reads both markdown table rows and `- [x]` checklists, and it
fades out ten minutes after the plan is complete instead of sitting there forever.

**Session cost.** A theoretical pay-per-use figure summed from the transcript at list API prices.
It is deliberately **hidden for Claude.ai subscribers**, because for them it does not correspond to
any money that changes hands and would be actively misleading. It also disappears when the
transcript contains a model whose price it does not know: a hard-coded table goes stale every time
a model ships, and a cost that is quietly wrong is worse than no cost at all.

### Line 2 — this account

| Block | Looks like | When it appears |
|---|---|---|
| **5-hour window** | `5h left 78% · resets in 1h 12m` | on a Claude.ai subscription |
| **7-day window** | `7d g3/7 left 58% · resets in 4d 6h (today still 8.1%)` | on a Claude.ai subscription |
| **Plan & billing** | `plan Max 5x · billed in 12d` | plan always; the countdown once you configure the date |
| **bmad-loop run** | `bmad 7-4 ⏵ 47m (dev)` | only if `bmad-loop` is installed and a run is alive |

**The two windows.** Both percentages are *remaining*, not used, so bigger is always better and
the colour never contradicts the number. Green above 25% left, orange below, red below 10%.

**The daily balance** in brackets is the heart of the thing: `today still 8.1%` is what you can
still spend before you start borrowing, and `today over by 3.2%` in red is how much you have
already borrowed. The "day" runs from one reset to the next — 08:00 to 08:00, whatever your
account's hour is — not from midnight, because that is the boundary Anthropic actually enforces.

**Plan & billing.** The plan name is read from your account profile, not typed in by hand, so it
follows an upgrade or a downgrade on its own. The billing countdown is the one thing Claude Code
does not expose, so it is the one thing you configure — and the installer walks you through
finding it, including the exact prompt to hand to Claude Code so it can look it up for you.

The countdown knows the *instant*, not just the day: a subscription that renewed at 15:41 stops
saying "today" at 15:41, not at midnight.

**bmad-loop.** For users of [bmad-loop](https://pypi.org/project/bmad-loop/), the unattended
story-runner. It shows the live run — never the finished ones, which would occupy the line
forever — with the state as a symbol when things are fine and as a word when they are not:

| | |
|---|---|
| `bmad 7-4 ⏵ 47m (dev)` | running, 47 minutes in, currently in the dev phase — green |
| `bmad 7-4 ⏸ PAUSED: budget (review)` | paused, and **why**, and **where** — orange |
| `bmad 7-4 ⏵ 47m · stop after story` | a graceful stop is pending; it will finish this story first |
| `bmad 7-4 ⏵ 47m · 2 deferred` | two review findings have been set aside |
| `bmad 7-4 ✖ CRASH` | died on an error — red, and stays visible for 24 hours |
| `bmad 7-4 ✖ INTERRUPTED` | the state file says alive, but nothing is running it any more |

A run you stopped yourself stays silent: you already know.

It reads `--json`, which bmad-loop documents as its stable machine-readable contract, and it
handles the fact that `list` and `status` do not use the same vocabulary for the same run.

---

## It is also a sensor, not just a display

> **Treat this part as experimental.** It is useful, it is what the author uses daily, and it has
> been hardened against every failure found so far — but it is unlocked shell code writing plain
> files, read by whatever you point at it. Build a report on it; think hard before building
> something that spends money on it unsupervised.

Claude Code passes the usage numbers to the status line **and nowhere else**. Anything else on
your machine that wants to know how much quota is left — a nightly agent, a spend guard, a script
that decides whether to start one more job — has no way to find out.

So `——pacekeeper-->` writes what it learns to disk, atomically:

| File | What is in it |
|---|---|
| `~/.claude/quota-state` | `day_idx`, `balance`, `over`, `week_used_pct`, `week_days`, `ts` |
| `~/.claude/rate-limits.json` | the freshest snapshot across all your open sessions |
| `~/.claude/rate-limits.d/<session>.json` | one file per session, so a conflict stays diagnosable |
| `~/.claude/context-usage/<session>.json` | context fill per session |

**This is off unless you ask for it.** The installer asks, and the default answer is no: those
files carry paths, session identifiers and usage figures, and nothing writes any of them until you
say yes. The config file and the shared quota file are written with `0600`.

Everything is created private to you (`0600`, inside `0700` directories).

**On the word "atomic", precisely.** Every file other tools read is written to a per-process
temporary name and renamed into place, so a reader never sees half of one. The shared file's whole
read-compare-write is taken under a lock (an atomic `mkdir`), so two status lines redrawing in the
same instant cannot both decide they are the fresher one. A lock left behind by a killed process is
taken over after a minute rather than waited for: this guards a status line, and one that stalls is
worse than one that occasionally skips a sample.

### Reading those numbers without getting them wrong

Do not parse `quota-state` by hand. It looks trivial and it has two traps that only show
themselves once they have cost you something — both of them measured, both of them on the author's
own machine, both of them written by someone who knew exactly how the file worked:

> **1. `week_days` is not always 7.** It is how many days your remaining 100% actually has to
> cover. After a mid-window reset that can be 2. A reader with 7 hardcoded computes a daily
> allowance three times too generous, and errs on the side of letting you spend.
>
> **2. `ts` has to be compared with the clock.** Nothing writes the file while every session is
> idle, so it can legitimately be old. A stale number read as current is the whole failure.

So the installer also puts down a reader that handles both:

```bash
$ pacekeeper-quota
day 1/2 · 2% of the week used · still 48.0% today · read 1s ago

$ pacekeeper-quota --json
{"ok":true,"day":1,"days":2,"used_pct":2,"balance":48.0,"over":false,"age_s":1}
```

Exit status is `0` for a trustworthy reading and `2` for none — missing, incomplete or stale. It
deliberately has **no** exit status for "you have spent too much": what counts as too much is a
policy, and a policy belongs to you. [`examples/spend-guard.sh`](examples/spend-guard.sh) is one
written out in full, with its thresholds marked as the one part you should be editing.

Note that `balance` leaves the reader **already signed** — positive still spendable, negative
already borrowed. On disk it is stored unsigned with a separate `over` flag, which is one more
invitation to a bug that you do not need to accept.

---

## Install

```bash
git clone https://github.com/Polloinfilzato/pacekeeper.git
cd pacekeeper
./install.sh
```

Or, without cloning — note the **version tag**, not a branch, so what you install is something
that was actually tried rather than whatever was pushed a minute ago:

```bash
curl -fsSL https://raw.githubusercontent.com/Polloinfilzato/pacekeeper/v1.0.0/install.sh | bash
```

The questions still work through a pipe: they are read from your terminal, not from standard
input. But cloning is listed first on purpose — this is a script that edits your Claude Code
configuration, and being able to read it before running it should not cost you anything.

The installer asks four short questions, patches `~/.claude/settings.json`, and puts four files
into `~/.claude`: the status line, its two helpers, and `pacekeeper-quota`.

```bash
./install.sh --yes        # take every default, ask nothing
./install.sh --uninstall  # put the machine back the way it was before the first install
./install.sh --restore    # list every backup with its date and pick one
```

**Nothing is overwritten without a backup**, named `<file>.pacekeeper-<date>-<time>.bak` next to
the original, and a backup is never overwritten either — not even by another backup taken in the
same second. If you already have a status line, it says so, shows you what it is, and asks before
replacing it. A symlink in place of any file it would touch stops the install rather than being
written through.

Each install also writes a **manifest** under `~/.claude/.pacekeeper/`, recording which files
existed beforehand. That is what makes uninstall honest: a backup file can say *what a file used to
contain*, but only the manifest can say *this file did not exist at all* — so `--uninstall` puts
back what was yours and removes what was ours, including the runtime state written since. Undoing
is itself undoable: whatever was in place a moment ago is backed up first.

### Requirements

| | |
|---|---|
| **Claude Code** | built and tested against 2.1.259 |
| **bash** | 3.2+ — the bash macOS already ships is enough |
| **jq**, **python3** | required |
| **git** | optional; the git block hides without it |
| **A Nerd Font** | optional; only the git icons need it |

**Tested on macOS only.** The shell is written to be portable and the one BSD-specific call is
guarded with a GNU fallback, but nobody has run this on Linux yet — so treat Linux as unverified
rather than supported, and please report what happens.

**It depends on fields Anthropic does not document.** The whole thing is built on the JSON Claude
Code hands to a status line command, whose shape is not part of any published contract. Every
block degrades to silence when a field it wants is missing, which is the only guarantee that can
honestly be offered: an update could take any of these numbers away without warning.

---

## Configuration

Everything lives in `~/.claude/subscription.conf`, which the installer writes for you.

```ini
RENEWAL_DAY=3          # monthly renewal, the 3rd of each month
RENEWAL_TIME=15:41     # local time of the charge — optional, but it makes "today" precise
# RENEWAL=2027-03-14   # or a fixed date, with PERIOD=yearly if it recurs
# TIER=Max 5x          # override the plan name; normally it is read from your account
```

### Finding your renewal date and time

**The date** is on your Claude.ai billing page: *Settings → Billing*. It shows the next renewal.

**The time** is not shown anywhere in the UI. On the account this was built against, the timestamp
on the **receipt email** has matched the charge time on every cycle — so that is where to look:
search your mail for `Claude` and `receipt`. That is an observation from one account, not a
documented guarantee; if the countdown flips at the wrong hour, this is the number to correct.

**Or let Claude Code find it for you.** The installer offers this, and you can also just paste
this into any Claude Code session:

```
Find my Claude.ai subscription renewal date and time. Check my most recent
Stripe receipt emails for Anthropic — the timestamp on the receipt is the
charge time. Then write RENEWAL_DAY and RENEWAL_TIME into
~/.claude/subscription.conf in HH:MM local time.
```

Without `RENEWAL_TIME` everything still works; the countdown just says "today" for the whole day
instead of switching over at the exact hour.

---

## Design notes

A few rules the code follows, in case you want to change it.

**When a number could be wrong in two directions, be wrong on the strict side.** A quota display
that errs high releases the brake; one that errs low costs you a little work. Every fallback in
here — an unreadable cache TTL, a missing snapshot, a window that cannot be dated — resolves to
the conservative answer.

**Never show a placeholder where a value should be.** A block with nothing to say removes itself.
`pid ?` and `unknown` in a status line are worse than silence, because they get read as data.

**Pay for what changed, not for what might have.** The status line runs every few seconds. Git is
cached for seconds, the plan name for hours, the billing countdown until the moment it can change,
and the cache expiry until the transcript file is touched. What is left is shell arithmetic.

**The comments are the documentation.** Most of them record an actual defect, with the date it was
measured. They are long on purpose.

---

## About the name

The wordmark is `——pacekeeper-->`: a shaft on the left, an arrowhead on the right, and the word
run straight through the middle. It is **skewered**.

That is a small joke in Italian, and it is the author's: the GitHub handle `polloinfilzato` reads
*pollo* + *infilzato* — a skewered chicken. `——` + `-->` is the same skewer, drawn in ASCII.

The repository itself is plain `pacekeeper`, because a directory called `--pacekeeper` breaks the
first command anyone runs on it:

```
$ rm -r --pacekeeper
rm: illegal option -- -
```

## License

MIT. See [LICENSE](LICENSE).
