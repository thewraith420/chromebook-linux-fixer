#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Every path below is overridable so this can be exercised fixture-only, the
# same way every other detect.sh in this repo is (GRUB_DIR, CUSTOM_CFG,
# INPUT_CLASS_DIR elsewhere) - defaults are the real paths, unchanged.
CROS_EC_DEV="${CROS_EC_DEV:-/dev/cros_ec}"
DMI_SYS_VENDOR="${DMI_SYS_VENDOR:-/sys/class/dmi/id/sys_vendor}"
DMI_PRODUCT_NAME="${DMI_PRODUCT_NAME:-/sys/class/dmi/id/product_name}"
EC_POLL_PARAM="${EC_POLL_PARAM:-/sys/module/cros_ec/parameters/ec_event_poll_ms}"
EVPOLL_DIR="${EVPOLL_DIR:-/sys/module/cros_ec_evpoll}"

# Needs a Chrome EC exposing the command chardev.
[ -e "$CROS_EC_DEV" ] || exit 1

# If the kernel is already draining the EC event FIFO (patch 9201, or the DKMS
# fix), userspace must NOT also drain it - the two would race. Stand down.
#
# Unless nothing is listening. Draining the FIFO only produces key presses if
# cros_ec_keyb is bound to GOOG0007, and on this board firmware can report that
# device absent (fixed in-kernel by patch 9207). A polling kernel with a hidden
# GOOG0007 has healthy delivery and silent buttons, and standing down there
# reports "not needed" at someone whose volume keys do nothing. Only defer to
# the kernel when its events have a consumer - or when we cannot tell, since
# racing a working EC is the worse mistake.
"$FIXER_REPO/lib/ec-buttons.sh" goog0007
GOOG=$?     # 0 = GOOG0007 hidden, so a FIFO drain has no consumer

# Firmware can fix the root cause outright: SlateFirmware's patch 0001b
# restores the main EC's own interrupt (dropped from CREC's _CRS by a 2022
# downstream patch), so MKBP events reach cros_ec_keyb the normal way and
# nothing needs to poll or inject anything. Confirmed live on a Slate running
# MrChromebox-2609.0-1-gf2fbda7cf0 (SlateFirmware, 2026-09-30): a stock kernel
# there shows the EC's own IRQ and needs neither ec_event_poll_ms nor this
# fix. See lib/ec-buttons.sh ec_lpc_irq_live for exactly what is checked and
# its limits - it is a static proxy (two "chromeos-ec" interrupt rows versus
# one), not a live button-press test.
#
# Still gated on GOOG: a working EC interrupt does nothing for buttons if
# cros_ec_keyb itself never bound (GOOG0007 hidden - the other, independent
# bug, fixed by kernel patch 9207 or by firmware 2609's own _STA fix). Getting
# this wrong in the "still needed" direction when it is not would be worse
# than redundant: the poller injects its OWN synthetic volume key through a
# second uinput device rather than reusing cros_ec_keyb's, so running it
# alongside a working native path double-fires every press.
"$FIXER_REPO/lib/ec-buttons.sh" irq-live
IRQ_LIVE=$?     # 0 = the EC's own interrupt is present
if [ "$IRQ_LIVE" -eq 0 ] && [ "$GOOG" -eq 1 ]; then
    echo "the EC's own interrupt is present (firmware fix) and cros_ec_keyb is"
    echo "bound - buttons are delivered natively; not offering this fix"
    exit 1
fi

POLL="$EC_POLL_PARAM"
if [ -r "$POLL" ] && [ "$(cat "$POLL" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
    [ "$GOOG" -eq 0 ] || exit 1
    echo "kernel is polling the EC FIFO, but GOOG0007 is hidden by firmware so"
    echo "cros_ec_keyb never bound - the events reach no one (kernel patch 9207"
    echo "fixes this properly; this fix injects the keys from userspace instead)"
fi

# Already running ours?
systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1 && exit 1

# Legacy guard: cros-ec-evpoll was an out-of-tree module (the removed
# ec-buttons-dkms fix) that drained the FIFO in-kernel. A machine that still
# has it loaded from an older checkout must not also run this, or the two
# race for the same events. Same caveat as the kernel-poll branch above:
# draining only produces key presses if something consumes them, and
# deferring unconditionally reported "not needed" on a machine where that
# module was loaded and could not restore a single button, because GOOG0007
# was hidden. Defer only when the drain actually reaches a consumer.
if [ -d "$EVPOLL_DIR" ]; then
    [ "$GOOG" -eq 0 ] || exit 1
    echo "a cros-ec-evpoll module is loaded and draining the EC FIFO, but"
    echo "GOOG0007 is hidden so cros_ec_keyb never bound and those events reach"
    echo "no one. This fix injects the keys from userspace instead - but the two"
    echo "drain the same FIFO, so unload cros-ec-evpoll before applying this."
fi

# The dead-EC-delivery fault is board specific. Only offer this where it is
# confirmed - enabling it on a board whose EC path works would race the kernel
# for events. Add confirmed boards here as they are verified.
VENDOR=$(cat "$DMI_SYS_VENDOR" 2>/dev/null || echo)
PRODUCT=$(cat "$DMI_PRODUCT_NAME" 2>/dev/null || echo)
case "$VENDOR/$PRODUCT" in
    Google/Nocturne) ;;                      # Pixel Slate — confirmed
    *)
        # Chrome EC present but board not on the confirmed list. Can't safely
        # tell whether its async event path works without pressing a button.
        echo "Chrome EC present but $VENDOR/$PRODUCT is not on the confirmed" \
             "dead-delivery list; not offering to avoid racing a working EC"
        exit 1
        ;;
esac

echo "$VENDOR $PRODUCT: EC present, async delivery known-dead, kernel not polling"
exit 0
