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
# PROVE IT CAN FAIL. `./tests/run.sh --prove` re-introduces the repaired defects
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
# A suite nobody has seen fail certifies nothing. This re-introduces the defects
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

    printf 'Putting the repaired defects back, one at a time:\n\n'

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

    prove_one "the bmad run goes back onto line 2" statusline.sh \
        "elif [ -n \"\$bmad_block\" ]; then
    bmad_info=\"  \${bmad_block}\${RESET}\"" \
        "elif [ -n \"\$bmad_block\" ]; then
    rate_info=\"\${rate_info}\${sep}\${bmad_block}\${RESET}\""

    prove_one "the update notice stops being conditional" statusline.sh \
        "    if pk_newer \"\$_bv_loop_have\" \"\$_bv_loop_latest\"; then" \
        "    if true; then"

    prove_one "a prerelease project is pointed at the stable channel" statusline.sh \
        "            *-*) _bv_m_want=\$_bv_m_next ;;    # a prerelease is compared against \`next\`" \
        "            *-*) _bv_m_want=\$_bv_m_latest ;;"

    prove_one "the module version is read instead of the installation one" statusline.sh \
        "        _bv_m_have=\$(awk '/^installation:/{f=1; next} f && /^[[:space:]]+version:/{gsub(/[[:space:]\"]/,\"\",\$2); print \$2; exit} f && /^[^[:space:]]/{exit}' \"\$_bv_man\" 2>/dev/null)" \
        "        _bv_m_have=\$(awk '/^[[:space:]]+version:/{gsub(/[[:space:]\"]/,\"\",\$2); v=\$2} END{print v}' \"\$_bv_man\" 2>/dev/null)"

    prove_one "an exceeded limit is thrown away again" statusline.sh \
        "    [ \"\${1%%.*}\" -le 1000 ] 2>/dev/null || return 1" \
        "    [ \"\${1%%.*}\" -le 100 ] 2>/dev/null || return 1"

    prove_one "the countdown depends on the percentage again" statusline.sh \
        "if [ -n \"\$five_reset\" ] && [ \"\$five_reset\" != \"null\" ]; then
    if [ -n \"\$five_block\" ]; then" \
        "if [ -n \"\$five_reset\" ] && [ \"\$five_reset\" != \"null\" ] && [ -n \"\$five_pct\" ]; then
    if [ -n \"\$five_block\" ]; then"

    prove_one "line two stops folding and is cut off again" statusline.sh \
        "    [ -n \"\$c\" ] && [ \"\$c\" -ge 20 ] 2>/dev/null || c=\"\"" \
        "    c=\"\""

    prove_one "the pace bands all collapse into one colour" statusline.sh \
        "    printf \"%d %s\", x, (x > 2700 ? \"R\" : (x > 900 ? \"A\" : (x >= -2700 ? \"G\" : \"Y\")))" \
        "    printf \"%d %s\", x, \"G\""

    prove_one "the pace is measured against the wrong window" statusline.sh \
        "    win = 18000" \
        "    win = 25200"

    prove_one "the run's start time is read as UTC again" statusline-bmad.py \
        "            stamp = stamp.astimezone()" \
        "            stamp = stamp.replace(tzinfo=datetime.timezone.utc)"

    prove_one "an unknown age is drawn as 0m again" statusline.sh \
        "                [ -n \"\$_bm_elapsed\" ] && _bm_body=\"\${_bm_body} \$(fmt_hm \"\$_bm_elapsed\")\"" \
        "                _bm_body=\"\${_bm_body} \$(fmt_hm \"\${_bm_elapsed:-0}\")\""

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
# Same as render(), with a terminal width declared. pk_cols reads $COLUMNS first, so this
# is the honest way to ask "what would this look like in a window that narrow".
render_at() {
    local cols="$1"; shift
    COLUMNS="$cols" render "$@"
}

render() {
    local home="$1" json="$2"
    printf '%s' "$json" > "$home/in.json"
    OUT=$(HOME="$home" TMPDIR="$home/tmp/" CC_STATUSLINE_LANG=en COLUMNS="${COLUMNS:-}" \
            bash "$SL" < "$home/in.json" 2>"$home/stderr.txt")
    OUT=$(printf '%s' "$OUT" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')
    L1=$(printf '%s' "$OUT" | sed -n '1p')
    L2=$(printf '%s' "$OUT" | sed -n '2p')
    NLINES=$(printf '%s\n' "$OUT" | grep -c '')
    L3=$(printf '%s' "$OUT" | sed -n '3p')
    NLINES=$(printf '%s' "$OUT" | grep -c '')
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

# A percentage above 100 is not a broken field, it is the limit exceeded: Claude Code
# computes this as `utilization * 100` and does not clamp it. Throwing it away used to
# delete the five-hour block at the one moment it is worth reading.
for p in 100.7 101 105 999; do
    h=$(new_home); render "$h" "$(payload "$p" 43)"
    has  "P   [$p] over the limit still draws the block" "5h" "$L2"
    has  "P   [$p] and reports nothing left"             "left 0%" "$L2"
    quiet "P   [$p]"
done

h=$(new_home); render "$h" "$(payload 1001 43)"
hasnt "P   [1001] a percentage in the thousands is not drawn" "left 0%" "$L2"

# A percentage this program cannot read must cost the PERCENTAGE, never the countdown.
# The reset time is the answer you want exactly when the other number is unusable.
for p in '"08"' '"."' '"1..2"' '"-3"' '"1e2"' 'null'; do
    h=$(new_home)
    now=$(date +%s)
    render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":43,"resets_at":%s}}}' "$p" "$((now+7000))" "$((now+300000))")"
    # Only the five-hour segment: everything up to the first separator.
    hasnt "P   [$p] the unreadable percentage is dropped" "left" "${L2%%│*}"
    matches "P   [$p] but the countdown survives it" "5h resets in [0-9]" "$L2"
    quiet "P   [$p]"
done

# Neither number readable: then there is nothing to say, and the block goes.
h=$(new_home)
now=$(date +%s)
render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":".","resets_at":"x"},"seven_day":{"used_percentage":43,"resets_at":%s}}}' "$((now+300000))")"
hasnt "P   neither figure readable: no five-hour block at all" "5h" "$L2"

# The window Claude Code drops from the payload once its reset instant has passed.
h=$(new_home)
now=$(date +%s)
render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"seven_day":{"used_percentage":43,"resets_at":%s}}}' "$((now+300000))")"
hasnt "P   no five_hour key at all: nothing invented" "5h" "$L2"
has   "P   and the weekly block is untouched by its absence" "7d" "$L2"

h=$(new_home)
now=$(date +%s)
render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":"1/0"},"seven_day":{"used_percentage":41,"resets_at":%s}}}' "$((now+300000))")"
quiet "P   a division by zero smuggled in as a reset stamp"
hasnt "P   and nothing about division reaches the line" "division" "$L2"

# ==================================================================== 4. cost
section "The five-hour pace: how much sooner the quota dies than the window reopens"

# The colour is half the message, so the tests read the escape sequence, not just the text.
# Reading only the digits would let every band silently collapse into one colour.
pace_of() {   # $1 used%, $2 minutes to the reset -> PACE (text) and PACE_COL (name)
    local h now
    h=$(new_home); now=$(date +%s)
    render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":1},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":43,"resets_at":%s}}}' "$1" "$((now + $2 * 60))" "$((now + 300000))")"
    PACE=$(printf '%s' "$L2" | sed 's/ *│.*//' | sed 's/.*(\(.*\))/\1/')
    local raw seg
    raw=$(HOME="$h" TMPDIR="$h/tmp/" CC_STATUSLINE_LANG=en COLUMNS=200 bash "$SL" < "$h/in.json" 2>/dev/null | sed -n 2p)
    seg=${raw%%│*}
    case "$(printf '%s' "$seg" | grep -o $'\033\[[0-9;]*m(' | tail -1)" in
        $'\033[31m('*)                RGB=red ;;
        $'\033[38;2;255;165;0m('*)    RGB=amber ;;
        $'\033[33m('*)                RGB=yellow ;;
        $'\033[38;2;0;200;0m('*)      RGB=green ;;
        *)                            RGB=none ;;
    esac
    PACE_COL=$RGB
}

# The worked example this was specified from: 44% left, 2h16 to the reset -> +4m, on pace.
pace_of 56 136
equals "X1  the specified example reads +4m" "+4m" "$PACE"
equals "X1b and it is green"                 "green" "$PACE_COL"

# The two ends of a window, where a pace built on percentages alone goes wrong.
pace_of 0 300
equals "X2  a window just opened is level, not behind" "0m" "$PACE"
equals "X2b and green"                                 "green" "$PACE_COL"

pace_of 0 270
equals "X3  half an hour gone with nothing spent" "-30m" "$PACE"

pace_of 100 120
equals "X4  blocked, two hours of wall ahead" "red" "$PACE_COL"

pace_of 88 100
equals "X5  more than 45m too fast is red" "red" "$PACE_COL"

pace_of 70 120
equals "X6  half an hour too fast is amber" "amber" "$PACE_COL"

pace_of 50 160
equals "X7  nine minutes too fast is still on pace" "green" "$PACE_COL"

pace_of 20 200
equals "X8  forty minutes of slack is the edge of green" "green" "$PACE_COL"

pace_of 10 180
equals "X9  an hour and a half of slack: use more"  "yellow" "$PACE_COL"
equals "X9b and it says how much"                   "-1h 30m" "$PACE"

# Neither figure alone is enough to compute a pace, and inventing one is worse than none.
h=$(new_home); now=$(date +%s)
render "$h" "$(printf '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"O"},"context_window":{"used_percentage":1},"rate_limits":{"five_hour":{"used_percentage":".","resets_at":%s},"seven_day":{"used_percentage":43,"resets_at":%s}}}' "$((now+7000))" "$((now+300000))")"
hasnt "X10 an unreadable percentage draws no pace" "(" "${L2%%│*}"
matches "X10b but the countdown is still there" "5h resets in" "$L2"

h=$(new_home); render "$h" "$(payload 22 43 "x" "$(( $(date +%s) + 300000 ))")"
hasnt "X11 an unreadable reset draws no pace" "(" "${L2%%│*}"

section "Folding line two when the terminal is too narrow"

# Claude Code truncates a status line that overruns the width, so anything past the right
# edge is not merely ugly, it is GONE. Reported from a Mac kept at a large font.
widest() {   # the widest visible line among the quota lines
    local w=0 n line
    while IFS= read -r line; do
        n=${#line}
        [ "$n" -gt "$w" ] && w=$n
    done <<< "$(printf '%s' "$OUT" | sed -n '2,$p')"
    printf '%s' "$w"
}

h=$(new_home); conf "$h" "RENEWAL_DAY=$TOMORROW_DOM"
render_at 200 "$h" "$(payload 22.5 41.2)"
equals "W1  a wide terminal keeps everything on one line" "2" "$NLINES"

h=$(new_home); conf "$h" "RENEWAL_DAY=$TOMORROW_DOM"
render_at 60 "$h" "$(payload 22.5 41.2)"
[ "$NLINES" -gt 2 ] && ok || bad "W2  a narrow terminal folds" "more than 2 lines" "$NLINES"
w=$(widest)
[ "$w" -le 60 ] && ok || bad "W3  and no folded line overruns the width" "<= 60" "$w"
has   "W4  the block that used to fall off the edge is present" "plan" "$OUT"
has   "W5  and so is the charge inside it" "billed" "$OUT"

# A block is never cut in half: each line either holds a whole block or starts a new one.
render_at 60 "$h" "$(payload 22.5 41.2)"
printf '%s' "$OUT" | sed -n '2,$p' | grep -q '│[[:space:]]*$' \
    && bad "W6  no line ends on a dangling separator" "no trailing │" "$(printf '%s' "$OUT" | sed -n '2,$p')" || ok

# No usable width: the old single line, unchanged. A machine whose status line has no
# controlling terminal must not fold at random, and neither must one reporting nonsense.
# `0` and `8` are the two ways to say "no answer here" that a test can force; the genuine
# no-controlling-terminal case cannot be produced portably from inside a test, which is
# why the fallback is written to be the DO-NOTHING branch rather than a guess.
h=$(new_home); conf "$h" "RENEWAL_DAY=$TOMORROW_DOM"
render_at 0 "$h" "$(payload 22.5 41.2)"
equals "W7  no usable width: nothing folds" "2" "$NLINES"

h=$(new_home); conf "$h" "RENEWAL_DAY=$TOMORROW_DOM"
render_at 8 "$h" "$(payload 22.5 41.2)"
equals "W8  an absurd width is ignored rather than obeyed" "2" "$NLINES"

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
# ============================================== 9. the bmad-loop run's own line
# The run block used to ride at the END of line 2, after both quota windows and the
# renewal countdown. Three blocks and two separators come first, so in an ordinary
# terminal the one thing that changes minute by minute was the part that got wrapped
# or cut. It now has line 3 to itself - but only when a run exists, because a row
# spent on nothing is a row taken from the terminal for ever.
section "The bmad-loop run has a line to itself"

US=$(printf '\037')

# Plants a run in the block's own cache, so no bmad-loop and no python is consulted:
# the payload under test is exactly the one written here. $1 home, $2 payload.
plant_run() {
    local h="$1" key cdir
    cp "$REPO/statusline-bmad.py" "$h/.claude/statusline-bmad.py"
    mkdir -p "$h/bin"
    printf '#!/bin/sh\nexit 0\n' > "$h/bin/bmad-loop"; chmod +x "$h/bin/bmad-loop"
    key=$(printf '%s' /tmp | cksum | cut -d' ' -f1)
    cdir="$h/tmp//cc-statusline-cache-$(id -u 2>/dev/null || echo 0)"
    mkdir -p "$cdir"
    { printf '%s\n' "$(( $(date +%s) + 300 ))"; printf '%s\n' "$2"; } > "$cdir/bmad-$key"
}

h=$(new_home)
plant_run "$h" "running${US}7-4${US}dev${US}2820${US}${US}0${US}0"
_pk_path=$PATH; PATH="$h/bin:$PATH"
render "$h" "$(payload 22.5 41.2)"
PATH=$_pk_path
has    "B1  a live run lands on line 3"            "bmad 7-4" "$L3"
has    "B2  with its phase and elapsed time"       "47m (dev)" "$L3"
hasnt  "B3  and line 2 no longer carries it"       "bmad"     "$L2"
has    "B4  line 2 still carries the quota windows" "7d"       "$L2"
equals "B5  three lines in all"                    "3"        "$NLINES"
quiet  "B6"

# A paused run says why and where, still on its own line.
h=$(new_home)
plant_run "$h" "paused${US}7-4${US}review${US}600${US}budget${US}0${US}2"
_pk_path=$PATH; PATH="$h/bin:$PATH"
render "$h" "$(payload 22.5 41.2)"
PATH=$_pk_path
has    "B7  a paused run keeps its reason on line 3" "budget"  "$L3"
hasnt  "B8  and still nothing on line 2"             "bmad"    "$L2"

# An age the helper could not establish must cost the DURATION, not the block, and
# above all it must not be drawn as "0m": zero is a plausible number, so it reads as a
# measurement and stops anybody from looking.
h=$(new_home)
plant_run "$h" "running${US}7-4${US}dev${US}${US}${US}0${US}0"
_pk_path=$PATH; PATH="$h/bin:$PATH"
render "$h" "$(payload 22.5 41.2)"
PATH=$_pk_path
hasnt  "B10 no age: nothing that looks like a duration" "0m"     "$L3"
has    "B11 but the run, and what it is doing, remain"  "7-4"    "$L3"
has    "B11b including the phase"                       "(dev)"  "$L3"

# --- the helper itself, where the age is actually computed ---
# bmad-loop writes `started_at` as plain wall-clock with no offset. Reading it as UTC
# shifted every run by the machine's offset: measured in CEST, a 42-minute-old run came
# out at MINUS 78 minutes, which the shell clamped to "0m" for the first two hours of
# every run. The test lives here, against a planted bmad-loop, because that is where the
# arithmetic is.
OFFSET=$(py "import datetime;print(int(datetime.datetime.now().astimezone().utcoffset().total_seconds()))")
if [ "$OFFSET" = "0" ]; then
    skip "B12 a naive started_at is local time, not UTC" "this machine runs at UTC, the two readings coincide"
else
    hb=$(new_home); mkdir -p "$hb/bin"
    STARTED=$(py "import datetime;print((datetime.datetime.now()-datetime.timedelta(minutes=42)).strftime('%Y-%m-%dT%H:%M:%S'))")
    cat > "$hb/bin/bmad-loop" <<FAKE
#!/bin/sh
case "\$2" in
  --json) case "\$1" in
      list)   printf '{"schema_version":1,"runs":[{"ref":"ab12","run_id":"r1","run_type":"story","started_at":"$STARTED","status":"running","paused_stage":""}]}' ;;
      status) printf '{"tasks":[{"story_key":"7-4","phase":"dev"}]}' ;;
  esac ;;
esac
FAKE
    chmod +x "$hb/bin/bmad-loop"
    AGE=$(PATH="$hb/bin:$PATH" python3 "$REPO/statusline-bmad.py" /tmp | cut -d"$US" -f4)
    if [ -n "$AGE" ] && [ "$AGE" -gt 2400 ] 2>/dev/null && [ "$AGE" -lt 2700 ] 2>/dev/null; then ok
    else bad "B12 a naive started_at is local time, not UTC" "about 2520s for a 42-minute-old run" "${AGE:-<empty>}"; fi
fi

# No run: the row must not be paid for. Two lines, exactly as before this change.
h=$(new_home)
render "$h" "$(payload 22.5 41.2)"
equals "B9  no run, no third line"                 "2"        "$NLINES"
equals "B10 and line 3 is empty"                   ""         "$L3"
quiet  "B11"

# ================================ 10. updates available for bmad-loop / BMAD Method
section "Updates available: shown only when there IS one"

# The two halves are planted separately, exactly as they are read: what is PUBLISHED goes
# into the fetched file, what is INSTALLED into the places the status line reads live.
# No network is touched here, and none should ever be: a test that needs the internet
# fails for reasons that have nothing to do with the code, and then gets switched off.
plant_versions() {  # $1 home, $2 loop_installed, $3 loop_latest, $4 method_latest, $5 method_next
    { printf 'stamp=%s\n' "$(date +%s)"
      printf 'loop_latest=%s\n' "$3"
      printf 'loop_installed=%s\n' "$2"
      printf 'method_latest=%s\n' "$4"
      printf 'method_next=%s\n' "$5"; } > "$1/.claude/bmad-versions"
}
# A project with BMAD Method installed at $3, and a payload whose cwd is $2 inside it.
plant_project() {  # $1 home, $2 subdir under the project root ("" for the root), $3 version
    local root="$1/proj"
    mkdir -p "$root/_bmad/_config"
    printf 'installation:\n  version: %s\n  installDate: x\nmodules:\n  - name: core\n    version: 9.9.9\n' "$3" \
        > "$root/_bmad/_config/manifest.yaml"
    [ -n "$2" ] && mkdir -p "$root/$2"
    printf '%s' "$root${2:+/$2}"
}
payload_in() {  # $1 dir, then the usual percentages
    local now; now=$(date +%s)
    printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":12},"rate_limits":{"five_hour":{"used_percentage":22.5,"resets_at":%s},"seven_day":{"used_percentage":41.2,"resets_at":%s}}}' \
        "$1" "$((now + 7000))" "$((now + 300000))"
}

# U1. THE WHOLE POINT: everything current, no run -> the line does not exist at all.
h=$(new_home); plant_versions "$h" "0.11.1" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.12.0")
render "$h" "$(payload_in "$d")"
equals "U1  all current: still only two lines" "2" "$NLINES"
hasnt  "U1b and no arrow anywhere"             "⬆" "$OUT"; quiet "U1"

# U2. bmad-loop behind, no run: the line APPEARS, carrying only the update.
h=$(new_home); plant_versions "$h" "0.11.1" "0.12.0" "6.12.0" "6.11.1-next.44"
render "$h" "$(payload 22.5 41.2)"
has    "U2  bmad-loop behind: the tool is named"   "bmad-loop"  "$L3"
has    "U2b with the NEW version in brackets"      "(0.12.0)"   "$L3"
hasnt  "U2c and not the installed one"             "(0.11.1)"   "$L3"
equals "U2d the line exists without any run"       "3"          "$NLINES"; quiet "U2"

# U3. BMAD Method is per PROJECT: read from the manifest under the session's directory.
h=$(new_home); plant_versions "$h" "0.11.1" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.11.0")
render "$h" "$(payload_in "$d")"
has    "U3  method behind: named with its target"  "bmad-method (6.12.0)" "$L3"
hasnt  "U3b and the loop, being current, is silent" "bmad-loop"           "$L3"; quiet "U3"

# U4. Both behind: both named, one line.
h=$(new_home); plant_versions "$h" "0.11.1" "0.12.0" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.11.0")
render "$h" "$(payload_in "$d")"
has    "U4  both: the loop"   "bmad-loop (0.12.0)"   "$L3"
has    "U4b both: the method" "bmad-method (6.12.0)" "$L3"
equals "U4c still one line"   "3"                    "$NLINES"

# U5. With a run in flight the notice rides the SAME line, after the run.
h=$(new_home); plant_versions "$h" "0.11.1" "0.12.0" "6.12.0" "6.11.1-next.44"
plant_run "$h" "running${US}7-4${US}dev${US}2820${US}${US}0${US}0"
_pk_path=$PATH; PATH="$h/bin:$PATH"
render "$h" "$(payload 22.5 41.2)"
PATH=$_pk_path
has    "U5  the run is still there"        "bmad 7-4"           "$L3"
has    "U5b and the update joins it"       "bmad-loop (0.12.0)" "$L3"
equals "U5c without costing a fourth line" "3"                  "$NLINES"

# U6. 🔴 THE CHANNEL. A project on a prerelease is compared against `next`, never against
# `latest`: pointed at `latest` it would be told, on every redraw for ever, to move to a
# version that is not on its channel.
h=$(new_home); plant_versions "$h" "0.11.1" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.10.1-next.12")
render "$h" "$(payload_in "$d")"
has    'U6  a prerelease project is offered next' "(6.11.1-next.44)" "$L3"
hasnt  'U6b and never latest' "(6.12.0)" "$L3"

# U7. Installed AHEAD of what is published says nothing. Ema runs a fork of bmad-loop, so
# this is the ordinary case there, not a curiosity.
h=$(new_home); plant_versions "$h" "0.12.0" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.12.0")
render "$h" "$(payload_in "$d")"
equals "U7  ahead of upstream: nothing to say" "2" "$NLINES"

# U8. No fetched file at all: silent, and no third line. The status line must never
# invent a target version, and must never wait for the network to find out.
h=$(new_home); d=$(plant_project "$h" "" "6.11.0")
render "$h" "$(payload_in "$d")"
equals "U8  nothing fetched yet: two lines" "2"  "$NLINES"
hasnt  "U8b and no empty brackets"          "()" "$OUT"; quiet "U8"

# U9. The manifest is found by walking UP: a session sitting three directories inside the
# project is still in that project.
h=$(new_home); plant_versions "$h" "0.11.1" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "src/deep/deeper" "6.11.0")
render "$h" "$(payload_in "$d")"
has    "U9  found from three levels down" "bmad-method (6.12.0)" "$L3"

# U10. The version read is `installation.version`, NOT the per-module one that follows it.
# They are the same number today and are free to diverge tomorrow; the fixture makes the
# module version 9.9.9 precisely so reading the wrong one cannot look right.
h=$(new_home); plant_versions "$h" "0.11.1" "0.11.1" "6.12.0" "6.11.1-next.44"
d=$(plant_project "$h" "" "6.11.0")
render "$h" "$(payload_in "$d")"
hasnt "U10 the module version is not what was read" "9.9.9" "$OUT"
has   "U10b the installation version was"           "(6.12.0)" "$L3"


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
