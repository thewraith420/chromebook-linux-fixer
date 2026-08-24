#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
VCM=$("$FIXER_REPO/lib/find-subdev.sh" ak7375) || exit 2
[ -n "$VCM" ] || exit 1          # no VCM on this machine: not applicable

# Test the condition, not our artifact. Keying this off "is the rule file
# present" made an installed-but-ineffective fix report as "not needed",
# which hides a regression instead of surfacing it: the rule can be in place
# while the lens still sits at 0 because the rule never fired, or something
# reset the VCM afterwards. "The file exists" and "the lens is parked
# sensibly" are different questions, and only the second one matters here.
POS=$(v4l2-ctl -d "$VCM" -C focus_absolute 2>/dev/null | grep -oE '[0-9]+$')
[ -n "$POS" ] || exit 2          # control unreadable: cannot tell
[ "$POS" -gt 0 ] && exit 1       # already parked somewhere sensible

echo "VCM at $VCM is parked at 0; no focus default in effect"
exit 0
