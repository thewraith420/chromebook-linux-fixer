#!/bin/bash
set -uo pipefail

RUNNING=$(uname -r)
TARGET="${FIXER_KERNEL:-$RUNNING}"

if ! "$FIXER_REPO/lib/dkms-support.sh" --kernel "$TARGET" 2>/dev/null; then
    echo "Cannot build for the running kernel ($RUNNING): no usable headers."
    echo
    mapfile -t OK < <("$FIXER_REPO/lib/dkms-support.sh" --list 2>/dev/null)
    if [ ${#OK[@]} -gt 0 ]; then
        echo "These installed kernels CAN be built for:"
        printf '    %s\n' "${OK[@]}"
        echo
        echo "To build for one of them (it will take effect when you boot it):"
        echo "    FIXER_KERNEL=${OK[0]} chromebook-fixer apply $FIX_ID"
    else
        "$FIXER_REPO/lib/dkms-support.sh" --why
    fi
    echo
    echo "Either way, a wedged ImgU can be recovered right now with no build:"
    echo "    sudo sh -c 'echo 0000:00:05.0 > /sys/bus/pci/drivers/ipu3-imgu/unbind'"
    echo "    sudo sh -c 'echo 0000:00:05.0 > /sys/bus/pci/drivers/ipu3-imgu/bind'"
    echo "That clears the leak; it does not stop it recurring."
    exit 1
fi

command -v dkms >/dev/null 2>&1 || {
    echo "dkms is not installed:  sudo apt install dkms"; exit 1; }

SRC="$FIX_DIR/src"
if [ ! -f "$SRC/ipu3-imgu.c" ]; then
    cat <<MSG
The ipu3 driver source for this kernel is not present.

DKMS needs the driver's own source, which the headers package does not carry.
Fetch it for the target kernel, e.g. on Debian/Ubuntu:

    apt-get source linux-image-unsigned-$TARGET
    cp -r <srcdir>/drivers/staging/media/ipu3/* "$SRC/"

then re-run this fix. The patch in patches/ applies against that source.
MSG
    exit 1
fi

BUILDER="$FIX_DIR/build-dkms.sh"
if [ ! -x "$BUILDER" ]; then
    echo "The DKMS build step is not implemented yet ($BUILDER is missing)."
    echo "Source is present, headers are usable - what remains is packaging the"
    echo "driver as a DKMS module and registering it."
    exit 1
fi

echo "Building patched ipu3-imgu for $TARGET via DKMS..."
exec "$BUILDER" "$TARGET"
