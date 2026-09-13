#!/bin/bash
# exit 0 = needed (and safe to offer), 1 = not needed / not yet earned, 2 = cannot tell
#
# Note on exit 1 vs 2: everything that means "not proven yet" must exit 1, not
# 2. The GUI enables Apply for both "needed" and "unknown", so returning 2 here
# would hand someone the button precisely when the evidence is missing - the
# opposite of this fix's whole point. 1 keeps it greyed out, and the first line
# of output becomes the row's subtitle, so the reason is still visible.
set -uo pipefail

MARK="# set by chromebook-fixer (nightfall-default)"
# Overridable so the gate can be exercised against every case - no log, a
# timed-out boot, a fallback, a tap - without contriving each one on a real
# machine. The gate is the whole point of this fix; asserting it works without
# testing it would be the same mistake it exists to prevent.
GRUB_DEFAULT_FILE="${GRUB_DEFAULT_FILE:-/etc/default/grub}"
CUSTOM_CFG="${CUSTOM_CFG:-/boot/grub/custom.cfg}"
NIGHTFALL_LOG="${NIGHTFALL_LOG:-}"

[ -f "$GRUB_DEFAULT_FILE" ] || exit 1                  # not a GRUB machine

installed() {
    local n
    for n in nightfall-boot-manager nocturne-boot-picker; do
        grep -qsF "### BEGIN $n ###" "$CUSTOM_CFG" 2>/dev/null && return 0
    done
    return 1
}
installed || { echo "Nightfall is not installed, so it cannot be the default"; exit 1; }

CURRENT=$(grep -hE '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE" 2>/dev/null \
          | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '"' | head -1)
case "$CURRENT" in
    nightfall|picker)
        exit 1 ;;                                      # already there
    saved)
        # With 'saved', GRUB remembers the last entry booted, so what boots by
        # default is a side effect of what you last chose rather than a
        # setting. Writing a fixed id over that changes how the whole menu
        # behaves, not just which entry wins - not this fix's call to make.
        echo "GRUB_DEFAULT=saved on this machine; the default follows whatever"
        echo "was last booted. Change that deliberately before pinning an entry."
        exit 1 ;;
esac

# --- the evidence ----------------------------------------------------------
# Nightfall writes what happened on its way past. Two fields matter, and only
# together: the outcome must be a normal completion, and the kernel must have
# been chosen by a tap. "booted user selection" is written whenever Nightfall
# finished normally - including when the timeout picked for you - so it is not
# on its own proof that anything was ever drawn. The timeout fires whether or
# not the panel lit. A tap does not: it means the display came up, the
# touchscreen enumerated and worked, and a person drove it.
LOG=""
for c in "$NIGHTFALL_LOG" /boot/nightfall-last-boot.log /boot/picker-last-boot.log; do
    [ -n "$c" ] && [ -r "$c" ] && { LOG="$c"; break; }
done
if [ -z "$LOG" ]; then
    echo "not yet: boot through Nightfall once and tap a kernel, to show it works"
    echo "(no boot log yet - it is written only when the machine boots through it)"
    exit 1
fi

OUTCOME=$(sed -n 's/^outcome:[[:space:]]*//p' "$LOG" | head -1)
CHOSEN=$(sed -n 's/^chosen_by=//p' "$LOG" | head -1)

case "$OUTCOME" in
    "booted user selection") ;;
    "")  echo "not yet: Nightfall's log has no outcome line; cannot judge it"
         exit 1 ;;
    *)   echo "not yet: the last boot through Nightfall ended in '$OUTCOME'"
         echo "see 'chromebook-fixer logs nightfall' - fix that before pinning it"
         exit 1 ;;
esac

if [ "$CHOSEN" != "user" ]; then
    echo "not yet: the last boot was chosen by '${CHOSEN:-unknown}', not a tap"
    echo "the timeout fires even if the screen never lit, so it proves nothing."
    echo "Boot through Nightfall and tap a kernel, then this unlocks."
    exit 1
fi

echo "Nightfall booted this machine from a tap, so its display and touch work."
echo "It can safely be made the entry GRUB boots on its own."
exit 0
