#!/bin/bash
# fixes/nightfall/detect.sh against fixture /boot/grub, custom.cfg and
# /sys/class/input trees. Nothing here touches the real system.
#
# The touchscreen cases exist because of a real miss: a genuine Pixel Slate,
# confirmed 2026-09-20, whose Wacom digitizer enumerates under its raw ACPI
# HID - "WCOM50C1:00 2D1F:486C" plus " Mouse"/" Stylus"/" UNKNOWN" sub-device
# suffixes - with neither "touch" nor the spelled-out company name anywhere in
# it. The regex looked for "wacom"; the device says "WCOM". That happens
# whenever nothing has renamed the device to something friendlier, which is a
# ChromeOS-specific udev rule - so every non-ChromeOS-derived distro on this
# hardware hit it, not just the one machine that happened to surface it first.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="${D:-$REPO/fixes/nightfall/detect.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() {  # expect <name> <exit> <command...>
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name  (want $want, got $got)"; fi
}
says() {    # says <name> <pattern> <command...>
    local name="$1" pat="$2"; shift 2
    local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<< "$out"; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name  (no '$pat' in output)"; fi
}

GRUB="$T/grub"; CFG="$T/grub/custom.cfg"; INPUT="$T/input"
run() { GRUB_DIR="$GRUB" CUSTOM_CFG="$CFG" INPUT_CLASS_DIR="$INPUT" "$D"; }

reset_fixture() {
    rm -rf "$GRUB" "$INPUT"; mkdir -p "$GRUB" "$INPUT"
    rm -f "$CFG"
}
touch_device() {   # touch_device <input-n> <name string>
    mkdir -p "$INPUT/input$1"
    printf '%s\n' "$2" > "$INPUT/input$1/name"
}

# ---- no GRUB, nothing to chainload into --------------------------------
reset_fixture
expect "no /boot/grub at all"            1 run

# ---- already installed short-circuits, regardless of touch state -------
reset_fixture
touch_device 0 "Lid Switch"        # no touch device present at all
printf '### BEGIN nightfall-boot-manager ###\n### END nightfall-boot-manager ###\n' > "$CFG"
expect "already installed (current name)" 1 run
: > "$CFG"
printf '### BEGIN nocturne-boot-picker ###\n### END nocturne-boot-picker ###\n' > "$CFG"
expect "already installed (renamed-from marker)" 1 run

# ---- no touch device: correctly not needed ------------------------------
reset_fixture
touch_device 0 "Lid Switch"
touch_device 1 "Power Button"
touch_device 2 "Logitech K540e"
expect "no touch device present"         1 run
says  "  says why"                        "no touchscreen found" run

# ---- a nicely-renamed touchscreen (the ChromeOS-udev-rule case) --------
reset_fixture
touch_device 0 "Atmel maXTouch Touchscreen"
expect "renamed touchscreen is recognised" 0 run
reset_fixture
touch_device 0 "some hid over i2c touch device"
expect "'hid...touch' pattern still matches" 0 run
reset_fixture
touch_device 0 "Wacom HID 1234"
expect "the spelled-out company name still matches" 0 run

# ---- the real miss: raw ACPI HID, no ChromeOS udev renaming ------------
reset_fixture
touch_device 0 "Lid Switch"
touch_device 1 "Power Button"
touch_device 7 "WCOM50C1:00 2D1F:486C"
touch_device 8 "WCOM50C1:00 2D1F:486C UNKNOWN"
touch_device 9 "WCOM50C1:00 2D1F:486C Stylus"
touch_device 10 "WCOM50C1:00 2D1F:486C UNKNOWN"
touch_device 11 "WCOM50C1:00 2D1F:486C Mouse"
touch_device 28 "Logitech K540e"
touch_device 29 "Logitech Wireless Mouse"
expect "raw WCOM ACPI HID is recognised" 0 run
says  "  gives the normal needed message" "no touch boot picker is installed" run

# A device name containing "wcom" only mid-string, not as the ACPI HID
# prefix, must not false-positive - the anchor is deliberate.
reset_fixture
touch_device 0 "Some Unrelated Device wcom-shaped-coincidence"
expect "'wcom' only matches as a leading ACPI HID prefix" 1 run

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
