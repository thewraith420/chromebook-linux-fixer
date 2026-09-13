#!/bin/bash
# boot-menu.sh — the settings that decide what the boot menus do on their own.
#
#   boot-menu.sh show
#   boot-menu.sh grub <seconds>          GRUB_TIMEOUT
#   boot-menu.sh nightfall <seconds>     /boot/nightfall-timeout
#   boot-menu.sh rotate <0|90|180|270>   /boot/nightfall-rotate
#   boot-menu.sh autorotate <on|off>     /boot/nightfall-autorotate
#
# GRUB's lives in /etc/default/grub and needs update-grub. Nightfall's three
# live as one-line files on /boot, read at boot by its init (34cb3bc, ac312cb)
# - files rather than a rebuilt initramfs, so they survive rebuilding the image
# and can be changed from a machine with no keyboard.
#
# `show` reports what Nightfall will actually USE, not what the file says.
# Nightfall ignores a file it cannot parse and falls back to its default, so a
# raw read of a garbage file would describe a setting that is not in effect.
# The parsing below mirrors init's exactly - `read -r`, which strips
# surrounding whitespace, then an exact match - so the two cannot disagree.
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
NF_TIMEOUT_FILE="${NF_TIMEOUT_FILE:-/boot/nightfall-timeout}"
NF_ROTATE_FILE="${NF_ROTATE_FILE:-/boot/nightfall-rotate}"
NF_AUTOROTATE_FILE="${NF_AUTOROTATE_FILE:-/boot/nightfall-autorotate}"
NF_MAX=3600              # Nightfall accepts 0..3600 inclusive
NF_DEFAULT_TIMEOUT=30    # DEFAULT_TIMEOUT_SECS in ui/nightfall.c as of 34cb3bc
NF_DEFAULT_ROTATE=270    # init's `: "${NIGHTFALL_ROTATE:=270}"`

die() { echo "error: $*" >&2; exit 1; }

# First line of a file with surrounding whitespace stripped - the same thing
# init's `read -r v < file` produces. Empty if unreadable.
first_line() { local v=""; read -r v < "$1" 2>/dev/null || true; printf '%s' "$v"; }

grub_current() {
    grep -hE '^GRUB_TIMEOUT=' "$GRUB_FILE" 2>/dev/null \
        | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# Each prints "<effective value>|<where it came from>".
nf_timeout_effective() {
    [ -f "$NF_TIMEOUT_FILE" ] || { echo "$NF_DEFAULT_TIMEOUT|built-in default"; return; }
    local v; v=$(first_line "$NF_TIMEOUT_FILE")
    case "$v" in
        ''|*[!0-9]*) echo "$NF_DEFAULT_TIMEOUT|built-in default (file ignored: '$v')" ;;
        *) if [ "$v" -le "$NF_MAX" ]; then echo "$v|$NF_TIMEOUT_FILE"
           else echo "$NF_DEFAULT_TIMEOUT|built-in default (file ignored: ${v}s out of range)"; fi ;;
    esac
}
nf_rotate_effective() {
    [ -f "$NF_ROTATE_FILE" ] || { echo "$NF_DEFAULT_ROTATE|default"; return; }
    local v; v=$(first_line "$NF_ROTATE_FILE")
    case "$v" in
        0|90|180|270) echo "$v|$NF_ROTATE_FILE" ;;
        *) echo "$NF_DEFAULT_ROTATE|default (file ignored: '$v')" ;;
    esac
}
nf_autorotate_effective() {
    [ -f "$NF_AUTOROTATE_FILE" ] || { echo "on|default"; return; }
    local v; v=$(first_line "$NF_AUTOROTATE_FILE")
    case "$v" in
        1|on)  echo "on|$NF_AUTOROTATE_FILE" ;;
        0|off) echo "off|$NF_AUTOROTATE_FILE" ;;
        *)     echo "on|default (file ignored: '$v')" ;;
    esac
}

cmd_show() {
    local g t r a
    g=$(grub_current)
    echo "GRUB menu              ${g:-unset}${g:+s}"
    case "$g" in
        -1) echo "                         waits forever - needs a keypress to continue" ;;
        0)  echo "                         no menu; boots the default entry immediately" ;;
    esac
    t=$(nf_timeout_effective)
    echo "Nightfall menu         ${t%%|*}s   (${t#*|})"
    [ "${t%%|*}" = 0 ] && echo "                         auto-boot DISABLED - the menu waits forever"
    r=$(nf_rotate_effective); a=$(nf_autorotate_effective)
    echo "Nightfall rotation     starts at ${r%%|*}°   (${r#*|})"
    echo "Nightfall auto-rotate  ${a%%|*}   (${a#*|})"
    if [ "${a%%|*}" = on ]; then
        echo "                         starting rotation only matters until the first"
        echo "                         accelerometer reading, about 750ms in"
    else
        echo "                         auto-rotate off: the starting rotation is pinned"
    fi
}

# Write one small file on /boot as root. One escalation: under the GUI $SUDO is
# pkexec, which keeps no credential cache.
write_boot_file() {
    $SUDO bash -s -- "$1" "$2" <<'ROOT'
set -euo pipefail
printf '%s\n' "$2" > "$1"
chmod 0644 "$1"
ROOT
}

cmd_grub() {
    local v="$1" prev
    # -1 means wait forever, 0 means no menu, otherwise whole seconds. A plain
    # digits test, not an extglob pattern: extglob is off by default, so the
    # clever version was a syntax error in this very file.
    case "$v" in
        -1) ;;
        ''|*[!0-9]*) die "GRUB timeout must be whole seconds, 0, or -1 to wait forever" ;;
    esac
    prev=$(grub_current)
    echo "setting GRUB_TIMEOUT=$v (was ${prev:-unset})"
    [ "$v" = -1 ] && echo "note: -1 waits forever, which needs a keypress to get past."
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
    # Same acceptance as Nightfall's own - digits only, 0..3600 - so what is
    # refused here is exactly what Nightfall would have silently ignored.
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
    echo "writing $v to $NF_TIMEOUT_FILE"
    write_boot_file "$NF_TIMEOUT_FILE" "$v"
    echo "takes effect on the next boot through Nightfall."
}

cmd_rotate() {
    local v="$1"
    # Exactly the four values Nightfall's hook accepts. Anything else it would
    # ignore and keep 270 - and it must never reach parse_rotation(), which
    # turns unknown strings into 0, sideways on this panel.
    case "$v" in
        0|90|180|270) ;;
        *) die "starting rotation must be 0, 90, 180 or 270" ;;
    esac
    echo "writing $v to $NF_ROTATE_FILE"
    write_boot_file "$NF_ROTATE_FILE" "$v"
    local a; a=$(nf_autorotate_effective)
    if [ "${a%%|*}" = on ]; then
        echo "auto-rotate is on, so this is only where Nightfall starts - the"
        echo "accelerometer takes over within about 750ms."
    else
        echo "auto-rotate is off, so Nightfall will stay at ${v}°."
    fi
}

cmd_autorotate() {
    local v
    # Normalised to 1/0 on disk. Nightfall accepts on/off too, but writing the
    # canonical form means nothing here ever depends on that.
    case "$1" in
        1|on)  v=1 ;;
        0|off) v=0 ;;
        *) die "auto-rotate must be on or off" ;;
    esac
    echo "writing $v to $NF_AUTOROTATE_FILE"
    write_boot_file "$NF_AUTOROTATE_FILE" "$v"
    if [ "$v" = 1 ]; then
        echo "auto-rotate on: Nightfall follows the accelerometer."
    else
        echo "auto-rotate off: Nightfall stays at its starting rotation."
    fi
}

case "${1:-show}" in
    show)       cmd_show ;;
    grub)       cmd_grub "${2:?usage: $0 grub <seconds>}" ;;
    nightfall)  cmd_nightfall "${2:?usage: $0 nightfall <seconds>}" ;;
    rotate)     cmd_rotate "${2:?usage: $0 rotate <0|90|180|270>}" ;;
    autorotate) cmd_autorotate "${2:?usage: $0 autorotate <on|off>}" ;;
    *) echo "usage: $0 {show|grub <s>|nightfall <s>|rotate <deg>|autorotate <on|off>}" >&2; exit 2 ;;
esac
