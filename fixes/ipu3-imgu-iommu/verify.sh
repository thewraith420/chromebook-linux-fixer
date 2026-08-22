#!/bin/bash
set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
[ -d "$IMGU" ] || exit 1
TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo none)
case "$TYPE" in
    identity) echo "ImgU in identity domain (per-device quirk or iommu=pt active)"; exit 0 ;;
    none)     echo "no IOMMU group (IOMMU disabled entirely)"; exit 0 ;;
    *)        exit 1 ;;
esac
