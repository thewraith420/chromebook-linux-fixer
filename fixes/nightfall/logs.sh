#!/bin/bash
# Print Nightfall's record of the last boot.
#
# Nightfall runs before any journal exists - no syslog, no scrollback, no
# network - so it writes what happened to the real root on its way past. That
# file is the only account of a boot that went through it, and until now the
# only way to read it was to know the path.
#
# Deliberately not summarised here: the value is in the detail (which stages
# were reached, what /dev/dri and /dev/input looked like, the full dmesg), and
# a fix that paraphrases a diagnostic log is a fix that hides the line you
# needed. verify says whether the last boot was clean; this is the whole thing.
set -uo pipefail

LOG=""
for c in /boot/nightfall-last-boot.log /boot/picker-last-boot.log; do
    [ -r "$c" ] && { LOG="$c"; break; }
done

if [ -z "$LOG" ]; then
    for c in /boot/nightfall-last-boot.log /boot/picker-last-boot.log; do
        if [ -e "$c" ]; then
            echo "$c exists but is not readable by $(id -un)."
            echo "  sudo cat $c"
            exit 1
        fi
    done
    echo "No Nightfall boot log found."
    echo
    echo "It is written on the way past, so there is only one if this machine"
    echo "has actually booted THROUGH Nightfall - selecting a kernel from its"
    echo "menu, or letting its timeout do it. Booting a GRUB entry directly"
    echo "never goes near it and leaves no log."
    exit 1
fi

echo "# $LOG  ($(stat -c %y "$LOG" | cut -d. -f1), $(wc -l < "$LOG") lines)"
echo
cat "$LOG"
