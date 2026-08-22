#!/bin/bash
set -uo pipefail
RULE=/etc/udev/rules.d/99-chromebook-vcm-focus.rules
[ -e "$RULE" ] || exit 1
VCM=$("$FIXER_REPO/lib/find-subdev.sh" ak7375) || exit 1
[ -n "$VCM" ] || exit 1
POS=$(v4l2-ctl -d "$VCM" -C focus_absolute 2>/dev/null | grep -oE '[0-9]+$')
[ -n "$POS" ] && [ "$POS" -gt 0 ] || exit 1
echo "rule installed, lens at position $POS"
