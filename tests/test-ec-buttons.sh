#!/bin/bash
# fixes/ec-buttons-poll/detect.sh and lib/ec-buttons.sh's ec_lpc_irq_live,
# against fixture /proc/interrupts, sysfs trees and a stub systemctl. Nothing
# here touches the real system.
#
# What this exists to catch: a real, concrete regression. The volume poller
# injects its OWN synthetic key through a second uinput device rather than
# reusing cros_ec_keyb's, so offering (or leaving installed) this fix on a
# machine whose EC interrupt now works natively does not just waste a
# service - it makes every physical button press raise or lower the volume
# TWICE. SlateFirmware's patch 0001b (upstreamed into MrChromebox 2609) fixes
# the EC's own interrupt at the firmware level; detect.sh and the daemon's own
# runtime check both need to recognise that and stand down.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/lib/ec-buttons.sh"
D="$REPO/fixes/ec-buttons-poll/detect.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (no '$pat' in: $(head -c 300 <<<"$out"))"; fi; }

# ===== unit: lib/ec-buttons.sh irq-live ===================================
mkone() { printf '  83:   18  IR-IO-APIC   83-fasteoi   chromeos-ec\n' > "$1"; }
mktwo() { mkone "$1"; printf ' 113:  453  IR-IO-APIC  113-fasteoi   chromeos-ec\n' >> "$1"; }

PI_ONE="$T/pi-one"; mkone "$PI_ONE"             # pre-fix: FPMCU only
PI_TWO="$T/pi-two"; mktwo "$PI_TWO"             # fixed firmware: EC gained its own
PI_NONE="$T/pi-none"; : > "$PI_NONE"            # no Chrome EC at all

expect "irq-live: one chromeos-ec line = pre-fix (1)"   1 env PROC_INTERRUPTS="$PI_ONE"  "$LIB" irq-live
expect "irq-live: two lines = fixed firmware (0)"       0 env PROC_INTERRUPTS="$PI_TWO"  "$LIB" irq-live
expect "irq-live: no line at all = cannot tell (2)"     2 env PROC_INTERRUPTS="$PI_NONE" "$LIB" irq-live
expect "irq-live: unreadable file = cannot tell (2)"    2 env PROC_INTERRUPTS="$T/nope"  "$LIB" irq-live
PI_UNRELATED="$T/pi-unrelated"; printf '  44:  1  IR-IO-APIC  44-fasteoi  i8042\n' > "$PI_UNRELATED"
expect "irq-live: other interrupts present, no EC = cannot tell (2)" 2 env PROC_INTERRUPTS="$PI_UNRELATED" "$LIB" irq-live
PI_THREE="$T/pi-three"; mktwo "$PI_THREE"; printf '  44:  1  IR-IO-APIC  44-fasteoi  chromeos-ec-something-else\n' >> "$PI_THREE"
expect "  a similarly-named-but-different line does not confuse the count" 0 env PROC_INTERRUPTS="$PI_THREE" "$LIB" irq-live

# ===== integration: detect.sh's new standdown ==============================
# A fake lib/ec-buttons.sh, fully driven by env vars, so detect.sh's own
# branching can be exercised without needing real ACPI/platform-driver sysfs
# paths (goog0007_status()'s own paths are not overridable, and are not this
# file's concern - only the NEW firmware-aware branch is under test here).
FAKE_REPO="$T/fakerepo"; mkdir -p "$FAKE_REPO/lib"
cat > "$FAKE_REPO/lib/ec-buttons.sh" <<'EOF'
#!/bin/bash
case "${1:-}" in
    goog0007) exit "${FAKE_GOOG:-2}" ;;
    irq-live) exit "${FAKE_IRQ:-2}" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_REPO/lib/ec-buttons.sh"

CROS_EC="$T/cros_ec"; : > "$CROS_EC"
DMI_V="$T/dmi-vendor"; DMI_P="$T/dmi-product"
echo Google > "$DMI_V"; echo Nocturne > "$DMI_P"
POLL="$T/poll"; echo 0 > "$POLL"
EVPOLL="$T/evpoll-absent"
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
[ "${FAKE_SERVICE_ACTIVE:-}" = 1 ] && exit 0
exit 1
EOF
chmod +x "$BIN/systemctl"

run() {
    env PATH="$BIN:$PATH" FIXER_REPO="$FAKE_REPO" CROS_EC_DEV="$CROS_EC" \
        DMI_SYS_VENDOR="$DMI_V" DMI_PRODUCT_NAME="$DMI_P" EC_POLL_PARAM="$POLL" \
        EVPOLL_DIR="$EVPOLL" FAKE_GOOG="${FAKE_GOOG:-2}" FAKE_IRQ="${FAKE_IRQ:-2}" \
        FAKE_SERVICE_ACTIVE="${FAKE_SERVICE_ACTIVE:-}" "$D"
}

# fixed firmware (irq-live=0) + cros_ec_keyb bound (goog=1): not needed, and
# for the NEW reason - the whole point of this change.
FAKE_GOOG=1 FAKE_IRQ=0
expect "fixed firmware + bound keyb: not needed"        1 run
says   "  for the firmware-fix reason specifically"     "firmware fix" run

# fixed EC interrupt but GOOG0007 still hidden (the independent _STA bug, not
# yet fixed): the EC's own interrupt existing does not help - cros_ec_keyb
# never bound, so nothing consumes it either way. Still needed.
FAKE_GOOG=0 FAKE_IRQ=0
expect "fixed EC irq but GOOG0007 still hidden: still needed" 0 run
says   "  message does not falsely claim it is delivered natively" "known-dead" run

# pre-fix firmware (irq-live=1, only the FPMCU's line) + bound keyb: this is
# the ordinary dead-delivery case the fix exists for. Still needed.
FAKE_GOOG=1 FAKE_IRQ=1
expect "pre-fix firmware + bound keyb: still needed (the normal case)" 0 run

# cannot tell (irq-live=2, e.g. /proc/interrupts unreadable): must not stand
# down on an unproven claim of "fixed" - falls through to the existing logic.
FAKE_GOOG=1 FAKE_IRQ=2
expect "irq-live cannot-tell: falls through, does not wrongly stand down" 0 run

# the already-active-service short-circuit must still fire even when the
# firmware looks fixed (an existing install should not be reported "needed"
# again just because detect ran before the daemon's own runtime check retired
# it - revert/replace is the deliberate path, not a second "needed" nag).
FAKE_GOOG=1 FAKE_IRQ=0 FAKE_SERVICE_ACTIVE=1
expect "already active service short-circuits regardless of irq state" 1 run

# board gate still applies: fixed-irq standdown must not be the ONLY thing
# keeping this from firing on an unconfirmed board - break the DMI gate too
# and confirm the unconfirmed-board message, not the firmware one, is what's
# reported, so the two refusal reasons stay distinguishable in logs.
echo SomeOEM > "$DMI_V"; echo RandomLaptop > "$DMI_P"
FAKE_GOOG=1 FAKE_IRQ=1 FAKE_SERVICE_ACTIVE=
says "unconfirmed board still refuses with its own, different reason" "not on the confirmed" run
echo Google > "$DMI_V"; echo Nocturne > "$DMI_P"

# no Chrome EC chardev at all: refuses before any of the above even runs.
expect "no /dev/cros_ec: not applicable" 1 env PATH="$BIN:$PATH" FIXER_REPO="$FAKE_REPO" \
    CROS_EC_DEV="$T/does-not-exist" DMI_SYS_VENDOR="$DMI_V" DMI_PRODUCT_NAME="$DMI_P" \
    EC_POLL_PARAM="$POLL" EVPOLL_DIR="$EVPOLL" "$D"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
