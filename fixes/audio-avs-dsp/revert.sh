#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /etc/modprobe.d/chromebook-audio-avs.conf
$SUDO update-initramfs -u
echo "AVS override removed; reboot to return to the default DSP driver selection"
