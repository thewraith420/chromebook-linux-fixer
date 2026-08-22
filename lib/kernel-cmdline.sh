#!/bin/bash
# kernel-cmdline.sh — add or remove kernel command line parameters safely,
# across every bootloader present on the machine.
#
#   kernel-cmdline.sh status
#   kernel-cmdline.sh add    iommu=pt
#   kernel-cmdline.sh remove iommu=pt
#   kernel-cmdline.sh active iommu=pt     # exit 0 if in the RUNNING cmdline
#
# Why this is not a one-line sed:
#
# A machine can have more than one bootloader installed, each with its own
# independent copy of the kernel options. The reference machine has both GRUB
# and rEFInd; GRUB is what currently boots, but rEFInd is a registered EFI boot
# entry with a *different* set of options in /boot/refind_linux.conf. Editing
# only GRUB leaves a fix that works today and silently vanishes the first time
# the machine boots the other way — which is a miserable thing to debug.
#
# So: write to every config that exists, verify the result, and restore the
# backup if the bootloader refuses to regenerate.
#
# A malformed kernel command line can stop the machine booting. Every file is
# backed up before modification, and callers should keep a second kernel
# installed as an escape route.

set -uo pipefail

GRUB_DEFAULT=/etc/default/grub
GRUB_KEY=GRUB_CMDLINE_LINUX_DEFAULT
REFIND_LINUX=/boot/refind_linux.conf
STAMP=$(date +%Y%m%d%H%M%S)

die() { echo "error: $*" >&2; exit 1; }

# --- discovery ---------------------------------------------------------------

active_bootloader() {
    # BOOT_IMAGE= is set by GRUB and by most loaders that use the Linux boot
    # protocol properly; rEFInd booting a kernel directly does not set it.
    if grep -q "BOOT_IMAGE=" /proc/cmdline 2>/dev/null; then
        echo grub
    elif [ -f "$REFIND_LINUX" ]; then
        echo refind
    else
        echo unknown
    fi
}

present_configs() {
    [ -f "$GRUB_DEFAULT" ] && echo grub
    [ -f "$REFIND_LINUX" ] && echo refind
}

# --- queries -----------------------------------------------------------------

# Is the parameter in the currently RUNNING kernel command line?
cmd_active() {
    local param="$1"
    grep -qE "(^| )${param//./\\.}( |$)" /proc/cmdline
}

cmd_status() {
    echo "active bootloader: $(active_bootloader)"
    echo "running cmdline:   $(cat /proc/cmdline)"
    echo
    for cfg in $(present_configs); do
        case $cfg in
            grub)   echo "grub   ($GRUB_DEFAULT):"
                    echo "         $(grep -oP "(?<=^$GRUB_KEY=\").*(?=\")" "$GRUB_DEFAULT" 2>/dev/null)" ;;
            refind) echo "refind ($REFIND_LINUX):"
                    grep -oP '(?<=")[^"]*root=[^"]*(?=")' "$REFIND_LINUX" 2>/dev/null \
                        | sed 's/^/         /' ;;
        esac
    done
}

# --- mutation ----------------------------------------------------------------

edit_grub() {
    local action="$1" param="$2"
    [ -f "$GRUB_DEFAULT" ] || return 0

    sudo cp -a "$GRUB_DEFAULT" "$GRUB_DEFAULT.chromebook-fixer.$STAMP" \
        || die "could not back up $GRUB_DEFAULT"

    sudo python3 - "$GRUB_DEFAULT" "$GRUB_KEY" "$action" "$param" <<'PY'
import re, sys
path, key, action, param = sys.argv[1:5]
src = open(path).read()
pat = re.compile(rf'^({re.escape(key)}=")(.*)(")$', re.M)
m = pat.search(src)
if not m:
    # Key absent entirely: add it rather than silently doing nothing.
    src = src.rstrip("\n") + f'\n{key}="{param if action == "add" else ""}"\n'
else:
    tokens = m.group(2).split()
    base = param.split("=", 1)[0]
    # Drop any existing setting of the same key, so add() is idempotent and
    # never leaves two conflicting values on the command line.
    tokens = [t for t in tokens if t != param and t.split("=", 1)[0] != base]
    if action == "add":
        tokens.append(param)
    src = pat.sub(lambda _m: f'{key}="{" ".join(tokens)}"', src, count=1)
open(path, "w").write(src)
PY
    [ $? -eq 0 ] || die "failed editing $GRUB_DEFAULT"

    if ! sudo update-grub >/dev/null 2>&1; then
        echo "update-grub failed; restoring backup" >&2
        sudo cp -a "$GRUB_DEFAULT.chromebook-fixer.$STAMP" "$GRUB_DEFAULT"
        sudo update-grub >/dev/null 2>&1
        die "update-grub failed, no changes kept"
    fi

    # Confirm the generated config really contains what we asked for; a
    # successful update-grub does not by itself prove that.
    if [ "$action" = add ] && [ -f /boot/grub/grub.cfg ]; then
        grep -q -- "$param" /boot/grub/grub.cfg \
            || die "'$param' did not reach /boot/grub/grub.cfg"
    fi
    echo "  grub:   $action $param (backup: $GRUB_DEFAULT.chromebook-fixer.$STAMP)"
}

edit_refind() {
    local action="$1" param="$2"
    [ -f "$REFIND_LINUX" ] || return 0

    sudo cp -a "$REFIND_LINUX" "$REFIND_LINUX.chromebook-fixer.$STAMP" \
        || die "could not back up $REFIND_LINUX"

    sudo python3 - "$REFIND_LINUX" "$action" "$param" <<'PY'
import re, sys
path, action, param = sys.argv[1:4]
base = param.split("=", 1)[0]
out = []
for line in open(path):
    # Each entry is:  "Label"   "kernel options"
    # Only touch real boot entries (those carrying root=), and leave the
    # deliberately minimal / recovery entries alone so a rescue path survives
    # whatever we do here.
    m = re.match(r'^(\s*"[^"]*"\s+")(.*)("\s*)$', line)
    if m and "root=" in m.group(2) and "minimal" not in line.lower():
        tokens = [t for t in m.group(2).split()
                  if t != param and t.split("=", 1)[0] != base]
        if action == "add":
            tokens.append(param)
        line = f'{m.group(1)}{" ".join(tokens)}{m.group(3)}'
        if not line.endswith("\n"):
            line += "\n"
    out.append(line)
open(path, "w").write("".join(out))
PY
    [ $? -eq 0 ] || die "failed editing $REFIND_LINUX"
    echo "  refind: $action $param (backup: $REFIND_LINUX.chromebook-fixer.$STAMP)"
}

cmd_mutate() {
    local action="$1" param="${2:-}"
    [ -n "$param" ] || die "usage: $0 $action <param>"
    case "$param" in
        *' '*) die "one parameter at a time" ;;
    esac

    local configs
    configs=$(present_configs)
    [ -n "$configs" ] || die "no supported bootloader config found"

    echo "Applying to every bootloader present ($(echo $configs | tr '\n' ' ')):"
    for cfg in $configs; do
        case $cfg in
            grub)   edit_grub   "$action" "$param" ;;
            refind) edit_refind "$action" "$param" ;;
        esac
    done
    echo
    echo "A REBOOT is required for this to take effect."
    if [ "$action" = add ]; then
        echo "If the machine fails to boot, choose an older kernel from the boot"
        echo "menu and run: $0 remove $param"
    fi
}

case "${1:-}" in
    status) cmd_status ;;
    active) cmd_active "${2:?usage: $0 active <param>}" ;;
    add|remove) cmd_mutate "$@" ;;
    *) echo "usage: $0 {status|active <param>|add <param>|remove <param>}" >&2; exit 2 ;;
esac
