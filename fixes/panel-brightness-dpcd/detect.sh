#!/bin/bash
set -uo pipefail
# Only relevant with an Intel panel.
[ -d /sys/module/i915 ] || exit 1
# Already set?
"$FIXER_REPO/lib/kernel-cmdline.sh" active i915.enable_dpcd_backlight=2 && exit 1

# Is there a working backlight interface at all?
for b in /sys/class/backlight/*/; do
    [ -e "$b/brightness" ] || continue
    MAX=$(cat "$b/max_brightness" 2>/dev/null || echo 0)
    [ "${MAX:-0}" -gt 0 ] && exit 1      # brightness control exists and works
done
echo "no usable backlight interface found for the Intel panel"
exit 0
