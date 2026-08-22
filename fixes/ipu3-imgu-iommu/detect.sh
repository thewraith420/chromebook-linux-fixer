#!/bin/bash
# Needed when an IPU3 ImgU exists but is NOT in a passthrough domain.
set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
[ -d "$IMGU" ] || exit 1                       # no ImgU: not applicable
grep -qi "8086.*1919" "$IMGU/uevent" 2>/dev/null || \
  [ -e "$IMGU/driver/module/drivers/pci:ipu3-imgu" ] || exit 1

TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo "none")
case "$TYPE" in
    identity|none)
        exit 1 ;;                              # already safe
    *)
        echo "ImgU is in a '$TYPE' IOMMU domain — streaming it will HARD LOCK this machine"
        echo "Fix is kernel-side: per-device passthrough quirk for 8086:1919, or iommu=pt"
        exit 0 ;;
esac
