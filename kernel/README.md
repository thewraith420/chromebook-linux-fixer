# Kernel patches

Fixes that require changing the kernel itself, rather than a boot parameter or
a userspace file.

**Nothing here is applied automatically.** Building and installing a kernel is
not something this tool does behind your back. These patches are shipped so the
fix is reproducible, and so `chromebook-fixer` can *detect* whether a running
kernel already carries them.

## Why a patch rather than a boot parameter

Several problems have both a kernel-side fix and a cmdline workaround. The
cmdline route is what `apply` can do; the patch is usually the better answer:

| Problem | cmdline workaround | kernel fix |
|---|---|---|
| IPU3 ImgU hard lockup | `iommu=pt` (global) | per-device passthrough quirk for `8086:1919` |
| Sensor mounting rotation absent | env overrides in userspace | DMI quirk exposing `V4L2_CID_CAMERA_SENSOR_ROTATION` |

The kernel fix is narrower — a per-device quirk changes IOMMU behaviour for one
device rather than the whole system, and a DMI quirk makes every libcamera
consumer work rather than just the one configured by hand.

## Where the patches live

They are maintained on a separate kernel build machine, and published:

**[nocturne-ipu3-camera](https://github.com/thewraith420/nocturne-ipu3-camera)**
carries the camera-side kernel work as standalone patches, plus the
libcamera changes and a write-up of how the IOMMU problem was found:

- `kernel/9202-ipu3-imgu-fix-pipe_mode-grab-leak.patch`
- `kernel/9203-imx319-imx355-nocturne-sensor-orientation.patch`
- `kernel/9204-iommu-vtd-ipu3-imgu-identity-domain.patch`
- `userspace/libcamera-nocturne-ipu3.patch`

**[BobZKernel](https://github.com/thewraith420/BobZKernel)**, branch
`pixel-slate`, is the kernel build itself:

- `patches/cachyos-7.1/9200-i915-pixel-slate-aux-backlight.patch`

**Not yet published: 9201**, the EC event FIFO poll. It is in the built
kernel - `/sys/module/cros_ec/parameters/ec_event_poll_ms` exists and its help
text describes it as a fallback for when the EC event IRQ never fires - but the
patch is not committed to either repository. It is what makes the volume
buttons work on this hardware, and the reason `ec-buttons-poll` and
`ec-buttons-dkms` in this repo exist for kernels that lack it.

Note that the `pixel-slate` branch is not self-contained: the camera patches
above are applied from elsewhere, so building that branch alone does not
reproduce the running kernel.

## Detecting rather than assuming

Every kernel fix here is detected by observing the running system, not by
checking a version number:

```bash
# is the ImgU in a domain where DMA will work?
cat /sys/bus/pci/devices/0000:00:05.0/iommu_group/type    # identity = good

# does the sensor report its mounting rotation?
v4l2-ctl -d "$(lib/find-subdev.sh imx319)" -L | grep camera_sensor_rotation
```

Version checks lie: a distro can backport a fix, a local build can omit one, and
`uname -r` tells you nothing about either.
