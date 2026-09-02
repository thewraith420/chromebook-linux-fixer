#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
# Only relevant with an Intel panel.
[ -d /sys/module/i915 ] || exit 1
# Already set?
"$FIXER_REPO/lib/kernel-cmdline.sh" active i915.enable_dpcd_backlight=2
case $? in
    0) exit 1 ;;                         # already on the running cmdline
    2) echo "/proc/cmdline is unreadable, so whether the parameter is already"
       echo "set cannot be determined - not guessing either way"
       exit 2 ;;
esac

# Is there a working backlight interface at all?
for b in /sys/class/backlight/*/; do
    [ -e "$b/brightness" ] || continue
    MAX=$(cat "$b/max_brightness" 2>/dev/null || echo 0)
    [ "${MAX:-0}" -gt 0 ] && exit 1      # brightness control exists and works
done
echo "no usable backlight interface found for the Intel panel"
exit 0
