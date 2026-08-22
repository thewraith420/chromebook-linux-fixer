#!/bin/bash
# Deliberately not automated. Two possible fixes, and the good one is a kernel
# patch this tool has no business applying behind the user's back.
cat <<'MSG'
This fix cannot be applied from userspace.

  Preferred  a per-device IOMMU passthrough quirk for PCI 8086:1919, applied
             in the kernel. No cmdline token, correct by default.
             See kernel/ipu3-imgu-iommu-passthrough.patch in this repo.

  Fallback   add iommu=pt to the kernel command line. Keeps the IOMMU enabled
             and protecting every other device, unlike intel_iommu=off:
               sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&iommu=pt /' \
                 /etc/default/grub && sudo update-grub && reboot

Until one is in place, do NOT install a libcamera built with the ipu3 pipeline
handler. It will hard lock the machine.
MSG
exit 1
