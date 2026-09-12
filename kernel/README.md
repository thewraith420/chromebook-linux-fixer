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

Two of these bear directly on fixes in this repository:

- **9205** builds v4l2loopback into the kernel. Nothing in this repository
  needs it any more: the fix that did, `camera-follow-rotation`, was removed
  once the camera rotation problem was settled a different way (see
  `display-autorotate`, which pins the screen to landscape while a camera app
  is open instead of rotating the image). 9205 still earns its place for
  Waydroid's external-camera HAL, which wants a plain V4L2 device the IPU3
  nodes cannot provide.
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
immediately. Patch 9201 fixes it in-kernel; `ec-buttons-poll` does the same
job from userspace.

**GOOG0007 is hidden.** Firmware reports `_STA = 0` for the ACPI device
`cros_ec_keyb` binds to, so that driver never probes and no volume-button input
device is ever created. Buttons are dead from the first boot after the firmware
changed — on the Pixel Slate, a MrChromebox update (2606.1; 2512.1 was fine).
Patch 9207 forces the status back. **This repository ships no equivalent.**

They interact in a way that is easy to misread:

- Draining the FIFO achieves nothing while GOOG0007 is hidden, because the
  events reach no consumer. A kernel carrying 9201 but not 9207 has healthy
  delivery and dead buttons, and the button fixes here used to report "not
  needed" on exactly that machine — they now check whether `cros-ec-keyb` is
  bound before deferring to the kernel.

  This is what retired the out-of-tree module. `ec-buttons-dkms` shipped the
  same drain as 9201 as a DKMS module; on 2026-09-05 it was applied on a stock
  kernel with GOOG0007 hidden, reported itself installed, and restored nothing,
  because there was no `cros_ec_keyb` to receive what it drained. Its other
  selling points did not save it either — `cros-ec-accel`/`cros-ec-gyro` read
  fine on demand over the synchronous command path with no drain at all, and
  the lid switch is an ACPI device, not MKBP. It was removed; `ec-buttons-poll`
  is the fix that works on a stock kernel.
- `ec-buttons-poll` masks the GOOG0007 fault by accident. It reads
  `/dev/cros_ec` and injects through uinput, never touching ACPI enumeration
  or `cros_ec_keyb`, so the buttons work and the underlying bug is invisible.

### Why there is no userspace fix for GOOG0007, and why none is needed

9201 has a userspace equivalent. 9207 cannot have one at all — no userspace
change makes the ACPI core enumerate a device firmware calls absent. What
follows is why the obvious attempts fail, and why the gap still closes.

The ACPI route does not work. `_STA` for this device lives at
`\_SB_.PCI0.LPCB.EC0_.CREC.CKSC` (read straight out of
`/sys/bus/acpi/devices/GOOG0007:00/path`, no `acpidump` needed). Injecting a
supplementary SSDT via the initrd is the usual no-kernel-rebuild trick and the
kernel supports it here — `CONFIG_ACPI_TABLE_UPGRADE=y`. It still fails:
an SSDT can *add* namespace objects, not *replace* existing ones, and a table
redefining a name that already exists is rejected rather than honoured. That
`_STA` demonstrably exists — a device with no `_STA` defaults to present, so
if there were none there would be no bug. Overriding it therefore means
replacing the whole DSDT, which has to be redone after every firmware update
and, on a machine whose default boot entry is a kexec picker, turns a
decompile-recompile mistake into a machine that does not boot.

`CONFIG_ACPI_CONFIGFS=m` allows loading a table at runtime, which would fit
this repo's systemd-service pattern far better, but almost certainly too late:
Linux does not re-walk the namespace or re-evaluate `_STA` for devices it has
already skipped, so a correction after boot arrives after the decision it
would change. Untested here, and not worth testing given the SSDT limitation
above applies either way.

**The enumeration stays broken, and the buttons still work.** `ec-buttons-poll`
reads `/dev/cros_ec` and injects through uinput, never touching ACPI
enumeration or `cros_ec_keyb`, so it restores volume keys under either fault.
It only has to be willing to offer itself, which is what the detection below
is for. That is a symptom fix, not a cure: GOOG0007 is still hidden, nothing
else that wants `cros_ec_keyb` gets it, and on a stock kernel that is the best
available. The kernel patch remains the real answer where you build your own
kernel — it matches on the resolved HID and survives firmware reshuffling,
where any namespace-path override would silently stop applying.

Detecting the GOOG0007 fault has one trap worth writing down:
`/sys/bus/acpi/devices/GOOG0007:00/status` is **not** usable. `status_show()`
in `drivers/acpi/device_sysfs.c` evaluates `_STA` against firmware directly and
never consults `acpi_device_override_status()`, so it reads the same raw `0`
whether or not the running kernel carries 9207. This is not a theory: the
reference Slate runs 9207, its volume buttons work, `cros-ec-keyb` is bound to
`GOOG0007:00` — and that file still reads `0`.

Ask enumeration instead, which is what `lib/ec-buttons.sh` does. A bound
driver — `/sys/bus/platform/drivers/cros-ec-keyb/GOOG0007:00` — proves the
path works, but its absence proves little, because a modular `cros_ec_keyb`
that never loaded looks identical to one that could not bind. So it falls back
to `/sys/bus/acpi/devices/GOOG0007:00/physical_node`: the platform device the
ACPI core creates only for a node it considers present. Absent means firmware
hid it and no driver could ever have bound.

That fallback is safe for the same reason `status` is not. `status_show()`
calls `acpi_evaluate_integer(..., "_STA", ...)` and goes straight to firmware,
while enumeration runs through `acpi_bus_get_status()`, which calls
`acpi_device_override_status()` first and returns early when a quirk matches
(`drivers/acpi/bus.c:100`). One path sees the kernel's override; the other
never can.

## Why 9201 is not offered as a fix here

The fixes in this repository deliberately avoid requiring a kernel rebuild.
Where a kernel patch is the tidier answer, the fix ships the userspace or
out-of-tree equivalent instead:

- `ec-buttons-poll` polls the EC from userspace - no kernel changes at all.

That does 9201's job on a kernel that lacks it. The kernel patch is better
where you already build your own kernel; this exists so you do not have to.
An out-of-tree DKMS module (`ec-buttons-dkms`) used to offer 9201's drain
without a rebuild, but a drain is only half the path: it needs 9207's
enumeration fix to have any consumer, so on the firmware that hides GOOG0007
it could not restore a button. Removed in favour of the userspace poll, which
sidesteps the enumeration problem entirely.

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
