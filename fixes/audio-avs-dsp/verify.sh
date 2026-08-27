#!/bin/bash
set -uo pipefail
CONF=/etc/modprobe.d/chromebook-audio-avs.conf
if ! { [ -f "$CONF" ] && grep -q "dsp_driver=4" "$CONF"; }; then
    # AVS may already be forced by some other means - commonly an edit to
    # /etc/modprobe.d/alsa-base.conf, which is how this was done by hand before
    # the fix existed. Say so rather than falling through silently: the state is
    # right, but this fix is not what is holding it up, and the conffile route
    # breaks on the next alsa-base upgrade.
    if grep -rqsE "snd[-_]intel[-_]dspcfg[[:space:]].*dsp_driver=4" /etc/modprobe.d/ 2>/dev/null; then
        echo "AVS is forced elsewhere in /etc/modprobe.d, not by this fix"
        exit 3
    fi
    exit 1
fi
if grep -qi avs /proc/asound/cards 2>/dev/null; then
    echo "AVS driver active; speaker output available"
else
    echo "AVS override in place (reboot to activate the driver)"
fi
