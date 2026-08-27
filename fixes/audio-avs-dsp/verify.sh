#!/bin/bash
set -uo pipefail
CONF=/etc/modprobe.d/chromebook-audio-avs.conf
[ -f "$CONF" ] && grep -q "dsp_driver=4" "$CONF" || exit 1
if grep -qi avs /proc/asound/cards 2>/dev/null; then
    echo "AVS driver active; speaker output available"
else
    echo "AVS override in place (reboot to activate the driver)"
fi
