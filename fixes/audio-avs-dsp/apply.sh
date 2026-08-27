#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
CONF=/etc/modprobe.d/chromebook-audio-avs.conf

# Idempotent / safety: if the AVS driver is already active, do nothing.
if grep -qi avs /proc/asound/cards 2>/dev/null \
   && grep -qsE "snd[-_]intel[-_]dspcfg[[:space:]].*dsp_driver" /etc/modprobe.d/ 2>/dev/null; then
    echo "AVS driver already forced and active; nothing to do."
    exit 0
fi

echo "Forcing the Intel AVS DSP driver (dsp_driver=4)."
echo "Writes $CONF and rebuilds the initramfs; a reboot is required after."
printf 'options snd-intel-dspcfg dsp_driver=4\n' | $SUDO tee "$CONF" >/dev/null
$SUDO update-initramfs -u

echo "Done. Reboot, then check Settings -> Sound (or 'pactl list short sinks')"
echo "for a speaker/analog output. If it is still silent, revert this fix."
