#!/bin/bash
# updates.sh — is this machine behind, and (for the two git checkouts) catch up.
#
#   updates.sh check [--porcelain] [fixer|nightfall-source|nightfall-kernel]...
#   updates.sh pull  fixer|nightfall-source
#
# Three things can be out of date, and they are three different kinds of stale:
#
#   fixer             this tool - a git checkout; ~/.local/bin/* are symlinks
#                     into it, so a fast-forward IS the update.
#   nightfall-source  the nightfall-boot-manager checkout the `nightfall` fix
#                     builds from. Pulled here; REBUILT and reinstalled by
#                     `chromebook-fixer update nightfall`, which is the part
#                     that needs root.
#   nightfall-kernel  /boot/nightfall/vmlinuz against BobZKernel's newest
#                     "nightfall" release. Only compared here - replacing it
#                     is the apply script's job, with its rollback copy.
#
# `check` changes nothing on disk. It talks to the network (git fetch, the
# release feed), so every network call is bounded and a failure is "unknown",
# never an error: an offline machine must not see a broken tool.
#
# `pull` is fast-forward only and refuses, saying why, whenever it would have
# to do anything else - local changes, unpushed commits, a diverged branch.
# The Slate and the build PC both commit to these repos (see CLAUDE.md: real
# collision history), so "just merge it" is exactly the wrong reflex here.
#
# Porcelain rows, tab-separated, one per component:
#   <component> <state> <installed> <available> <detail>
# state is one of: current behind blocked unknown na
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXER_ROOT="${FIXER_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
NF_BOOT_DIR="${NF_BOOT_DIR:-/boot/nightfall}"
NF_KERNEL_API="${NF_KERNEL_API:-https://api.github.com/repos/thewraith420/BobZKernel/releases}"
NET_SECS="${UPDATES_NET_SECS:-20}"
export GIT_TERMINAL_PROMPT=0     # a credential prompt here would hang a GUI

die() { echo "$*" >&2; exit 1; }

# Same search order as fixes/nightfall/apply.sh, so both find the same checkout.
find_nightfall_source() {
    local c
    if [ -n "${FIXER_NIGHTFALL_REPO:-${FIXER_PICKER_REPO:-}}" ]; then
        echo "${FIXER_NIGHTFALL_REPO:-$FIXER_PICKER_REPO}"; return 0
    fi
    for c in "$HOME/nightfall-boot-manager" "$HOME/buildstuff/nightfall-boot-manager" \
             "$HOME/nocturne-boot-picker" "$HOME/buildstuff/nocturne-boot-picker"; do
        [ -d "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

# git_state <dir>  ->  sets G_STATE G_INSTALLED G_AVAILABLE G_DETAIL G_BEHIND
git_state() {
    local dir="$1" up ahead dirty
    G_STATE=na; G_INSTALLED=""; G_AVAILABLE=""; G_DETAIL=""; G_BEHIND=0
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
        || { G_DETAIL="not a git checkout"; return; }
    G_INSTALLED=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    if ! timeout "$NET_SECS" git -C "$dir" fetch -q 2>/dev/null; then
        G_STATE=unknown; G_DETAIL="could not reach the remote"; return
    fi
    up=$(git -C "$dir" rev-parse --abbrev-ref '@{u}' 2>/dev/null) \
        || { G_STATE=unknown; G_DETAIL="branch has no upstream to compare with"; return; }
    G_AVAILABLE=$(git -C "$dir" rev-parse --short "$up" 2>/dev/null)
    G_BEHIND=$(git -C "$dir" rev-list --count "HEAD..$up" 2>/dev/null || echo 0)
    ahead=$(git -C "$dir" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)
    dirty=$(git -C "$dir" status --porcelain -uno 2>/dev/null | wc -l)
    if [ "$G_BEHIND" -eq 0 ]; then
        G_STATE=current
        [ "$ahead" -gt 0 ] && G_DETAIL="$ahead commit(s) not pushed yet"
        return
    fi
    G_DETAIL="$G_BEHIND commit(s) behind"
    if [ "$ahead" -gt 0 ]; then
        G_STATE=blocked; G_DETAIL="$G_DETAIL, but $ahead local commit(s) are not pushed - would need a merge"
    elif [ "$dirty" -gt 0 ]; then
        G_STATE=blocked; G_DETAIL="$G_DETAIL, but $dirty file(s) have local changes"
    else
        G_STATE=behind
    fi
}

row() {   # row <component> <state> <installed> <available> <detail>
    if [ -n "$PORCELAIN" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
        return
    fi
    local label; case "$1" in
        fixer)            label="Chromebook Fixer" ;;
        nightfall-source) label="Nightfall (source)" ;;
        nightfall-kernel) label="Nightfall kernel" ;;
        *)                label="$1" ;;
    esac
    case "$2" in
        current) printf '  %-20s up to date%s\n' "$label" "${3:+  ($3)}${5:+ - $5}" ;;
        behind)  printf '  %-20s UPDATE AVAILABLE  %s -> %s%s\n' "$label" "$3" "$4" "${5:+  ($5)}" ;;
        blocked) printf '  %-20s update available but not applied: %s\n' "$label" "$5" ;;
        unknown) printf '  %-20s could not tell: %s\n' "$label" "$5" ;;
        na)      printf '  %-20s -\n' "$label" ;;
    esac
    return 0
}

check_fixer() {
    git_state "$FIXER_ROOT"
    row fixer "$G_STATE" "$G_INSTALLED" "$G_AVAILABLE" "$G_DETAIL"
}

check_nightfall_source() {
    local src
    src=$(find_nightfall_source) || { row nightfall-source na "" "" "no checkout on this machine"; return; }
    git_state "$src"
    row nightfall-source "$G_STATE" "$G_INSTALLED" "$G_AVAILABLE" "$G_DETAIL"
}

# The kernel release string of an installed bzImage, or empty.
kernel_release_of() {
    command -v file >/dev/null 2>&1 || return 0
    file -b "$1" 2>/dev/null | sed -n 's/.*[Vv]ersion \([^ ,]*\).*/\1/p' | head -1
}

# Newest published nightfall-kernel release string (vmlinuz-<this>), or empty.
latest_nightfall_release() {
    command -v curl >/dev/null 2>&1 || return 0
    timeout "$NET_SECS" curl -fsSL "$NF_KERNEL_API" 2>/dev/null \
        | grep -oE '"browser_download_url": *"[^"]*/vmlinuz-[^"/]*nightfall"' \
        | head -1 | sed -E 's#.*/vmlinuz-([^"/]*)"#\1#' || true
}

check_nightfall_kernel() {
    local have want newest
    [ -e "$NF_BOOT_DIR/vmlinuz" ] || { row nightfall-kernel na "" "" "Nightfall is not installed"; return; }
    have=$(kernel_release_of "$NF_BOOT_DIR/vmlinuz")
    [ -n "$have" ] || { row nightfall-kernel unknown "" "" "cannot read the installed kernel's version"; return; }
    want=$(latest_nightfall_release)
    [ -n "$want" ] || { row nightfall-kernel unknown "$have" "" "could not read the release list"; return; }
    if [ "$have" = "$want" ]; then
        row nightfall-kernel current "$have" "$want" ""
        return
    fi
    # Different is not the same as older: a kernel deployed from a build ahead
    # of its own release is legitimately newer, and must not be "updated" back.
    newest=$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -1)
    if [ "$newest" = "$have" ]; then
        row nightfall-kernel current "$have" "$want" "newer than the published release"
    else
        row nightfall-kernel behind "$have" "$want" ""
    fi
}

cmd_check() {
    local want=("$@") c
    [ ${#want[@]} -gt 0 ] || want=(fixer nightfall-source nightfall-kernel)
    [ -n "$PORCELAIN" ] || echo "Updates:"
    for c in "${want[@]}"; do
        case "$c" in
            fixer)            check_fixer ;;
            nightfall-source) check_nightfall_source ;;
            nightfall-kernel) check_nightfall_kernel ;;
            *) die "unknown component: $c" ;;
        esac
    done
}

# pull <dir> <label>: fast-forward only, or refuse and say why. Sets PULLED=1
# only when something actually moved, so callers do follow-up work (relinking,
# "restart the app") for a real update and not for a no-op.
pull_checkout() {
    local dir="$1" label="$2"
    PULLED=""
    git_state "$dir"
    case "$G_STATE" in
        na)      die "$label: ${G_DETAIL:-nothing to update}" ;;
        unknown) die "$label: could not check for updates - ${G_DETAIL}. Nothing changed." ;;
        blocked) die "$label: not updating - ${G_DETAIL}. Nothing changed." ;;
        current) echo "$label is already up to date ($G_INSTALLED)."; return 0 ;;
    esac
    echo "$label: $G_BEHIND commit(s) behind; updating $G_INSTALLED -> $G_AVAILABLE"
    git -C "$dir" log --oneline "HEAD..@{u}" | head -15 | sed 's/^/    /'
    git -C "$dir" pull --ff-only -q || die "$label: fast-forward failed. Nothing changed."
    PULLED=1
    echo "$label updated to $(git -C "$dir" rev-parse --short HEAD)."
}

cmd_pull() {
    case "${1:-}" in
        fixer)
            pull_checkout "$FIXER_ROOT" "Chromebook Fixer" || exit 1
            [ -n "$PULLED" ] || exit 0
            # The desktop entry and icon are COPIES made by install.sh, so a
            # pull alone leaves them stale; re-running it is idempotent.
            if [ -x "$FIXER_ROOT/install.sh" ]; then
                "$FIXER_ROOT/install.sh" >/dev/null 2>&1 \
                    && echo "Refreshed the launcher entry and links." \
                    || echo "note: install.sh did not complete; run it by hand to refresh the launcher."
            fi
            echo "Restart the app to run the new version."
            ;;
        nightfall-source)
            local src; src=$(find_nightfall_source) \
                || die "no nightfall-boot-manager checkout found on this machine"
            pull_checkout "$src" "Nightfall source" || exit 1
            ;;
        *) die "usage: updates.sh pull fixer|nightfall-source" ;;
    esac
}

main() {
    PORCELAIN=""; PULLED=""
    local sub="${1:-}"; shift || true
    if [ "${1:-}" = "--porcelain" ]; then PORCELAIN=1; shift; fi
    case "$sub" in
        check) cmd_check "$@" ;;
        pull)  cmd_pull "$@" ;;
        *) die "usage: updates.sh check [--porcelain] [component...] | pull fixer|nightfall-source" ;;
    esac
}
# A function and an explicit exit: `pull fixer` replaces this very file on
# disk, and bash must not go on reading a script that changed under it.
main "$@"
exit $?
