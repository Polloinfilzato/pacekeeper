#!/usr/bin/env bash
# ——pacekeeper--> installer
#
# Copies the status line into ~/.claude, wires it into settings.json, and asks four
# short questions. Every question has a working default, so `--yes` is a complete answer.
#
# THE RULE THIS FILE IS BUILT AROUND: a stranger's machine must end up either fully
# installed or exactly as it was. Nothing in between, and nothing lost. Every earlier
# version of this file broke that rule in a different way, so the mechanisms below are
# not ceremony — each one is a defect that was found by trying it:
#
#   - a MANIFEST per install, because a backup file cannot represent "this did not
#     exist before", and without that, uninstall leaves the whole thing installed;
#   - backups that can never be overwritten, not even by another backup taken in the
#     same second, because a backup that can be overwritten is not a backup;
#   - the config file backed up too, which the first version simply forgot;
#   - symlinks refused rather than followed, because following one writes through it;
#   - every `cmd && action` written as `if ! cmd; then die; fi`, because under
#     `set -e` a failing left-hand side does NOT stop the script, and the success
#     message then gets printed over a failure.
set -euo pipefail

VERSION="1.0.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CONF="$CLAUDE_DIR/subscription.conf"
MANIFEST_DIR="$CLAUDE_DIR/.pacekeeper"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Where a no-clone install fetches from. A TAG, never a branch: with a branch, whoever
# runs the one-liner gets whatever was pushed a second ago, which nobody has tried.
PACEKEEPER_REF="${PACEKEEPER_REF:-v${VERSION}}"
PACEKEEPER_BASE="${PACEKEEPER_BASE:-https://raw.githubusercontent.com/Polloinfilzato/pacekeeper}"

# The files that get installed, and the files that get touched. The second list is
# longer than the first: subscription.conf and settings.json are modified rather than
# copied, and the version that forgot to protect them lost people's configuration.
FILES="statusline.sh statusline-bmad.py statusline-cache.py pacekeeper-quota"
TOUCHED="statusline.sh statusline-bmad.py statusline-cache.py pacekeeper-quota settings.json subscription.conf"

# Runtime state the status line CREATES while it runs. It cannot be in the manifest,
# because none of it exists at install time - and that is exactly why an uninstall that
# only consults the manifest leaves it behind. Measured 2026-09-03: after a clean install
# and uninstall, quota-origin and rate-limits.json were still there.
ARTIFACT_FILES="quota-state quota-origin rate-limits.json"
ARTIFACT_DIRS="rate-limits.d context-usage"

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
        -y|--yes)    ASSUME_YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --restore)   RESTORE=1 ;;
        -h|--help)
            cat <<EOF
——pacekeeper--> installer $VERSION

  ./install.sh              install, asking four short questions
  ./install.sh --yes        install with the defaults, asking nothing
  ./install.sh --uninstall  put the machine back the way it was before the FIRST
                            install: restores what existed, removes what did not
  ./install.sh --restore    list every install with its date and go back to one

Nothing is overwritten without a backup named <file>.pacekeeper-<date>-<time>.bak next
to the original, and a backup is never overwritten either. Each install also writes a
manifest under $MANIFEST_DIR recording which files existed beforehand — without it,
uninstall could not know what to delete.

Files land in $CLAUDE_DIR; your settings in $CONF.
EOF
            exit 0 ;;
        *) die "unknown option: $arg (try --help)" ;;
    esac
done

# Reads one line from the human, not from whatever is on stdin. Without this, an
# installer running from a pipe silently answers all of its own questions.
# `[ -r /dev/tty ]` answers the WRONG QUESTION: it asks whether that file exists and
# is readable by permission, and both are true even for a process with no controlling
# terminal at all. The only reliable test is to open it. Measured 2026-09-03 with
# setsid: the check said "there is a terminal", and every question then failed with
# "/dev/tty: Device not configured" while the installer carried on regardless.
# And the suppression has to wrap the whole thing. `: > /dev/tty 2>/dev/null` does NOT
# work: bash applies redirections left to right, so the failure of `> /dev/tty` is
# reported while stderr is still the terminal, and only afterwards does `2>/dev/null`
# take effect. The error escapes. Same trap as the one in statusline.sh.
HAVE_TTY=0
if { : > /dev/tty; } 2>/dev/null; then
    HAVE_TTY=1
fi

ask() {
    local prompt="$1" default="$2" reply=""
    if [ "$ASSUME_YES" = 1 ] || [ "$HAVE_TTY" = 0 ]; then
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
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ safety helpers
#
# A symlink is refused rather than followed. `cp` through a symlink writes to its
# TARGET: if ~/.claude/statusline.sh happens to point somewhere else, this would
# overwrite that instead — outside the directory the user agreed to let us touch.
refuse_symlinks() {
    local target
    for target in $TOUCHED; do
        if [ -L "$CLAUDE_DIR/$target" ]; then
            die "$CLAUDE_DIR/$target is a symlink. Refusing to write through it — resolve it by hand first."
        fi
        if [ -e "$CLAUDE_DIR/$target" ] && [ ! -f "$CLAUDE_DIR/$target" ]; then
            die "$CLAUDE_DIR/$target is not a regular file. Refusing to touch it."
        fi
    done
}

# Copies a file to its backup and NEVER overwrites an existing backup. Two runs inside
# the same second share a stamp, and that once let the safety copy taken before a
# restore destroy the very backup it was named after.
BACKUP_MADE=""
backup_file() {
    local target="$1" dest="$CLAUDE_DIR/$1.pacekeeper-$STAMP.bak" i=1
    BACKUP_MADE=""
    [ -f "$CLAUDE_DIR/$target" ] || return 0
    while [ -e "$dest" ]; do
        dest="$CLAUDE_DIR/$1.pacekeeper-$STAMP-$i.bak"
        i=$((i + 1))
    done
    cp "$CLAUDE_DIR/$target" "$dest"
    BACKUP_MADE=${dest##*/}
}

# ------------------------------------------------------------- uninstall / restore
#
# The manifest is what makes uninstall possible. A directory full of .bak files can say
# "this is what that file used to contain"; only the manifest can say "this file did not
# exist at all", which is the common case on a first install and the one that used to
# leave pacekeeper installed and running after an uninstall.
list_installs() {
    local f base
    for f in "$MANIFEST_DIR"/*.manifest; do
        [ -e "$f" ] || continue
        base=${f##*/}
        printf '%s\n' "${base%.manifest}"
    done | sort
}

pretty_stamp() {
    local s="$1"
    printf '%s-%s-%s %s:%s:%s' \
        "${s:0:4}" "${s:4:2}" "${s:6:2}" "${s:9:2}" "${s:11:2}" "${s:13:2}"
}

if [ "$UNINSTALL" = 1 ] || [ "$RESTORE" = 1 ]; then
    installs=$(list_installs)
    if [ -z "$installs" ]; then
        warn "no install manifest found in $MANIFEST_DIR"
        say "  Nothing to undo. If a status line is still configured, remove the"
        say "  \"statusLine\" block from $SETTINGS by hand."
        exit 1
    fi

    if [ "$UNINSTALL" = 1 ]; then
        # The OLDEST install, not the newest: "uninstall" means the machine as it was
        # before this ever touched it. The newest manifest usually describes our own
        # previous install, and going back to that reinstalls rather than removes.
        chosen=$(printf '%s\n' "$installs" | head -1)
        step "Uninstalling — going back to before $(pretty_stamp "$chosen")"
    else
        step "Installs on record"
        i=0
        for st in $installs; do
            i=$((i + 1))
            printf '  %2d) %s\n' "$i" "$(pretty_stamp "$st")"
        done
        say ""
        pick=$(ask "  Which one to go back to? (1-$i, blank to cancel)" "")
        case "$pick" in
            ''|*[!0-9]*) say "  cancelled"; exit 0 ;;
        esac
        if [ "$pick" -lt 1 ] || [ "$pick" -gt "$i" ]; then
            die "out of range"
        fi
        chosen=$(printf '%s\n' "$installs" | sed -n "${pick}p")
        step "Going back to before $(pretty_stamp "$chosen")"
    fi

    manifest="$MANIFEST_DIR/$chosen.manifest"
    [ -r "$manifest" ] || die "$manifest is not readable"

    # THE MANIFEST IS A FILE ON DISK, so it is input, not testimony. Every name in it is
    # checked against the fixed list this installer knows about, before anything is
    # touched: a line reading `../victim  absent` would otherwise make the removal loop
    # delete outside the directory entirely. A manifest that does not validate aborts
    # the whole operation - a half-understood recovery plan is worse than none.
    seen=""
    while IFS=$'\t' read -r target state backup; do
        [ -n "$target" ] || continue

        known=0
        is_artifact=0
        for allowed in $TOUCHED; do
            [ "$target" = "$allowed" ] && known=1
        done
        for allowed in $ARTIFACT_FILES $ARTIFACT_DIRS; do
            if [ "$target" = "$allowed" ]; then known=1; is_artifact=1; fi
        done
        [ "$known" = 1 ] || die "manifest names an unexpected file ($target) — refusing to act on it"

        # A name appearing twice lets a crafted manifest pair an `existed` line with a
        # later `absent` one and defeat the rule that protects pre-existing state.
        case " $seen " in
            *" $target "*) die "manifest names $target more than once" ;;
        esac
        seen="$seen $target"

        case "$state" in
            existed|absent) : ;;
            *) die "manifest has an unknown state ($state) for $target" ;;
        esac

        if [ "$state" = existed ]; then
            if [ -z "$backup" ]; then
                # Runtime state is recorded as pre-existing WITHOUT a backup: it is noted
                # so uninstall knows not to delete it, never restored. Requiring a backup
                # here made uninstall abort in exactly the case the rule protects.
                [ "$is_artifact" = 1 ] || die "manifest records $target as existing but names no backup"
            else
                # `*` matches slashes, so a name like `x.pacekeeper-/../../outside.bak`
                # satisfied the pattern and then resolved outside $CLAUDE_DIR entirely.
                case "$backup" in
                    */*) die "manifest backup name contains a path separator ($backup)" ;;
                esac
                case "$backup" in
                    "$target".pacekeeper-*.bak) : ;;
                    *) die "manifest points $target at an unexpected backup name ($backup)" ;;
                esac
                [ -f "$CLAUDE_DIR/$backup" ] || die "backup $backup named by the manifest is missing"
            fi
        fi
    done < "$manifest"

    # ORDER MATTERS. Everything to be put back is read into a scratch directory FIRST,
    # before anything on disk is touched. Writing the safety copies first once let a
    # stamp collision overwrite the backup that was about to be read, and the restore
    # silently put back what was already there.
    scratch=$(mktemp -d) || die "cannot create a temporary directory"
    trap 'rm -rf "$scratch"' EXIT INT TERM

    while IFS=$'\t' read -r target state backup; do
        [ -n "$target" ] || continue
        if [ "$state" = existed ] && [ -n "$backup" ]; then
            cp "$CLAUDE_DIR/$backup" "$scratch/$target"
        fi
    done < "$manifest"

    # What is here now gets backed up too: undoing an undo has to be possible, or
    # --restore becomes the destructive command.
    for target in $TOUCHED; do
        backup_file "$target"
    done

    while IFS=$'\t' read -r target state backup; do
        [ -n "$target" ] || continue
        if [ "$state" = existed ]; then
            # Recorded without a backup means "it was here, leave it alone".
            if [ -n "$backup" ]; then
                cp "$scratch/$target" "$CLAUDE_DIR/$target"
                say "  $target restored"
            fi
        else
            if [ -f "$CLAUDE_DIR/$target" ]; then
                rm -f "$CLAUDE_DIR/$target"
                say "  $target removed (it did not exist before)"
            fi
        fi
    done < "$manifest"

    # Only on a real uninstall: --restore is a step sideways between installs, and it
    # must not throw away state the user may still be relying on.
    # AND ONLY WHAT THE MANIFEST SAYS WAS NOT THERE BEFORE. These paths are ours by
    # convention, not by ownership: deleting one that predated the install would be
    # taking someone else's file because it happened to share a name.
    if [ "$UNINSTALL" = 1 ]; then
        removed=0
        while IFS=$'\t' read -r target state backup; do
            [ -n "$target" ] || continue
            [ "$state" = absent ] || continue
            for a in $ARTIFACT_FILES; do
                if [ "$target" = "$a" ] && [ -f "$CLAUDE_DIR/$target" ]; then
                    rm -f "$CLAUDE_DIR/$target"
                    removed=$((removed + 1))
                fi
            done
            for a in $ARTIFACT_DIRS; do
                if [ "$target" = "$a" ] && [ -d "$CLAUDE_DIR/$target" ]; then
                    rm -rf "$CLAUDE_DIR/$target"
                    removed=$((removed + 1))
                fi
            done
        done < "$manifest"
        if [ "$removed" -gt 0 ]; then
            say "  $removed runtime state path(s) removed"
        fi
    fi

    say ""
    say "  What was in place a moment ago was saved as .pacekeeper-$STAMP.bak, so this is undoable."
    say "  The backups and the manifests were left where they are."
    exit 0
fi

# ------------------------------------------------------------------------ preflight
step "Checking what is here"

# The command written into settings.json says ~/.claude, and the status line reads and
# writes $HOME/.claude throughout. Honouring CLAUDE_CONFIG_DIR here while everything
# downstream ignores it installs into one place and runs from another. Refusing is the
# honest answer until the whole path is threaded through.
if [ "$CLAUDE_DIR" != "$HOME/.claude" ]; then
    die "CLAUDE_CONFIG_DIR is set to $CLAUDE_DIR, and this installs only into ~/.claude. Unset it and re-run."
fi

[ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR does not exist — is Claude Code installed?"
[ -w "$CLAUDE_DIR" ] || die "$CLAUDE_DIR is not writable"

missing=""
for tool in jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing="$missing $tool"
    fi
done
[ -n "$missing" ] && die "missing required tool(s):$missing"

# A no-clone install: the script was piped in on its own, so the files it installs are
# not next to it and have to be fetched. Pinned to a TAG, so what gets installed is
# something that was actually tried, not whatever was pushed a minute ago.
if [ ! -f "$SRC_DIR/statusline.sh" ]; then
    command -v curl >/dev/null 2>&1 || die "the files are not next to this script and curl is missing"
    step "Fetching ——pacekeeper--> $PACEKEEPER_REF"
    fetched=$(mktemp -d) || die "cannot create a temporary directory"
    trap 'rm -rf "$fetched"' EXIT INT TERM
    for f in $FILES; do
        if ! curl -fsSL "$PACEKEEPER_BASE/$PACEKEEPER_REF/$f" -o "$fetched/$f"; then
            die "could not download $f from $PACEKEEPER_BASE/$PACEKEEPER_REF"
        fi
        say "  $f"
    done
    SRC_DIR="$fetched"
fi

for f in $FILES; do
    [ -f "$SRC_DIR/$f" ] || die "$f is missing from $SRC_DIR — is the clone complete?"
done

say "  bash $BASH_VERSION"
say "  jq, python3 ${G}ok${N}"
if ! command -v git >/dev/null 2>&1; then
    warn "git not found — the git block will stay hidden"
fi
if command -v bmad-loop >/dev/null 2>&1; then
    say "  bmad-loop found ${DIM}— its block will appear when a run is alive${N}"
fi

refuse_symlinks

# settings.json has to be a JSON OBJECT. `jq empty` happily accepts `[]`, `42` and
# `"text"`, and the assignment further down would then fail on a file we had already
# begun replacing.
if [ -f "$SETTINGS" ]; then
    [ -w "$SETTINGS" ] || die "$SETTINGS is not writable"
    if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
        die "$SETTINGS is not a JSON object — fix it first, I will not touch it"
    fi
fi

# No terminal and no --yes: refuse, rather than answer four questions on somebody's
# behalf and write files they never agreed to.
if [ "$HAVE_TTY" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    die "no terminal to ask questions on. Re-run with --yes to accept every default."
fi

existing=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
if [ -n "$existing" ]; then
    warn "a status line is already configured here:"
    say "     $existing"
    say "  It will be backed up, and ./install.sh --restore brings it back."
    if ! yesno "  Replace it?" "y"; then
        say "  nothing was changed."
        exit 0
    fi
fi

# ------------------------------------------------------------------------ questions
UI_LANG="auto"
DISABLE=""
# OFF BY DEFAULT, and it takes a deliberate yes to turn on. Those files carry paths,
# session identifiers and usage figures, and they are read by whatever the user points
# at them. Default-on data publication is not a default anybody chose.
PUBLISH="no"
RENEWAL_DAY=""
RENEWAL_TIME=""

if [ "$ASSUME_YES" = 0 ]; then
    step "Four questions"

    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
        it|it_*|it.*|*_IT*) detected="Italian" ;;
        *)                  detected="English" ;;
    esac
    say ""
    say "${B}1. Language${N}"
    say "   Labels only — everything else is the same. Detected from your locale: ${B}$detected${N}."
    UI_LANG=$(ask "   auto / en / it" "auto")

    say ""
    say "${B}2. Billing countdown${N}"
    say "   Claude Code does not expose your renewal date, so this is the one thing you"
    say "   have to tell it. Skip it and everything else still works."
    say ""
    say "   ${DIM}Where to find it:${N}"
    say "   ${DIM}· the date — claude.ai, Settings, Billing shows the next renewal${N}"
    say "   ${DIM}· the time — not shown anywhere in the UI. It is the timestamp on the${N}"
    say "   ${DIM}  receipt email for your subscription. Search your mail for \"receipt\".${N}"
    say "   ${DIM}  Without it the countdown says \"today\" for the whole day instead of${N}"
    say "   ${DIM}  flipping at the exact hour.${N}"
    say ""
    if yesno "   Set it up now?" "y"; then
        RENEWAL_DAY=$(ask "   Day of the month you are billed (1-31)" "")
        case "$RENEWAL_DAY" in
            ''|*[!0-9]*) RENEWAL_DAY=""; warn "  not a number — skipping the countdown" ;;
            *)
                if [ "$RENEWAL_DAY" -lt 1 ] || [ "$RENEWAL_DAY" -gt 31 ]; then
                    RENEWAL_DAY=""
                    warn "  out of range — skipping the countdown"
                fi ;;
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
        say "   ${DIM}You can let Claude Code find it for you later. Paste this into a session:${N}"
        say "   ${DIM}  Find my Claude.ai subscription renewal date and time from my most${N}"
        say "   ${DIM}  recent subscription receipt emails - the timestamp on the receipt is${N}"
        say "   ${DIM}  the charge time. Then write RENEWAL_DAY and RENEWAL_TIME into${N}"
        say "   ${DIM}  ~/.claude/subscription.conf in HH:MM local time.${N}"
    fi

    say ""
    say "${B}3. Optional blocks${N}"
    say "   All on by default. Each one hides itself anyway when it has nothing to say."
    yesno "   git branch and status?"            "y" || DISABLE="$DISABLE,git"
    yesno "   prompt-cache warm/cold timer?"     "y" || DISABLE="$DISABLE,cache"
    yesno "   progress of a long plan file?"     "y" || DISABLE="$DISABLE,plan"
    if command -v bmad-loop >/dev/null 2>&1; then
        yesno "   bmad-loop run status?"         "y" || DISABLE="$DISABLE,bmad"
    fi
    DISABLE="${DISABLE#,}"

    say ""
    say "${B}4. Write the quota numbers to disk? ${DIM}(off unless you say yes)${N}"
    say "   Claude Code hands those numbers to the status line and nowhere else, so a"
    say "   script of yours cannot read them any other way. Saying yes writes them to"
    say "   ~/.claude/quota-state and a few sibling files, which contain paths, session"
    say "   ids and usage figures. Say no unless something of yours is going to read them."
    if yesno "   Write them?" "n"; then
        PUBLISH="yes"
    fi
fi

# ------------------------------------------------------------------------- install
step "Installing"

mkdir -p "$MANIFEST_DIR"
manifest="$MANIFEST_DIR/$STAMP.manifest"
# Written beside its final name and moved into place only once complete. A manifest that
# becomes visible while it is still being filled in is worse than none: an install
# interrupted halfway leaves a file that LOOKS like a full record, and the next
# --uninstall restores the handful of lines that made it in.
manifest_tmp="$MANIFEST_DIR/.$STAMP.$$.partial"
: > "$manifest_tmp"
trap 'rm -f "$manifest_tmp"' EXIT INT TERM

# The manifest is written BEFORE anything is copied, and it records the state of every
# file this run is allowed to touch — including the ones that do not exist yet, which is
# the only way uninstall can know to delete them afterwards.
for target in $TOUCHED; do
    if [ -f "$CLAUDE_DIR/$target" ]; then
        backup_file "$target"
        printf '%s\texisted\t%s\n' "$target" "$BACKUP_MADE" >> "$manifest_tmp"
    else
        printf '%s\tabsent\t\n' "$target" >> "$manifest_tmp"
    fi
done
# The runtime paths too. They do not exist yet in the normal case, and recording that is
# the only way uninstall can tell "we made this" from "this was already here".
for target in $ARTIFACT_FILES; do
    if [ -f "$CLAUDE_DIR/$target" ]; then
        # A pre-existing runtime file is not only protected from deletion: it gets a real
        # backup, because the status line will start writing over it within seconds.
        # Recording it without one protected it from the uninstall and left it to be
        # overwritten in the meantime, which is half a promise.
        backup_file "$target"
        printf '%s\texisted\t%s\n' "$target" "$BACKUP_MADE" >> "$manifest_tmp"
    elif [ -e "$CLAUDE_DIR/$target" ]; then
        printf '%s\texisted\t\n' "$target" >> "$manifest_tmp"
    else
        printf '%s\tabsent\t\n' "$target" >> "$manifest_tmp"
    fi
done
for target in $ARTIFACT_DIRS; do
    if [ -e "$CLAUDE_DIR/$target" ]; then
        printf '%s\texisted\t\n' "$target" >> "$manifest_tmp"
    else
        printf '%s\tabsent\t\n' "$target" >> "$manifest_tmp"
    fi
done
mv -f "$manifest_tmp" "$manifest" || die "could not write the install manifest"
trap - EXIT INT TERM
say "  manifest written to ${manifest##*/}"

for f in $FILES; do
    cp "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
chmod +x "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/pacekeeper-quota"
say "  four files copied into $CLAUDE_DIR"

# settings.json — merged, never rewritten from scratch: everything else in there belongs
# to the user and to Claude Code. Written to a temp file and moved into place, and every
# step checked: `jq ... && mv` does NOT stop the script when jq fails, and the success
# line then gets printed over a failure.
if [ ! -f "$SETTINGS" ]; then
    printf '{}\n' > "$SETTINGS"
fi
tmp_settings="$SETTINGS.pacekeeper.tmp.$$"
if ! jq '.statusLine = {"type":"command","command":"~/.claude/statusline.sh","refreshInterval":8}' \
        "$SETTINGS" > "$tmp_settings"; then
    rm -f "$tmp_settings"
    die "could not update $SETTINGS — nothing else was changed"
fi
if ! mv -f "$tmp_settings" "$SETTINGS"; then
    rm -f "$tmp_settings"
    die "could not replace $SETTINGS"
fi
say "  settings.json points at the status line"

# The config file. An existing one is amended key by key, so a renewal date already there
# survives a re-run. It is in the manifest, so it can be restored too.
touch "$CONF"
set_key() {
    local key="$1" value="$2" tmpf="$CONF.tmp.$$"
    grep -v "^[[:space:]]*$key[[:space:]]*=" "$CONF" > "$tmpf" 2>/dev/null || true
    if [ -n "$value" ]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmpf"
    fi
    mv -f "$tmpf" "$CONF"
}
if [ "$ASSUME_YES" = 0 ]; then
    set_key UI_LANG "$UI_LANG"
    set_key DISABLE "$DISABLE"
    set_key PUBLISH_STATE "$PUBLISH"
    [ -n "$RENEWAL_DAY" ]  && set_key RENEWAL_DAY "$RENEWAL_DAY"
    [ -n "$RENEWAL_TIME" ] && set_key RENEWAL_TIME "$RENEWAL_TIME"
    say "  settings written to $CONF"
else
    # --yes must not turn on data publication by omission. It is written explicitly.
    set_key PUBLISH_STATE "no"
fi
chmod 600 "$CONF" 2>/dev/null || true

# -------------------------------------------------------------------------- preview
step "This is what it will look like"
now=$(date +%s)
preview_json=$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5"},"transcript_path":"","context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}},"effort":{"level":"high"}}' \
    "$SRC_DIR" "$((now + 4300))" "$((now + 320000))")
say ""
if ! printf '%s\n' "$preview_json" | bash "$CLAUDE_DIR/statusline.sh"; then
    warn "the preview failed — the numbers in it are made up, but the failure is real"
fi
say ""
say "${DIM}(made-up numbers — your real ones appear when Claude Code runs it)${N}"

step "Done"
say "  Open a new Claude Code session, or run ${B}/config${N} in one already open."
say "  Settings live in ${B}$CONF${N} and take effect on the next redraw."
say "  To undo: ${B}./install.sh --uninstall${N}"
