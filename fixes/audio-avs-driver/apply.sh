#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
CONF=/etc/modprobe.d/chromebook-audio-avs.conf

$SUDO tee "$CONF" >/dev/null <<'CONFEOF'
# Force the AVS driver for the Intel DSP.
#
# snd-intel-dspcfg picks between SOF and AVS automatically and chooses SOF on
# these Chromebooks, which has no topology for their I2S codecs - so nothing
# enumerates and there is no sound. AVS drives them.
#
# Deliberately its own file: alsa-base.conf is a package conffile, and putting
# this there produces a prompt on upgrade whose obvious answer breaks audio.
options snd-intel-dspcfg dsp_driver=4
CONFEOF
echo "wrote $CONF"

# Some initramfs images carry sound modules; refresh so the option is seen
# wherever they are loaded from.
if command -v update-initramfs >/dev/null; then
    $SUDO update-initramfs -u >/dev/null 2>&1 || true
    echo "refreshed the initramfs"
fi

echo
echo "Reboot for this to take effect - module options are read at load time."
