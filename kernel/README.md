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

| patch | what it does | proven on hardware? |
|---|---|---|
| `9200-i915-pixel-slate-aux-backlight.patch` | backlight over DPCD/AUX | yes — diagnosed from live DPCD reads |
| `9201-cros-ec-poll-event-fifo-fallback.patch` | polls the EC event FIFO when its IRQ never fires | yes |
| `9202-ipu3-imgu-fix-pipe_mode-grab-leak.patch` | releases a control the ImgU driver leaks on a failed start | yes |
| `9203-imx319-imx355-nocturne-sensor-orientation.patch` | reports sensor mounting rotation and front/back | yes |
| `9204-iommu-vtd-ipu3-imgu-identity-domain.patch` | puts the ImgU in an IOMMU identity domain | yes |
| `9205-v4l2loopback-in-tree-module.patch` | vendors v4l2loopback 0.15.3 as an in-tree module | yes |
| `9206-hid-google-hammer-null-check.patch` | fixes a NULL deref that crashed on module load | yes — the module blacklist was dropped after |
| `9207-acpi-goog0007-sta-override-nocturne.patch` | forces GOOG0007 present so the volume buttons work | yes |
| `9208-i915-nocturne-disable-psr-dmi-quirk.patch` | disables PSR via DMI quirk instead of `i915.enable_psr=0` | **no — compile-checked only** |

Read that last column before relying on any of these. 9208 has never been
booted; its own commit message is honest about that, and so is this table.
9207's commit message still says "not yet confirmed on real hardware", which
was true when it was written and is now stale — it was confirmed afterwards.

Two of these bear directly on fixes in this repository:

- **9205** builds v4l2loopback into the kernel. `camera-follow-rotation`
  installs `v4l2loopback-dkms` from the distro instead, because it cannot
  assume a kernel that carries the patch. On a kernel that does, the DKMS
  package is redundant — the fix's `modinfo v4l2loopback` check finds the
  in-tree module and skips the install.
- **9207** is the one volume-button failure this repository has no answer for.
  See below.

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

## The volume buttons fail two different ways

Do not conflate these. They have different causes, different symptoms and
different fixes, and each one can hide the other.

**The EC stops delivering.** Its interrupt fires once at boot and never again,
so MKBP events pile up in a FIFO nobody drains. Volume keys, the sensor FIFO
and lid angle all go quiet together, typically after some uptime rather than
immediately. Patch 9201 fixes it in-kernel; `ec-buttons-poll` and
`ec-buttons-dkms` do the same job from userspace and out-of-tree.

**GOOG0007 is hidden.** Firmware reports `_STA = 0` for the ACPI device
`cros_ec_keyb` binds to, so that driver never probes and no volume-button input
device is ever created. Buttons are dead from the first boot after the firmware
changed — on the Pixel Slate, a MrChromebox update (2606.1; 2512.1 was fine).
Patch 9207 forces the status back. **This repository ships no equivalent.**

They interact in a way that is easy to misread:

- Draining the FIFO achieves nothing while GOOG0007 is hidden, because the
  events reach no consumer. A kernel carrying 9201 but not 9207 has healthy
  delivery and dead buttons, and both button fixes here used to report "not
  needed" on exactly that machine — they now check whether `cros-ec-keyb` is
  bound before deferring to the kernel.
- `ec-buttons-poll` masks the GOOG0007 fault by accident. It reads
  `/dev/cros_ec` and injects through uinput, never touching ACPI enumeration
  or `cros_ec_keyb`, so the buttons work and the underlying bug is invisible.

Detecting the GOOG0007 fault has one trap worth writing down:
`/sys/bus/acpi/devices/GOOG0007:00/status` is **not** usable. `status_show()`
in `drivers/acpi/device_sysfs.c` evaluates `_STA` against firmware directly and
never consults `acpi_device_override_status()`, so it reads the same raw `0`
whether or not the running kernel carries 9207. Check whether the driver bound
instead — `/sys/bus/platform/drivers/cros-ec-keyb/GOOG0007:00` — which is what
`lib/ec-buttons.sh` does.

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
