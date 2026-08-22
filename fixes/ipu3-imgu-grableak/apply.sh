#!/bin/bash
set -uo pipefail

if ! "$FIXER_REPO/lib/dkms-support.sh" >/dev/null 2>&1; then
    echo "Cannot build an out-of-tree module on this machine yet."
    echo
    "$FIXER_REPO/lib/dkms-support.sh" --why
    echo
    echo "Meanwhile, a wedged ImgU can be recovered without any build:"
    echo "    sudo sh -c 'echo 0000:00:05.0 > /sys/bus/pci/drivers/ipu3-imgu/unbind'"
    echo "    sudo sh -c 'echo 0000:00:05.0 > /sys/bus/pci/drivers/ipu3-imgu/bind'"
    echo "or simply reboot. That clears the leak; it does not stop it recurring."
    exit 1
fi

echo "Building a patched ipu3-imgu via DKMS is not implemented yet."
echo "The driver source must be obtained for this exact kernel before the"
echo "patch can be applied and built. See kernel/README.md."
exit 1
