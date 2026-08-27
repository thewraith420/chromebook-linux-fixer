#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = in place and working, 1 = not, 3 = already true but not our doing
set -uo pipefail
CONF=/etc/modprobe.d/chromebook-audio-avs.conf

ours=0
[ -e "$CONF" ] && ours=1

cards=$(cat /proc/asound/cards 2>/dev/null || true)
active=$(cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver 2>/dev/null || echo 0)

case "$cards" in
    *avs_*)
        if [ "$ours" = "1" ]; then
            echo "AVS driver selected; cards: $(echo "$cards" | grep -oE 'avs_[a-z0-9]+' | sort -u | tr '\n' ' ')"
            exit 0
        fi
        echo "AVS audio is already working, but not because of this fix"
        exit 3 ;;
esac

[ "$ours" = "1" ] && { echo "$CONF is installed but no avs_* card is present (reboot needed?)"; exit 1; }
exit 1
