#!/bin/bash
set -uo pipefail
CONF=/etc/modprobe.d/chromebook-audio-avs.conf
TPLG_BAK=/lib/firmware/intel/avs/max98357a-tplg.bin.chromebook-fixer.bak
if ! { [ -f "$CONF" ] && grep -q "dsp_driver=4" "$CONF"; }; then
    # AVS may already be forced by some other means - an edit to
    # /etc/modprobe.d/alsa-base.conf, which is how this was done by hand before
    # the fix existed, or chromebook-linux-audio's own snd-avs.conf. Say so
    # rather than falling through silently: the state is right, but this fix is
    # not what is holding it up, and the conffile route breaks on the next
    # alsa-base upgrade.
    SRC=$(grep -rlsE "snd[-_]intel[-_]dspcfg[[:space:]].*dsp_driver=4" \
          /etc/modprobe.d/ 2>/dev/null | head -1)
    if [ -n "$SRC" ]; then
        echo "AVS is forced by $SRC, not by this fix"
        # Naming the file matters when it is a package conffile. dpkg replays
        # the maintainer's version on upgrade and prompts about the conflict;
        # accepting the package version - the default for an unattended
        # upgrade - silently drops the option and the speakers go quiet again,
        # months later, with nothing obviously connecting the two events.
        # dpkg records every conffile it owns, one per package. Reading that
        # list is instant and definitive; "dpkg --verify" with no package
        # argument walks every package on the system instead, which is slow
        # enough to look like it simply found nothing.
        OWNER=$(grep -lF "$SRC" /var/lib/dpkg/info/*.conffiles 2>/dev/null | head -1)
        if [ -n "$OWNER" ]; then
            PKG=$(basename "$OWNER" .conffiles)
            echo "WARNING: that file is a CONFFILE owned by the '$PKG' package."
            echo "Upgrading $PKG prompts about the conflict, and taking the"
            echo "package version drops the option and kills audio - months"
            echo "later, with nothing obviously connecting the two events."
            echo "Applying this fix with --force writes the same option to a"
            echo "file no package owns, which survives the upgrade."
        fi
        exit 3
    fi
    exit 1
fi
if grep -qi avs /proc/asound/cards 2>/dev/null; then
    echo "AVS driver active; speaker output available"
else
    echo "AVS override in place (reboot to activate the driver)"
fi
[ -e "$TPLG_BAK" ] && \
    echo "MAX98357A speakers deliberately disabled (amp has no volume limiter)"
exit 0
