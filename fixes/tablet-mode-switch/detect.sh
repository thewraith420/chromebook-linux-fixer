#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

systemctl is-active --quiet chromebook-tablet-switch.service 2>/dev/null && exit 1
[ -e /dev/uinput ] || exit 2                    # cannot create the device

# Does anything already report a tablet-mode switch?
for n in /sys/class/input/input*/name; do
    name=$(cat "$n" 2>/dev/null || true)
    case "$name" in *[Tt]ablet\ [Mm]ode*) exit 1 ;; esac
done

# Is mutter already managing panel orientation by some other means?
managed=$(busctl --user get-property org.gnome.Mutter.DisplayConfig \
    /org/gnome/Mutter/DisplayConfig org.gnome.Mutter.DisplayConfig \
    PanelOrientationManaged 2>/dev/null || true)
case "$managed" in *true*) exit 1 ;; esac

# Only worth it where there is an accelerometer to rotate from.
grep -qs . /sys/bus/iio/devices/iio:device*/name 2>/dev/null || exit 1

echo "accelerometer present but nothing reports SW_TABLET_MODE, so GNOME will not auto-rotate"
exit 0
