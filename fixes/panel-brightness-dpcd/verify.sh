#!/bin/bash
# exit 0 = this fix is in place, 1 = it is not
set -uo pipefail
"$FIXER_REPO/lib/kernel-cmdline.sh" active i915.enable_dpcd_backlight=2
case $? in
    0) echo "DPCD backlight control enabled on the kernel cmdline" ;;
    # Falls through to detect, which reports 'cannot tell' for the same reason.
    # Claiming "not applied" here would invite re-adding a parameter that may
    # already be present.
    2) exit 1 ;;
    *) exit 1 ;;
esac
