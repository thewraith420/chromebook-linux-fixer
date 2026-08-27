#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# The dsp_driver override only means anything where snd-intel-dspcfg drives the
# choice. If that knob is absent, this platform/kernel is not applicable.
[ -e /sys/module/snd_intel_dspcfg/parameters/dsp_driver ] || exit 1

# Only the Intel cAVS-1.5 generation (Skylake..Gemini Lake) is served by the
# AVS driver. Newer SOF platforms must NOT be forced onto AVS. Gate on the
# audio controller's PCI id. Extend as boards are confirmed.
#   9d70 Skylake-LP  9d71 Kaby Lake-LP (nocturne)  a171 Kaby/Sky-H
#   5a98 Apollo Lake  3198 Gemini Lake
# (these HDA controllers report class 0401 or 0403 depending on the SoC, so
# match by device id rather than class.)
AVS_AUDIO_IDS="8086:9d70 8086:9d71 8086:a171 8086:5a98 8086:3198"
DEV=""
for id in $AVS_AUDIO_IDS; do
    lspci -n 2>/dev/null | grep -qi "$id" && { DEV="$id"; break; }
done
[ -n "$DEV" ] || exit 1

# Already forced (cmdline or a modprobe.d option)? then nothing to do.
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
exit 0
