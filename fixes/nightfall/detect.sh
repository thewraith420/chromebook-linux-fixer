#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# The project was renamed (nocturne-boot-picker -> nightfall-boot-manager).
# Match either marker: a machine can be on either side of that migration, and
# checking only the current name reports a working install as absent.
PICKER_NAMES="nightfall-boot-manager nocturne-boot-picker"
CUSTOM_CFG="${CUSTOM_CFG:-/boot/grub/custom.cfg}"
GRUB_DIR="${GRUB_DIR:-/boot/grub}"

picker_marker() {
    local n
    for n in $PICKER_NAMES; do
        grep -qsF "### BEGIN $n ###" "$CUSTOM_CFG" 2>/dev/null && { echo "$n"; return 0; }
    done
    return 1
}

# The picker is a GRUB entry that chainloads a kernel. No GRUB, nothing to add.
[ -d "$GRUB_DIR" ] || exit 1

# Already installed? The markers install-picker.sh writes are the record.
if picker_marker >/dev/null; then
    exit 1
fi

# Nightfall used to be Slate-only, so this required a touchscreen: the problem
# it solved was "no keyboard, so GRUB's menu cannot be navigated". It now runs
# on any x86-64-v2 PC and is driven by touch, keyboard or mouse, so a missing
# touchscreen is no longer a reason to withhold it - it changes what the row
# SAYS, not whether Apply is offered. What can still make it impossible is the
# CPU: the kernel is built for x86-64-v2 and does not start on anything older.
. "${FIXER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/lib/cpu-level.sh"
MISSING=$(cpu_x86_64_v2_missing)
if [ -n "$MISSING" ]; then
    echo "this CPU is missing x86-64-v2 features ($MISSING); the Nightfall kernel would not start"
    exit 1
fi

# "wcom" (not "wacom"): confirmed missing this exact device on a real Nocturne
# 2026-09-20 - its digitizer enumerates under its raw ACPI HID, "WCOM50C1:00
# 2D1F:486C" (base node, plus "... Mouse", "... Stylus", "... UNKNOWN" x2 for
# the touch/pen/proximity sub-devices), with no "touch" or the spelled-out
# company name anywhere in it. "WCOM" is Wacom's actual 4-letter ACPI vendor
# prefix (2D1F is their USB vendor ID, visible in the same string) - this is
# what a Wacom digitizer looks like whenever nothing has renamed it to
# something friendlier, which on this hardware is a ChromeOS-specific udev
# rule. Any non-ChromeOS-derived distro is missing that rule, so this was
# never a one-off: it would misdetect on every one of them, not only the
# machine that happened to surface it.
INPUT_CLASS_DIR="${INPUT_CLASS_DIR:-/sys/class/input}"
TOUCH=no
for d in "$INPUT_CLASS_DIR"/input*/name; do
    grep -qiE "touchscreen|wacom|^wcom|hid.*touch" "$d" 2>/dev/null && { TOUCH=yes; break; }
done
if [ "$TOUCH" = yes ]; then
    echo "GRUB's menu needs a keyboard this machine may not have attached;"
    echo "no touch boot picker is installed"
else
    echo "no Nightfall boot manager is installed (no touchscreen here: it is driven by keyboard and mouse)"
fi
echo "Tested on the Google Pixel Slate and a Lenovo LOQ; other hardware is untested."
exit 0
