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
# nocturne-boot-picker adds a THIRD copy, for the same reason and with a worse
# failure mode. Its GRUB entry lives in /boot/grub/custom.cfg, which 41_custom
# sources at boot and which update-grub deliberately never regenerates - so the
# i915 panel quirks it carries are frozen at install time and drift the moment
# a fix here adds or removes one. When they drift wrong the panel does not
# light: drmModeSetCrtc returns success into a dark screen, so the picker's own
# error handling has nothing to catch, and on the Slate the picker is the
# default entry. Only i915.* is propagated there - the picker mounts its own
# root and has no use for iommu=, root= or crashkernel=, matching what
# install-picker.sh chooses to carry.
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
PICKER_CFG=/boot/grub/custom.cfg
PICKER_BEGIN="### BEGIN nocturne-boot-picker ###"
PICKER_END="### END nocturne-boot-picker ###"
STAMP=$(date +%Y%m%d%H%M%S)

die() { echo "error: $*" >&2; exit 1; }

# --- discovery ---------------------------------------------------------------

active_bootloader() {
    # BOOT_IMAGE= is set by GRUB and by most loaders that use the Linux boot
    # protocol properly; rEFInd booting a kernel directly does not set it.
    #
    # Neither does a kexec from the boot picker: the picker passes the cmdline
    # it parsed out of the grub.cfg "linux" line, and BOOT_IMAGE= is injected
    # by GRUB at boot rather than being part of that text. So a picker boot
    # looks exactly like a rEFInd boot to the test above, and this reported
    # "refind" on a machine that had booted through GRUB. Check the picker
    # first, and only then fall through.
    if grep -q "BOOT_IMAGE=" /proc/cmdline 2>/dev/null; then
        echo grub
    elif picker_installed && [ -f /boot/grub/grub.cfg ]; then
        echo "grub (kexec via boot picker)"
    elif [ -f "$REFIND_LINUX" ]; then
        echo refind
    else
        echo unknown
    fi
}

# The picker's entry, identified by the markers install-picker.sh writes.
# Absent markers mean the picker is not installed, or was installed by hand -
# either way there is no block we own the shape of, so leave it alone.
picker_installed() {
    [ -f "$PICKER_CFG" ] || return 1
    grep -qF "$PICKER_BEGIN" "$PICKER_CFG" 2>/dev/null
}

# The kernel options on the picker entry's own "linux" line.
picker_cmdline() {
    picker_installed || return 1
    awk -v b="$PICKER_BEGIN" -v e="$PICKER_END" '
        index($0, b) { inblock = 1; next }
        index($0, e) { inblock = 0; next }
        inblock && $1 == "linux" {
            c = ""
            for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i
            print c
            exit
        }' "$PICKER_CFG"
}

# The i915.* options of a cmdline, one per line and sorted, so two cmdlines
# can be compared on the part the picker actually carries.
i915_options() {
    tr ' ' '\n' | grep '^i915\.' | sort
}

present_configs() {
    [ -f "$GRUB_DEFAULT" ] && echo grub
    [ -f "$REFIND_LINUX" ] && echo refind
}

# --- queries -----------------------------------------------------------------

# Is the parameter in the currently RUNNING kernel command line?
# exit 0 = present, 1 = absent, 2 = cannot tell.
#
# "Absent" and "unreadable" must not collapse into one answer. /proc/cmdline is
# world-readable by default, but not always: on the reference Slate it is mode
# 0440 root:1001, and an ordinary user reading it gets EACCES. A caller that
# reads that failure as "the parameter is not set" reports an applied fix as
# missing and invites someone to add a boot parameter that is already there -
# or, worse, credits a kernel quirk for a state a cmdline parameter produced.
# Callers should map 2 onto their own "cannot tell" exit rather than guessing.
cmd_active() {
    local param="$1"
    if [ ! -r /proc/cmdline ]; then
        echo "cannot read /proc/cmdline ($(stat -c '%A %U:%G (uid %u gid %g)' /proc/cmdline \
              2>/dev/null || echo 'not present'))" >&2
        return 2
    fi
    grep -qE "(^| )${param//./\\.}( |$)" /proc/cmdline
}

cmd_status() {
    echo "active bootloader: $(active_bootloader)"
    if [ -r /proc/cmdline ]; then
        echo "running cmdline:   $(cat /proc/cmdline)"
    else
        echo "running cmdline:   UNREADABLE" \
             "($(stat -c '%A %U:%G (uid %u gid %g)' /proc/cmdline 2>/dev/null || echo absent))"
        echo "                   every check against the running kernel reads"
        echo "                   'cannot tell' until this is readable"
    fi
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
    if picker_installed; then
        echo "picker ($PICKER_CFG):"
        echo "         $(picker_cmdline)"
        if cmd_picker_drift >/dev/null 2>&1; then
            echo "         WARNING: its i915.* options differ from the running kernel"
        fi
    fi
}

# --- the picker's frozen copy -------------------------------------------------

# exit 0 = drifted (the picker carries different i915.* options than the
# running kernel), 1 = in sync, 2 = no picker installed.
cmd_picker_drift() {
    picker_installed || return 2
    # Unreadable is not the same as different: comparing against an empty
    # string would report drift on every machine where /proc/cmdline is
    # restricted, and the "repair" for that is rewriting a boot entry that
    # was correct.
    [ -r /proc/cmdline ] || return 2
    local running picker
    running=$(i915_options < /proc/cmdline)
    picker=$(picker_cmdline | i915_options)
    [ "$running" = "$picker" ] && return 1
    return 0
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

edit_picker() {
    local action="$1" param="$2"
    picker_installed || return 0

    # The picker mounts its own root and draws on the panel; nothing else on
    # the command line is its business. install-picker.sh makes the same cut.
    case "$param" in
        i915.*) : ;;
        *) return 0 ;;
    esac

    sudo cp -a "$PICKER_CFG" "$PICKER_CFG.chromebook-fixer.$STAMP" \
        || die "could not back up $PICKER_CFG"

    sudo python3 - "$PICKER_CFG" "$PICKER_BEGIN" "$PICKER_END" "$action" "$param" <<'PY'
import re, sys
path, begin, end, action, param = sys.argv[1:6]
base = param.split("=", 1)[0]
out, inblock, changed = [], False, False
for line in open(path):
    if begin in line:
        inblock = True
    elif end in line:
        inblock = False
    elif inblock:
        # "linux <image> <options...>" - keep the image, rewrite the options.
        m = re.match(r'^(\s*linux\s+\S+)(.*)$', line)
        if m:
            tokens = [t for t in m.group(2).split()
                      if t != param and t.split("=", 1)[0] != base]
            if action == "add":
                tokens.append(param)
            line = (m.group(1) + (" " + " ".join(tokens) if tokens else "")) + "\n"
            changed = True
    out.append(line)
open(path, "w").write("".join(out))
sys.exit(0 if changed else 1)
PY
    [ $? -eq 0 ] || die "no 'linux' line inside the picker block in $PICKER_CFG"

    # Deliberately no update-grub: custom.cfg is sourced at boot, never
    # regenerated. Running it here would undo the one property the picker's
    # installer is built around.
    echo "  picker: $action $param (backup: $PICKER_CFG.chromebook-fixer.$STAMP)"
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

    local present="$configs"
    picker_installed && present="$present picker"
    echo "Applying to every bootloader present ($(echo $present | tr '\n' ' ')):"
    for cfg in $configs; do
        case $cfg in
            grub)   edit_grub   "$action" "$param" ;;
            refind) edit_refind "$action" "$param" ;;
        esac
    done
    edit_picker "$action" "$param"
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
    picker-cmdline) picker_cmdline ;;
    picker-drift) cmd_picker_drift ;;
    *) echo "usage: $0 {status|active <param>|add <param>|remove <param>|"\
            "picker-cmdline|picker-drift}" >&2; exit 2 ;;
esac
