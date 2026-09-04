#!/bin/bash
# ——pacekeeper--> · a status line for Claude Code
# What can show up on it:
#   - the model in use
#   - directory : session name (when it has been renamed)
#   - branch in green (RGB) when clean, orange when there are changes
#   - up-arrow n for unpushed commits, down-arrow n for commits to pull
#   - * for local modifications, + for untracked files
#   - a context bar with its percentage (from the JSON)
#   - progress of the plan in flight (gear, tasks done/total, current piece). It hides
#     itself 10 minutes after the plan is complete (CC_PLAN_DONE_FADE_MIN, 0 = never), and
#     can be limited to certain folders by writing `**Scope:** /path` in the preamble of
#     the register. The register may be called PIANO.md or PLAN.md and be written in
#     Italian or English: names, labels and states are recognised in both languages, with
#     or without backticks and bold. Details in the comment above that block.
#   - session cost (API users only, above $0.01)

input=$(cat)

# Every field needed in ONE single call to jq (this used to be 10 separate processes):
# the script is re-run constantly, so every fork is paid for.
# One field per line, read with separate reads: do NOT use @tsv + IFS=tab, because bash
# treats a tab as whitespace and collapses consecutive separators, sliding the values
# left when a field in the middle is empty (an API user with no rate_limits, say).
{
    read -r cwd
    read -r model
    read -r transcript_path
    read -r ctx_pct
    read -r five_pct
    read -r week_pct
    read -r five_reset
    read -r week_reset
    read -r effort_level
} <<EOF
$(echo "$input" | jq -r '
    (.workspace.current_dir // ""),
    (.model.display_name // ""),
    (.transcript_path // ""),
    (.context_window.used_percentage // 0),
    (.rate_limits.five_hour.used_percentage // .rate_limits.fiveHour.usedPercentage // .rateLimits.fiveHour.usedPercentage // ""),
    (.rate_limits.seven_day.used_percentage // .rate_limits.sevenDay.usedPercentage // .rateLimits.sevenDay.usedPercentage // ""),
    (.rate_limits.five_hour.resets_at // .rate_limits.fiveHour.resetsAt // .rateLimits.fiveHour.resetsAt // ""),
    (.rate_limits.seven_day.resets_at // .rate_limits.sevenDay.resetsAt // .rateLimits.sevenDay.resetsAt // ""),
    (.effort.level // "")
' 2>/dev/null)
EOF

[ -z "$cwd" ] && cwd="$PWD"
[ -z "$ctx_pct" ] && ctx_pct=0

# THE JSON IS INPUT, NOT A PROMISE. These values end up inside `$(( ))` and inside awk.
# A field that is not a plain number turns arithmetic into an error printed on the line:
# `"resets_at": "1/0"` produces a division-by-zero message. Anything that is not a bare
# integer, or a bare decimal for the percentages, is dropped - and a dropped field simply
# hides its block, which is the behaviour every other failure here already has.
# `0[0-9]*` is rejected too: shell arithmetic reads a leading zero as octal, so "08"
# produces "value too great for base" printed on the status line. And a lone "." passes
# a naive digits-or-dot test while being no number at all.
# Extended patterns, for the one substitution that strips colour escapes when measuring
# how wide a block is on screen. It only ADDS syntax; every plain glob in here keeps
# meaning what it meant.
shopt -s extglob

pk_int()  { case "$1" in ''|*[!0-9]*|0?*) return 1 ;; *) return 0 ;; esac; }
pk_pct()  {
    # `0?*` was meant to catch a leading zero like "08", but it also matches "0.5" - so
    # every percentage below one was thrown away and its whole block vanished from the
    # line. Found on the fourth review, and my own tests missed it because I only tried
    # to break this function, never to feed it a small valid number.
    case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac
    case "$1" in 0[0-9]*) return 1 ;; esac
    case "${1%%.*}" in ''|*[!0-9]*) return 1 ;; esac
    # NOT `-le 100`. Claude Code computes this field as `utilization * 100` with no clamp,
    # so it goes ABOVE 100 the moment a limit is exceeded - the binary's own documentation
    # of the sibling `spend_limit` field says so in as many words: "0-100, above 100 once
    # exceeded". Rejecting 101 threw away the whole five-hour block AT THE ONE MOMENT it is
    # worth reading, when you are blocked and want to know when it lifts. Reported by the
    # user on 2026-09-04 and reproduced here: at 101 the block vanished, countdown included.
    # A ceiling stays, because a percentage in the thousands is a broken field, not usage.
    [ "${1%%.*}" -le 1000 ] 2>/dev/null || return 1
    return 0
}
# An unbounded reset instant is accepted by the grammar and then produces a countdown of
# nonsense - "resets in 5000000d". Anything further out than a year is not a deadline
# this program can be looking at, so it is dropped like any other unusable field.
pk_reset() {
    pk_int "$1" || return 1
    [ "$1" -lt 4102444800 ] 2>/dev/null || return 1   # beyond 2100: not a real deadline
    return 0
}
pk_reset "$five_reset" || five_reset=""
pk_reset "$week_reset" || week_reset=""
pk_int "$ctx_pct"    || ctx_pct=0
[ "$ctx_pct" -le 100 ] 2>/dev/null || ctx_pct=100
pk_pct "$five_pct"   || five_pct=""
pk_pct "$week_pct"   || week_pct=""
dir=${cwd##*/}

# Session name from the transcript
session_name=""
if [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ] && [ -f "$transcript_path" ]; then
    session_name=$(grep '"type":"custom-title"' "$transcript_path" 2>/dev/null | jq -r '.customTitle // empty' 2>/dev/null | tail -1)
fi

# Colours
GREEN=$'\033[32m'
ORANGE=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'
RED=$'\033[31m'
RESET=$'\033[0m'
GIT_GREEN=$'\033[38;2;0;200;0m'
GIT_ORANGE=$'\033[38;2;255;165;0m'

# --- Git ---
# The git commands are the slowest part of this script (on a large repository they are
# worth over 150ms on their own) and the state of a repository does not change from one
# instant to the next, so the result is cached on file for a few seconds, one per workdir.
# BSD and GNU `stat` do not share a syntax, and the difference is not a clean failure:
# GNU `stat -f` SUCCEEDS while reporting filesystem data instead of a timestamp, so a
# `bsd || gnu` fallback never reaches the fallback and feeds nonsense into arithmetic.
# The flavour is decided once, by asking for something only GNU accepts.
# Everything this script creates is private to its owner. Set once, at the top, rather
# than chmod-ing each file afterwards: a chmod after the write leaves a window in which
# the file is readable, and one forgotten call is enough to undo the whole intention.
# It covers the temporary files and the directories too.
umask 077

# Values that arrive from outside and end up inside a JSON string. Interpolating a path
# that contains a quote or a backslash produces something that is not JSON, and the
# caller reads that as our data being wrong rather than our formatting.
pk_json_escape() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//$'\n'/ }
    v=${v//$'\t'/ }
    printf '%s' "$v"
}

PK_STAT=""
pk_mtime() {
    if [ -z "$PK_STAT" ]; then
        if stat -c %Y / >/dev/null 2>&1; then PK_STAT=gnu; else PK_STAT=bsd; fi
    fi
    if [ "$PK_STAT" = gnu ]; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

GIT_CACHE_TTL=6
# The user id in the name: on Linux TMPDIR is often unset and everything lands in /tmp,
# which belongs to everybody. Two users on the same machine would fight over the same
# caches (plan, renewal, git) and would see each other's data. On macOS TMPDIR is already
# per user, but the suffix costs nothing and makes it true everywhere.
cache_dir="${TMPDIR:-/tmp}/cc-statusline-cache-$(id -u 2>/dev/null || echo 0)"

# --- User configuration ---
# One file, read once, with a `sed` over a handful of lines: cheaper than a read per key
# scattered through the script. Every key is optional - with no file at all the script
# behaves exactly as it did before, which is the requirement for handing it to anyone.
#   UI_LANG=it|en|auto   language of the labels (auto = from the locale)
#   PUBLISH_STATE=yes|no write the quota numbers to file for other tools
#   DISABLE=a,b,c        blocks to switch off: git,cache,plan,bmad,cost
# OFF unless the config says exactly `yes`. It used to default to "yes", with only the
# installer writing "no" - so anyone who copied this file by hand published their paths,
# session ids and usage figures without being asked. The default has to be the safe one:
# the installer is not the only way this file ends up on a machine.
PK_PUBLISH="no"; PK_DISABLE=""
_pk_conf="$HOME/.claude/subscription.conf"
if [ -f "$_pk_conf" ]; then
    while IFS='=' read -r _pk_k _pk_v; do
        case "$_pk_k" in
            UI_LANG)       [ -z "${CC_STATUSLINE_LANG:-}" ] && [ "$_pk_v" != auto ] && CC_STATUSLINE_LANG=$_pk_v ;;
            PUBLISH_STATE) [ "$_pk_v" = yes ] && PK_PUBLISH=yes ;;
            DISABLE)       PK_DISABLE=$_pk_v ;;
        esac
    done <<EOF
$(sed -nE 's/^[[:space:]]*(UI_LANG|PUBLISH_STATE|DISABLE)[[:space:]]*=[[:space:]]*([^#]*)$/\1=\2/p' "$_pk_conf" 2>/dev/null | sed 's/[[:space:]]*$//')
EOF
fi
# True when the block being asked about has been switched off by the user.
pk_off() { case ",${PK_DISABLE}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# --- Language ---
# Italian when the locale says so, English in every other case (including a missing or
# unknown locale): the script has to be handed to anyone without them touching it first.
# CC_STATUSLINE_LANG=it|en overrides, to try the other language without changing the env.
case "${CC_STATUSLINE_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    it|it_*|it.*|*_IT*) LANG_IT=1 ;;
    *)                  LANG_IT=0 ;;
esac
if [ "$LANG_IT" = 1 ]; then
    T_LEFT="resta";        T_RESETS="si azzera tra";  T_STILL="oggi ancora"
    T_OVER="oggi oltre di"; T_SUB="abbonamento";      T_BILL="addebito"
    T_TODAY="oggi";        T_TOMORROW="domani";       T_IN="tra"
    T_DAY="g"
    T_DECSEP=","
    T_PAUSED="IN PAUSA";   T_STOPPED="FERMATA";   T_CRASH="CRASH"
    T_INTERRUPTED="INTERROTTA"; T_UNKNOWN="STATO IGNOTO"
    T_DEFERRED="rinviati";  T_GRACEFUL="stop a fine storia"
    T_CACHE="cache"
else
    T_LEFT="left";         T_RESETS="resets in";      T_STILL="today still"
    T_OVER="today over by"; T_SUB="plan";             T_BILL="billed"
    T_TODAY="today";       T_TOMORROW="tomorrow";     T_IN="in"
    T_DAY="d"
    T_DECSEP="."
    T_PAUSED="PAUSED";     T_STOPPED="STOPPED";   T_CRASH="CRASH"
    T_INTERRUPTED="INTERRUPTED"; T_UNKNOWN="UNKNOWN STATE"
    T_DEFERRED="deferred";  T_GRACEFUL="stop after story"
    T_CACHE="cache"
fi
# Key = the working path made safe for a filename. CAREFUL: in bash ${var: -N} on a
# string shorter than N returns the EMPTY string (zsh returns the whole thing instead):
# using that form, every short path ended up in the same cache file, and different
# sessions overwrote each other's branch.
cache_key=${cwd//\//_}
cache_key=${cache_key//[^A-Za-z0-9._-]/_}
if [ ${#cache_key} -gt 100 ]; then
    cache_key="${#cwd}_${cache_key:$(( ${#cache_key} - 90 ))}"
fi
git_cache="${cache_dir}/git${cache_key}"

# ONLY valid results are cached: an empty or truncated file must never be mistaken for
# "there is no repository here", or the branch would vanish from the line for as long as
# the cache lives.
git_info=""
git_cached=false
if [ -s "$git_cache" ]; then
    cache_age=$(( $(date +%s) - $(pk_mtime "$git_cache") ))
    if [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$GIT_CACHE_TTL" ]; then
        cached_val=$(cat "$git_cache" 2>/dev/null)
        if [ -n "$cached_val" ]; then
            git_cached=true
            [ "$cached_val" = "NOGIT" ] || git_info="$cached_val"
        fi
    fi
fi

if ! pk_off git && [ "$git_cached" = false ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    # --show-current prints an empty line (without failing) when HEAD is detached:
    # during a rebase, say, or after checking out a tag. Without this check the branch
    # name would disappear from the status line.
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
        branch="detached${branch:+ $branch}"
    fi

    has_changes=false
    has_untracked=false

    if ! git -C "$cwd" diff --quiet 2>/dev/null || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi
    if [ -n "$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null)" ]; then
        has_untracked=true
    fi

    if [ "$has_changes" = true ] || [ "$has_untracked" = true ]; then
        branch_color="$GIT_ORANGE"
    else
        branch_color="$GIT_GREEN"
    fi

    changes=""
    [ "$has_changes" = true ] && changes="*"
    [ "$has_untracked" = true ] && changes="${changes}+"

    ahead=$(git -C "$cwd" rev-list @{u}..HEAD 2>/dev/null | wc -l | tr -d " ")
    unpushed=""
    if [ "$ahead" -gt 0 ] 2>/dev/null; then
        unpushed=" ${CYAN}↑$ahead${RESET}"
    fi

    behind=$(git -C "$cwd" rev-list HEAD..@{u} 2>/dev/null | wc -l | tr -d " ")
    unpulled=""
    if [ "$behind" -gt 0 ] 2>/dev/null; then
        unpulled=" ${RED}↓$behind${RESET}"
    fi

    # There used to be a branch here choosing a different icon for GitHub remotes. Both
    # arms assigned the SAME codepoint (U+F09B), so it never distinguished anything -
    # dead code that the README then described as a feature. Removed 2026-09-03 rather
    # than guessing a second glyph nobody has seen rendered.
    repo_icon=""
    branch_icon=""

    git_info=" ${repo_icon} ${branch_icon} ${branch_color}${branch}${changes}${RESET}${unpushed}${unpulled}"
fi

# Atomic write (another session might read the same file in the same instant). The "not a
# repository" case is stored as an explicit NOGIT marker, never as an empty string, so it
# cannot be confused with a write that went wrong.
if [ "$git_cached" = false ]; then
    mkdir -p "$cache_dir" 2>/dev/null
    tmp_cache="${git_cache}.$$"
    trap 'rm -f "$tmp_cache" 2>/dev/null' EXIT INT TERM
    { printf '%s' "${git_info:-NOGIT}" > "$tmp_cache" &&
        mv -f "$tmp_cache" "$git_cache"; } 2>/dev/null
fi

# --- Safety net for a vanishing branch ---
# It only fires in the genuinely anomalous case: the directory IS a git repository but the
# line is about to go out without a branch. It recovers the value on the spot and leaves a
# written trace, so a return of the defect is documented instead of reproduced from memory.
# Only emptiness coming FROM THE CACHE is checked: if the emptiness comes from a check
# just made, we already know there is no repository here, and repeating the check would
# only be one more process on every refresh.
if [ -z "$git_info" ] && [ "$git_cached" = true ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    fallback_branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    [ -z "$fallback_branch" ] && fallback_branch="detached"
    git_info="  ${GIT_GREEN}${fallback_branch}${RESET}"

    # A debug log used to be written here, recording the working path and the branch
    # to a file that grew forever, with no gate and nobody asking for it. It existed to
    # catch a defect that has not recurred since it was fixed. Removed 2026-09-03: a
    # diagnostic that outlives its bug is just a log of where its user has been.
fi

# --- Directory ---
dir_display="${BLUE}${dir}${RESET}"

# --- Context window (uses used_percentage from the JSON) ---
context_info=""

if [ "$ctx_pct" -gt 0 ] 2>/dev/null; then
    # The bar itself (10 blocks)
    filled=$((ctx_pct / 10))
    empty=$((10 - filled))
    bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    # Colour from the percentage
    if [ "$ctx_pct" -ge 58 ]; then
        ctx_color="$RED"
    elif [ "$ctx_pct" -ge 38 ]; then
        ctx_color="$ORANGE"
    else
        ctx_color="$GIT_GREEN"
    fi

    context_info=" ${ctx_color}${bar} ${ctx_pct}%${RESET}"
fi

# --- Rate limits (Claude.ai subscribers only, visible after the first answer) ---
# The presence of these fields marks a subscription user (Pro/Max), NOT pay-per-use API.
# used_percentage is the quota consumed against the plan; at 100 or above the user may have
# entered overage (extra pay-as-you-go credits), which is the closest thing to "real spend"
# available in the hook JSON (there is no field with the overage amount in dollars).
rate_info=""

is_subscriber=false
if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
    is_subscriber=true
fi

# --- Persisting the rate limits, for other tools (not for the bar) ---
# Claude Code passes these values to THIS process only, on stdin: nobody else sees them.
# A tool that has to decide "can I start a run with the quota that is left?" therefore has no
# way to read them. We write them to a known, stable file: no fork (printf builtin plus a
# redirect), so it does not weigh on a script re-run every few seconds.
# We write ONLY when the data is really there: a file with empty fields would be worse than no
# file at all, because a tool would read it as "zero quota" rather than "I do not know".
#
# TWO SESSIONS WERE OVERWRITING EACH OTHER - measured 2026-08-20, 9 samples out of 20 (45%).
# The comment on the twin block below (per-session context) had already diagnosed this exact
# failure and fixed it, but this block had been left as a single shared file on the grounds that
# "the quota belongs to the account, not to the session". True of the QUOTA, false of the DATA:
# what arrives on stdin is the snapshot taken at THIS session's last answer. A session left open
# and idle for days keeps rewriting its old snapshot over the live one, and since `stamp` is reset
# to "now" on every write, stale data presents itself as fresh: measured a 5-hour window that had
# reset 4.17 DAYS earlier, reporting 38% consumed against a true 72%. The error ALWAYS goes the
# permissive way -> the quota brake lets you through.
#
# The writing rule, with no fork (builtins only), so the cost stays at zero:
#   the shared file is written only if our snapshot is AT LEAST AS FRESH as the one on disk.
#   The yardstick is NOT `stamp` (always "now" for whoever writes) but `five_hour_resets_at`,
#   which only moves when a session actually receives a new answer. Within the same window the
#   HIGHER consumption wins, because inside a window the quota can only go up.
# The per-session file is ALWAYS written, so a conflict stays diagnosable after the fact.
#
# WHAT THIS RULE CANNOT DO, said plainly, because a reader will otherwise assume more.
# The payload carries no observation timestamp and no sequence number, so two snapshots
# that share a five-hour deadline cannot be ordered at all. Inside that one window the
# rule assumes consumption only rises - true except immediately after a mid-window
# counter reset, where the newer snapshot is the LOWER one and loses. That case is not
# solvable from this data. It is why the published file carries `ts`, and why every
# reader is expected to reject a reading older than its own tolerance rather than trust
# the arbitration to have been right.
# Everything below writes into ~/.claude. If that directory is missing or not writable -
# an unusable HOME, a full disk, a read-only mount - a redirection towards it is reported
# by the SHELL ITSELF, before the command's own `2>/dev/null` can suppress anything, and
# four "Not a directory" lines end up printed inside the status line. Measured 2026-09-03
# by running with HOME=/dev/null. A status line that prints errors is a status line that
# gets uninstalled, so writability is established once, here, and nothing is attempted
# when it fails.
PK_CAN_WRITE=no
if [ -d "$HOME/.claude" ] && [ -w "$HOME/.claude" ]; then
    PK_CAN_WRITE=yes
fi

if [ "$is_subscriber" = true ] && [ "$PK_CAN_WRITE" = yes ]; then
    _rl_now=$(date +%s)
    _rl_sid=""
    if [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ]; then
        _rl_sid=${transcript_path##*/}; _rl_sid=${_rl_sid%.jsonl}
    fi
    _rl_payload=$(printf '{"stamp":%s,"five_hour_used_pct":"%s","seven_day_used_pct":"%s","five_hour_resets_at":"%s","seven_day_resets_at":"%s","session_id":"%s"}' \
        "$_rl_now" "$five_pct" "$week_pct" "$five_reset" "$week_reset" "$(pk_json_escape "$_rl_sid")")

    # 1. the per-session file: unconditional among the writers, but still gated by the
    # user's answer. Everything under this heading is DATA PUBLISHED FOR OTHER TOOLS -
    # paths, session ids and usage figures - and it is off unless somebody asked for it.
    # The first version gated only `quota-state`, so answering "no" still left these on
    # disk; the README even claimed nothing was written. Measured 2026-09-03.
    if [ "$PK_PUBLISH" != no ] && [ -n "$_rl_sid" ]; then
        _rl_dir="$HOME/.claude/rate-limits.d"
        [ -d "$_rl_dir" ] || mkdir -p "$_rl_dir" 2>/dev/null
        { printf '%s\n' "$_rl_payload" > "$_rl_dir/$_rl_sid.json.$$" \
            && mv -f "$_rl_dir/$_rl_sid.json.$$" "$_rl_dir/$_rl_sid.json"; } 2>/dev/null
    fi

    # 2. the shared file, the one tools read: only if we are the freshest.
    #
    # THE WHOLE READ-COMPARE-WRITE IS TAKEN UNDER A LOCK. `mkdir` is the one filesystem
    # operation that is atomic everywhere and needs no extra tool: it either creates the
    # directory or fails, and only one caller can win. Without it two redraws landing
    # together both compare themselves against the same old value, both conclude they are
    # fresher, and the loser writes last.
    # A lock does NOT fix the ordering ambiguity documented above - that needs a field the
    # payload does not carry - and saying otherwise would be the comfortable lie. It fixes
    # the race, which is a different and cheaper problem.
    # A lock left behind by a killed process would block every future write, so one older
    # than a minute is taken over rather than waited for: this guards a status line, and a
    # status line that stalls is worse than one that occasionally loses a sample.
    # THE LOCK CARRIES A TOKEN, and a holder releases only its own. Without that, the
    # takeover rule eats itself: a process paused for a minute has its lock removed, a
    # second process takes it, and when the first wakes up its unconditional release
    # deletes the SECOND one's lock - leaving the file unprotected precisely during the
    # window the lock existed for. The token makes release conditional on still owning it.
    _rl_lock="$HOME/.claude/.rate-limits.lock"
    _rl_token="$$-$_rl_now"
    _rl_locked=no
    if mkdir "$_rl_lock" 2>/dev/null; then
        { printf '%s\n' "$_rl_token" > "$_rl_lock/owner"; } 2>/dev/null
        _rl_locked=yes
    elif [ -d "$_rl_lock" ]; then
        # A lock left behind by a killed process must not block a status line forever.
        # Sixty seconds is far longer than any redraw and far shorter than a session.
        _rl_lock_age=$(( _rl_now - $(pk_mtime "$_rl_lock") ))
        if [ "$_rl_lock_age" -gt 60 ] 2>/dev/null; then
            # Taking over goes through a RENAME, which is atomic: only one process can
            # succeed in moving the stale directory aside, so nobody can delete a lock
            # that somebody else took in the meantime. Removing it in place left a gap
            # between "I saw it was old" and "I removed it" - long enough for another
            # process to acquire a fresh one and have it deleted underneath.
            _rl_dead="$_rl_lock.dead.$$"
            if mv "$_rl_lock" "$_rl_dead" 2>/dev/null; then
                rm -rf "$_rl_dead" 2>/dev/null || true
            fi
            if mkdir "$_rl_lock" 2>/dev/null; then
                { printf '%s\n' "$_rl_token" > "$_rl_lock/owner"; } 2>/dev/null
                _rl_locked=yes
            fi
        fi
    fi
    # Releases the lock, but only if it is still ours.
    pk_unlock() {
        local held=""
        [ "$_rl_locked" = yes ] || return 0
        [ -r "$_rl_lock/owner" ] && read -r held < "$_rl_lock/owner" 2>/dev/null
        if [ "$held" = "$_rl_token" ]; then
            rm -f "$_rl_lock/owner" 2>/dev/null || true
            rmdir "$_rl_lock" 2>/dev/null || true
        fi
        _rl_locked=no
    }
    _rl_write=yes
    _rl_old=""; _rl_o7p=""; _rl_o7r=""; _rl_o5=""
    _rl_fresh=no          # la nostra fotografia e' almeno fresca quanto quella su disco?
    _wp_int=${week_pct%%.*}                    # il server manda anche "14.000000000000002"
    [ -f "$HOME/.claude/rate-limits.json" ] &&
        { read -r _rl_old < "$HOME/.claude/rate-limits.json" 2>/dev/null || _rl_old=""; }
    if [ -n "$_rl_old" ] && [ "${_rl_old#*\"five_hour_resets_at\":\"}" != "$_rl_old" ]; then
        _rl_o5=${_rl_old#*\"five_hour_resets_at\":\"}; _rl_o5=${_rl_o5%%\"*}
        _rl_o7p=${_rl_old#*\"seven_day_used_pct\":\"}; _rl_o7p=${_rl_o7p%%\"*}
        _rl_o7p=${_rl_o7p%%.*}
        _rl_o7r=${_rl_old#*\"seven_day_resets_at\":\"}; _rl_o7r=${_rl_o7r%%\"*}
        # A shared file whose window has already expired has no say: anyone replaces it.
        if [ "$_rl_o5" -gt "$_rl_now" ] 2>/dev/null; then
            # A snapshot WITHOUT `five_hour_resets_at` is not comparable, and has to be treated
            # as the oldest, not the freshest. Measured 2026-09-03 at 12:49: some sessions
            # (agents, secondary panes) receive a JSON where that field is empty; `[ "" -lt N ]`
            # fails, the error is suppressed, and the "no" branch was never taken -> the stale
            # sample won. Here the direction is explicit: you win by proving you are fresh, not
            # by failing the comparison.
            # A snapshot from an OLDER WEEKLY WINDOW must never win, whatever its
            # five-hour deadline says. This was not checked at all, and it is a real
            # hole: the weekly reset and the five-hour reset move independently.
            if [ -n "$_rl_o7r" ] && [ -n "$week_reset" ] \
               && [ "$week_reset" -lt "$_rl_o7r" ] 2>/dev/null; then
                _rl_write=no
            elif ! [ "$five_reset" -ge "$_rl_o5" ] 2>/dev/null; then
                _rl_write=no                       # field missing, or an earlier window
            elif [ "$five_reset" -eq "$_rl_o5" ] 2>/dev/null \
                 && [ "$_wp_int" -lt "$_rl_o7p" ] 2>/dev/null; then
                _rl_write=no                       # stessa finestra, ma qualcuno ha visto consumare di piu'
            else
                _rl_fresh=yes
            fi
        else
            _rl_fresh=yes                          # aggregato scaduto: la nostra vale comunque di piu'
        fi
    else
        _rl_fresh=yes                              # nessun aggregato: siamo i primi
    fi
    if [ "$_rl_write" = yes ] && [ "$PK_PUBLISH" != no ] && [ "$_rl_locked" = yes ]; then
        { printf '%s\n' "$_rl_payload" > "$HOME/.claude/rate-limits.json.$$" \
            && mv -f "$HOME/.claude/rate-limits.json.$$" "$HOME/.claude/rate-limits.json"; } 2>/dev/null
    fi
    # Released as soon as the shared file is settled. Everything after this point either
    # writes a per-session file or a file derived from what was just decided.
    _rl_took_lock=$_rl_locked

    # --- WHERE THE WEEKLY COUNTER REALLY STARTED ---
    # The 7-day window and the counter that fills it can have two DIFFERENT origins.
    # Measured 2026-09-01 at 21:13: when Fable 5.1 shipped, the counter jumped from 36% to 1%
    # while `seven_day_resets_at` stayed pinned to Saturday 5 Sep 08:00. Anyone assuming the
    # 100% spreads over 7 days ends up spreading it over three and a half, and the daily balance
    # comes out too generous -> the error goes the PERMISSIVE way, exactly as with freshness
    # above: the quota brake lets you through.
    # So we keep track of the instant the counter really restarted:
    #   - new window (`seven_day_resets_at` changed) -> origin = nominal start, reset - 7d
    #   - same window but the counter DROPPED by 10 points or more -> restart: origin = now
    # The drop is only judged when our snapshot has already won the freshness comparison above
    # (`_rl_write=yes`): a stale sample from another session sees lower numbers and would
    # trigger a restart that never happened.
    # Also only under the lock. A process that lost the comparison was still writing this
    # derived file, and a snapshot that was never good enough to publish is not good
    # enough to change what the next window is measured against.
    if [ "$_rl_write" = yes ] && [ "$_rl_fresh" = yes ] && [ "$_rl_locked" = yes ] \
       && [ -n "$week_reset" ] && [ "$week_reset" != "null" ] && [ -n "$_wp_int" ]; then
        _qo_origin=""; _qo_line=""; _qo_seen=""
        [ -f "$HOME/.claude/quota-origin" ] &&
            { read -r _qo_line < "$HOME/.claude/quota-origin" 2>/dev/null || _qo_line=""; }
        if [ -n "$_qo_line" ] && [ "${_qo_line#*\"week_reset\":}" != "$_qo_line" ]; then
            _qo_w=${_qo_line#*\"week_reset\":}; _qo_w=${_qo_w%%,*}
            _qo_t=${_qo_line#*\"origin_ts\":}; _qo_t=${_qo_t%%,*}
            _qo_s=${_qo_line#*\"seen_pct\":\"}; _qo_s=${_qo_s%%\"*}; _qo_s=${_qo_s%%.*}
            if [ "$_qo_w" = "$week_reset" ]; then
                _qo_origin=$_qo_t
                _qo_seen=$_qo_s
            fi
        fi
        # WHICH EARLIER READING THE DROP IS JUDGED AGAINST.
        # The shared snapshot first, because it is arbitrated for freshness across every open
        # session. But `rate-limits.json` is only written when PUBLISH_STATE=yes (see the
        # publish guard above), so with publication off `$_rl_o7p` is empty on EVERY redraw and
        # the drop could never be seen at all: the headline feature - noticing a counter that
        # restarted mid-window - was silently off for anyone who answered "no" to the install
        # question, which is the default answer. Measured 2026-09-03: two renders, 40% then 2%,
        # same `seven_day_resets_at`. With publication on: `d1/4 ... today still 23.0%`. With it
        # off: `d4/7 ... today still 55.1%` - the window still believed to be seven days long,
        # and the daily balance more than twice what it should be. It errs the PERMISSIVE way,
        # which is the one direction this program says it will never err in.
        # So fall back to `seen_pct`, the reading THIS machine wrote last: it is already in
        # quota-origin, already tied to a `week_reset` that has just been checked to match, and
        # it discloses nothing new - which is what makes it usable while publication is off.
        # HONEST ABOUT THE LIMIT: with publication off there is no freshness arbitration, so an
        # idle session can write a high `seen_pct` after a live one wrote a low one, and the next
        # render then reads a drop that never happened. That mistake SHORTENS the window and
        # tightens the daily share, which is the conservative direction - the same trade the
        # ten-point threshold already accepts.
        _qo_prev=""
        if [ -n "$_rl_o7p" ] && [ "$_rl_o7r" = "$week_reset" ]; then
            _qo_prev=$_rl_o7p
        elif [ -n "$_qo_seen" ]; then
            _qo_prev=$_qo_seen
        fi
        if [ -z "$_qo_origin" ]; then
            _qo_origin=$(( week_reset - 604800 ))          # finestra nuova: origine nominale
        elif [ -n "$_qo_prev" ] && [ $(( _qo_prev - _wp_int )) -ge 10 ] 2>/dev/null; then
            _qo_origin=$_rl_now                            # ripartenza a meta' finestra
        fi
        # Per-process temporary name: two redraws landing together must not share one.
        { printf '{"origin_ts":%s,"week_reset":%s,"seen_pct":"%s","stamp":%s}\n' \
            "$_qo_origin" "$week_reset" "$_wp_int" "$_rl_now" \
            > "$HOME/.claude/quota-origin.tmp.$$" \
            && mv -f "$HOME/.claude/quota-origin.tmp.$$" "$HOME/.claude/quota-origin"; } 2>/dev/null
    fi

    # THE LOCK IS RELEASED HERE, at the end of the whole shared-state transaction, and
    # not one line earlier. Releasing it before this block meant `quota-origin` demanded
    # a lock that had just been given up, so it was NEVER written and every shortened
    # window silently reverted to looking like seven days - the one thing this program
    # exists to notice. Found on the fifth review; the parallel test that came before it
    # checked the shared file and never looked at this one.
    pk_unlock
fi

# --- Persisting CONTEXT SATURATION, per session ---
# Same reason as the rate limits: Claude Code passes `context_window.used_percentage` to THIS
# process only, on stdin. A guard that has to decide "can I start another agent with the context
# that is left?" has no other way of knowing.
# UNLIKE the rate limits, context is PER SESSION, not per account: two open sessions mean two
# status lines writing, and a single shared file would be overwritten back and forth, giving each
# of them the other one's number. So we write one file per session, keyed on the id inside the
# transcript filename.
# We write ONLY when the data is really there: a file with 0 in it would be read as "empty
# context" rather than "I do not know", and that is exactly the wrong way round to be wrong.
if [ "$PK_PUBLISH" != no ] && [ "$PK_CAN_WRITE" = yes ] && [ -n "$transcript_path" ] \
   && [ "$transcript_path" != "null" ] && [ "$ctx_pct" -gt 0 ] 2>/dev/null; then
    _cu_dir="$HOME/.claude/context-usage"
    [ -d "$_cu_dir" ] || mkdir -p "$_cu_dir" 2>/dev/null
    _cu_sid=${transcript_path##*/}; _cu_sid=${_cu_sid%.jsonl}
    { printf '{"stamp":%s,"session_id":"%s","used_pct":%s,"transcript":"%s"}\n' \
        "$(date +%s)" "$(pk_json_escape "$_cu_sid")" "$ctx_pct" "$(pk_json_escape "$transcript_path")" \
        > "$_cu_dir/$_cu_sid.json.$$" \
        && mv -f "$_cu_dir/$_cu_sid.json.$$" "$_cu_dir/$_cu_sid.json"; } 2>/dev/null
fi

# The reset times (Unix timestamps) come from the single read at the top of the script.
# Current time and local midnight in the SAME call to date: they are needed by the billing
# countdown, and taking them separately would cost one more fork on every refresh.
IFS=' ' read -r now _h_now _m_now _s_now <<< "$(date '+%s %H %M %S')"
# 10# forces base ten: "08" and "09" do not exist in octal and would break the arithmetic.
midnight_ts=$(( now - (10#$_h_now * 3600 + 10#$_m_now * 60 + 10#$_s_now) ))

# Format seconds -> "3h 12m", or "12m"
fmt_hm() {
    local s=$1 h m
    [ "$s" -lt 0 ] && s=0
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ] && [ "$m" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
    elif [ "$h" -gt 0 ]; then printf '%dh' "$h"
    else printf '%dm' "$m"; fi
}

# Format seconds -> "4d 6h", or hours and minutes when less than a day is left
fmt_dh() {
    local s=$1 d h
    [ "$s" -lt 0 ] && s=0
    d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 ))
    if [ "$d" -gt 0 ]; then printf '%d%s %dh' "$d" "$T_DAY" "$h"; else fmt_hm "$s"; fi
}

# Turn the colour code (R/O/G) into the matching ANSI sequence
pick_color() {
    case "$1" in
        R) printf '%s' "$RED" ;;
        O) printf '%s' "$ORANGE" ;;
        *) printf '%s' "$GIT_GREEN" ;;
    esac
}

# The 5-hour block
# THE COUNTDOWN DOES NOT DEPEND ON THE PERCENTAGE, and that is the whole point of the
# shape of this block. The two facts arrive in the same payload but they fail apart: a
# percentage this program cannot read used to take the reset time down with it, so the
# line went silent precisely when the answer it was hiding - "how long until it lifts" -
# was the only one being asked. Whatever is readable is drawn.
five_block=""
if [ -n "$five_pct" ]; then
    # A single awk for the remaining percentage plus the colour code
    IFS=' ' read -r five_left five_col <<EOF
$(awk -v p="$five_pct" 'BEGIN{ v=100-p; if (v<0) v=0; printf "%.0f %s", v, (v<=10?"R":(v<=25?"O":"G")) }')
EOF
    fc=$(pick_color "$five_col")
    five_block="${GRAY}5h ${fc}${T_LEFT} ${five_left}%${GRAY}"
fi
if [ -n "$five_reset" ] && [ "$five_reset" != "null" ]; then
    if [ -n "$five_block" ]; then
        five_block="${five_block} · ${T_RESETS} $(fmt_hm $(( five_reset - now )))"
    else
        five_block="${GRAY}5h ${T_RESETS} $(fmt_hm $(( five_reset - now )))"
    fi
fi

# The 7-day block, plus the sustainable daily pace
week_block=""
if [ -n "$week_pct" ]; then
    has_wreset=false
    week_rem=-1
    if [ -n "$week_reset" ] && [ "$week_reset" != "null" ]; then
        week_rem=$(( week_reset - now ))
        # A window whose deadline has passed says nothing about a pace: the counter is
        # about to be replaced by a new one and the day index would read 0/7, a value
        # that then got published and accepted by readers as if it meant something.
        # Better to show the remaining percentage alone until a fresh window arrives.
        if [ "$week_rem" -gt 0 ]; then
            has_wreset=true
        fi
    fi

    # How many days the 100% in hand REALLY has to cover. Normally 7, but after a mid-window
    # restart of the counter (see "WHERE THE WEEKLY COUNTER REALLY STARTED" above) it is fewer:
    # the counter is at zero and the deadline is not. With no file, fall back to 7.
    week_span=604800
    if [ -f "$HOME/.claude/quota-origin" ]; then
        read -r _qc_line < "$HOME/.claude/quota-origin" 2>/dev/null || _qc_line=""
        if [ -n "$_qc_line" ] && [ "${_qc_line#*\"week_reset\":}" != "$_qc_line" ]; then
            _qc_w=${_qc_line#*\"week_reset\":}; _qc_w=${_qc_w%%,*}
            _qc_t=${_qc_line#*\"origin_ts\":}; _qc_t=${_qc_t%%,*}
            if [ "$_qc_w" = "$week_reset" ] && [ "$_qc_t" -gt 0 ] 2>/dev/null; then
                week_span=$(( week_reset - _qc_t ))
                [ "$week_span" -lt 3600 ] && week_span=3600
                [ "$week_span" -gt 604800 ] && week_span=604800
            fi
        fi
    fi

    # --- Every weekly-window calculation in one awk ---
    # LC_ALL=C, not LC_NUMERIC=C: if the environment exports LC_ALL (it_IT.UTF-8 here) that
    # wins over LC_NUMERIC, and `printf "%.1f"` produces "7,0" instead of "7.0". The separator
    # substitution further down would find no dot at all and the comma would survive even in
    # English. Measured 2026-09-03.
    # The balance for the current "CC day": the day does not run midnight to midnight but from
    # one reset to the next (08:00 -> 08:00, say), because that is the boundary Claude Code
    # actually enforces. Daily share: 100/G, where G is the number of days the 100% really has
    # to cover (7 normally, fewer after a restart).
    # Cumulative budget spendable by the end of today without eating into the quota of the full
    # days that come after today:
    #     allowed = 100 - (100/G) * (full days after today)
    # Balance = allowed - consumed:
    #     positive -> percentage still available today
    #     negative -> how much has already been borrowed (repaid by the days that follow)
    IFS=' ' read -r week_left week_col day_idx balance over week_days <<EOF
$(LC_ALL=C awk -v p="$week_pct" -v s="$week_rem" -v span="$week_span" -v dsep="$T_DECSEP" 'BEGIN{
    v = 100 - p; if (v < 0) v = 0;
    col = (v <= 10 ? "R" : (v <= 25 ? "O" : "G"));
    if (s < 0) { printf "%.0f %s 0 0 0 7", v, col; exit }
    g = span / 86400;
    G = int(g); if (g > G) G++;           # giorni che il 100% deve coprire, per eccesso
    if (G < 1) G = 1; if (G > 7) G = 7;
    d = s / 86400;
    n = int(d); if (d > n) n++;           # whole days left before the reset, rounded up
    # AT THE EXACT INSTANT OF THE RESET s is 0, so n is 0 and `G - n + 1` produced day
    # 8 of 7 - a number that cannot exist, and that the spend guard reads. A window with
    # no time left in it is the LAST day, not one past it. Measured 2026-09-03.
    if (n < 1) n = 1;
    if (n > G) n = G;
    idx = G - n + 1; if (idx < 1) idx = 1; if (idx > G) idx = G;
    after = n - 1; if (after < 0) after = 0;   # giorni pieni dopo oggi
    bal = (100 - (100/G) * after) - p;
    txt = sprintf("%.1f", (bal < 0 ? -bal : bal)); sub(/\./, dsep, txt);
    printf "%.0f %s %d %s %d %d", v, col, idx, txt, (bal < 0 ? 1 : 0), G
}')
EOF
    wc_=$(pick_color "$week_col")

    # Exposes the 7-day numbers to whoever does NOT receive the status line JSON
    # (unattended sessions, which have to respect its spending ceiling).
    # Atomic write: a reader must never be able to see a half-written file.
    # ONLY if our snapshot won the freshness comparison above. Without this condition every
    # open session rewrote its own numbers here on every redraw, including one that had been
    # idle for hours, and since `ts` is reset to "now" the stale data presented itself as
    # fresh. Measured 2026-09-03 at 19:10: the spend guard read 66% (the value from before
    # the 15:41 reset) while the live number was 2%, and it blocked good work. It is the same
    # disease already cured for `rate-limits.json` on 2026-08-20: the cure had never been
    # extended to the file the guard actually reads. Here it errs in BOTH directions, so
    # "err on the strict side" is not enough: when nobody is fresh the file simply stays
    # behind and carries its `ts`, which the reader already checks (MAX_AGE) - an admittedly
    # old file beats one that lies.
    if [ "$has_wreset" = true ] && [ "$PK_PUBLISH" != no ] \
       && [ "${_rl_write:-no}" = yes ] && [ "${_rl_fresh:-no}" = yes ] \
       && [ "${_rl_took_lock:-no}" = yes ]; then
        { printf 'day_idx=%s\nbalance=%s\nover=%s\nweek_used_pct=%s\nweek_days=%s\nts=%s\n' \
            "$day_idx" "${balance//,/.}" "$over" "$week_pct" "${week_days:-7}" "$now" \
            > "$HOME/.claude/quota-state.tmp.$$" \
            && mv -f "$HOME/.claude/quota-state.tmp.$$" "$HOME/.claude/quota-state"; } 2>/dev/null
    fi

    week_block="${GRAY}7d"
    if [ "$has_wreset" = true ]; then
        # The "/G" says how many days the 100% in hand really has to last: 7 normally, fewer
        # after a mid-window restart of the counter.
        # When the window is short, the anomaly is in the DENOMINATOR: it is the 2 where you
        # expect a 7. So that is what gets coloured. There used to be a symbol here that
        # explained WHY; it was removed on 2026-09-03 because nobody can decode it - and the
        # proof is that the person who asked for it read it as an absurdity. Colouring the
        # slash alone is not enough either: a coloured separator on an already colourful line
        # reads as decoration.
        # And the colour is the EMPHASIS, never the information: someone who cannot tell the
        # colours apart, or who pipes the line into a file, still reads "/2" and knows
        # everything they need to know.
        if [ "${week_days:-7}" -lt 7 ] 2>/dev/null; then
            week_block="${week_block} ${CYAN}${T_DAY}${day_idx}${ORANGE}/${week_days}${GRAY}"
        else
            week_block="${week_block} ${CYAN}${T_DAY}${day_idx}/7${GRAY}"
        fi
    fi
    week_block="${week_block} ${wc_}${T_LEFT} ${week_left}%${GRAY}"
    if [ "$has_wreset" = true ]; then
        # "resets", not "renews": on this line it lives next to the BILLING countdown, and
        # two similar words for two different clocks is exactly how one gets mistaken for the
        # other. This is about usage limits, never about money.
        week_block="${week_block} · ${T_RESETS} $(fmt_dh $week_rem)"
        if [ "$over" = "1" ]; then
            week_block="${week_block} ${RED}(${T_OVER} ${balance}%)${GRAY}"
        else
            week_block="${week_block} ${GIT_GREEN}(${T_STILL} ${balance}%)${GRAY}"
        fi
    fi
fi

# --- The bmad-loop run block ---
# It appears ONLY when there is something to look at: a live run, or one that recently died
# badly. Finished and stopped runs stay in the listing forever, so showing them would occupy
# the line forever.
# The real work is done by ~/.claude/statusline-bmad.py, which documents bmad-loop's TWO state
# vocabularies: list and status do NOT use the same words for the same run.
# Cost: a 60s cache when there is nothing, 30s when a run is alive.
bmad_block=""
if ! pk_off bmad && command -v bmad-loop >/dev/null 2>&1 && [ -f "$HOME/.claude/statusline-bmad.py" ]; then
    _bm_key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
    _bm_cache="${cache_dir}/bmad-${_bm_key}"
    _bm_payload=""
    _bm_fresh=""
    if [ -f "$_bm_cache" ]; then
        IFS= read -r _bm_until < "$_bm_cache" 2>/dev/null
        if [ -n "$_bm_until" ] && [ "$now" -lt "$_bm_until" ] 2>/dev/null; then
            _bm_payload=$(tail -n +2 "$_bm_cache" 2>/dev/null)
            _bm_fresh=yes
        fi
    fi
    if [ -z "$_bm_fresh" ]; then
        _bm_payload=$(python3 "$HOME/.claude/statusline-bmad.py" "$cwd" 2>/dev/null)
        [ -z "$_bm_payload" ] && _bm_payload="NONE"
        if [ "$_bm_payload" = "NONE" ]; then _bm_ttl=60; else _bm_ttl=30; fi
        mkdir -p "$cache_dir" 2>/dev/null
        _bm_tmp="${_bm_cache}.$$"
        { printf '%s
' "$(( now + _bm_ttl ))"; printf '%s
' "$_bm_payload"; } > "$_bm_tmp" 2>/dev/null &&
            mv -f "$_bm_tmp" "$_bm_cache" 2>/dev/null
    fi

    if [ -n "$_bm_payload" ] && [ "$_bm_payload" != "NONE" ]; then
        IFS=$'' read -r _bm_status _bm_story _bm_phase _bm_elapsed _bm_reason _bm_grace _bm_defer <<< "$_bm_payload"
        case "$_bm_status" in
            running|in-progress)
                _bm_body="${GIT_GREEN}⏵${GRAY} $(fmt_hm "${_bm_elapsed:-0}")"
                [ -n "$_bm_phase" ] && _bm_body="${_bm_body} (${_bm_phase})"
                [ "$_bm_grace" = "1" ] && _bm_body="${_bm_body} · ${T_GRACEFUL}"
                ;;
            paused)
                _bm_body="${ORANGE}⏸ ${T_PAUSED}${GRAY}"
                [ -n "$_bm_reason" ] && _bm_body="${_bm_body}: ${_bm_reason}"
                [ -n "$_bm_phase" ] && _bm_body="${_bm_body} (${_bm_phase})"
                ;;
            crashed)     _bm_body="${RED}✖ ${T_CRASH}${GRAY}" ;;
            interrupted) _bm_body="${RED}✖ ${T_INTERRUPTED}${GRAY}" ;;
            *)           _bm_body="${ORANGE}✖ ${T_UNKNOWN}${GRAY}" ;;
        esac
        [ "${_bm_defer:-0}" -gt 0 ] 2>/dev/null && _bm_body="${_bm_body} · ${_bm_defer} ${T_DEFERRED}"
        bmad_block="${GRAY}bmad ${CYAN}${_bm_story}${GRAY} ${_bm_body}"
    fi
fi

# The subscription renewal block.
# The date is NOT exposed by Claude Code: it goes by hand into ~/.claude/subscription.conf
#   RENEWAL_DAY=14           -> monthly renewal, the 14th of each month
#   RENEWAL=2027-03-14       -> a fixed date (add PERIOD=yearly if it recurs annually)
renew_block=""
renew_conf="$HOME/.claude/subscription.conf"
renew_days=""
renew_hhmm=""
renew_cache="${cache_dir}/renew"

# The number of days changes once a day: caching it until midnight avoids starting python3
# on every refresh of the status line.
if [ -f "$renew_cache" ] && [ ! "$renew_conf" -nt "$renew_cache" ]; then
    IFS=' ' read -r cached_until cached_days cached_time < "$renew_cache" 2>/dev/null
    if [ -n "$cached_until" ] && [ "$now" -lt "$cached_until" ] 2>/dev/null; then
        renew_days="$cached_days"
        renew_hhmm="$cached_time"
    fi
fi

if [ -z "$renew_days" ] && [ -f "$renew_conf" ]; then
    # Two values in one go: the days to the charge, and how long that number stays valid.
    # The second is NOT always midnight: on renewal day the number changes at the INSTANT of
    # the charge, not at midnight. Measured 2026-09-03: charged at 15:41, and at 17:10 the
    # line still read "billed today, expected at 15:41" - future tense for something that had
    # already happened, on the one day of the year anybody looks at it.
    # The program goes in through a QUOTED heredoc, never `python3 -c "..."`. Inside a
    # double-quoted shell string every `"` in the Python - including the ones in its own
    # comments - closes the string, and whatever follows is word-split. Measured 2026-09-03:
    # a comment reading `"today" becomes "in 30 days"` cut the program at the spaces inside
    # `in 30 days`; python received a block that ended on `if target:` with nothing under it,
    # raised an IndentationError into a discarded stderr, and printed nothing. The countdown
    # to the charge disappeared from the status line with no error anywhere on the machine,
    # and only when the config file was next touched - the cached number was serving until
    # then. A quoted heredoc expands nothing, so no comment can ever do this again.
    renew_raw=$(python3 - "$renew_conf" 2>/dev/null <<'PY'
import calendar, datetime, sys

conf = {}
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            conf[k.strip().upper()] = v.strip()
except Exception:
    sys.exit()

now_dt = datetime.datetime.now()
today = now_dt.date()

# The time of the charge, when declared. It does two things: stops an already-completed
# charge from counting as "today", and expires the cache at the right instant.
hhmm = None
try:
    _h, _m = conf.get('RENEWAL_TIME', '').split(':')
    hhmm = datetime.time(int(_h), int(_m))
except Exception:
    hhmm = None

def instant(d):
    # With no declared time the charge counts for the whole day: midnight of the day AFTER,
    # so "today" stays "today" until the day ends, exactly as it behaved before.
    if hhmm is None:
        return datetime.datetime.combine(d + datetime.timedelta(days=1), datetime.time(0, 0))
    return datetime.datetime.combine(d, hhmm)

target = None

if conf.get('RENEWAL_DAY'):
    try:
        day = int(conf['RENEWAL_DAY'])
        y, m = today.year, today.month
        for _ in range(4):
            cand = datetime.date(y, m, min(day, calendar.monthrange(y, m)[1]))
            if instant(cand) > now_dt:
                target = cand
                break
            m += 1
            if m > 12:
                m, y = 1, y + 1
    except Exception:
        pass
elif conf.get('RENEWAL'):
    try:
        target = datetime.date.fromisoformat(conf['RENEWAL'])
        if instant(target) <= now_dt and conf.get('PERIOD', '').lower() == 'yearly':
            for yy in (today.year, today.year + 1):
                cand = target.replace(year=yy)
                if instant(cand) > now_dt:
                    target = cand
                    break
        if instant(target) <= now_dt:
            target = None
    except Exception:
        pass

if target:
    # The number is good until the next midnight, BUT on the day of the charge it expires at
    # the instant of the charge: that is where "today" becomes "in 30 days".
    midnight = datetime.datetime.combine(today + datetime.timedelta(days=1), datetime.time(0, 0))
    until = min(midnight, instant(target)) if target == today else midnight
    # The time goes back out as a THIRD field. Whoever draws the countdown must not parse
    # this file a second time: two parsers mean two grammars, and the shell one accepted
    # 99:99 - ninety-nine hours after midnight - while this one had already rejected it.
    print((target - today).days, int(until.timestamp()), hhmm.strftime('%H:%M') if hhmm else '-')
PY
)
    IFS=' ' read -r renew_days renew_until renew_hhmm <<EOF
$renew_raw
EOF

    if [ -n "$renew_days" ] && [ -n "$renew_until" ]; then
        mkdir -p "$cache_dir" 2>/dev/null
        tmp_renew="${renew_cache}.$$"
        printf '%s %s %s' "$renew_until" "$renew_days" "${renew_hhmm:--}" > "$tmp_renew" 2>/dev/null &&
            mv -f "$tmp_renew" "$renew_cache" 2>/dev/null
    fi
fi

# --- The active PLAN, which belongs next to the billing countdown ---
# "what I pay" and "how much I can work" are two different things, and the second depends on
# the TIER: the same percentage on Max 5x is worth a quarter of what it is on Max 20x. The
# real tier is written by Claude Code into ~/.claude.json when it refreshes the account
# profile; a TIER= line in subscription.conf overrides it, for when you already know what is
# about to change.
# Six-hour cache: the plan does not change between one refresh of the status line and the next.
tier_label=""
tier_cache="${cache_dir}/tier"
# The six-hour cache has to be broken when the SOURCE changes too, not only by the manual
# override. Measured 2026-09-03: the plan changed to Max 5x at 15:41, ~/.claude.json already
# said so, and the status line went on showing "Max 20x" because the cache had been written at
# 15:27 and stayed valid until 20:47. A wrong plan is not a cosmetic detail: the same
# percentage on Max 5x is worth a quarter. `-nt` costs one stat; the re-read (7 ms over 170 KB)
# only happens when the file has genuinely changed.
if [ -f "$tier_cache" ] && [ ! "$renew_conf" -nt "$tier_cache" ] \
   && [ ! "$HOME/.claude.json" -nt "$tier_cache" ]; then
    IFS=' ' read -r tier_until tier_label < "$tier_cache" 2>/dev/null
    [ -n "$tier_until" ] && [ "$now" -ge "$tier_until" ] 2>/dev/null && tier_label=""
fi
if [ -z "$tier_label" ]; then
    tier_raw=""
    [ -f "$renew_conf" ] && tier_raw=$(sed -n 's/^[[:space:]]*TIER[[:space:]]*=[[:space:]]*//p' "$renew_conf" 2>/dev/null | tail -1)
    if [ -z "$tier_raw" ] && [ -f "$HOME/.claude.json" ]; then
        # ~/.claude.json is written INDENTED: there is a space between the colon and the
        # value, and a `"key":"value"` pattern with no space never matches and never says so.
        tier_raw=$(sed -n 's/.*"organizationRateLimitTier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.claude.json" 2>/dev/null | head -1)
        case "$tier_raw" in
            *max_20x*) tier_raw="Max 20x" ;;
            *max_5x*)  tier_raw="Max 5x" ;;
            *pro*)     tier_raw="Pro" ;;
            *team*)    tier_raw="Team" ;;
            null|"")   tier_raw="" ;;
        esac
    fi
    if [ -n "$tier_raw" ]; then
        tier_label="$tier_raw"
        mkdir -p "$cache_dir" 2>/dev/null
        tmp_tier="${tier_cache}.$$"
        printf '%s %s' "$(( now + 21600 ))" "$tier_label" > "$tmp_tier" 2>/dev/null &&
            mv -f "$tmp_tier" "$tier_cache" 2>/dev/null
    fi
fi

# --- The BILLING countdown ---
# On renewal day "today" is not enough: the charge has a precise time (the anniversary of the
# instant the cycle was born, readable from the timestamp on the Stripe receipts), and knowing
# whether ten hours or twenty minutes are left changes what you do in the meantime.
# RENEWAL_TIME=HH:MM in subscription.conf. Without that line it behaves as it did before.
if [ -n "$renew_days" ] || [ -n "$tier_label" ]; then
    renew_when=""
    # The time arrives already validated, from the one parser that owns this file, and is
    # checked again here because a cache file can be hand-edited or left over from an older
    # version. The check is not politeness: an arithmetic expansion that fails does not just
    # skip its own line, it ABANDONS THE WHOLE ENCLOSING COMPOUND. Measured 2026-09-03 with
    # RENEWAL_TIME=ab:cd - `10#ab` printed a bash error onto the terminal and every line
    # after it inside this `if`, `renew_block` included, never ran: the plan and the charge
    # vanished from the status line together, and nothing said why.
    renew_time="$renew_hhmm"
    case "$renew_time" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *) renew_time="" ;;
    esac
    if [ -n "$renew_time" ] && [ "$renew_days" -le 1 ] 2>/dev/null; then
        _rt=$(( midnight_ts + renew_days * 86400 + 10#${renew_time%%:*} * 3600 + 10#${renew_time##*:} * 60 ))
        if [ "$_rt" -gt "$now" ]; then
            renew_when="${T_IN} $(fmt_dh $(( _rt - now )))"
        fi
    fi
    if [ -z "$renew_when" ] && [ -n "$renew_days" ]; then
        case "$renew_days" in
            0) renew_when="$T_TODAY" ;;
            1) renew_when="$T_TOMORROW" ;;
            *) renew_when="${T_IN} ${renew_days}${T_DAY}" ;;
        esac
    fi
    renew_block="${GRAY}${T_SUB}"
    [ -n "$tier_label" ] && renew_block="${renew_block} ${CYAN}${tier_label}${GRAY}"
    # With no renewal date configured the charge is not mentioned at all: better a block with
    # only the plan in it than the word "billed" followed by nothing.
    if [ -n "$renew_when" ]; then
        if [ "$renew_days" -le 1 ] 2>/dev/null; then
            renew_block="${renew_block} · ${T_BILL} ${GIT_GREEN}${renew_when}${GRAY}"
        else
            renew_block="${renew_block} · ${T_BILL} ${renew_when}"
        fi
    fi
fi

# Assembling line 2: whichever blocks exist, separated by a vertical bar - and folded onto
# further lines when the terminal is not wide enough to hold them.
#
# WHY IT HAS TO FOLD. Claude Code TRUNCATES a status line that overruns the width, it does
# not wrap it, so the blocks on the right simply stop existing. Reported on 2026-09-04 from
# a Mac whose owner keeps a large font: the subscription block was off the edge and nobody
# could have known it was there.
#
# A BLOCK IS NEVER SPLIT. It moves to the next line whole - half a countdown is worse than
# a second row.
#
# WHERE THE WIDTH COMES FROM. Not from the payload: there is no width field in it (checked
# against the JSON documentation inside the 2.1.260 binary). $COLUMNS is not exported to a
# hook either. The controlling terminal is the only source, and a process that has none
# folds NOTHING rather than guessing - the old single line is the fallback, so a machine
# where this cannot be asked behaves exactly as before.
pk_cols() {
    # $COLUMNS FIRST, and on Claude Code it is the answer: measured on 2026-09-04 by
    # recording what this function saw across four live sessions - 152, 195, 273, each the
    # real width of its own pane. So the common case costs nothing at all, no process.
    # `stty` stays as the fallback for whatever else ends up running this file.
    local c=""
    c=${COLUMNS:-}
    if [ -z "$c" ]; then
        c=$( { stty size < /dev/tty; } 2>/dev/null )
        c=${c##* }
    fi
    case "$c" in ''|*[!0-9]*) c="" ;; esac
    # Below about twenty columns there is no layout to speak of, and a bogus small number
    # would put every block on a line of its own.
    [ -n "$c" ] && [ "$c" -ge 20 ] 2>/dev/null || c=""
    printf '%s' "$c"
}

# The visible width of a block: the colour escapes are bytes on the wire and zero columns
# on the screen. `${#s}` counts CHARACTERS, not bytes, so the box-drawing bar and the
# accented labels count as the one column they occupy.
pk_visible() {
    local _s=${1//$'\033'\[*([0-9;])m/}
    printf '%s' "${#_s}"
}

sep="${GRAY}   │   "
_sep_w=7          # "   │   " on screen
_indent="  "
_cols=$(pk_cols)
rate_info=""; _cur=""; _cur_w=0
for blk in "$five_block" "$week_block" "$renew_block"; do
    [ -z "$blk" ] && continue
    _w=$(pk_visible "$blk")
    if [ -z "$_cur" ]; then
        _cur="${_indent}${blk}"; _cur_w=$(( ${#_indent} + _w ))
    elif [ -n "$_cols" ] && [ $(( _cur_w + _sep_w + _w )) -gt "$_cols" ]; then
        rate_info="${rate_info}${_cur}${RESET}
"
        _cur="${_indent}${blk}"; _cur_w=$(( ${#_indent} + _w ))
    else
        _cur="${_cur}${sep}${blk}"; _cur_w=$(( _cur_w + _sep_w + _w ))
    fi
done
[ -n "$_cur" ] && rate_info="${rate_info}${_cur}${RESET}"

# Assembling line 3: the bmad-loop run, on a line of its own.
# It used to ride at the end of line 2, after the two quota windows and the renewal
# countdown. Three blocks and two separators come first, so by the time the run gets its
# turn the text is past the width of an ordinary terminal: it wraps, or the terminal cuts
# it, and the one block that changes minute by minute is the one you cannot read. Its own
# line costs a row only while a run exists - with no run, `bmad_info` is empty and nothing
# is printed, exactly as before.
bmad_info=""
[ -n "$bmad_block" ] && bmad_info="  ${bmad_block}${RESET}"

# --- Session cost, computed from the transcript ---
# NOTE: this is a THEORETICAL "as-if pay-per-use" cost, summed from the transcript tokens at
# list API prices. For Claude.ai subscribers (Pro/Max) the figure does NOT correspond to money
# changing hands: requests included in the plan cost nothing, and the status line hook exposes
# no field carrying the real amount of any extra/overage credits consumed. For that reason,
# when a subscription is detected (rate_limits present), the theoretical cost is hidden rather
# than shown misleadingly; it stays visible only for a pure pay-per-use API key, where it
# really is what the session cost.
cost_info=""
if [ "$is_subscriber" = false ] && [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ] && [ -f "$transcript_path" ]; then
    # Quoted heredoc, for the reason written over the renewal block.
    cost=$(python3 - "$transcript_path" 2>/dev/null <<'PY' || echo "0"
import json, sys

PRICING = {
    'claude-opus-4-8':       {'in': 15.0,  'out': 75.0,  'cw': 18.75, 'cr': 1.50},
    'claude-opus-4-7':       {'in': 15.0,  'out': 75.0,  'cw': 18.75, 'cr': 1.50},
    'claude-sonnet-4-6':     {'in': 3.0,   'out': 15.0,  'cw': 3.75,  'cr': 0.30},
    'claude-sonnet-4-5':     {'in': 3.0,   'out': 15.0,  'cw': 3.75,  'cr': 0.30},
    'claude-haiku-4-5':      {'in': 0.80,  'out': 4.0,   'cw': 1.0,   'cr': 0.08},
    'claude-haiku-4-0':      {'in': 0.80,  'out': 4.0,   'cw': 1.0,   'cr': 0.08},
}
DEFAULT = {'in': 3.0, 'out': 15.0, 'cw': 3.75, 'cr': 0.30}

total = 0.0
unknown = False
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') != 'assistant':
                    continue
                msg = d.get('message', {})
                model = msg.get('model', '')
                usage = msg.get('usage', {})
                # An unknown model used to be priced as Sonnet, which understates a
                # more expensive one by multiples. A cost that is silently wrong is
                # worse than no cost at all, so an unrecognised model abandons the sum.
                # It has to abandon it from OUT HERE: raising inside the per-line try
                # was caught by the handler two lines down, so the unknown model was
                # merely skipped and the sum was printed anyway. Measured 2026-09-03:
                # one known message and one unpriced model showed $15.00 for a
                # transcript worth over a thousand - the exact failure the comment
                # above says is worse than printing nothing.
                p = next((v for k, v in PRICING.items() if k in model), None)
                if p is None:
                    unknown = True
                    break
                total += (
                    usage.get('input_tokens', 0) * p['in'] +
                    usage.get('output_tokens', 0) * p['out'] +
                    usage.get('cache_creation_input_tokens', 0) * p['cw'] +
                    usage.get('cache_read_input_tokens', 0) * p['cr']
                ) / 1_000_000
            except Exception:
                pass
except Exception:
    pass
if unknown:
    sys.exit()
print(f'{total:.4f}')
PY
)

    formatted=$(python3 - "$cost" 2>/dev/null <<'PY'
import sys
c = float(sys.argv[1])
if c > 0.0001:
    print(f'${c:.4f}' if c < 0.01 else f'${c:.2f}')
PY
)
    [ -n "$formatted" ] && cost_info=" ${GRAY}≈${formatted}${RESET}"
fi

# --- The plan-in-flight marker: "gear 2/3 · 4/9" ---
# WHY. A long job lives in a REGISTER on disk (`PLAN.md`), not in the conversation: whoever
# picks the work back up has to read that. But a file nobody looks at gets forgotten, so the
# register shows its face here: pieces closed over pieces total, and inside the current piece,
# tasks done over tasks total. Always in view, without having to ask for it.
#
# WHAT IT READS, and why in this particular way:
#   ~/.claude/plans/piani-in-corso/*/{PIANO.md,PLAN.md} — one file per folder, and when both
#   are present PIANO.md wins. Among those whose preamble declares the register OPEN, the LAST
#   one in alphabetical path order wins. Normally there is exactly ONE and the rule never shows
#   itself. If two were open at once the bar would still show only one - alphabetical order is
#   NOT chronological when the names carry different prefixes, so the place to see ALL the open
#   registers is a tool that lists them rather than picking one.
#
#   The numbers are ALREADY WRITTEN in the register (`## Piece 1 — Hygiene *(9/9)*`): that is
#   what gets read, the rows are not recounted. But recognising a piece does NOT depend on its
#   title, so renaming a piece breaks nothing: a `##` is a piece if it carries a `*(x/y)*`
#   counter OR if it has at least one task row underneath. And a task row is a table row in
#   which ONE WHOLE field, once spaces, backticks, bold and case are stripped, is a known state
#   - in Italian or in English (`fatto`/`done`/tick, `da fare`/`todo`, `in corso`/`in progress`,
#   `bloccato`/`blocked`, `parcheggiato`/`parked`, and more; the full list lives in the awk
#   functions isdone()/isopen()). A TICK LIST `- [x]` / `- [ ]` counts too, which is how a plan
#   gets written in English nine times out of ten.
#   The comparison stays on the WHOLE field, and that is where the safety is: a cell that
#   CONTAINS the word inside a sentence does not count. The column index is never looked at, so
#   reordering columns or adding a row moves nothing. If the piece has a counter the counter
#   wins; if it has none its rows are counted (the case of a piece just added, whose total
#   nobody has written yet).
#   A section heading with no counter and no task rows (something like "What NOT to do") is not
#   a piece and does not enter the count.
#
#   Current piece = the FIRST piece, in file order, not yet complete.
#
# IT FAILS SILENTLY, always. Register missing, malformed, plan closed, awk not understanding:
# the segment simply does not appear, and the bar prints exactly what it printed before.
# A status line that prints an error is a status line that gets switched off.
#
# IT TOUCHES NOTHING THIS SCRIPT WRITES. This bar is the only place some of that data exists,
# and other guards read it from there: `context-usage/<sid>.json`, `rate-limits.json` plus
# `rate-limits.d/`, and `quota-state`. This block is READ-ONLY on a fourth file, sits after all
# of those writes, and shares no variable with them.
#
# TWO FILTERS, added 2026-08-24: a register finished a day earlier went on occupying the bar in
# every session, including the ones that had nothing to do with that plan.
#
#   1) SCOPE (optional). If the register's preamble carries a line
#      `**Scope:** /path/one, /path/two` (or `**Ambito:**`), the segment appears ONLY when the
#      session's working directory sits inside one of those paths. Without that line nothing
#      changes: it shows up everywhere, as before.
#      WHY THE FOLDER AND NOT THE SESSION. The bar knows perfectly well which session it is in
#      - the identifier is the transcript filename, and this script already uses it twice
#      further up. But tying a register to a session does exactly the opposite of the intended
#      good: that identifier changes at every /clear, and the session that MUST see the
#      reminder is precisely the one that opens after the /clear. The folder, on the other
#      hand, stays.
#
#   2) FADING OUT ON COMPLETION. When the segment reads `complete`, the information has been
#      read and is no longer needed: after CC_PLAN_DONE_FADE_MIN minutes (10 by default; 0
#      disables it) it disappears. The moment of completion is NOT taken from the file's mtime:
#      a `chore: sync`, a `git checkout` or one retouched line of prose push that back to
#      today, and the segment would resurrect itself (measured 2026-08-24: a register sitting
#      at 31/31 for a day, with an mtime from nine minutes earlier). So a MARK is written the
#      first time the bar sees that plan complete, under ~/.claude/state/plan-fade/. The mark
#      is born with the mtime of that moment, so a plan that finished a day ago disappears at
#      once instead of granting itself another ten minutes; and if a task is reopened the mark
#      is deleted, so the countdown starts again at the next completion.
#      It is the only write this block performs, in a folder of its own that nobody else
#      reads: the four files listed above stay untouched.
plan_info=""
# The register may be called PIANO.md or PLAN.md. A plan written in English must not vanish
# from the bar because of the FILE NAME: that is exactly how the segment went silent on
# 2026-08-31 over an open, active plan, without raising any error.
# When a folder contains BOTH, PIANO.md wins, so the same plan is not counted twice and the
# result does not depend on the order of the glob.
_plan_files=()
for _pd in "$HOME"/.claude/plans/piani-in-corso/*/; do
    [ -d "$_pd" ] || continue
    for _pn in PIANO.md PLAN.md; do
        if [ -f "$_pd$_pn" ]; then _plan_files+=("$_pd$_pn"); break; fi
    done
done

# --- Filter 1: declared scope ---
if [ -e "${_plan_files[0]}" ]; then
    _plan_kept=()
    for _pf in "${_plan_files[@]}"; do
        [ -f "$_pf" ] || continue
        _scope=$(sed -n '1,15p' "$_pf" 2>/dev/null \
                 | sed -nE 's/.*\*\*(Ambito|Scope):\*\*[[:space:]]*([^*]*).*/\2/p' | head -1)
        # Fallback for the line written without bold, or with the bold placed
        # differently: two simple expressions instead of one clever one.
        if [ -z "$_scope" ]; then
            _scope=$(sed -n '1,15p' "$_pf" 2>/dev/null \
                     | sed -nE 's/^[[:space:]]*\**[[:space:]]*(Ambito|AMBITO|ambito|Scope|SCOPE|scope)[[:space:]]*\**[[:space:]]*:[[:space:]]*\**[[:space:]]*(.*)$/\2/p' \
                     | head -1)
            _scope=${_scope%%\*\**}
        fi
        if [ -n "$_scope" ]; then
            _in_scope=0
            _ifs_old=$IFS; IFS=','
            for _s in $_scope; do
                IFS=$_ifs_old
                _s="${_s//\`/}"
                _s="${_s#"${_s%%[![:space:]]*}"}"; _s="${_s%"${_s##*[![:space:]]}"}"
                [ -z "$_s" ] && { IFS=','; continue; }
                case "$_s" in "~"*) _s="$HOME${_s#\~}" ;; esac
                while [ "${_s%/}" != "$_s" ]; do _s="${_s%/}"; done
                [ -n "$_s" ] && case "$cwd/" in "$_s"/*) _in_scope=1 ;; esac
                IFS=','
            done
            IFS=$_ifs_old
            [ "$_in_scope" = 1 ] || continue
        fi
        _plan_kept+=("$_pf")
    done
    if [ ${#_plan_kept[@]} -gt 0 ]; then
        _plan_files=("${_plan_kept[@]}")
    else
        _plan_files=()
    fi
fi

if [ ${#_plan_files[@]} -gt 0 ] && [ -e "${_plan_files[0]}" ]; then
    _plan_raw=$(awk '
        # --- The vocabulary of states --------------------------------------
        # A table field counts as a task DONE or a task OPEN.
        # Italian and English together, case ignored, backticks and bold
        # stripped before the comparison: a register is written by a person,
        # and the bar must not disappear over a word in the other language.
        # The comparison stays on the WHOLE field, which is where the safety
        # is: a cell that CONTAINS the word "done" in a sentence does not count.
        function isdone(s) {
            return s ~ /^(fatto|fatta|fatti|fatte|done|completo|completa|completato|completata|completed|complete|finito|finita|finished|chiuso|chiusa|closed|risolto|risolta|resolved|merged)$/ \
                || s == "\342\234\205" || s == "\342\234\224" || s == "\342\234\223"
        }
        function isopen(s) {
            return s ~ /^(da fare|dafare|todo|to do|to-do|pending|aperto|aperta|open|in corso|in-corso|incorso|in progress|in-progress|inprogress|wip|doing|running|bloccato|bloccata|blocked|fermo|ferma|stuck|parcheggiato|parcheggiata|parked|rinviato|rinviata|deferred|postponed|in revisione|in review|da rivedere|review|da verificare|fallito|fallita|failed)$/
        }
        function norm(s) {
            gsub(/[`*_~]/, "", s)
            gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
            return tolower(s)
        }
        function endpiece(   d, t) {
            if (!inpiece) return
            inpiece = 0
            # The ROWS are the ground truth; the counter in the heading is a hand-kept
            # summary, and it goes stale. Measured 2026-08-22: the heading said 0/4 while a
            # row already read `done`. So rows first, the heading only as a fallback for a
            # piece that has none.
            if (r_t > 0)      { d = r_d; t = r_t }
            else if (h_t > 0) { d = h_d; t = h_t }
            else              { return }
            np++
            td += d; tt += t          # totale su TUTTO il piano
            if (d >= t) nd++
            else if (!sel) { sel = 1; sd = d; st = t; si = idx }
        }
        function newfile() {
            endpiece()
            # The TOTAL COMES FIRST, because it is the number people say out loud
            # ("30 out of 31"). This used to show only pieces plus the current piece, and
            # those two matched nothing anybody ever said: on 2026-08-22 they were read as
            # an indicator lagging behind, which was a reasonable reading.
            # Shape: <done>/<total> · p<piece number> <done>/<total>
            # The `!sel` branch is NOT a detail: without it, at the exact moment the last
            # row turns `done` the segment DISAPPEARS, because there is no incomplete piece
            # left to show. A bar that empties itself reads as "something broke", not as
            # "finished". Found on 2026-08-22 by testing the reaction in both directions,
            # not by reading the code.
            # An OPEN, incomplete plan always beats a complete one, whatever the alphabetical
            # order of the folders. The LAST file of the glob used to win: on 2026-08-25 a
            # register with 5 tasks still to do was INVISIBLE because a folder sorting after
            # it held a finished plan, whose "complete" overwrote the segment and then faded
            # away on its own by the fade rule. Result: an empty bar with open work in it.
            # Between two incomplete plans, the first wins.
            if (open && np > 0) {
                if (sel && out_inc) { }
                else if (!sel && out != "") { }
                else {
                if (sel) { out = td "/" tt " · p" si " " sd "/" st; out_inc = 1 }
                else     out = td "/" tt " · completo"
                # The file NAME comes out alongside the segment: it is needed downstream
                # for the completion mark, which is per-register. `curfile` is the file just
                # finished, not the one about to begin, because newfile() is called BEFORE it
                # is reassigned (and in END it is not reassigned at all).
                outfile = curfile
                }
            }
            open = 0; seenh = 0; np = 0; nd = 0; sel = 0; sd = 0; st = 0
            inpiece = 0; h_d = 0; h_t = 0; r_d = 0; r_t = 0; idx = 0
            td = 0; tt = 0; si = 0
        }
        FNR == 1 { newfile(); curfile = FILENAME }

        # --- Is the register OPEN? ----------------------------------------
        # This used to look for EXACTLY `**Stato:**` with `in corso` between
        # backticks. Changed on 2026-08-31: a register written in English, or
        # with a comma out of place, still has to show up.
        # The label can now be Stato/Status/State with or without bold, and the
        # value counts in Italian or English, quoted or not, case ignored.
        !seenh && tolower($0) ~ /(stato|status|state)[*_ \t]*:/ {
            _l = tolower($0)
            if (match(_l, /(stato|status|state)[*_ \t]*:/)) {
                _v = substr($0, RSTART + RLENGTH)
                # The bold that CLOSES the label goes first: without that,
                # "**Status:** `in progress`" was truncated to zero characters
                # by the rule below, and an open register came out as closed -
                # a silent bar over live work.
                sub(/^[*_ \t]+/, "", _v)
                # The separator has to be written LITERALLY. In this awk (BWK
                # 20200816) an octal escape works inside a string but NOT inside
                # a regular expression: measured 2026-08-31, sub(/\\302\\267.*$/)
                # makes 0 substitutions while sub(/·.*$/) makes 1.
                sub(/·.*$/, "", _v)
                sub(/\|.*$/, "", _v)
                sub(/\*\*.*$/, "", _v)
                _v = norm(_v)
                # Compared by PREFIX: if an exotic separator survives the
                # trimming, "in progress · something" still counts as "in
                # progress". A silent bar is the worst way to be wrong, because
                # it reads as "there is no open work".
                if (_v ~ /^(in corso|in-corso|incorso|corso|in progress|in-progress|inprogress|aperto|aperta|open|active|attivo|attiva|ongoing|wip|running|live)([^a-z0-9-].*)?$/) open = 1
            }
        }

        # --- A PIECE -------------------------------------------------------
        /^##[^#]/ {
            endpiece()
            seenh = 1; inpiece = 1; h_d = 0; h_t = 0; r_d = 0; r_t = 0
            idx++
            _l = tolower($0)
            # The piece number, whatever it is called. tolower does not change
            # lengths, so the offsets stay valid.
            if (match(_l, /(pezzo|piece|parte|part|fase|phase|passo|step|blocco|block|sprint|milestone|tappa|stage)[ \t]+[0-9]+/)) {
                _t = substr(_l, RSTART, RLENGTH)
                if (match(_t, /[0-9]+/)) idx = substr(_t, RSTART, RLENGTH) + 0
            }
            # The counter, with or without the asterisks around it.
            if (match($0, /\([0-9]+[ \t]*\/[ \t]*[0-9]+\)/)) {
                _t = substr($0, RSTART + 1, RLENGTH - 2)
                split(_t, a, "/")
                h_d = a[1] + 0; h_t = a[2] + 0
            }
            next
        }

        # --- A task row, TABLE form ----------------------------------------
        inpiece && /^[ \t]*\|/ {
            n = split($0, f, "|")
            for (i = 1; i <= n; i++) {
                g = norm(f[i])
                if (isdone(g)) { r_t++; r_d++; break }
                if (isopen(g)) { r_t++; break }
            }
        }

        # --- A task row, TICK LIST form ------------------------------------
        # `- [x] thing` / `- [ ] thing`. It is how a plan gets written in English
        # nine times out of ten, and it used to count for nothing.
        inpiece && /^[ \t]*([-*+]|[0-9]+[.)])[ \t]*\[[^]]?\]/ {
            _b = $0
            sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]*\[/, "", _b)
            _c = substr(_b, 1, 1)
            r_t++
            if (_c != "]" && _c != " " && _c != "\t") r_d++
        }

        END { newfile(); if (out != "") printf "%s\t%s\n", outfile, out }
    ' "${_plan_files[@]}" 2>/dev/null)

    # --- Filter 2: fading out on completion ---
    _plan_seg=""; _plan_file=""
    case "$_plan_raw" in
        *"$(printf '\t')"*)
            _plan_file=${_plan_raw%%$'\t'*}
            _plan_seg=${_plan_raw#*$'\t'}
            ;;
    esac
    if [ -n "$_plan_seg" ] && [ -n "$_plan_file" ]; then
        _fade_min=${CC_PLAN_DONE_FADE_MIN:-10}
        case "$_fade_min" in ''|*[!0-9]*) _fade_min=10 ;; esac
        # Local state, not published data - but it is still a path-derived file on
        # someone's disk, so it is created private and every write is wrapped in a
        # group whose stderr is closed BEFORE the redirection is attempted.
        _stamp_dir="$HOME/.claude/state/plan-fade"
        _pkey=${_plan_file//\//_}; _pkey=${_pkey//[^A-Za-z0-9._-]/_}
        _stamp="$_stamp_dir/$_pkey"
        case "$_plan_seg" in
            *"· completo")
                if [ "$_fade_min" -gt 0 ]; then
                    if [ ! -f "$_stamp" ]; then
                        mkdir -p "$_stamp_dir" 2>/dev/null
                        _mt=$(pk_mtime "$_plan_file")
                        case "$_mt" in ''|*[!0-9]*) _mt=$(date +%s) ;; esac
                        printf '%s\n' "$_mt" > "$_stamp" 2>/dev/null
                    fi
                    _t0=$(cat "$_stamp" 2>/dev/null)
                    case "$_t0" in ''|*[!0-9]*) _t0=$(date +%s) ;; esac
                    [ $(( $(date +%s) - _t0 )) -ge $(( _fade_min * 60 )) ] && _plan_seg=""
                fi
                ;;
            *)
                # A reopened task deletes the mark: the countdown starts from scratch at
                # the next completion, instead of staying expired forever.
                [ -f "$_stamp" ] && rm -f "$_stamp" 2>/dev/null
                ;;
        esac
    fi
    [ -n "$_plan_seg" ] && plan_info=" ${GRAY}⛭ ${_plan_seg}${RESET}"
fi

# --- Effort (the reasoning effort level, already read at the top) ---
effort_info=""
if [ -n "$effort_level" ]; then
    effort_info=" ${GRAY}[${effort_level}]${RESET}"
fi

# --- The session cache: warm or cold ---
# With a warm cache a turn RE-READS the context at a fraction of the price; with a cold one it
# buys the whole thing again. It is there to decide whether to pick the work back up now or
# later, and it is a PER-SESSION number, like the context bar: every window runs its own status
# line and sees its own.
# The real work is done by ~/.claude/statusline-cache.py, which reads the TTL from the data
# instead of assuming it. Here a python3 is paid for only when the transcript has changed:
# between one turn and the next the expiry instant does not move, and the countdown is shell
# arithmetic.
cache_info=""
if ! pk_off cache && [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ] && [ -f "$transcript_path" ] \
   && [ -f "$HOME/.claude/statusline-cache.py" ]; then
    _ch_sid=${transcript_path##*/}; _ch_sid=${_ch_sid%.jsonl}
    _ch_cache="${cache_dir}/cachettl-${_ch_sid}"
    # BSD and GNU stat do not share a syntax, and `stat -f` on GNU reports FILESYSTEM
    # data rather than a timestamp - so on Linux this quietly fed a mount path into
    # arithmetic instead of an epoch. Try one, fall back to the other.
    _ch_mtime=$(pk_mtime "$transcript_path")
    _ch_om=""; _ch_exp=""; _ch_ttl=""
    if [ -f "$_ch_cache" ]; then
        IFS=' ' read -r _ch_om _ch_exp _ch_ttl < "$_ch_cache" 2>/dev/null
        [ "$_ch_om" != "$_ch_mtime" ] && _ch_exp=""
    fi
    if [ -z "$_ch_exp" ]; then
        IFS=' ' read -r _ch_exp _ch_ttl <<EOF
$(python3 "$HOME/.claude/statusline-cache.py" "$transcript_path" 2>/dev/null)
EOF
        if [ -n "$_ch_exp" ] && [ -n "$_ch_mtime" ]; then
            mkdir -p "$cache_dir" 2>/dev/null
            printf '%s %s %s' "$_ch_mtime" "$_ch_exp" "$_ch_ttl" > "${_ch_cache}.$$" 2>/dev/null &&
                mv -f "${_ch_cache}.$$" "$_ch_cache" 2>/dev/null
        fi
    fi
    if [ -n "$_ch_exp" ] && [ "$_ch_exp" -gt 0 ] 2>/dev/null; then
        _ch_left=$(( _ch_exp - now ))
        if [ "$_ch_left" -gt 0 ]; then
            # Green while there is room, orange in the last quarter of an hour: that is
            # where "answer now or in ten minutes" starts to cost real money.
            if [ "$_ch_left" -le 900 ]; then _ch_col=$ORANGE; else _ch_col=$GIT_GREEN; fi
            # Two spaces between the dot and the time: pushed together they read as one thing.
            cache_info=" ${GRAY}${T_CACHE} ${_ch_col}⬤${GRAY}  $(fmt_hm "$_ch_left")${RESET}"
        else
            cache_info=" ${GRAY}${T_CACHE} ◌${RESET}"
        fi
    fi
fi

# --- Output ---
# Line 1: directory, git, context, cache, plan, model, effort
printf "%s%s%s%s%s %s%s%s\n" \
    "${dir_display}" \
    "${git_info}" \
    "${context_info}" \
    "${cache_info}" \
    "${plan_info}" \
    "${GRAY}[${model}]${RESET}" \
    "${effort_info}" \
    "${cost_info}"

# Line 2: the usage windows in detail (Claude.ai subscribers only)
if [ -n "$rate_info" ]; then
    printf "%s\n" "${rate_info}"
fi

# Line 3: the bmad-loop run, when there is one
if [ -n "$bmad_info" ]; then
    printf "%s\n" "${bmad_info}"
fi
exit 0
