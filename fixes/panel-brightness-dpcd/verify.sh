#!/bin/bash
set -uo pipefail
"$FIXER_REPO/lib/kernel-cmdline.sh" active i915.enable_dpcd_backlight=2 || exit 1
echo "DPCD backlight control enabled on the kernel cmdline"
