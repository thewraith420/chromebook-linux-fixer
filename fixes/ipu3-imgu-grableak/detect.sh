#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
[ -d /sys/bus/pci/devices/0000:00:05.0 ] || exit 1     # no ImgU

# Already replaced by a DKMS build of ours?
if command -v dkms >/dev/null 2>&1 && \
   dkms status 2>/dev/null | grep -q "ipu3-imgu-fixed"; then
    exit 1
fi

# The leak is observable: pipe_mode reported as 'grabbed' while nothing is
# streaming means the device is wedged right now.
for sd in $("$FIXER_REPO/lib/find-subdev.sh" "ipu3-imgu" 2>/dev/null); do
    if v4l2-ctl -d "$sd" -L 2>/dev/null | grep -q "pipe_mode.*grabbed"; then
        echo "$sd has pipe_mode grabbed with nothing streaming (leaked)"
        exit 0
    fi
done

# Not currently wedged. Whether the running kernel carries the fix cannot be
# determined by inspection, so report 'cannot tell' rather than guessing.
if ! "$FIXER_REPO/lib/dkms-support.sh" >/dev/null 2>&1; then
    exit 2
fi
exit 2
