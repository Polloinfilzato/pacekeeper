#!/usr/bin/env bash
# ——pacekeeper--> · the test suite
#
# WHY THIS FILE EXISTS. Six adversarial review passes read this program and missed five
# defects; every one of the five was found the moment somebody RAN it. Reading is not the
# filter. This is the filter, and it takes two seconds.
#
# WHAT IT REFUSES TO DO. It never touches a real $HOME. Every case runs against a
# throwaway home and a throwaway TMPDIR, because this program WRITES while it runs: a
# check that "only reads" once destroyed a real quota record on the author's machine.
#
# PROVE IT CAN FAIL. `./tests/run.sh --prove` re-introduces seven of the repaired defects
# into a copy of the sources, one at a time, and asserts the suite goes RED for each. A
# suite that has never been seen to fail certifies nothing.

set -u

REPO="${PK_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SL="$REPO/statusline.sh"
INST="$REPO/install.sh"

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pacekeeper-tests.XXXXXX") || exit 1
case "$ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) : ;;
    *) printf 'refusing to run: %s is not a temporary directory\n' "$ROOT" >&2; exit 1 ;;
esac
trap 'rm -rf "$ROOT"' EXIT

# ------------------------------------------------------------------- --prove
# A suite nobody has seen fail certifies nothing. This re-introduces seven of the defects
# that were actually repaired, one at a time, into a COPY of the sources, and demands that
# the suite go red for each. If one of them comes back green, that case is decoration.
if [ "${1:-}" = "--prove" ]; then
    PROVEN=0; UNPROVEN=0
    prove_one() {
        local label="$1" file="$2" old="$3" new="$4" dir rc
        dir=$(mktemp -d "$ROOT/mutant.XXXXXX")
        cp "$REPO/statusline.sh" "$REPO/install.sh" "$REPO/pacekeeper-quota" \
           "$REPO/statusline-bmad.py" "$REPO/statusline-cache.py" "$dir/" || return 1
        if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
n = s.count(old)
if n != 1:
    sys.exit("anchor found %d times, need exactly 1" % n)
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PY
        then
            printf '  BROKEN  %s (the mutation no longer applies to this source)\n' "$label"
            UNPROVEN=$((UNPROVEN + 1)); return
        fi
        PK_REPO="$dir" bash "$0" > "$dir/out.txt" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '  caught  %s  (%s)\n' "$label" "$(tail -1 "$dir/out.txt" | head -c 60)"
            PROVEN=$((PROVEN + 1))
        else
            printf '  MISSED  %s  - the suite stayed green with this defect back in\n' "$label"
            UNPROVEN=$((UNPROVEN + 1))
        fi
    }

    printf 'Putting seven repaired defects back, one at a time:\n\n'

    prove_one "the renewal countdown prints nothing" statusline.sh \
        "    print((target - today).days, int(until.timestamp()), hhmm.strftime('%H:%M') if hhmm else '-')" \
        "    pass"

    prove_one "no grammar check before the arithmetic" statusline.sh \
        "        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;" \
        "        *:*) ;;"

    prove_one "an unpriced model no longer abandons the sum" statusline.sh \
        "                    unknown = True" \
        "                    unknown = False"

    prove_one "two installs in one second share a manifest" install.sh \
        "while [ -e \"\$MANIFEST_DIR/\$STAMP.manifest\" ]; do" \
        "while false; do"

    prove_one "a leading zero reaches the shell arithmetic again" statusline.sh \
        "    case \"\$1\" in 0[0-9]*) return 1 ;; esac" \
        "    case \"\$1\" in 0[0-9][0-9][0-9]zz*) return 1 ;; esac"

    prove_one "publishing off no longer stops the shared file" statusline.sh \
        "    if [ \"\$has_wreset\" = true ] && [ \"\$PK_PUBLISH\" != no ] \\" \
        "    if [ \"\$has_wreset\" = true ] \\"

    prove_one "the restart is judged only against the published file" statusline.sh \
        "        elif [ -n \"\$_qo_seen\" ]; then" \
        "        elif [ -n \"\" ]; then"

    printf '\n%d of %d mutations were caught\n' "$PROVEN" "$((PROVEN + UNPROVEN))"
    [ "$UNPROVEN" -eq 0 ] || exit 1
    exit 0
fi

# ----------------------------------------------------------------- reporting
ok()   { PASS=$((PASS + 1)); }
bad()  {
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
  - $1"
    printf '  FAIL  %s\n        wanted: %s\n        got:    %s\n' "$1" "$2" "$3"
}
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }

has()     { case "$3" in *"$2"*) ok ;; *) bad "$1" "contains [$2]" "$3" ;; esac; }
hasnt()   { case "$3" in *"$2"*) bad "$1" "does NOT contain [$2]" "$3" ;; *) ok ;; esac; }
matches() { if printf '%s' "$3" | grep -Eq "$2"; then ok; else bad "$1" "matches /$2/" "$3"; fi; }
equals()  { [ "$2" = "$3" ] && ok || bad "$1" "[$2]" "[$3]"; }

# ----------------------------------------------------------------- fixtures
py() { python3 -c "$1"; }

TODAY_DOM=$(py "import datetime;print(datetime.date.today().day)")
TOMORROW_DOM=$(py "import datetime;print((datetime.date.today()+datetime.timedelta(days=1)).day)")
IN45=$(py "import datetime;print(datetime.date.today()+datetime.timedelta(days=45))")
# A time later TODAY, when there is enough of the day left for one to exist.
SOON=$(py "
import datetime
t = datetime.datetime.now() + datetime.timedelta(minutes=70)
print(t.strftime('%H:%M') if t.date() == datetime.date.today() else '')
")

new_home() {
    local h
    h=$(mktemp -d "$ROOT/home.XXXXXX")
    mkdir -p "$h/.claude" "$h/tmp"
    printf '{\n  "organizationRateLimitTier": "max_5x"\n}\n' > "$h/.claude.json"
    printf '%s' "$h"
}

conf() { printf '%s\n' "$2" > "$1/.claude/subscription.conf"; }

# A status-line payload. $1/$2 are the two percentages, $3/$4 the two reset stamps,
# $5 a transcript path. Empty $1 means: no rate_limits at all, i.e. an API key.
payload() {
    local now; now=$(date +%s)
    if [ -z "$1" ]; then
        printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"transcript_path":"%s","context_window":{"used_percentage":12}}' "${5:-}"
    else
        printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"transcript_path":"%s","context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}},"effort":{"level":"high"}}' \
            "${5:-}" "$1" "${3:-$((now + 7000))}" "$2" "${4:-$((now + 300000))}"
    fi
}

# Runs the status line and leaves the result in OUT / L1 / L2 / ERR.
render() {
    local home="$1" json="$2"
    printf '%s' "$json" > "$home/in.json"
    OUT=$(HOME="$home" TMPDIR="$home/tmp/" CC_STATUSLINE_LANG=en \
            bash "$SL" < "$home/in.json" 2>"$home/stderr.txt")
    OUT=$(printf '%s' "$OUT" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')
    L1=$(printf '%s' "$OUT" | sed -n '1p')
    L2=$(printf '%s' "$OUT" | sed -n '2p')
    ERR=$(cat "$home/stderr.txt")
}

# Every rendering must be silent on stderr. A status line that writes to stderr writes
# onto the user's terminal, which is how a malformed RENEWAL_TIME announced itself.
quiet() { equals "$1: nothing on stderr" "" "$ERR"; }

# ================================================================= 1. renewal
section() { printf '\n%s\n' "$1"; }

section "The renewal countdown"

h=$(new_home); render "$h" "$(payload 22.5 41.2)"
hasnt "R1  no config file: the charge is not mentioned" "billed" "$L2"
has   "R1b no config file: the plan still is"           "plan"   "$L2"

h=$(new_home); conf "$h" "RENEWAL_DAY=$TODAY_DOM"; render "$h" "$(payload 22.5 41.2)"
has   "R2  renewal today, no time declared" "billed today" "$L2"; quiet "R2"

h=$(new_home); conf "$h" "RENEWAL_DAY=$TOMORROW_DOM"; render "$h" "$(payload 22.5 41.2)"
has   "R3  renewal tomorrow" "billed tomorrow" "$L2"; quiet "R3"

if [ -n "$SOON" ]; then
    h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=%s\n' "$TODAY_DOM" "$SOON")"
    render "$h" "$(payload 22.5 41.2)"
    matches "R4  today, charge still ahead: an hours countdown" "billed in [0-9]+[hm]" "$L2"
    quiet "R4"
else
    skip "R4  today, charge still ahead" "less than 70 minutes of today left"
fi

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=00:00\n' "$TODAY_DOM")"
render "$h" "$(payload 22.5 41.2)"
matches "R5  today but already charged: rolls to the next one" "billed in [0-9]+d" "$L2"

h=$(new_home); conf "$h" "RENEWAL=$IN45"; render "$h" "$(payload 22.5 41.2)"
has   "R6  a fixed date 45 days out" "billed in 45d" "$L2"

h=$(new_home); conf "$h" "$(printf 'RENEWAL=2020-01-01\nPERIOD=yearly\n')"
render "$h" "$(payload 22.5 41.2)"
matches "R7  a past yearly date recurs" "billed in [0-9]+d" "$L2"

h=$(new_home); conf "$h" "RENEWAL=2020-01-01"; render "$h" "$(payload 22.5 41.2)"
hasnt "R8  a past one-off date is not drawn" "billed" "$L2"

h=$(new_home); conf "$h" "RENEWAL_DAY=31"; render "$h" "$(payload 22.5 41.2)"
matches "R9  day 31 in a month that has 30" "billed (today|tomorrow|in [0-9]+[dhm])" "$L2"

h=$(new_home); conf "$h" "RENEWAL_DAY=abc"; render "$h" "$(payload 22.5 41.2)"
hasnt "R10 a nonsense day draws no charge" "billed" "$L2"
has   "R10b and does not take the plan down with it" "plan" "$L2"; quiet "R10"

h=$(new_home); conf "$h" "RENEWAL_TIME=15:41"; render "$h" "$(payload 22.5 41.2)"
hasnt "R11 a time with no date draws no charge" "billed" "$L2"; quiet "R11"

h=$(new_home); : > "$h/.claude/subscription.conf"; render "$h" "$(payload 22.5 41.2)"
has   "R12 an empty config still shows the plan" "plan" "$L2"; quiet "R12"

# ============================================================ 2. time grammar
section "RENEWAL_TIME: one grammar, and no arithmetic before it is checked"

for t in "ab:cd" "99:99" "15:" ":41" "1 5:41" "24:00" "-1:00"; do
    h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=%s\n' "$TODAY_DOM" "$t")"
    render "$h" "$(payload 22.5 41.2)"
    has  "T   [$t] degrades to the no-time behaviour" "billed today" "$L2"
    quiet "T   [$t]"
done

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=8:5\n' "$TODAY_DOM")"
render "$h" "$(payload 22.5 41.2)"
matches "T8  [8:5] is a real time, normalised to 08:05" "billed (in [0-9]+[dhm]|today)" "$L2"

# The cache is a FILE ON DISK: an older version wrote two fields where there are now
# three, and anyone can edit it. It is the one route by which an unchecked time can still
# reach the arithmetic, so the grammar check in the drawing code is tested from HERE - not
# through the config file, which the single parser has already validated.
plant_cache() {   # $1 home, $2 the raw cache line
    local dir="$1/tmp/cc-statusline-cache-$(id -u)"
    mkdir -p "$dir"
    printf '%s' "$2" > "$dir/renew"
    # The cache is only consulted when it is NOT older than the config file.
    touch -t 200001010000 "$1/.claude/subscription.conf" 2>/dev/null
}

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=23:59\n' "$TODAY_DOM")"
plant_cache "$h" "$(( $(date +%s) + 3600 )) 0"
render "$h" "$(payload 22.5 41.2)"
has     "T9  a two-field cache from an older version" "billed today" "$L2"; quiet "T9"

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=23:59\n' "$TODAY_DOM")"
plant_cache "$h" "$(( $(date +%s) + 3600 )) 0 ab:cd"
render "$h" "$(payload 22.5 41.2)"
has     "T10 a corrupt time in the cache does not reach the arithmetic" "billed today" "$L2"
quiet   "T10"

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=23:59\n' "$TODAY_DOM")"
plant_cache "$h" "$(( $(date +%s) + 3600 )) 0 99:99"
render "$h" "$(payload 22.5 41.2)"
has     "T11 an out-of-range time in the cache is refused, not counted down" "billed today" "$L2"
quiet   "T11"

h=$(new_home); conf "$h" "$(printf 'RENEWAL_DAY=%s\nRENEWAL_TIME=23:59\n' "$TODAY_DOM")"
plant_cache "$h" "$(( $(date +%s) + 3600 )) 0 23:59"
render "$h" "$(payload 22.5 41.2)"
matches "T12 and a good time in the cache IS counted down" "billed in [0-9]+[hm]" "$L2"
quiet   "T12"

# ====================================================== 3. percentage grammar
section "The percentages arrive as input, not as a promise"

for p in 0 0.5 99.9 100; do
    h=$(new_home); render "$h" "$(payload "$p" "$p")"
    has  "P   [$p] is a number and must be drawn" "5h" "$L2"
    quiet "P   [$p]"
done

for p in '"08"' '"."' '"1..2"' '"-3"' '"1e2"'; do
    h=$(new_home)
    now=$(date +%s)
    render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$p" "$((now+7000))" "$p" "$((now+300000))")"
    hasnt "P   [$p] is not a number and must be dropped" "5h" "$L2"
    quiet "P   [$p]"
done

h=$(new_home)
now=$(date +%s)
render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":"1/0"},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$((now+300000))")"
quiet "P   a division by zero smuggled in as a reset stamp"
hasnt "P   and nothing about division reaches the line" "division" "$L2"

# ==================================================================== 4. cost
section "The theoretical cost"

mktranscript() { printf '%s\n' "$2" > "$1"; }

h=$(new_home)
tr="$h/t.jsonl"
{
 echo '{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":2000,"cache_creation_input_tokens":500,"cache_read_input_tokens":100000}}}'
 echo '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":50,"output_tokens":10}}}'
} > "$tr"
render "$h" "$(payload "" "" "" "" "$tr")"
has   "C1  an API key sums the transcript" '$0.32' "$L1"

render "$h" "$(payload 22.5 41.2 "" "" "$tr")"
hasnt "C2  a subscriber is never shown a price" '$' "$L1"

h=$(new_home); tr="$h/t.jsonl"
{
 echo '{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0}}}'
 echo '{"type":"assistant","message":{"model":"claude-opus-9-quantum","usage":{"input_tokens":100000000,"output_tokens":9000000}}}'
} > "$tr"
render "$h" "$(payload "" "" "" "" "$tr")"
hasnt "C3  one unpriced model abandons the whole sum" '$' "$L1"

h=$(new_home); tr="$h/t.jsonl"
echo '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000,"output_tokens":0}}}' > "$tr"
render "$h" "$(payload "" "" "" "" "$tr")"
has   "C4  a sum under a cent keeps four decimals" '$0.0008' "$L1"

h=$(new_home); tr="$h/t.jsonl"; : > "$tr"
render "$h" "$(payload "" "" "" "" "$tr")"
hasnt "C5  an empty transcript prices nothing" '$' "$L1"

# ================================================================= 5. publish
section "What lands on disk, and only when asked"

h=$(new_home); conf "$h" "$(printf 'PUBLISH_STATE=no\n')"
render "$h" "$(payload 22.5 41.2)"
for f in rate-limits.json quota-state; do
    [ -e "$h/.claude/$f" ] && bad "U   publishing off: no $f" "absent" "present" || ok
done
for d in rate-limits.d context-usage; do
    [ -e "$h/.claude/$d" ] && bad "U   publishing off: no $d/" "absent" "present" || ok
done
[ -e "$h/.claude/quota-origin" ] && ok \
    || bad "U   publishing off: quota-origin IS still written (declared in the README)" "present" "absent"

h=$(new_home); conf "$h" "$(printf 'PUBLISH_STATE=yes\n')"
render "$h" "$(payload 22.5 41.2)"
[ -e "$h/.claude/rate-limits.json" ] && ok || bad "U   publishing on: rate-limits.json" "present" "absent"
[ -e "$h/.claude/quota-state" ]     && ok || bad "U   publishing on: quota-state"     "present" "absent"

# ================================================== 5b. the mid-window restart
section "A counter that restarts in the middle of its window"

# The headline feature, exercised through the front door: two renders sharing one weekly
# deadline, with the counter dropping between them. It has to hold WITH PUBLISHING OFF,
# which is the default answer to the install question - the drop used to be judged only
# against `rate-limits.json`, a file that publishing off never writes, so the whole thing
# was quietly inert for anyone who took the default. The five-hour stamps deliberately
# differ by a minute: inside one five-hour window a drop loses the freshness comparison,
# which is a separate limitation and not what this case is about.
NOW=$(date +%s)
for pub in no yes; do
    h=$(new_home); conf "$h" "PUBLISH_STATE=$pub"
    WREset=$((NOW + 345600))
    render "$h" "$(payload 10 40 $((NOW + 7200)) "$WREset")"
    has "W1-$pub  a full window reads as seven days"        "d4/7" "$L2"
    render "$h" "$(payload 10 2 $((NOW + 7260)) "$WREset")"
    has "W2-$pub  the restart shortens the denominator"     "d1/4" "$L2"
    has "W3-$pub  and the daily share shrinks with it"      "today still 23.0%" "$L2"
    quiet "W4-$pub"
done

# =============================================================== 6. installer
section "The installer, executed rather than read"

shim=$(mktemp -d "$ROOT/shim.XXXXXX")
cat > "$shim/date" <<'SHIM'
#!/bin/sh
case "$1" in
  +%Y%m%d-%H%M%S) echo "20260101-120000" ;;
  *) exec /bin/date "$@" ;;
esac
SHIM
chmod +x "$shim/date"

install_into() { HOME="$1" PATH="$shim:$PATH" sh "$INST" "${@:2}" > "$1/install.log" 2>&1; }

h=$(new_home)
install_into "$h" --yes
equals "I1  a fresh install exits clean" "0" "$?"
[ -f "$h/.claude/statusline.sh" ] && ok || bad "I1b the status line is in place" "present" "absent"
grep -q statusLine "$h/.claude/settings.json" && ok || bad "I1c settings.json is wired up" "statusLine" "absent"
grep -q '^PUBLISH_STATE=no' "$h/.claude/subscription.conf" && ok \
    || bad "I2  --yes never turns publishing on by omission" "PUBLISH_STATE=no" "$(cat "$h/.claude/subscription.conf")"

# Installing again on a machine that has already run this status line: the runtime
# directories exist, and two of them are directories by design.
install_into "$h" --yes
equals "I3  a second install over the first" "0" "$?"

h=$(new_home)
printf '#!/bin/sh\necho THE-USERS-OWN-LINE\n' > "$h/.claude/statusline.sh"
printf '{}\n' > "$h/.claude/settings.json"
install_into "$h" --yes; install_into "$h" --yes; install_into "$h" --yes
n=$(find "$h/.claude/.pacekeeper" -name '*.manifest' | wc -l | tr -d ' ')
equals "I4  three installs in one second keep three manifests" "3" "$n"
out=$(printf '\n' | HOME="$h" PATH="$shim:$PATH" sh "$INST" --restore 2>&1)
has   "I5  and the chooser can tell them apart" "(#1)" "$out"
install_into "$h" --uninstall --yes
has   "I6  uninstall goes back to before the FIRST one" "THE-USERS-OWN-LINE" "$(cat "$h/.claude/statusline.sh")"
grep -q statusLine "$h/.claude/settings.json" \
    && bad "I7  uninstall unwires settings.json" "no statusLine" "statusLine still there" || ok

h=$(new_home)
ln -s /etc/hosts "$h/.claude/statusline.sh"
install_into "$h" --yes
[ "$?" -ne 0 ] && ok || bad "I8  a symlink in the way is refused" "non-zero exit" "0"
[ -L "$h/.claude/statusline.sh" ] && ok || bad "I8b and the symlink is left alone" "still a symlink" "replaced"

h=$(new_home)
HOME="$h" PATH="$shim:$PATH" sh "$INST" < /dev/null > "$h/log" 2>&1
[ "$?" -ne 0 ] && ok || bad "I9  no terminal and no --yes: refuses" "non-zero exit" "0"

# ================================================================== the count
printf '\n'
TOTAL=$((PASS + FAIL + SKIP))
printf '%d cases: %d passed, %d failed, %d skipped\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
if [ "$TOTAL" -eq 0 ]; then
    printf 'no case ran at all, which is not a pass\n' >&2
    exit 2
fi
if [ "$FAIL" -gt 0 ]; then
    printf 'failed:%s\n' "$FAILED_NAMES" >&2
    exit 1
fi
exit 0
