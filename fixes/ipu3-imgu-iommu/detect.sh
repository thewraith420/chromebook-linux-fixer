#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
[ -d "$IMGU" ] || exit 1                        # no IPU3 ImgU on this machine

TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo none)
case "$TYPE" in
    identity|none)
        exit 1 ;;                               # already safe
esac

echo "ImgU sits in a '$TYPE' IOMMU domain; streaming it will hard lock this machine."
if "$FIXER_REPO/lib/kernel-cmdline.sh" active iommu=pt; then
    echo "iommu=pt is already on the running cmdline but the domain is still '$TYPE'"
    echo "- this needs the per-device kernel quirk instead (see kernel/)."
    exit 2
fi
exit 0
