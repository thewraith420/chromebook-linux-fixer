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

## Status

The patches themselves are **not yet included in this repository.** They were
developed and are maintained on a separate kernel build machine, as commits
against a `BobZKernel` tree:

- **9202** — `ipu3-imgu`: fix `pipe_mode` grab leak. `imgu_vb2_start_streaming()`
  grabs the control, then returns 0 even when `imgu_s_stream()` failed, so
  `imgu->streaming` stays false and the ungrab in the stop path never runs. The
  device is then wedged for the rest of the session and reports `EBUSY`.
- **9204** — `ipu3-imgu`: place the device in an IOMMU identity domain via a
  per-device quirk, because the driver programs its MMU with raw physical
  addresses and cannot work in a translated domain. Without this, streaming the
  ImgU hard locks the machine. **This must be carried forever on any
  mainline-derived kernel** — the equivalent upstream patch was *rejected*, so
  mainline will not grow one. Ubuntu ships it as SAUCE, which is why stock
  Ubuntu kernels need no quirk of their own. Full history, the upstream diff,
  and the maintainer's objection:
  [`ipu3-imgu-iommu-upstream-reference.md`](ipu3-imgu-iommu-upstream-reference.md).
- DMI quirk exposing camera sensor rotation and front/back orientation for
  machines whose firmware omits the ChromeOS SSDB table.

To contribute them here, export as `git format-patch` output and drop them in
this directory named after the fix id, e.g.
`ipu3-imgu-iommu-passthrough.patch`. The detect scripts do not depend on the
files being present — they test the running kernel's actual behaviour, which is
the more reliable signal anyway.

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
