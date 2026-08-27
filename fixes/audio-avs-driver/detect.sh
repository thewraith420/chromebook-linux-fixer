#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Only meaningful where the Intel DSP selector is in play at all.
[ -e /sys/module/snd_intel_dspcfg/parameters/dsp_driver ] || exit 1

# Already forced to AVS, by us or by anyone?
current=$(cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver 2>/dev/null || echo 0)
[ "$current" = "4" ] && exit 1
grep -rqsE "^[[:space:]]*options[[:space:]]+snd-intel-dspcfg.*dsp_driver=4" /etc/modprobe.d/ && exit 1

# If AVS cards are already present, nothing to do.
grep -qs "avs_" /proc/asound/cards && exit 1

# Any working analogue output at all? If the machine already has sound, do not
# meddle - this fix is for the case where the codecs never enumerate.
if grep -qsE "\[.*\]" /proc/asound/cards && ! grep -qsE "^ *[0-9]+ \[" /proc/asound/cards; then
    exit 2
fi

echo "Intel DSP present, AVS not selected (dsp_driver=$current) and no avs_* card enumerated"
exit 0
