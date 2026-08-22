#!/bin/bash
# imgu-safe.sh — is it safe to drive the IPU3 hardware ISP on this machine?
#
#   imgu-safe.sh            exit 0 = safe, 1 = NOT safe, 2 = no ImgU present
#   imgu-safe.sh --why      also explain, and print remediation if unsafe
#
# Driving the ImgU without an IOMMU passthrough domain hard locks the machine.
# Anything that might start the hardware ISP must consult this first.

set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
EXPLAIN=${1:-}

[ -d "$IMGU" ] || exit 2

TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo none)

case "$TYPE" in
    identity|none)
        [ "$EXPLAIN" = --why ] && \
            echo "ImgU is in a '$TYPE' IOMMU domain: hardware ISP is safe to use."
        exit 0
        ;;
esac

if [ "$EXPLAIN" = --why ]; then
cat <<EOF
The IPU3 hardware ISP is NOT safe to use on this kernel.

  ImgU IOMMU domain: $TYPE  (needs 'identity' or no IOMMU)

The staging ipu3-imgu driver programs the ImgU's own MMU with raw physical
addresses, bypassing the DMA API. In a translated domain VT-d re-translates
them, finds no mapping, and the machine hard locks on the first DMA - no
panic, no oops, nothing in any log. A forced power-off is the only way out.

To enable the hardware ISP, do ONE of these:

  1. Kernel quirk (best). Place PCI 8086:1919 in an IOMMU identity domain via
     a per-device quirk. Narrow, needs no boot parameter, correct by default.
     Requires building a kernel. See kernel/README.md.

  2. Boot parameter (works today, no rebuild):
         chromebook-fixer apply ipu3-imgu-iommu
     Adds iommu=pt, which keeps the IOMMU enabled and protecting every other
     device - unlike intel_iommu=off. Needs a reboot.

You do NOT have to do either. The software ISP path needs no kernel changes
and cannot lock the machine, at the cost of CPU and some image quality.
EOF
fi
exit 1
