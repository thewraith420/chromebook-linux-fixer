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

# Not currently wedged, and that is as far as inspection reaches. The leak is
# latent: pipe_mode is only stranded once a stream start has actually failed,
# so a clean reading is equally consistent with a kernel carrying the fix and
# one that simply has not failed a start yet. Nothing distinguishes them - the
# fix releases a control on an error path, and an error path that has not run
# leaves nothing behind to observe. A version test would answer confidently and
# be wrong, which is worse than this.
#
# So the answer stays 2. What changes is that it now says so: this used to call
# dkms-support.sh, discard the result, and exit 2 down both arms of an if, so
# "unknown" appeared in status with no reason attached and no way to tell the
# fix was working as intended rather than broken.
#
# Only the first two lines reach the status listing, so they carry the point.
echo "not leaked right now, but a clean reading proves nothing: pipe_mode is"
echo "only stranded after a failed stream start, which may not have happened yet"
if "$FIXER_REPO/lib/dkms-support.sh" --kernel "$(uname -r)" >/dev/null 2>&1; then
    echo "The replacement module can be built for $(uname -r) if you want it anyway."
else
    echo "The replacement module cannot be built for $(uname -r) as things stand;"
    echo "  $FIXER_REPO/lib/dkms-support.sh --why $(uname -r)"
    echo "says what is missing."
fi
exit 2
