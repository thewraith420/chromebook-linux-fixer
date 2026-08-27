#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
CONF=/etc/systemd/zram-generator.conf

if ! dpkg -s systemd-zram-generator >/dev/null 2>&1; then
    echo "installing systemd-zram-generator..."
    $SUDO apt-get install -y systemd-zram-generator
fi

# Retire any hand-rolled zram unit. These typically write to
# /sys/block/zram0/disksize before the zram module is loaded, so they fail at
# boot and only appear to work if something loaded the module first.
for unit in zram-init zram-swap zramswap; do
    U=/etc/systemd/system/$unit.service
    [ -e "$U" ] || continue
    echo "retiring $unit.service (superseded by systemd-zram-generator)"
    $SUDO systemctl disable --now "$unit.service" 2>/dev/null || true
    $SUDO mv "$U" "$U.replaced-by-chromebook-fixer"
done

# Size: half of RAM, capped at 4G. Compressed roughly 2-3x, so a full device of
# this size costs well under half its nominal size in real memory.
#
# lz4 not zstd: compression runs in the page-fault path, and these CPUs are
# low-power and thermally limited. lz4 is several times faster to compress for
# a modestly worse ratio, which is the right trade here.
#
# Priority 100 puts zram ahead of any disk swap, which stays as overflow.
$SUDO tee "$CONF" >/dev/null <<'CONFEOF'
# Written by chromebook-fixer (zram-swap).
# Compressed swap in RAM, so pressure does not land on slow eMMC flash.
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = lz4
swap-priority = 100
fs-type = swap
CONFEOF
echo "wrote $CONF"

# Hand back a device an older script may have set up by hand.
if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram0'; then
    $SUDO swapoff /dev/zram0 2>/dev/null || true
fi

$SUDO systemctl daemon-reload
$SUDO systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
sleep 2

if swapon --show=NAME,SIZE,PRIO --noheadings 2>/dev/null | grep -q zram; then
    echo
    swapon --show
    echo
    echo "zram swap active."
else
    echo
    echo "configured, but zram is not active yet - it will come up on the next boot."
fi
