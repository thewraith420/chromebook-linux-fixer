#!/bin/bash
# boot-timeout.sh — how long each boot menu waits before deciding for you.
#
#   boot-timeout.sh show
#   boot-timeout.sh grub <seconds>
#   boot-timeout.sh nightfall <seconds>
#
# Two menus, two mechanisms, deliberately not merged into one number.
#
# GRUB's is GRUB_TIMEOUT in /etc/default/grub and needs update-grub to take
# effect. Nightfall's is /boot/nightfall-timeout, a bare integer read at boot -
# a file rather than a rebuilt initramfs, so it survives rebuilding the image
# and can be changed from a machine with no keyboard.
#
# The value that strands you is not the same on both. For GRUB, 0 boots the
# default immediately and -1 waits forever. For Nightfall, 0 DISABLES auto-boot
# and the menu waits forever - so on a tablet whose touchscreen may be the
# thing that is broken, Nightfall's 0 is the dangerous one and GRUB's is not.
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
NF_FILE="${NF_FILE:-/boot/nightfall-timeout}"
NF_MAX=3600            # Nightfall's own accepted range is 0..3600 inclusive

die() { echo "error: $*" >&2; exit 1; }

grub_current() {
    grep -hE '^GRUB_TIMEOUT=' "$GRUB_FILE" 2>/dev/null \
        | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

cmd_show() {
    local g nf
    g=$(grub_current)
    echo "GRUB menu      ${g:-unset}${g:+s}"
    case "$g" in
        -1) echo "                 waits forever - needs a keypress to continue" ;;
        0)  echo "                 no menu; boots the default entry immediately" ;;
    esac

    if [ -r "$NF_FILE" ]; then
        nf=$(head -1 "$NF_FILE" 2>/dev/null | tr -d '[:space:]')
        echo "Nightfall menu ${nf}s   ($NF_FILE)"
        [ "$nf" = 0 ] && echo "                 auto-boot DISABLED - the menu waits forever"
    elif [ -e "$NF_FILE" ]; then
        echo "Nightfall menu (unreadable: $NF_FILE)"
    else
        echo "Nightfall menu built-in default (no $NF_FILE)"
    fi
}

cmd_grub() {
    local v="$1" prev
    # -1 means wait forever, 0 means no menu, otherwise whole seconds. Kept as
    # a plain digits test rather than an extglob pattern: extglob is off by
    # default, so the clever version was a syntax error in this very file.
    case "$v" in
        -1) ;;
        ''|*[!0-9]*) die "GRUB timeout must be whole seconds, 0, or -1 to wait forever" ;;
    esac

    prev=$(grub_current)
    echo "setting GRUB_TIMEOUT=$v (was ${prev:-unset})"
    [ "$v" = -1 ] && echo "note: -1 waits forever, which needs a keypress to get past."
    # One escalation: under the GUI $SUDO is pkexec and keeps no credential
    # cache, so a second call is a second password prompt.
    $SUDO bash -s -- "$GRUB_FILE" "$v" <<'ROOT'
set -euo pipefail
F="$1"; V="$2"
BAK="$F.chromebook-fixer.$(date +%Y%m%d%H%M%S)"
cp -a "$F" "$BAK"
if grep -qE '^GRUB_TIMEOUT=' "$F"; then
    sed -i "s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=$V|" "$F"
else
    printf 'GRUB_TIMEOUT=%s\n' "$V" >> "$F"
fi
if ! update-grub >/dev/null 2>&1; then
    echo "update-grub failed; restoring $F" >&2
    cp -a "$BAK" "$F"; update-grub >/dev/null 2>&1 || true
    exit 1
fi
echo "  backup: $BAK"
ROOT
}

cmd_nightfall() {
    local v="$1"
    # Nightfall accepts digits only, 0..3600, and treats anything else as
    # absent. Rejecting the same things here means someone finds out now
    # rather than from a log line after a reboot.
    case "$v" in
        ''|*[!0-9]*) die "Nightfall's timeout must be whole seconds, digits only (0-$NF_MAX)" ;;
    esac
    [ "$v" -le "$NF_MAX" ] || die "Nightfall's timeout tops out at ${NF_MAX}s"

    if [ "$v" = 0 ]; then
        echo "WARNING: 0 does not boot immediately - it DISABLES Nightfall's"
        echo "auto-boot, so the menu waits for a tap forever. On a machine with"
        echo "no keyboard, that is unrecoverable if the touchscreen is the thing"
        echo "that has failed."
        [ -n "${FIXER_YES:-}" ] || die "re-run with -y if that is genuinely what you want"
    elif [ "$v" -lt 5 ]; then
        echo "note: ${v}s is short - this panel takes a moment to light, so a"
        echo "very low timeout can decide before anything is visible."
    fi

    echo "writing $v to $NF_FILE"
    $SUDO bash -s -- "$NF_FILE" "$v" <<'ROOT'
set -euo pipefail
F="$1"; V="$2"
printf '%s\n' "$V" > "$F"
chmod 0644 "$F"
ROOT
    echo "takes effect on the next boot through Nightfall."
}

case "${1:-show}" in
    show)      cmd_show ;;
    grub)      cmd_grub "${2:?usage: $0 grub <seconds>}" ;;
    nightfall) cmd_nightfall "${2:?usage: $0 nightfall <seconds>}" ;;
    *) echo "usage: $0 {show|grub <secs>|nightfall <secs>}" >&2; exit 2 ;;
esac
