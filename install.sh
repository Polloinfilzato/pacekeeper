#!/usr/bin/env bash
# ——pacekeeper--> installer
#
# Copies the status line into ~/.claude, wires it into settings.json, and asks four
# short questions. Everything it asks has a working default, so `--yes` is a complete
# answer. Nothing is overwritten without a timestamped backup next to the original.
set -euo pipefail

VERSION="1.0.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CONF="$CLAUDE_DIR/subscription.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

FILES="statusline.sh statusline-bmad.py statusline-cache.py pacekeeper-quota"

# Colours, but only when someone is actually looking at a terminal.
if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
    B=""; DIM=""; G=""; Y=""; R=""; N=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
warn() { printf '%s!%s   %s\n' "$Y" "$N" "$*"; }
die()  { printf '%sx%s   %s\n' "$R" "$N" "$*" >&2; exit 1; }

ASSUME_YES=0
UNINSTALL=0
RESTORE=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)       ASSUME_YES=1 ;;
        --uninstall)    UNINSTALL=1 ;;
        --restore)      RESTORE=1 ;;
        -h|--help)
            cat <<EOF
——pacekeeper--> installer $VERSION

  ./install.sh              install, asking four short questions
  ./install.sh --yes        install with the defaults, asking nothing
  ./install.sh --uninstall  put the machine back the way it was before the
                            FIRST install: the oldest backup wins
  ./install.sh --restore    list every backup with its date and pick one

Nothing here is ever overwritten without a backup next to the original, named
<file>.pacekeeper-<date>-<time>.bak. The status line lands in $CLAUDE_DIR and
its settings in $CONF.
EOF
            exit 0 ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

# Reads one line from the human, not from whatever is on stdin. Without this an
# installer run from a pipe silently answers all of its own questions.
ask() {
    local prompt="$1" default="$2" reply=""
    if [ "$ASSUME_YES" = 1 ] || [ ! -r /dev/tty ]; then
        printf '%s' "$default"
        return
    fi
    printf '%s %s[%s]%s ' "$prompt" "$DIM" "$default" "$N" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    printf '%s' "${reply:-$default}"
}

yesno() {
    local answer
    answer=$(ask "$1 (y/n)" "$2")
    case "$answer" in [yYsS]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------- backups and restore
# Every backup carries the timestamp of the install that made it, so the files
# written in one go share one stamp and can be put back together. Restoring half
# a set — new settings.json, old statusline.sh — is worse than restoring nothing.
BACKUP_TARGETS="statusline.sh statusline-bmad.py statusline-cache.py pacekeeper-quota settings.json"

# Copies a file to its backup, and NEVER overwrites a backup that already exists.
# Two runs inside the same second share a stamp, and on 2026-09-03 that let the safety
# copy taken before a restore destroy the historical backup it was named after: the
# restore still worked once, but the original file was gone for good afterwards. A
# backup that can be overwritten is not a backup.
backup_file() {
    local target="$1" dest="$CLAUDE_DIR/$1.pacekeeper-$STAMP.bak" i=1
    [ -f "$CLAUDE_DIR/$target" ] || return 0
    while [ -e "$dest" ]; do
        dest="$CLAUDE_DIR/$1.pacekeeper-$STAMP-$i.bak"
        i=$((i + 1))
    done
    cp "$CLAUDE_DIR/$target" "$dest"
    BACKUP_MADE=${dest##*/}
}
BACKUP_MADE=""

# The distinct stamps present, oldest first.
list_stamps() {
    local f base
    for f in "$CLAUDE_DIR"/*.pacekeeper-*.bak; do
        [ -e "$f" ] || continue
        base=${f##*.pacekeeper-}
        printf '%s\n' "${base%.bak}"
    done | sort -u
}

# A stamp shown to a human: 20260903-191455 -> 2026-09-03 19:14:55
pretty_stamp() {
    local s="$1"
    printf '%s-%s-%s %s:%s:%s' \
        "${s:0:4}" "${s:4:2}" "${s:6:2}" "${s:9:2}" "${s:11:2}" "${s:13:2}"
}

if [ "$UNINSTALL" = 1 ] || [ "$RESTORE" = 1 ]; then
    stamps=$(list_stamps)
    if [ -z "$stamps" ]; then
        warn "no backups found in $CLAUDE_DIR"
        say "  nothing to put back. If a status line is still configured, remove the"
        say "  \"statusLine\" block from $SETTINGS by hand."
        exit 1
    fi

    if [ "$UNINSTALL" = 1 ]; then
        # The OLDEST set, not the newest: "uninstall" means the machine as it was
        # before this ever touched it. The newest backup is usually a copy of our
        # own previous install, which would put pacekeeper back rather than remove it.
        chosen=$(printf '%s\n' "$stamps" | head -1)
        step "Uninstalling — restoring the state from $(pretty_stamp "$chosen")"
    else
        step "Backups found"
        i=0
        for st in $stamps; do
            i=$((i + 1))
            printf '  %2d) %s   %s\n' "$i" "$(pretty_stamp "$st")" \
                "$(cd "$CLAUDE_DIR" && ls -1 ./*.pacekeeper-"$st".bak 2>/dev/null | sed 's|^\./||; s|\.pacekeeper-.*||' | tr '\n' ' ')"
        done
        say ""
        pick=$(ask "  Which one? (1-$i, or blank to cancel)" "")
        case "$pick" in
            ''|*[!0-9]*) say "  cancelled"; exit 0 ;;
        esac
        [ "$pick" -ge 1 ] && [ "$pick" -le "$i" ] || { warn "out of range"; exit 1; }
        chosen=$(printf '%s\n' "$stamps" | sed -n "${pick}p")
        step "Restoring the state from $(pretty_stamp "$chosen")"
    fi

    # ORDER MATTERS, and getting it wrong cost a real defect on 2026-09-03. What is
    # here now must be backed up too — undoing an undo has to be possible, or --restore
    # becomes the destructive command. But if that safety copy is written FIRST and its
    # stamp happens to equal the one being restored (same second, or a second run inside
    # the same second), it overwrites the very backup we are about to read, and the
    # restore silently puts back what was already there. Measured: --uninstall restored
    # pacekeeper instead of the status line it had replaced.
    # So: read the chosen set into a scratch directory first, and only then touch anything.
    scratch=$(mktemp -d) || die "cannot create a temporary directory"
    trap 'rm -rf "$scratch"' EXIT INT TERM
    found=0
    for target in $BACKUP_TARGETS; do
        if [ -f "$CLAUDE_DIR/$target.pacekeeper-$chosen.bak" ]; then
            cp "$CLAUDE_DIR/$target.pacekeeper-$chosen.bak" "$scratch/$target"
            found=1
        fi
    done
    [ "$found" = 1 ] || die "that backup set is empty — nothing was changed"

    for target in $BACKUP_TARGETS; do
        backup_file "$target"
    done
    for target in $BACKUP_TARGETS; do
        if [ -f "$scratch/$target" ]; then
            cp "$scratch/$target" "$CLAUDE_DIR/$target"
            say "  $target restored"
        fi
    done
    say ""
    say "  What was there a moment ago was saved as .pacekeeper-$STAMP.bak, so this is undoable."
    exit 0
fi

# ----------------------------------------------------------------- preflight
step "Checking what is here"

[ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR does not exist — is Claude Code installed?"

missing=""
for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -n "$missing" ] && die "missing required tool(s):$missing"

for f in $FILES; do
    [ -f "$SRC_DIR/$f" ] || die "$f is missing from $SRC_DIR — is the clone complete?"
done

say "  bash $BASH_VERSION"
say "  jq, python3 ${G}ok${N}"
command -v git  >/dev/null 2>&1 || warn "git not found — the git block will stay hidden"
if command -v bmad-loop >/dev/null 2>&1; then
    say "  bmad-loop found ${DIM}— its block will appear when a run is alive${N}"
fi

# A status line already configured here is somebody's work. It gets backed up either
# way, but a backup nobody is told about is a backup nobody goes looking for — so the
# question is asked out loud, with "yes" as the default for whoever is in a hurry.
existing=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
if [ -n "$existing" ]; then
    warn "a status line is already configured here:"
    say "     $existing"
    say "  It will be saved as a backup, and ./install.sh --restore brings it back."
    if ! yesno "  Replace it?" "y"; then
        say "  nothing was changed."
        exit 0
    fi
fi

# ----------------------------------------------------------------- questions
UI_LANG="auto"
DISABLE=""
PUBLISH="yes"
RENEWAL_DAY=""
RENEWAL_TIME=""

if [ "$ASSUME_YES" = 0 ]; then
    step "Four questions"

    # 1 — language --------------------------------------------------------
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
        it|it_*|it.*|*_IT*) detected="Italian" ;;
        *)                  detected="English" ;;
    esac
    say ""
    say "${B}1. Language${N}"
    say "   Labels only — everything else is the same. Detected from your locale: ${B}$detected${N}."
    UI_LANG=$(ask "   auto / en / it" "auto")

    # 2 — billing ---------------------------------------------------------
    say ""
    say "${B}2. Billing countdown${N}"
    say "   Claude Code does not expose your renewal date, so this is the one thing"
    say "   you have to tell it. Skip it and everything else still works."
    say ""
    say "   ${DIM}Where to find it:${N}"
    say "   ${DIM}· the date — claude.ai → Settings → Billing shows the next renewal${N}"
    say "   ${DIM}· the time — not shown anywhere in the UI. It is the timestamp on the${N}"
    say "   ${DIM}  Stripe receipt email for your subscription. Search your mail for${N}"
    say "   ${DIM}  \"Anthropic receipt\". Without it the countdown just says \"today\"${N}"
    say "   ${DIM}  for the whole day instead of flipping at the exact hour.${N}"
    say ""
    if yesno "   Set it up now?" "y"; then
        RENEWAL_DAY=$(ask "   Day of the month you are billed (1-31)" "")
        case "$RENEWAL_DAY" in
            ''|*[!0-9]*) RENEWAL_DAY=""; warn "  not a number — skipping the countdown" ;;
            *) [ "$RENEWAL_DAY" -ge 1 ] && [ "$RENEWAL_DAY" -le 31 ] || { RENEWAL_DAY=""; warn "  out of range — skipping"; } ;;
        esac
        if [ -n "$RENEWAL_DAY" ]; then
            RENEWAL_TIME=$(ask "   Time of the charge, HH:MM local (blank to skip)" "")
            case "$RENEWAL_TIME" in
                ''|[0-2][0-9]:[0-5][0-9]) : ;;
                *) RENEWAL_TIME=""; warn "  not HH:MM — leaving the time out" ;;
            esac
        fi
    else
        say ""
        say "   ${DIM}You can let Claude Code find it for you later. Paste this into any session:${N}"
        say ""
        say "   ${DIM}  Find my Claude.ai subscription renewal date and time. Check my most${N}"
        say "   ${DIM}  recent Stripe receipt emails for Anthropic — the timestamp on the${N}"
        say "   ${DIM}  receipt is the charge time. Then write RENEWAL_DAY and RENEWAL_TIME${N}"
        say "   ${DIM}  into ~/.claude/subscription.conf in HH:MM local time.${N}"
    fi

    # 3 — optional blocks -------------------------------------------------
    say ""
    say "${B}3. Optional blocks${N}"
    say "   All on by default. Each one hides itself anyway when it has nothing to say,"
    say "   so turning them off is a matter of taste, not of avoiding clutter."
    yesno "   git branch and status?"                  "y" || DISABLE="$DISABLE,git"
    yesno "   prompt-cache warm/cold timer?"           "y" || DISABLE="$DISABLE,cache"
    yesno "   progress of a long plan file?"           "y" || DISABLE="$DISABLE,plan"
    if command -v bmad-loop >/dev/null 2>&1; then
        yesno "   bmad-loop run status?"               "y" || DISABLE="$DISABLE,bmad"
    fi
    DISABLE="${DISABLE#,}"

    # 4 — publish -----------------------------------------------------------
    say ""
    say "${B}4. Share the numbers with your other tools${N}"
    say "   Claude Code hands the quota numbers to the status line and nowhere else."
    say "   Saying yes writes them to ~/.claude/quota-state so a script of yours can"
    say "   read them — a spend guard, a nightly job deciding whether to start one more."
    yesno "   Write them to disk?" "y" || PUBLISH="no"
fi

# ----------------------------------------------------------------- install
step "Installing"

for f in $FILES; do
    if [ -f "$CLAUDE_DIR/$f" ] && ! cmp -s "$SRC_DIR/$f" "$CLAUDE_DIR/$f"; then
        backup_file "$f"
        say "  your $f saved as $BACKUP_MADE"
    fi
    cp "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
chmod +x "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/pacekeeper-quota"
say "  four files copied into $CLAUDE_DIR"

# settings.json — merged, never rewritten from scratch: everything else in there
# belongs to the user and to Claude Code.
if [ -f "$SETTINGS" ]; then
    jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON — fix it first, I will not touch it"
    backup_file settings.json
    say "  your settings.json saved as $BACKUP_MADE"
else
    echo '{}' > "$SETTINGS"
fi

tmp="$SETTINGS.pacekeeper.tmp.$$"
jq '.statusLine = {"type":"command","command":"~/.claude/statusline.sh","refreshInterval":8}' \
    "$SETTINGS" > "$tmp" && mv -f "$tmp" "$SETTINGS"
say "  settings.json points at the status line"

# The config file. An existing one is amended key by key, so a renewal date you
# already had is not lost by re-running the installer.
touch "$CONF"
set_key() {
    local key="$1" value="$2" tmpf="$CONF.tmp.$$"
    grep -v "^[[:space:]]*$key[[:space:]]*=" "$CONF" > "$tmpf" 2>/dev/null || true
    [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$tmpf"
    mv -f "$tmpf" "$CONF"
}
if [ "$ASSUME_YES" = 0 ]; then
    set_key UI_LANG "$UI_LANG"
    set_key DISABLE "$DISABLE"
    set_key PUBLISH_STATE "$PUBLISH"
    [ -n "$RENEWAL_DAY" ]  && set_key RENEWAL_DAY "$RENEWAL_DAY"
    [ -n "$RENEWAL_TIME" ] && set_key RENEWAL_TIME "$RENEWAL_TIME"
    say "  settings written to $CONF"
fi

# ----------------------------------------------------------------- preview
step "This is what it will look like"

preview_json=$(cat <<EOF
{"workspace":{"current_dir":"$SRC_DIR"},
 "model":{"display_name":"Opus 5"},
 "transcript_path":"",
 "context_window":{"used_percentage":42},
 "rate_limits":{"five_hour":{"used_percentage":22,"resets_at":$(( $(date +%s) + 4300 ))},
                "seven_day":{"used_percentage":41,"resets_at":$(( $(date +%s) + 320000 ))}},
 "effort":{"level":"high"}}
EOF
)
say ""
printf '%s\n' "$preview_json" | bash "$CLAUDE_DIR/statusline.sh" || warn "the preview failed — the numbers above are made up, but the failure is real"
say ""
say "${DIM}(made-up numbers — your real ones appear when Claude Code runs it)${N}"

step "Done"
say "  Open a new Claude Code session, or run ${B}/config${N} in one that is already open."
say "  Settings live in ${B}$CONF${N} and take effect on the next redraw."
say "  To undo: ${B}./install.sh --uninstall${N}"
