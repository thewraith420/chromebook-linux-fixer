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
# A CPU that meets x86-64-v2, so no case depends on the machine running the tests.
CPU_OK="$T/cpuinfo-v2"; CPU_OLD="$T/cpuinfo-old"
echo "flags : fpu vme sse sse2 pni ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm lm avx" > "$CPU_OK"
echo "flags : fpu vme sse sse2 pni ssse3 cx16 lahf_lm lm" > "$CPU_OLD"    # Core 2 era: no SSE4/POPCNT
CPU="$CPU_OK"
run() { GRUB_DIR="$GRUB" CUSTOM_CFG="$CFG" INPUT_CLASS_DIR="$INPUT" FIXER_CPUINFO="$CPU" "$D"; }

reset_fixture() {
    rm -rf "$GRUB" "$INPUT"; mkdir -p "$GRUB" "$INPUT"
    rm -f "$CFG"
}
touch_device() {   # touch_device <input-n> <name string>
    mkdir -p "$INPUT/input$1"
    printf '%s\n' "$2" > "$INPUT/input$1/name"
}

# ---- no GRUB, nothing to chainload into --------------------------------
reset_fixture; rm -rf "$GRUB"
touch_device 0 "Atmel maXTouch Touchscreen"   # everything else is fine: only GRUB is missing
expect "no /boot/grub at all"            1 run

# ---- already installed short-circuits, regardless of touch state -------
reset_fixture
touch_device 0 "Lid Switch"        # no touch device present at all
printf '### BEGIN nightfall-boot-manager ###\n### END nightfall-boot-manager ###\n' > "$CFG"
expect "already installed (current name)" 1 run
: > "$CFG"
printf '### BEGIN nocturne-boot-picker ###\n### END nocturne-boot-picker ###\n' > "$CFG"
expect "already installed (renamed-from marker)" 1 run

# ---- no touch device: still offered - Nightfall runs on keyboard and mouse
# now, so a missing touchscreen changes what the row says, not whether the
# install button exists (a Lenovo LOQ with no touchscreen was the case that
# found the old rule hiding it).
reset_fixture
touch_device 0 "Lid Switch"
touch_device 1 "Power Button"
touch_device 2 "Logitech K540e"
expect "no touch device present: still offered"  0 run
says  "  says it is keyboard and mouse driven"   "keyboard and mouse" run
says  "  and that only two machines have tested it" "Pixel Slate and a Lenovo LOQ" run

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
# prefix, must not false-positive - the anchor is deliberate. Detection no
# longer gates on it, so what is checked is the message: it must read as "no
# touchscreen", not claim one was found.
reset_fixture
touch_device 0 "Some Unrelated Device wcom-shaped-coincidence"
says  "'wcom' only matches as a leading ACPI HID prefix" "no touchscreen here" run
touch_device 1 "WCOM50C1:00 2D1F:486C"
says  "  and a real leading WCOM still reads as a touchscreen" "needs a keyboard this machine may not have" run

# ---- the CPU: the kernel is built for x86-64-v2 and dies silently below it --
reset_fixture
touch_device 0 "Atmel maXTouch Touchscreen"
CPU="$CPU_OLD"
expect "a CPU below x86-64-v2 is not offered"     1 run
says  "  and the reason names what is missing"     "sse4_1" run
says  "  including every missing feature, not just the first" "popcnt" run
CPU="$CPU_OK"
expect "a CPU that meets v2 is offered"           0 run
CPU="$T/does-not-exist"
expect "an unreadable cpuinfo is not offered (never install blind)" 1 run
says  "  and says the flags were unreadable"       "unreadable" run
CPU="$CPU_OK"
echo "flags : fpu sse sse2 ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm lm" > "$T/cpu-nopni"
CPU="$T/cpu-nopni"
says  "each v2 feature counts on its own (pni alone)" "pni" run
CPU="$CPU_OK"
# the check must come AFTER 'already installed' and 'no GRUB', which are
# stronger reasons and print nothing
reset_fixture; printf '### BEGIN nightfall-boot-manager ###\n' > "$CFG"; CPU="$CPU_OLD"
expect "already installed short-circuits before the CPU check" 1 run
CPU="$CPU_OK"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
