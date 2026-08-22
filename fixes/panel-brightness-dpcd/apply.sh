#!/bin/bash
set -euo pipefail
"$FIXER_REPO/lib/kernel-cmdline.sh" add i915.enable_dpcd_backlight=2
