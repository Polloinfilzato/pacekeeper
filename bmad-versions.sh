#!/usr/bin/env bash
# bmad-versions.sh — fetch the LATEST published versions of bmad-loop and BMAD Method.
#
# WHY IT IS A SEPARATE PROGRAM. The status line redraws every few seconds; asking the
# network how a project is doing takes a second or two. Doing that inline would freeze
# the prompt, so this runs DETACHED, on its own slow clock, and writes one small file
# that the status line reads for free:
#
#     ~/.claude/bmad-versions        stamp=… loop_latest=… method_latest=… method_next=…
#
# The status line never calls the network and never waits for this. When the file is
# missing or old it simply shows nothing about updates — which is the behaviour every
# other block here already has: hide, never guess.
#
# WHAT IT DOES NOT DO: it does not read the INSTALLED versions, and that is deliberate.
# Those are local and free to read, so the status line reads them itself at draw time —
# meaning the notice disappears the instant an upgrade lands, instead of lingering until
# the next fetch. The one exception is bmad-loop's installed version, recorded here as a
# fallback for installs this file cannot see (see the status line's own comment).
#
# THE TWO CHANNELS ARE NOT THE SAME KIND OF THING:
#
#   bmad-loop     is a git project. Ema runs a FORK, so "the latest" is upstream's newest
#                 release tag (bmad-code-org/bmad-loop), not his fork's.
#   BMAD Method   is an npm package with TWO channels that both matter: `latest` and
#                 `next`. Some of his projects deliberately track `next` (measured
#                 2026-09-05: gritty and Live-the-Dungeon on 6.10.1-next.12), so a
#                 project on a prerelease must be compared against `next` — comparing it
#                 against `latest` would nag it toward a version that is not its channel.
#
# Usage: bmad-versions.sh [--print] [--self-test]
#   (no flag)   fetch and write the file; silent
#   --print     fetch, write, and echo what was written
# Exit: 0 wrote something usable, 2 nothing usable was obtained.

set -uo pipefail
export LC_ALL=C

OUT="${BMAD_VERSIONS_OUT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bmad-versions}"
UPSTREAM="${BMAD_LOOP_UPSTREAM:-bmad-code-org/bmad-loop}"
NPM_PKG="${BMAD_METHOD_PKG:-bmad-method}"
NET_TIMEOUT="${BMAD_VERSIONS_TIMEOUT:-20}"
PRINT=0

for a in "$@"; do
    case "$a" in
        --print) PRINT=1 ;;
        --self-test) SELFTEST=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    esac
done

# A version comes out of someone else's program, so it is INPUT: anything that is not a
# version is dropped rather than written into a file the status line will render.
tag_to_version() {
    local v=${1#v}
    case "$v" in
        ''|*[!0-9.a-zA-Z_-]*) printf '' ;;
        [0-9]*) printf '%s' "$v" ;;
        *) printf '' ;;
    esac
}

# --------------------------------------------------------------------- the self-test
# It does NOT touch the network: a test that needs the internet fails for reasons that
# have nothing to do with the code, and then gets switched off. What is proved here is
# the part that has actually been wrong: reading a version out of someone else's output.
if [ "${SELFTEST:-0}" = 1 ]; then
    RUN=0; FAIL=0
    ck() { RUN=$((RUN+1)); if [ "$3" = "$2" ]; then printf '  ok    %-24s %s\n' "$1" "$3"
           else FAIL=$((FAIL+1)); printf '  FAIL  %-24s atteso=%s ottenuto=%s\n' "$1" "$2" "$3"; fi; }
    # tag_to_version strips a leading v and refuses anything that is not a version
    ck "tag-con-v"      "0.11.1" "$(tag_to_version v0.11.1)"
    ck "tag-senza-v"    "0.11.1" "$(tag_to_version 0.11.1)"
    # 🔴 THIS CASE FIRST, and it is not ceremony. The two negative cases below expect an
    # EMPTY answer, which is exactly what a MISSING function also produces: when the
    # definition sat below this block they both reported `ok` while nothing was being
    # tested at all. Measured 2026-09-05, on this file. So the suite proves the function
    # exists before it trusts a single empty answer.
    ck "la-funzione-esiste" "si" "$(type -t tag_to_version >/dev/null 2>&1 && echo si || echo NO)"
    ck "tag-spazzatura" ""       "$(tag_to_version 'main; rm -rf /')"
    ck "tag-vuoto"      ""       "$(tag_to_version '')"
    ck "npm-prerelease" "6.11.1-next.44" "$(tag_to_version 6.11.1-next.44)"
    printf 'casi=%d falliti=%d\n' "$RUN" "$FAIL"
    [ "$FAIL" = 0 ] || exit 1
    exit 0
fi

loop_latest=""; method_latest=""; method_next=""; loop_installed=""

# --- bmad-loop: upstream's newest RELEASE tag ---------------------------------------
# `gh` first because it carries the user's own credentials and is not rate-limited into
# uselessness; plain curl as the fallback, so a machine without `gh` still gets the
# number. Neither is required: with both missing the block simply never mentions the loop.
if command -v gh >/dev/null 2>&1; then
    loop_latest=$(tag_to_version "$(gh api "repos/$UPSTREAM/releases/latest" --jq .tag_name 2>/dev/null)")
fi
if [ -z "$loop_latest" ] && command -v curl >/dev/null 2>&1; then
    loop_latest=$(tag_to_version "$(curl -fsSL --max-time "$NET_TIMEOUT" \
        "https://api.github.com/repos/$UPSTREAM/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)")
fi

# --- BMAD Method: both npm channels --------------------------------------------------
if command -v npm >/dev/null 2>&1; then
    _tags=$(npm view "$NPM_PKG" dist-tags --json 2>/dev/null)
    method_latest=$(tag_to_version "$(printf '%s' "$_tags" | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)")
    method_next=$(tag_to_version   "$(printf '%s' "$_tags" | sed -n 's/.*"next"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'   | head -n1)")
fi

# --- the fallback reading of the INSTALLED loop --------------------------------------
if command -v bmad-loop >/dev/null 2>&1; then
    loop_installed=$(tag_to_version "$(bmad-loop --version 2>/dev/null | awk '{print $NF}')")
fi

if [ -z "$loop_latest" ] && [ -z "$method_latest" ] && [ -z "$method_next" ]; then
    exit 2      # nothing usable: leave whatever is on disk, an old file beats a blank one
fi

# Atomic: a reader must never see this half-written.
_dir=${OUT%/*}
[ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null
{
    printf 'stamp=%s\n'          "$(date +%s)"
    printf 'loop_latest=%s\n'    "$loop_latest"
    printf 'loop_installed=%s\n' "$loop_installed"
    printf 'method_latest=%s\n'  "$method_latest"
    printf 'method_next=%s\n'    "$method_next"
} > "$OUT.tmp.$$" 2>/dev/null && mv -f "$OUT.tmp.$$" "$OUT" 2>/dev/null

[ "$PRINT" = 1 ] && cat "$OUT"
exit 0
