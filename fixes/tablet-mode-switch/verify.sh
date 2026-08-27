#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = ours and working, 1 = not, 3 = true but not our doing
set -uo pipefail

found=""
for n in /sys/class/input/input*/name; do
    name=$(cat "$n" 2>/dev/null || true)
    case "$name" in *[Tt]ablet\ [Mm]ode*) found="$name" ;; esac
done

if systemctl is-active --quiet chromebook-tablet-switch.service 2>/dev/null; then
    [ -n "$found" ] && { echo "synthetic switch present: $found"; exit 0; }
    echo "service running but no tablet-mode switch appeared"
    exit 1
fi

[ -n "$found" ] && { echo "a tablet-mode switch exists ($found), but not from this fix"; exit 3; }
exit 1
