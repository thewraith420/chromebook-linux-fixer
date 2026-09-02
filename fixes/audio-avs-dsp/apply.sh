#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
CONF=/etc/modprobe.d/chromebook-audio-avs.conf
TPLG=/lib/firmware/intel/avs/max98357a-tplg.bin
TPLG_BAK="$TPLG.chromebook-fixer.bak"

# Idempotent / safety: if the AVS driver is already active, do nothing.
if grep -qi avs /proc/asound/cards 2>/dev/null \
   && grep -qsE "snd[-_]intel[-_]dspcfg[[:space:]].*dsp_driver" /etc/modprobe.d/ 2>/dev/null; then
    echo "AVS driver already forced and active; nothing to do."
    exit 0
fi

# MAX98357A boards can be driven past what the amp survives, because nothing in
# the AVS path limits volume yet. Upstream's own installer
# (WeirdTreeThing/chromebook-linux-audio) removes the topology file to keep the
# speakers off until a limiter exists, and demands a typed acknowledgement
# before it will do otherwise. Do the same, but move the file aside rather than
# delete it: it belongs to a firmware package, and revert has to be able to put
# it back.
DISABLE_SPEAKERS=0
if [ -e /sys/bus/acpi/devices/MX98357A:00 ]; then
    if [ "${FIXER_ALLOW_MAX98357A_SPEAKERS:-0}" = "1" ]; then
        echo "!!! MAX98357A speakers ENABLED by FIXER_ALLOW_MAX98357A_SPEAKERS=1."
        echo "!!! There is no volume limiter on this path. Playing loudly can"
        echo "!!! PERMANENTLY DAMAGE the speakers. You asked for this explicitly."
    else
        DISABLE_SPEAKERS=1
        echo "This board has a MAX98357A amp."
        echo "Speakers will be left DISABLED on purpose: the AVS path has no"
        echo "volume limiter, and driving this amp too loud can permanently"
        echo "damage it. Headphones and HDMI audio are unaffected."
        echo "To override (at your own risk): FIXER_ALLOW_MAX98357A_SPEAKERS=1"
    fi
fi

echo "Forcing the Intel AVS DSP driver (dsp_driver=4)."
echo "Writes $CONF and rebuilds the initramfs; a reboot is required after."

# Heredoc rather than a pipe: "echo x | $SUDO tee" runs sudo in a forked
# subshell, which with no tty makes sudo re-prompt for every pipeline.
$SUDO tee "$CONF" >/dev/null <<'CONF'
# Written by chromebook-fixer (audio-avs-dsp).
options snd-intel-dspcfg dsp_driver=4
# The AVS firmware shipped for these boards does not match the version the
# driver expects, and the driver refuses to load it without this.
options snd-soc-avs ignore_fw_version=1
# Keep the pre-rename card names, which the ALSA UCM profiles for these
# boards are written against.
options snd-soc-avs obsolete_card_names=1
CONF

if [ "$DISABLE_SPEAKERS" = "1" ] && [ -e "$TPLG" ]; then
    if [ -e "$TPLG_BAK" ]; then
        # A previous apply already saved the original; the firmware package has
        # since reinstated this one. Keep the first backup - it is the pristine
        # copy - and drop the reinstated file.
        $SUDO rm -f "$TPLG"
    else
        $SUDO mv "$TPLG" "$TPLG_BAK"
    fi
    echo "$(basename "$TPLG") moved aside; speakers stay silent until revert"
fi

$SUDO update-initramfs -u

echo "Done. Reboot, then check Settings -> Sound (or 'pactl list short sinks')"
echo "for a speaker/analog output. If it is still silent, revert this fix."
