#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# The dsp_driver override only means anything where snd-intel-dspcfg drives the
# choice. If that knob is absent, this platform/kernel is not applicable.
[ -e /sys/module/snd_intel_dspcfg/parameters/dsp_driver ] || exit 1

# Only the platforms the upstream AVS driver actually covers - Skylake, Kaby
# Lake and Apollo Lake. Gate on the audio controller's PCI id. Extend as boards
# are confirmed.
#   9d70 Skylake-LP  9d71 Kaby Lake-LP (nocturne)  a171 Kaby/Sky-H
#   5a98 Apollo Lake
# (these HDA controllers report class 0401 or 0403 depending on the SoC, so
# match by device id rather than class.)
#
# Gemini Lake (8086:3198) was here and was wrong. GLK is a SOF platform, not an
# AVS one: the kernel has SND_SOC_SOF_GEMINILAKE and no AVS machine driver for
# it, so forcing dsp_driver=4 there selects a driver that cannot drive the
# board. Cross-checked against WeirdTreeThing/chromebook-linux-audio, which
# routes skl/kbl/apl to AVS and glk to SOF.
AVS_AUDIO_IDS="8086:9d70 8086:9d71 8086:a171 8086:5a98"
DEV=""
for id in $AVS_AUDIO_IDS; do
    lspci -n 2>/dev/null | grep -qi "$id" && { DEV="$id"; break; }
done
[ -n "$DEV" ] || exit 1

# Already forced (cmdline or a modprobe.d option)? then nothing to do. This
# also stands down cleanly when chromebook-linux-audio has configured the
# machine - its /etc/modprobe.d/snd-avs.conf matches this same pattern.
grep -qsE "snd[-_]intel[-_]dspcfg\.dsp_driver=" /proc/cmdline && exit 1
grep -rqsE "snd[-_]intel[-_]dspcfg[[:space:]].*dsp_driver" /etc/modprobe.d/ 2>/dev/null && exit 1

# SAFETY: never touch a working setup. If a real analog output already exists,
# the current driver is fine - stand down. Needs the session to ask PipeWire;
# if we cannot, report "cannot tell" rather than applying blind.
command -v pactl >/dev/null 2>&1 || exit 2
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SINKS=$(pactl list short sinks 2>/dev/null) || exit 2
if printf '%s\n' "$SINKS" | grep -iE "alsa_output" | grep -qivE "hdmi|monitor|null|dummy"; then
    exit 1   # a working analog output already exists
fi

echo "cAVS Chromebook ($DEV) with no working analog output; forcing the AVS driver should recover the speakers"
if [ -e /sys/bus/acpi/devices/MX98357A:00 ]; then
    echo "NOTE: this board has a MAX98357A amp - speakers will be left disabled"
    echo "on purpose (headphones and HDMI still work). See this fix's danger field."
fi
exit 0
