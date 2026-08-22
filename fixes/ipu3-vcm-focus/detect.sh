#!/bin/bash
# exit 0 = fix is needed, 1 = not needed, 2 = cannot tell
set -uo pipefail
VCM=$("$FIXER_REPO/lib/find-subdev.sh" ak7375) || exit 2
[ -n "$VCM" ] || exit 1          # no VCM on this machine: not applicable
[ -e /etc/udev/rules.d/99-chromebook-vcm-focus.rules ] && exit 1
echo "VCM present at $VCM with no focus default configured"
exit 0
