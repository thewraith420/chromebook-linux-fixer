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

They are maintained on a separate kernel build machine and published in
**[BobZKernel](https://github.com/thewraith420/BobZKernel)**, branch
`pixel-slate`, under `patches/cachyos-7.1/`:

| patch | what it does |
|---|---|
| `9200-i915-pixel-slate-aux-backlight.patch` | backlight over DPCD/AUX |
| `9201-cros-ec-poll-event-fifo-fallback.patch` | polls the EC event FIFO when its IRQ never fires |
| `9202-ipu3-imgu-fix-pipe_mode-grab-leak.patch` | releases a control the ImgU driver leaks on a failed start |
| `9203-imx319-imx355-nocturne-sensor-orientation.patch` | reports sensor mounting rotation and front/back |
| `9204-iommu-vtd-ipu3-imgu-identity-domain.patch` | puts the ImgU in an IOMMU identity domain |

**[nocturne-ipu3-camera](https://github.com/thewraith420/nocturne-ipu3-camera)**
carries the camera ones again as standalone patches, alongside the libcamera
changes and a write-up of how the IOMMU problem was found.

**9204 is load-bearing and permanent.** The staging `ipu3-imgu` driver programs
its MMU with raw physical addresses, so in a translated domain the machine hard
locks on the first DMA - no panic, nothing in the logs. The equivalent upstream
patch was *rejected* (see
[`ipu3-imgu-iommu-upstream-reference.md`](ipu3-imgu-iommu-upstream-reference.md)),
so mainline will never grow one and this must survive every rebase.

Stock Ubuntu kernels are unaffected: they carry a SAUCE quirk that does the same
job, which is why this fix reports "not needed" there.

## Why 9201 is not offered as a fix here

The fixes in this repository deliberately avoid requiring a kernel rebuild.
Where a kernel patch is the tidier answer, the fix ships the userspace or
out-of-tree equivalent instead:

- `ec-buttons-poll` polls the EC from userspace - no kernel changes at all.
- `ec-buttons-dkms` builds the same logic as an out-of-tree module.

Both do 9201's job on a kernel that lacks it. The kernel patch is better where
you already build your own kernel; these exist so you do not have to.

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
