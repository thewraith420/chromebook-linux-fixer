#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = in place, 1 = not, 3 = zram works but not because of this fix
set -uo pipefail
CONF=/etc/systemd/zram-generator.conf

active=$(swapon --show=NAME --noheadings 2>/dev/null | grep -c zram || true)

if [ -e "$CONF" ]; then
    if [ "$active" -gt 0 ]; then
        algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "?")
        size=$(swapon --show=NAME,SIZE,PRIO --noheadings 2>/dev/null | grep zram)
        echo "zram swap active via systemd-zram-generator ($algo): $size"
        exit 0
    fi
    echo "$CONF is installed but no zram swap is active (reboot needed?)"
    exit 1
fi

# Deliberately NOT exit 3 when a hand-rolled unit is doing the work. Exit 3
# means "the desired state holds and there is nothing for this fix to do", and
# that is not true here: such a unit races the zram module at boot and fails
# intermittently. Report it as not-in-place so detect gets asked, and detect
# explains why replacing it is worthwhile.
for unit in zram-init zram-swap zramswap; do
    [ -e "/etc/systemd/system/$unit.service" ] && exit 1
done

[ "$active" -gt 0 ] && { echo "zram swap is active, but not via this fix"; exit 3; }
exit 1
