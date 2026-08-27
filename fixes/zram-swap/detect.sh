#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

modinfo zram >/dev/null 2>&1 || exit 1          # kernel cannot do it
[ -e /etc/systemd/zram-generator.conf ] && exit 1   # already ours

# A hand-rolled zram unit is worth replacing even when it happens to be working.
# These race the zram module: they write to /sys/block/zram0/disksize, which does
# not exist until the module loads, and nothing orders them after it. Observed on
# the reference machine failing on one boot and succeeding on the next.
for unit in zram-init zram-swap zramswap; do
    if [ -e "/etc/systemd/system/$unit.service" ]; then
        state=$(systemctl is-active "$unit.service" 2>/dev/null || true)
        echo "$unit.service configures zram by hand (currently $state) and races the"
        echo "zram module at boot; systemd-zram-generator does this without the race"
        exit 0
    fi
done

swapon --show=NAME --noheadings 2>/dev/null | grep -q zram && exit 1

echo "no zram swap configured; swap would go to eMMC"
exit 0
